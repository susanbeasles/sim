import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {mkdtempSync,rmSync,readFileSync,existsSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {randomBytes} from 'node:crypto';
import {once} from 'node:events';
import {configuration,grant} from './fixtures.mjs';
import {Store} from '../src/store.mjs';
import {createController} from '../src/controller.mjs';
import {extractBundle,encodeBundle,ArtifactStore} from '../src/artifacts.mjs';
import {SBXRuntime} from '../src/runtime.mjs';
import {GCPProvider} from '../src/gcp.mjs';
import {canonical,digest} from '../src/canonical.mjs';
import {wrapKey,seal} from '../src/crypto.mjs';

test('bundle rejects traversal, symlinks, Git metadata, duplicates and byte overruns',()=>{
 const dir=mkdtempSync(join(tmpdir(),'sim-bundle-'));
 try {
  const bundle=encodeBundle([{path:'src/a.txt',mode:420,data:Buffer.from('ok').toString('base64')}],'1'.repeat(40));
  extractBundle(bundle,join(dir,'good'),1024);assert.equal(readFileSync(join(dir,'good/src/a.txt'),'utf8'),'ok');
  for(const file of [{path:'../escape',mode:420,data:'YQ=='},{path:'.git/config',mode:420,data:'YQ=='},{path:'x',mode:40960,data:'YQ=='}]){
   assert.throws(()=>extractBundle(encodeBundle([file],'1'.repeat(40)),join(dir,'bad'),1024));
  }
  assert.equal(existsSync(join(dir,'escape')),false);
  assert.throws(()=>extractBundle(encodeBundle([{path:'x',mode:420,data:'YQ=='},{path:'x',mode:420,data:'Yg=='}],'1'.repeat(40)),join(dir,'dup'),1024));
  assert.throws(()=>extractBundle(bundle,join(dir,'huge'),1));
 }finally{rmSync(dir,{recursive:true,force:true});}
});
test('concurrent encrypted uploads cannot exceed the artifact cache quota',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'sim-cache-'));try{const store=new ArtifactStore(dir,64,64),a=Buffer.alloc(40,1),b=Buffer.alloc(40,2);const results=await Promise.allSettled([store.put(digest(a),a),store.put(digest(b),b)]);assert.equal(results.filter(r=>r.status==='fulfilled').length,1);assert.match(results.find(r=>r.status==='rejected').reason.message,/cache quota/);await store.put(digest(a),a);assert.deepEqual(await store.get(digest(a)),a);}
 finally{rmSync(dir,{recursive:true,force:true});}
});

test('controller accepts exact grant, replays fail, and 200 tasks survive server restart',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'sim-api-'));let server,store;
 const config=configuration(),now=1000;const identity=async(token)=>{assert.equal(token,'test-identity');return{sub:'12345'};};
 const start=async()=>{store=new Store(join(dir,'db'));const handler=createController({config,store,artifactRoot:join(dir,'artifacts'),clock:()=>now,identity,signature:async(bytes,sig)=>{assert.equal(sig,'signed');assert.equal(typeof bytes,'string');}});server=createServer(handler);server.listen(0,'127.0.0.1');await once(server,'listening');return 'http://127.0.0.1:'+server.address().port;};
 const req=(url,path,body)=>fetch(url+path,{method:body?'POST':'GET',headers:{authorization:'Bearer test-identity','content-type':'application/json'},body:body?JSON.stringify(body):undefined});
 try{
  let url=await start();let response=await req(url,'/v1/challenges',{});assert.equal(response.status,200);const challenge=await response.json();
  const key=randomBytes(32),source=seal(Buffer.from('{}'),key,'source');const g={...grant(),nonce:challenge.nonce,brokerKeyDigest:digest(challenge.publicKey),sourceDigest:digest(source),keyEnvelope:wrapKey(key,challenge.publicKey,'grant-1')};
  response=await fetch(url+'/v1/artifacts/'+g.sourceDigest,{method:'PUT',headers:{authorization:'Bearer test-identity'},body:source});assert.equal(response.status,201);
  response=await req(url,'/v1/grants',{manifest:g,signature:'signed'});assert.equal(response.status,201);
  response=await req(url,'/v1/grants',{manifest:g,signature:'signed'});assert.equal(response.status,400);
  response=await req(url,'/v1/tasks',{grantId:g.id,count:200});assert.equal(response.status,201);assert.equal((await response.json()).tasks.length,200);
  response=await req(url,'/v1/tasks',{grantId:g.id,count:1});assert.equal(response.status,400);
  await new Promise(r=>server.close(r));store.close();url=await start();response=await req(url,'/v1/tasks');assert.equal((await response.json()).tasks.length,200);
  response=await fetch(url+'/v1/tasks');assert.equal(response.status,401);
 }finally{await new Promise(r=>server?.close(r));store?.close();rmSync(dir,{recursive:true,force:true});}
});

