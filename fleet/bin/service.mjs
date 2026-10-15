#!/usr/bin/env node
import {readFile,mkdir,stat} from 'node:fs/promises';
import {createServer} from 'node:https';
import {join} from 'node:path';
import {Store} from '../src/store.mjs';
import {validateConfig} from '../src/policy.mjs';
import {requireThat} from '../src/canonical.mjs';
import {verifyGoogleToken} from '../src/auth.mjs';
import {GCPProvider,identityToken,metadataValue} from '../src/gcp.mjs';
import {createController} from '../src/controller.mjs';
import {createGateway,openaiFederation} from '../src/gateway.mjs';
import {AuditCollector,GCSStorage} from '../src/audit.mjs';
import {APIClient} from '../src/client.mjs';
import {attachEgress} from '../src/egress.mjs';
import {Worker} from '../src/worker.mjs';
import {SBXRuntime} from '../src/runtime.mjs';
import {bearer,guarded,json,send} from '../src/http.mjs';

async function start(){
  requireThat(Number(process.versions.node.split('.')[0])===24,'Node 24 is required');
  const file=process.argv[2];requireThat(file,'usage: service.mjs SERVICE.json');
  const settings=JSON.parse(await readFile(file,'utf8'));const config=validateConfig(JSON.parse(await readFile(settings.policy,'utf8')));
  const ca=await readFile(settings.ca);const state=settings.state??'/var/lib/sim-fleet';await mkdir(state,{recursive:true,mode:0o700});
  const api=new APIClient({url:config.controllerURL,ca,token:()=>identityToken(config.audience)});
  let handler,store,timer,worker;
  const identity=async token=>{const payload=JSON.parse(Buffer.from(token.split('.')[1],'base64url'));return verifyGoogleToken(token,{audience:config.adminSubjects.includes(payload.sub)?config.adminAudience??config.audience:config.audience});};
  if(settings.role==='worker'){
    const runtime=new SBXRuntime({config});await runtime.preflight();
    const host=(await metadataValue('instance/name')).trim();const zone=(await metadataValue('instance/zone')).trim().split('/').at(-1);
    await api.request('/v1/hosts/register',{method:'POST',body:{name:host,zone}});
    worker=new Worker({config,api,runtime,host,root:settings.scratch??'/run/sim-worker'});
    let polling=false;timer=setInterval(async()=>{if(polling)return;polling=true;try{await worker.tick();}catch(e){process.stderr.write('worker poll failed: '+e.message+'\n');}finally{polling=false;}},1000);
    const stop=()=>{clearInterval(timer);worker.stop();};process.once('SIGTERM',stop);process.once('SIGINT',stop);return;
  }
  if(settings.role==='reaper'){
    const provider=new GCPProvider({config});for(const host of await provider.list()){const expires=Number(host.labels?.['sim-expires-at']);if(Number.isSafeInteger(expires)&&expires>0&&expires<Math.floor(Date.now()/1000))await provider.remove(host);}return;
  }
  requireThat(settings.cert&&settings.key,'service TLS certificate and key paths required');
  requireThat(((await stat(settings.key)).mode&0o077)===0,'TLS key must be private to service user');
  const credentials={cert:await readFile(settings.cert),key:await readFile(settings.key),minVersion:'TLSv1.3'};
  if(settings.role==='controller'){
    store=new Store(join(state,'controller.sqlite'));const collectorAPI=new APIClient({url:settings.collectorURL,ca,token:()=>identityToken(config.audience)});
    const collector={append:(record,at)=>collectorAPI.request('/v1/audit',{method:'POST',body:{record,at}})};
    handler=createController({config,store,artifactRoot:join(state,'artifacts'),identity,provider:new GCPProvider({config}),collector});
    timer=setInterval(()=>handler.reconcile().catch(e=>process.stderr.write('fleet reconcile failed: '+e.message+'\n')),10000);
  }else if(settings.role==='gateway'){
    const openaiToken=settings.openaiProviderID?openaiFederation({providerID:settings.openaiProviderID,serviceAccountID:settings.openaiServiceAccountID}):settings.openaiKeyFile?async()=>(await readFile(settings.openaiKeyFile,'utf8')).trim():undefined;
    const anthropicToken=settings.anthropicKeyFile?async()=>(await readFile(settings.anthropicKeyFile,'utf8')).trim():undefined;
    handler=createGateway({config,authorize:payload=>api.request('/v1/inference/authorize',{method:'POST',body:payload}),openaiToken,anthropicToken,vertexProject:settings.vertexProject,vertexRegion:settings.vertexRegion});
  }else if(settings.role==='collector'){
    store=new Store(join(state,'collector.sqlite'));const collector=new AuditCollector({store,storage:new GCSStorage(settings.bucket),maxLogBytes:config.maxLogBytes});
    handler=guarded(async(req,res)=>{if(req.url==='/healthz'){send(res,200,{ok:true});return;}const claims=await identity(bearer(req));requireThat(claims.sub===settings.controllerSubject,'collector subject rejected');requireThat(req.method==='POST'&&req.url==='/v1/audit','unknown route');const b=await json(req,524288);send(res,201,await collector.append(b.record,b.at));});
  }else throw new Error('unknown service role');
  const server=createServer(credentials,handler);if(settings.role==='gateway')attachEgress(server,{config,authorize:payload=>api.request('/v1/egress/authorize',{method:'POST',body:payload})});server.requestTimeout=30000;server.headersTimeout=15000;server.maxHeadersCount=50;server.listen(settings.port,settings.bind??'0.0.0.0');
  const stop=()=>{clearInterval(timer);server.close(()=>{store?.close();process.exitCode=0;});};process.once('SIGTERM',stop);process.once('SIGINT',stop);
}
start().catch(error=>{process.stderr.write('sim service: '+error.message+'\n');process.exitCode=1;});
