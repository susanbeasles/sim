import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer as httpServer} from 'node:http';
import {createServer as tcpServer,connect} from 'node:net';
import {once} from 'node:events';
import {attachEgress,publicIPv4} from '../src/egress.mjs';
import {Store} from '../src/store.mjs';
import {configuration,grant} from './fixtures.mjs';

test('egress accounting is transactional and revoked task capabilities cannot reserve traffic',()=>{
 const s=new Store(':memory:'),c=configuration(),g=grant();try{
 s.challenge(g.nonce,'12345',2000);s.authorize(g,'12345',1000);const [id]=s.submit(g.id,1,1000);s.host({id:'host-one',name:'host-one',zone:c.zones[0],state:'ready',cpus:32,memoryMiB:131072},1000);const t=s.lease('host-one',c,1000);
 assert.equal(s.reserveEgress(id,t.capability,65536,{...c,maxTaskEgressBytes:65536},1000).bytes,65536);
 assert.throws(()=>s.reserveEgress(id,t.capability,1,{...c,maxTaskEgressBytes:65536},1000),/network budget/);
 s.revoke(g.id,1001);assert.throws(()=>s.reserveEgress(id,t.capability,1,c,1001));
 }finally{s.close();}
});

test('authenticated CONNECT allows reviewed public destinations and rejects metadata/private DNS',async()=>{
 assert.equal(publicIPv4('8.8.8.8'),true);for(const address of ['127.0.0.1','10.0.0.1','169.254.169.254','192.168.1.1','100.64.0.1','224.0.0.1','::1'])assert.equal(publicIPv4(address),false);
 const upstream=tcpServer(socket=>socket.end('package-bytes'));upstream.listen(0,'127.0.0.1');await once(upstream,'listening');
 const calls=[],lookups=[],server=httpServer();attachEgress(server,{config:{...configuration(),egressHosts:['packages.example:443','private.example:443']},authorize:async p=>{if(p.capability==='fake')throw Error('invalid capability');calls.push(p);return{bytes:p.bytes,expiresAt:Math.floor(Date.now()/1000)+30};},lookup:async host=>{lookups.push(host);return[host==='packages.example'?'8.8.8.8':'10.0.0.1'];},dial:()=>connect(upstream.address().port,'127.0.0.1')});server.listen(0,'127.0.0.1');await once(server,'listening');
 async function request(destination,credential='task-one:cap'){const socket=connect(server.address().port,'127.0.0.1');let output='';socket.on('data',d=>{output+=d.toString();});socket.write('CONNECT '+destination+' HTTP/1.1\r\nHost: '+destination+'\r\nProxy-Authorization: Basic '+Buffer.from(credential).toString('base64')+'\r\n\r\n');await once(socket,'close');return output;}
 try{assert.match(await request('packages.example:443'),/200 Connection Established[\s\S]*package-bytes/);assert.equal(calls[0].task,'task-one');const count=calls.length;assert.match(await request('metadata.google.internal:443'),/403/);assert.equal(calls.length,count);assert.match(await request('private.example:443'),/403/);const before=lookups.length;for(let n=0;n<20;n++)assert.match(await request('packages.example:443','task-rejected-'+n+':fake'),/403/);assert.equal(lookups.length,before);}
 finally{await new Promise(r=>server.close(r));await new Promise(r=>upstream.close(r));}
});
