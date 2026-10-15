import {readFile,writeFile,mkdir,mkdtemp,rm,cp,readdir} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {randomBytes,randomUUID,X509Certificate,publicEncrypt,constants} from 'node:crypto';
import {canonical,digest,integer,identifier,requireThat} from './canonical.mjs';
import {validateConfig,requiredHosts,canonicalCost,validateGrant} from './policy.mjs';
import {APIClient} from './client.mjs';
import {run} from './process.mjs';
import {seal,open,wrapKey} from './crypto.mjs';
import {packDirectory,extractBundle} from './artifacts.mjs';

const options=['--config','--ca','--connect','--count','--profile','--seconds','--budget-micros','--repo','--vendor','--model','--owner-cert','--grant','--state','--out','--task','--max-requests','--max-output-tokens'];
export function parseArgs(args,allowed=options){const result={positionals:[],values:{},remainder:[]};for(let i=0;i<args.length;i++){const a=args[i];if(a==='--'){result.remainder=args.slice(i+1);break;}if(a.startsWith('--')){requireThat(allowed.includes(a)&&i+1<args.length&&!Object.hasOwn(result.values,a),'unknown, repeated or missing option: '+a);result.values[a]=args[++i];}else result.positionals.push(a);}return result;}
export function plan(config,{count,profile,seconds,maxCostMicros}){validateConfig(config);integer(count,1,config.maxAgents,'agent count');integer(seconds,30,config.maxGrantSeconds,'grant duration');integer(maxCostMicros,1,config.maxFleetMicros,'cost authorization');const hosts=requiredHosts(config,profile,count);requireThat(hosts<=config.maxHosts,'host maximum exceeded');const cost=canonicalCost(hosts,seconds,config.hostHourlyMicros);requireThat(cost<=maxCostMicros,'compute estimate exceeds budget');return{agents:count,hosts,profile,seconds,computeEstimateMicros:cost,maxCostMicros,rootless:true,configDigest:digest(config),excludes:['model inference','disks','network','audit storage']};}
async function readJSON(path){return JSON.parse(await readFile(path,'utf8'));}
async function signManifest(manifest,directory){const path=join(directory,'manifest.json'),out=join(directory,'manifest.sig');await writeFile(path,canonical(manifest),{mode:0o600});process.stderr.write('Authorize exact transaction:\n'+canonical(manifest)+'\n');await run(process.env.SIM_FLEET_SIGNER??'/usr/local/bin/sim',['fleet','sign','--manifest',path,'--out',out],{timeout:180000,maxBytes:1048576});return readFile(out,'utf8');}
async function unwrap(manifest,certificateSHA){const result=await run(process.env.SIM_FLEET_SIGNER??'/usr/local/bin/sim',['fleet','unwrap-key','--wrapped',manifest.ownerWrap,'--certificate',certificateSHA],{timeout:180000,maxBytes:4096});const key=Buffer.from(result.stdout.trim(),'base64');requireThat(key.length===32,'hardware unwrap returned an invalid key');return key;}
function noSecretPaths(paths){for(const path of paths)requireThat(!/(^|\/)(\.env(?:\..*)?|\.npmrc|\.netrc|credentials|auth\.json|id_(rsa|ed25519|ecdsa)(?:$|\.)|[^/]+\.(pem|key))$/.test(path),'source contains a credential-like file: '+path);}
export async function snapshot(repo,maxBytes){const opts=['--no-optional-locks','-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null','-C',repo];const listed=await run('/usr/bin/git',[...opts,'ls-files','-z','-c','-o','--exclude-standard'],{maxBytes:8*1024*1024});const paths=[...new Set(listed.stdout.split('\0').filter(Boolean))];noSecretPaths(paths);const head=(await run('/usr/bin/git',[...opts,'rev-parse','HEAD'])).stdout.trim();return packDirectory(repo,paths,head,maxBytes);}
export async function* logPages(api,task,{follow=false}={}){
  let cursor=-1;
  do{const result=await api.request('/v1/tasks/'+task+'/logs?after='+cursor);for(const row of result.logs){requireThat(row.seq===cursor+1,'remote log sequence gap');cursor=row.seq;yield row;}
    if(result.logs.length===100)continue;if(!follow||!['running','queued'].includes(result.state))return;await new Promise(resolve=>setTimeout(resolve,1000));
  }while(true);
}
export function gitEnvironment(){const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>!k.startsWith('GIT_')));return{...env,GIT_CONFIG_NOSYSTEM:'1',GIT_CONFIG_GLOBAL:'/dev/null'};}
export async function reviewPatch(review,candidate,maxBytes){
  const git=['-c','core.hooksPath=/dev/null','-c','core.fsmonitor=false','-c','commit.gpgsign=false','-C',review];
  const call=(args,options={})=>run('/usr/bin/git',[...git,...args],{...options,env:gitEnvironment()});
  await call(['init','-q']);await call(['add','-f','-A']);await call(['-c','user.name=sim-review','-c','user.email=sim@invalid','commit','-q','--allow-empty','-m','BASELINE']);
  for(const name of await readdir(review))if(name!=='.git')await rm(join(review,name),{recursive:true,force:true});
  for(const name of await readdir(candidate))await cp(join(candidate,name),join(review,name),{recursive:true});
  await call(['add','-f','-A']);return(await call(['diff','--cached','--full-index','--binary','--no-ext-diff','--no-textconv'],{maxBytes})).stdout;
}
export async function main(args){
  const p=parseArgs(args);const command=p.positionals[0]??'help',v=p.values;
  if(command==='help'){process.stdout.write('sim fleet plan|authorize|create|tasks|hosts|reconcile|revoke|pause|resume|unlock\nsim remote logs|attach|fetch|diff|import TASK_ID\nRequired: --config POLICY.json; remote operations also require --ca CA.pem.\nAuthorize: --repo PATH --owner-cert PUBLIC.pem --vendor codex|claude --model ID --count N --profile NAME --seconds N --budget-micros N -- [agent arguments]\nNo cloud credentials or hardware keys are stored in images.\n');return;}
  requireThat(v['--config'],'--config is required');const config=validateConfig(await readJSON(v['--config']));
  const state=resolve(v['--state']??'/usr/local/var/agent/fleet');const directory=await mkdtemp(join(tmpdir(),'sim-fleet-cli-'));
  const planning=()=>plan(config,{count:Number(v['--count']??1),profile:v['--profile']??'light',seconds:Number(v['--seconds']??3600),maxCostMicros:Number(v['--budget-micros'])});
  try{
    if(command==='plan'){process.stdout.write(JSON.stringify(planning(),null,2)+'\n');return;}
    requireThat(v['--ca'],'--ca is required');const ca=await readFile(v['--ca']);
    const api=new APIClient({url:v['--connect']??config.controllerURL,ca,token:async()=>(await run('/usr/bin/env',['gcloud','auth','print-identity-token'],{maxBytes:20000})).stdout.trim()});
    const challenge=()=>api.request('/v1/challenges',{method:'POST',body:{}});
    if(command==='authorize'){
      const computed=planning();requireThat(v['--repo']&&v['--owner-cert'],'--repo and --owner-cert are required');const vendor=v['--vendor']??'codex',model=v['--model'];requireThat(config.models[vendor]?.includes(model),'select an allowed --model');
      const source=await snapshot(resolve(v['--repo']),config.maxArtifactBytes-64),key=randomBytes(32),encrypted=seal(source,key,'source'),c=await challenge();requireThat(c.configDigest===digest(config),'remote policy differs from local policy');
      const cert=new X509Certificate(await readFile(v['--owner-cert']));const ownerWrap=publicEncrypt({key:cert.publicKey,oaepHash:'sha256',padding:constants.RSA_PKCS1_OAEP_PADDING},key).toString('base64');
      const id='grant-'+randomUUID(),manifest={schema:1,id,fleet:config.fleet,nonce:c.nonce,issuedAt:c.at,expiresAt:c.at+computed.seconds,configDigest:digest(config),brokerKeyDigest:digest(c.publicKey),maxAgents:computed.agents,maxHosts:computed.hosts,maxTasks:computed.agents,maxCostMicros:computed.maxCostMicros,vendor,model,profile:computed.profile,args:p.remainder,sourceDigest:digest(encrypted),plaintextDigest:digest(source),keyEnvelope:wrapKey(key,c.publicKey,id),ownerWrap,maxRequests:Number(v['--max-requests']??100),maxOutputTokens:Number(v['--max-output-tokens']??8192),taskTTLSeconds:Math.min(computed.seconds,config.profiles[computed.profile].maxSeconds)};
      validateGrant(manifest,config,c.at);const signature=await signManifest(manifest,directory);
      await api.request('/v1/artifacts/'+manifest.sourceDigest,{method:'PUT',raw:encrypted});await api.request('/v1/grants',{method:'POST',body:{manifest,signature}});
      await mkdir(state,{recursive:true,mode:0o700});await writeFile(join(state,id+'.json'),JSON.stringify({manifest,signature,certificateSHA:cert.fingerprint256.replaceAll(':','').toLowerCase(),source:encrypted.toString('base64')}),{flag:'wx',mode:0o600});key.fill(0);process.stdout.write(id+'\n');return;
    }
    if(command==='create'){requireThat(v['--grant'],'--grant is required');const result=await api.request('/v1/tasks',{method:'POST',body:{grantId:v['--grant'],count:Number(v['--count']??1)}});process.stdout.write(JSON.stringify(result,null,2)+'\n');return;}
    if(['tasks','hosts'].includes(command)){process.stdout.write(JSON.stringify(await api.request('/v1/'+command),null,2)+'\n');return;}
    if(command==='reconcile'){await api.request('/v1/reconcile',{method:'POST',body:{}});return;}
    if(['revoke','pause','resume','unlock'].includes(command)){const c=await challenge();const manifest={schema:1,operation:command,grantID:v['--grant']??'',nonce:c.nonce,issuedAt:c.at,expiresAt:c.at+300,configDigest:digest(config)};
      if(command==='unlock'){identifier(v['--grant']);const saved=await readJSON(join(state,v['--grant']+'.json'));const key=await unwrap(saved.manifest,saved.certificateSHA);manifest.brokerKeyDigest=digest(c.publicKey);manifest.keyEnvelope=wrapKey(key,c.publicKey,saved.manifest.id);key.fill(0);}
      const signature=await signManifest(manifest,directory);await api.request('/v1/control',{method:'POST',body:{manifest,signature}});return;
    }
    const taskID=p.positionals[1]??v['--task'];identifier(taskID);const info=await api.request('/v1/tasks/'+taskID);const saved=await readJSON(join(state,info.task.grant_id+'.json'));requireThat(digest(saved.manifest)===digest(Object.fromEntries(Object.entries(info.grant).filter(([k])=>!['subject','submitted','revoked'].includes(k)))),'remote grant changed');const key=await unwrap(saved.manifest,saved.certificateSHA);
    try{
      if(command==='logs'||command==='attach'){let partial='';const input=async bytes=>{await api.request('/v1/tasks/'+taskID+'/input',{method:'POST',body:{data:bytes.toString('base64')}});};if(command==='attach'){process.stdin.resume();if(process.stdin.isTTY)process.stdin.setRawMode(true);process.stdin.on('data',bytes=>{input(bytes).catch(e=>process.stderr.write(e.message+'\n'));});}
        try{for await(const row of logPages(api,taskID,{follow:command==='attach'})){partial+=open(Buffer.from(row.data,'base64'),key,'audit/'+taskID+'/'+row.seq).toString();let newline;while((newline=partial.indexOf('\n'))>=0){const line=partial.slice(0,newline);partial=partial.slice(newline+1);let frame;try{frame=JSON.parse(line);}catch{continue;}if(['stdout','stderr'].includes(frame.stream))process.stdout.write(Buffer.from(frame.data,'base64'));}}
        }finally{if(process.stdin.isTTY)process.stdin.setRawMode(false);process.stdin.pause();}return;
      }
      requireThat(info.task.result,'task has no candidate result');const result=JSON.parse(info.task.result);const ciphertext=await api.request('/v1/artifacts/'+result.digest,{rawResponse:true});requireThat(digest(ciphertext)===result.digest,'result digest mismatch');const candidate=open(ciphertext,key,'result/'+taskID);const sourceCipher=Buffer.from(saved.source,'base64');requireThat(digest(sourceCipher)===saved.manifest.sourceDigest,'local source record changed');const baseline=open(sourceCipher,key,'source');requireThat(digest(baseline)===saved.manifest.plaintextDigest,'local source baseline mismatch');
      const destination=command==='fetch'?resolve(v['--out']??taskID):join(directory,'review');await mkdir(destination,{mode:0o700});extractBundle(baseline,join(destination,'baseline'),config.maxArtifactBytes);extractBundle(candidate,join(destination,'candidate'),config.maxArtifactBytes);
      if(command==='fetch'){process.stdout.write(destination+'\n');return;}
      requireThat(['diff','import'].includes(command),'unknown command');const review=join(destination,'baseline');const patch=await reviewPatch(review,join(destination,'candidate'),config.maxArtifactBytes);
      if(command==='diff'){process.stdout.write(patch);return;}
      requireThat(v['--repo'],'--repo is required for import');const repo=resolve(v['--repo']),host=['--no-optional-locks','-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null','-C',repo];requireThat(!(await run('/usr/bin/git',[...host,'status','--porcelain'])).stdout.trim(),'remote import requires a clean host worktree and index');const head=(await run('/usr/bin/git',[...host,'rev-parse','HEAD'])).stdout.trim();
      const transaction={schema:1,operation:'remote.import',task:taskID,grantDigest:digest(saved.manifest),candidateDigest:result.digest,patchDigest:digest(patch),hostHead:head,repo,nonce:randomBytes(32).toString('base64url')};await signManifest(transaction,directory);
      requireThat((await run('/usr/bin/git',[...host,'rev-parse','HEAD'])).stdout.trim()===head&&!(await run('/usr/bin/git',[...host,'status','--porcelain'])).stdout.trim(),'host changed after authorization');
      const baselineData=JSON.parse(baseline);for(const file of baselineData.files)await run('/usr/bin/git',[...host,'hash-object','-w','--stdin'],{input:Buffer.from(file.data,'base64')});
      await run('/usr/bin/git',[...host,'apply','--3way','--index','--binary','-'],{input:patch,maxBytes:1048576});process.stdout.write('Imported and staged '+taskID+'\n');
    }finally{key.fill(0);}
  }finally{await rm(directory,{recursive:true,force:true});}
}