test('runtime constructs mountless VM and confines rootless commands to the guest',async()=>{
 const calls=[];const runtime=new SBXRuntime({config:configuration(),run:async(file,args)=>{calls.push({file,args});return{stdout:'',stderr:'',code:0};}});
 const task={id:'task-one',generation:1,grant:grant()};await runtime.create(task,'/tmp/source');
 assert.deepEqual(calls[0],{file:'/usr/local/bin/sbx',args:['create','--name','sim-task-one-1','--skills','off','--cpus','1','--memory','2048MiB','--template',configuration().sandboxTemplate,'shell']});
 const launch=calls.find(c=>c.args.includes('/usr/local/libexec/sim-guest/setup'));
 assert.ok(launch);assert.ok(!calls.some(c=>c.file.includes('podman')));
 assert.ok(!calls[0].args.includes('/tmp/source'));
});

test('provider pins template and nested capability via immutable template source',async()=>{
 const calls=[];const config=configuration();const p=new GCPProvider({config,accessToken:async()=>'local-test-token',fetcher:async(url,opts)=>{calls.push({url,body:JSON.parse(opts.body),headers:opts.headers});return new Response(JSON.stringify({name:'operation',status:'DONE'}),{status:200});}});
 await p.create({name:'sim-worker-one',zone:'us-central1-a',grantID:'grant-1',expiresAt:2000});
 assert.match(calls[0].url,/sourceInstanceTemplate=projects%2Ftest-project%2Fglobal%2FinstanceTemplates%2Fsim-release-1/);
 assert.equal(calls[0].body.name,'sim-worker-one');
 assert.equal(calls[0].body.labels['sim-expires-at'],'2000');
 await assert.rejects(()=>p.create({name:'sim-worker-two',zone:'europe-west1-a',grantID:'grant-1',expiresAt:2000}));
});

test('controller retries failed provisioning with the same identity and retires expired hosts',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'sim-scale-')),store=new Store(':memory:'),c=configuration();let now=1000,attempts=0;const ids=[];
 const provider={async create(h){ids.push(h.requestID);if(++attempts===1)throw Error('temporary provider failure');},async remove(){return{status:'DONE'};}};
 const collector={append:async()=>{}};let server;
 try{const handler=createController({config:c,store,artifactRoot:dir,provider,collector,clock:()=>now,identity:async()=>({sub:'12345'}),signature:async()=>{}});server=createServer(handler);server.listen(0,'127.0.0.1');await once(server,'listening');const url='http://127.0.0.1:'+server.address().port;
 const post=async(path,value)=>{const r=await fetch(url+path,{method:'POST',headers:{authorization:'Bearer test'},body:JSON.stringify(value)});assert.ok(r.ok,await r.clone().text());return r.json();};
 const ch=await post('/v1/challenges',{}),key=randomBytes(32),source=seal(Buffer.from('{}'),key,'source');const g={...grant(),nonce:ch.nonce,sourceDigest:digest(source),brokerKeyDigest:digest(ch.publicKey),keyEnvelope:wrapKey(key,ch.publicKey,'grant-1')};
 await fetch(url+'/v1/artifacts/'+g.sourceDigest,{method:'PUT',headers:{authorization:'Bearer test'},body:source});await post('/v1/grants',{manifest:g,signature:'signed'});await post('/v1/tasks',{grantId:g.id,count:1});
 await handler.reconcile();await handler.reconcile();assert.equal(attempts,2);assert.equal(ids[0],ids[1]);assert.equal(store.hosts().length,1);
 now=g.expiresAt;await handler.reconcile();assert.equal(store.hosts()[0].state,'deleted');
 }finally{await new Promise(r=>server?.close(r));store.close();rmSync(dir,{recursive:true,force:true});}
});
