import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {mkdtempSync,rmSync,writeFileSync,readFileSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {randomBytes} from 'node:crypto';
import {Worker,agentCommand} from '../src/worker.mjs';
import {createGateway,openaiFederation} from '../src/gateway.mjs';
import {AuditCollector} from '../src/audit.mjs';
import {Store} from '../src/store.mjs';
import {open,seal} from '../src/crypto.mjs';
import {encodeBundle} from '../src/artifacts.mjs';
import {digest} from '../src/canonical.mjs';
import {configuration,grant} from './fixtures.mjs';

test('worker verifies source, encrypts evidence/results and removes guest after completion',async()=>{
 const root=mkdtempSync(join(tmpdir(),'sim-worker-')),key=randomBytes(32),events=[];
 const plaintext=encodeBundle([{path:'a',mode:420,data:'YQ=='}],'1'.repeat(40)),source=seal(plaintext,key,'source');
 const task={id:'task-one',generation:1,expires:2000,key:key.toString('base64'),capability:'cap',grant:{...grant(),sourceDigest:digest(source),plaintextDigest:digest(plaintext)}};
 const api={async request(path,{method,body,raw}={}){events.push({path,body});if(path.endsWith('/source'))return source;if(path.endsWith('/artifact')){assert.equal(open(raw,key,'result/task-one').length>0,true);return{digest:digest(raw)};}return{};}};
 const runtime={async create(t,path){assert.ok(events.some(e=>e.path.endsWith('/heartbeat')),'lease must be renewed before guest creation');assert.equal(readFileSync(join(path,'a'),'utf8'),'a');},async launch(t,env,output){assert.equal(env.OPENAI_API_KEY,'task-one.cap');assert.equal(env.NODE_EXTRA_CA_CERTS,'/usr/local/share/ca-certificates/sim-fleet.crt');assert.ok(t.command.args.includes('--model'));await output(Buffer.from('output'));return 0;},async collect(t,path){writeFileSync(path,plaintext);},async remove(){events.push({path:'removed'});},async input(){}};
 try{const worker=new Worker({config:configuration(),api,runtime,host:'host-one',root,clock:()=>1000});await worker.execute(task);
 assert.equal(events.at(-1).path,'removed');assert.ok(events.find(e=>e.path.endsWith('/finish')&&e.body.exitCode===0));
 const evidence=events.find(e=>e.path.endsWith('/logs'));assert.equal(open(Buffer.from(evidence.body.data,'base64'),key,'audit/task-one/0').toString(),'output');
 }finally{rmSync(root,{recursive:true,force:true});}
});

test('agent launch pins the signed model and custom Responses provider',()=>{
 const c=configuration(),g=grant();const command=agentCommand(g,c);
 assert.deepEqual(command.args.slice(-2),['--model','codex-model']);
 assert.ok(command.args.some(a=>a.includes('model_provider="sim-fleet"')));
 assert.ok(command.args.some(a=>a.includes('supports_websockets=false')));
 const claude=agentCommand({...g,vendor:'claude',model:'claude-model',args:['-p','hello']},c);
 assert.deepEqual(claude.args,['-p','hello','--model','claude-model']);
});

test('gateway enforces task/model/output budget and forwards Responses streaming without redirects',async()=>{
 const calls=[];const config=configuration();const authorize=async(payload)=>{assert.equal(payload.task,'task-one');assert.equal(payload.model,'codex-model');return{maxOutputTokens:100};};
 const server=createServer(createGateway({config,authorize,openaiToken:async()=>'provider-token',fetcher:async(url,opts)=>{calls.push({url,opts});return new Response('data: {"type":"done"}\n\n',{headers:{'content-type':'text/event-stream'}});}}));server.listen(0,'127.0.0.1');await once(server,'listening');
 const url='http://127.0.0.1:'+server.address().port;
 try{let r=await fetch(url+'/v1/responses',{method:'POST',headers:{authorization:'Bearer task-one.cap','content-type':'application/json'},body:JSON.stringify({model:'codex-model',input:'hi',max_output_tokens:80,stream:true})});assert.equal(r.status,200);assert.match(await r.text(),/done/);assert.equal(calls[0].opts.redirect,'error');assert.equal(calls[0].opts.headers.authorization,'Bearer provider-token');
 r=await fetch(url+'/v1/responses',{method:'POST',headers:{authorization:'Bearer task-one.cap','content-type':'application/json'},body:JSON.stringify({model:'codex-model',max_output_tokens:101})});assert.equal(r.status,400);assert.equal(calls.length,1);
 }finally{await new Promise(r=>server.close(r));}
});

test('external collector is idempotent and rejects missing or overwritten audit segments',async()=>{
 const objects=new Map();const storage={async put(name,bytes){if(objects.has(name))assert.deepEqual(objects.get(name),bytes);objects.set(name,bytes);}};const store=new Store(':memory:');
 try{const c=new AuditCollector({store,storage,maxLogBytes:1024});const record={task:'task-one',seq:0,grant:'grant-1',host:'host-one',generation:1,data:'encrypted'};
 const first=await c.append(record,1000),again=await c.append(record,1000);assert.equal(first.digest,again.digest);assert.equal(objects.size,1);
 await assert.rejects(()=>c.append({...record,data:'changed'},1000));await assert.rejects(()=>c.append({...record,seq:2},1000));
 }finally{store.close();}
});

test('Vertex token counting retains model and uses the documented count-tokens route',async()=>{
 const calls=[],config=configuration();const server=createServer(createGateway({config,authorize:async()=>({maxOutputTokens:100}),vertexProject:config.project,vertexToken:async()=>'attached-identity',fetcher:async(url,options)=>{calls.push({url,options});return Response.json({input_tokens:3});}}));server.listen(0,'127.0.0.1');await once(server,'listening');
 try{const r=await fetch('http://127.0.0.1:'+server.address().port+'/v1/messages/count_tokens',{method:'POST',headers:{authorization:'Bearer task-one.cap','anthropic-beta':'count-tokens-2024-11-01'},body:JSON.stringify({model:'claude-model',messages:[]})});assert.equal(r.status,200);assert.match(calls[0].url,/models\/count-tokens:rawPredict$/);assert.equal(JSON.parse(calls[0].options.body).model,'claude-model');assert.equal(calls[0].options.headers.authorization,'Bearer attached-identity');assert.equal(calls[0].options.headers['anthropic-beta'],'count-tokens-2024-11-01');}
 finally{await new Promise(r=>server.close(r));}
});

test('OpenAI federation coalesces concurrent exchanges and caches the short-lived token',async()=>{
 const calls=[];const token=openaiFederation({providerID:'provider-id',serviceAccountID:'account-id',subjectToken:async()=>'google-jwt',fetcher:async(url,options)=>{calls.push({url,options});await new Promise(r=>setTimeout(r,5));return Response.json({access_token:'short-lived',expires_in:300});}});
 assert.deepEqual(await Promise.all(Array.from({length:20},()=>token())),Array(20).fill('short-lived'));assert.equal(calls.length,1);assert.equal(calls[0].url,'https://auth.openai.com/oauth/token');assert.equal(JSON.parse(calls[0].options.body).identity_provider_id,'provider-id');assert.equal(calls[0].options.redirect,'error');
});

test('gateway bounds concurrent requests before reading additional task bodies',async()=>{
 let release,ready;const blocked=new Promise(r=>{release=r;}),started=new Promise(r=>{ready=r;});let count=0;
 const server=createServer(createGateway({config:configuration(),authorize:async()=>({maxOutputTokens:100}),openaiToken:async()=>'test-token',fetcher:async()=>{if(++count===2)ready();await blocked;return Response.json({ok:true});}}));server.listen(0,'127.0.0.1');await once(server,'listening');
 const request=()=>fetch('http://127.0.0.1:'+server.address().port+'/v1/responses',{method:'POST',headers:{authorization:'Bearer task-one.cap'},body:JSON.stringify({model:'codex-model',input:'hello'})});
 const first=request(),second=request();try{await started;const third=await request();assert.equal(third.status,429);assert.equal(third.headers.get('retry-after'),'1');assert.equal(count,2);release();assert.equal((await first).status,200);assert.equal((await second).status,200);}
 finally{release();await Promise.allSettled([first,second]);await new Promise(r=>server.close(r));}
});
