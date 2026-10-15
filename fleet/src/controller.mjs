import {randomBytes,randomUUID} from 'node:crypto';
import {canonical,digest,fields,identifier,integer,requireThat,sha256} from './canonical.mjs';
import {validateConfig,validateGrant,requiredHosts} from './policy.mjs';
import {verifyGoogleToken,verifyHardwareSignature} from './auth.mjs';
import {recipient,unwrapKey} from './crypto.mjs';
import {ArtifactStore} from './artifacts.mjs';
import {body,json,send,bearer,guarded} from './http.mjs';

export function createController({config,store,artifactRoot,provider,collector,clock=()=>Math.floor(Date.now()/1000),identity=t=>verifyGoogleToken(t,{audience:config.audience}),signature=verifyHardwareSignature}) {
  validateConfig(config);const broker=recipient(),keys=new Map(),artifacts=new ArtifactStore(artifactRoot,config.maxArtifactBytes);let reconciling=false;
  const admin=claims=>requireThat(config.adminSubjects.includes(claims.sub),'admin subject rejected');
  const worker=async(claims,name)=>{requireThat(claims.sub===config.workerSubject,'worker subject rejected');identifier(name);const host=store.hosts().find(h=>h.id===name);requireThat(host,'unknown worker host');await provider.verifyHost(name,host.zone,claims);return host;};
  async function control(payload,claims){admin(claims);const p=payload.manifest;fields(p,['schema','operation','grantID','nonce','issuedAt','expiresAt','configDigest','brokerKeyDigest','keyEnvelope']);requireThat(p.schema===1&&p.configDigest===digest(config)&&p.expiresAt>clock()&&p.expiresAt<=clock()+300&&p.issuedAt<=clock()+30&&p.issuedAt>=clock()-300,'invalid control transaction');await signature(canonical(p),payload.signature,config.hardwarePublicKey);store.consumeChallenge(p.nonce,claims.sub,clock());return p;}
  const handler=guarded(async(req,res)=>{
    const url=new URL(req.url,'https://controller.invalid');const path=url.pathname,now=clock();
    if(path==='/healthz'){send(res,200,{ok:true});return;}
    const claims=await identity(bearer(req));
    if(req.method==='GET'&&path==='/v1/config'){admin(claims);send(res,200,{config,configDigest:digest(config)});return;}
    if(req.method==='POST'&&path==='/v1/challenges'){admin(claims);const nonce=randomBytes(32).toString('base64url');store.challenge(nonce,claims.sub,now+300);send(res,200,{nonce,publicKey:broker.publicKey,configDigest:digest(config),at:now});return;}
    if(req.method==='POST'&&path==='/v1/grants'){
      admin(claims);const value=await json(req);fields(value,['manifest','signature']);const g=validateGrant(value.manifest,config,now);requireThat(g.brokerKeyDigest===digest(broker.publicKey),'wrong broker recipient');await signature(canonical(g),value.signature,config.hardwarePublicKey);await artifacts.get(g.sourceDigest);const key=unwrapKey(g.keyEnvelope,broker.privateKey,g.id);store.authorize(g,claims.sub,now,config.maxFleetMicros);keys.set(g.id,key);send(res,201,{grant:g.id});return;
    }
    if(req.method==='POST'&&path==='/v1/control'){
      const value=await json(req),p=await control(value,claims);
      switch(p.operation){case 'revoke':store.revoke(p.grantID,now);keys.get(p.grantID)?.fill(0);keys.delete(p.grantID);break;
        case 'pause':store.setPaused(true,now);break;case 'resume':store.setPaused(false,now);break;
        case 'unlock':{const g=store.active(p.grantID,now);requireThat(p.brokerKeyDigest===digest(broker.publicKey),'wrong broker recipient');keys.set(g.id,unwrapKey(p.keyEnvelope,broker.privateKey,g.id));break;}
        default:throw new Error('unknown control operation');}
      send(res,200,{ok:true});return;
    }
    if(req.method==='GET'&&path==='/v1/tasks'){admin(claims);send(res,200,{tasks:store.tasks()});return;}
    if(req.method==='POST'&&path==='/v1/tasks'){admin(claims);const b=await json(req);fields(b,['grantId','count']);send(res,201,{tasks:store.submit(b.grantId,b.count,now)});return;}
    if(req.method==='GET'&&path==='/v1/hosts'){admin(claims);send(res,200,{hosts:store.hosts()});return;}
    if(req.method==='POST'&&path==='/v1/reconcile'){admin(claims);await reconcile();send(res,200,{ok:true});return;}
    if(path==='/v1/hosts/register'&&req.method==='POST'){
      requireThat(claims.sub===config.workerSubject,'worker subject rejected');const b=await json(req);fields(b,['name','zone']);identifier(b.name);requireThat(config.zones.includes(b.zone),'wrong zone');const h=store.hosts().find(h=>h.name===b.name);requireThat(h&&h.zone===b.zone&&['provisioning','ready'].includes(h.state),'host not provisioned by fleet');await provider.verifyHost(b.name,b.zone,claims);store.host({...h,state:'ready',cpus:config.hostCPUs,memoryMiB:config.hostMemoryMiB},now);send(res,200,{host:b.name});return;
    }
    if(path==='/v1/hosts/poll'&&req.method==='POST'){
      const b=await json(req);fields(b,['host']);const h=await worker(claims,b.host);store.host(h,now);store.expire(now);
      if(store.paused()||!collector){send(res,200,{task:null,paused:true});return;}
      const lease=store.lease(h.id,config,now,new Set(keys.keys()));if(!lease){send(res,200,{task:null});return;}
      const key=keys.get(lease.grant.id);if(!key){store.lose(lease.id,'broker locked',now);send(res,200,{task:null,locked:true});return;}
      send(res,200,{task:{...lease,key:key.toString('base64')}});return;
    }
    if(path==='/v1/inference/authorize'&&req.method==='POST'){
      requireThat(claims.sub===config.gatewaySubject,'gateway subject rejected');const b=await json(req);fields(b,['task','capability','model','vendor']);const g=store.reserveInference(b.task,b.capability,b.model,b.vendor,now);send(res,200,{maxOutputTokens:g.maxOutputTokens,grant:g.id});return;
    }
    if(path==='/v1/egress/authorize'&&req.method==='POST'){requireThat(claims.sub===config.gatewaySubject,'gateway subject rejected');const b=await json(req);fields(b,['task','capability','bytes']);send(res,200,store.reserveEgress(b.task,b.capability,b.bytes,config,now));return;}
    const match=path.match(/^\/v1\/tasks\/(task-[a-z0-9-]+)(?:\/(heartbeat|finish|logs|input|source|artifact|key))?$/);
    if(match){const id=match[1],action=match[2],t=store.task(id);requireThat(t,'unknown task');
      if(config.adminSubjects.includes(claims.sub)){
        if(req.method==='GET'&&!action){send(res,200,{task:t,grant:store.grant(t.grant_id)});return;}
        if(req.method==='GET'&&action==='logs'){const after=Number(url.searchParams.get('after')??-1);integer(after,-1,Number.MAX_SAFE_INTEGER,'log cursor');send(res,200,{logs:store.logs(id,after),state:t.state});return;}
        if(req.method==='POST'&&action==='input'){requireThat(t.state==='running','task is not running');const b=await json(req,65536);requireThat(typeof b.data==='string'&&b.data.length<=32768,'input too large');store.input(id,b.data);send(res,200,{ok:true});return;}
      }else{
        const h=await worker(claims,req.headers['x-sim-host']);const generation=Number(req.headers['x-sim-generation']);store.owned(id,h.id,generation,now);
        if(req.method==='POST'&&action==='heartbeat'){store.renew(id,h.id,generation,config,now);send(res,200,{input:store.takeInput(id)});return;}
        if(req.method==='GET'&&action==='source'){const g=store.active(t.grant_id,now);res.writeHead(200,{'content-type':'application/octet-stream'});res.end(await artifacts.get(g.sourceDigest));return;}
        if(req.method==='PUT'&&action==='artifact'){const bytes=await body(req,config.maxArtifactBytes);const hash=digest(bytes);await artifacts.put(hash,bytes);send(res,201,{digest:hash});return;}
        if(req.method==='POST'&&action==='logs'){const b=await json(req,config.maxLogBytes);fields(b,['seq','data']);integer(b.seq,0,1000000,'log sequence');requireThat(typeof b.data==='string'&&b.data.length<=262144,'log segment too large');requireThat(collector,'audit collector unavailable');await collector.append({task:id,seq:b.seq,data:b.data,grant:t.grant_id,host:h.id,generation},now);store.appendLog(id,b.seq,b.data,config.maxLogBytes);send(res,201,{ok:true});return;}
        if(req.method==='POST'&&action==='finish'){const b=await json(req);fields(b,['exitCode','result']);integer(b.exitCode,0,255,'exit code');if(b.result){sha256(b.result.digest);await artifacts.get(b.result.digest);}store.finish(id,h.id,generation,b.exitCode,b.result,now);send(res,200,{ok:true});return;}
      }
    }
    const artifact=path.match(/^\/v1\/artifacts\/([a-f0-9]{64})$/);
    if(artifact){admin(claims);if(req.method==='PUT'){await artifacts.put(artifact[1],await body(req,config.maxArtifactBytes));send(res,201,{digest:artifact[1]});return;}if(req.method==='GET'){res.writeHead(200,{'content-type':'application/octet-stream'});res.end(await artifacts.get(artifact[1]));return;}}
    send(res,404,{error:'unknown route'});
  });
  async function reconcile(){if(reconciling)return;reconciling=true;try{
    const now=clock();store.expire(now);
    for(const g of store.grants())if(g.revoked||g.expiresAt<=now){keys.get(g.id)?.fill(0);keys.delete(g.id);for(const h of store.hosts().filter(h=>h.grantID===g.id&&h.state!=='deleted'))store.setHostState(h.id,'draining');}
    if(provider)for(const h of store.hosts()){
      if(h.state==='provisioning'&&h.created+900<=now)store.setHostState(h.id,'draining');
      if(h.state==='draining'||(h.state==='provisioning'&&h.created+900<=now)){
        try{await provider.remove(h);store.setHostState(h.id,'deleted');}catch{store.event('host.delete.retry',{host:h.id},now);}
      }else if(h.state==='provisioning'){
        try{await provider.create(h);}catch{store.event('host.create.retry',{host:h.id},now);}
      }
    }
    if(!provider||store.paused()||!collector)return;
    for(const g of store.grants().filter(g=>!g.revoked&&g.expiresAt>now&&keys.has(g.id))){
      const tasks=store.tasks().filter(t=>t.grant_id===g.id&&['queued','running'].includes(t.state));let hosts=store.hosts().filter(h=>h.grantID===g.id&&!['deleted','draining'].includes(h.state));
      const desired=tasks.length?Math.min(g.maxHosts,requiredHosts(config,g.profile,Math.min(tasks.length,g.maxAgents))):0;
      while(hosts.length<desired&&store.hosts().filter(h=>h.state!=='deleted').length<config.maxHosts){
        const h={id:'sim-'+randomUUID(),name:'',zone:config.zones[hosts.length%config.zones.length],grantID:g.id,expiresAt:g.expiresAt,state:'provisioning',cpus:config.hostCPUs,memoryMiB:config.hostMemoryMiB,requestID:randomUUID()};h.name=h.id;store.host(h,now);try{await provider.create(h);}catch{store.event('host.create.retry',{host:h.id},now);}hosts.push(h);
      }
      for(const h of hosts){if(tasks.some(t=>t.host===h.id&&t.state==='running')||h.idleSince+config.idleSeconds>now)continue;if(hosts.length<=desired)break;store.setHostState(h.id,'draining');try{await provider.remove(h);store.setHostState(h.id,'deleted');}catch{store.event('host.delete.retry',{host:h.id},now);}hosts=hosts.filter(x=>x.id!==h.id);}
    }
  }finally{reconciling=false;}}
  handler.reconcile=reconcile;return handler;
}
