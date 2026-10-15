import {resolve4} from 'node:dns/promises';
import {connect,isIP} from 'node:net';
import {Transform} from 'node:stream';
import {once} from 'node:events';
import {requireThat} from './canonical.mjs';

const quantum=16*1024*1024;
export function publicIPv4(address){
  if(isIP(address)!==4)return false;
  const [a,b,c]=address.split('.').map(Number);
  return !(a===0||a===10||a===127||a>=224||(a===100&&b>=64&&b<=127)||(a===169&&b===254)||(a===172&&b>=16&&b<=31)||(a===192&&(b===168||b===0||b===88&&c===99))||(a===198&&(b===18||b===19||b===51&&c===100))||(a===203&&b===0&&c===113));
}

// The public CA authenticates this TLS proxy. CONNECT keeps repository TLS intact.
// DNS is resolved once and a verified public IP is dialed directly (no rebinding).
export function attachEgress(server,{config,authorize,lookup=resolve4,dial=connect}){
  const active=new Map();let total=0;
  server.on('connect',(request,client,head)=>{
    client.pause();let upstream,timer,started=false,task,counted=false;
    if(total>=Math.min(1024,config.maxAgents*8)){client.end('HTTP/1.1 503 Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');return;}total++;counted=true;timer=setTimeout(()=>client.destroy(),15000);timer.unref();
    const release=()=>{clearTimeout(timer);if(counted){total--;counted=false;}if(task){const remaining=(active.get(task)??1)-1;if(remaining>0)active.set(task,remaining);else active.delete(task);}upstream?.destroy();};
    client.once('close',release);client.on('error',()=>upstream?.destroy());
    (async()=>{
      const target=request.url;
      requireThat(config.egressHosts.includes(target),'egress destination rejected');
      const [hostname,port]=target.split(':');requireThat(port==='443','only HTTPS repositories are supported');
      const header=request.headers['proxy-authorization'];requireThat(typeof header==='string'&&header.startsWith('Basic '),'proxy authentication required');
      const decoded=Buffer.from(header.slice(6),'base64').toString();requireThat(/^task-[a-z0-9-]+:[A-Za-z0-9_-]{1,128}$/.test(decoded),'invalid proxy capability');
      const [id,capability]=decoded.split(':');requireThat((active.get(id)??0)<8,'task proxy concurrency exceeded');
      const allocation=Math.min(quantum,config.maxTaskEgressBytes);let credit=0,queue=Promise.resolve();
      const reserve=async()=>{const allowance=await authorize({task:id,capability,bytes:allocation});credit+=allowance.bytes;return allowance;};
      const allowance=await reserve();requireThat(Number.isSafeInteger(allowance.expiresAt)&&allowance.expiresAt*1000>Date.now(),'network lease expired');clearTimeout(timer);timer=setTimeout(()=>client.destroy(),Math.min(120000,allowance.expiresAt*1000-Date.now()));timer.unref();if(client.destroyed)return;requireThat((active.get(id)??0)<8,'task proxy concurrency exceeded');task=id;active.set(id,(active.get(id)??0)+1);
      const addresses=await lookup(hostname);requireThat(addresses.length>0&&addresses.every(publicIPv4),'nonpublic egress destination rejected');if(client.destroyed)return;
      upstream=dial({host:addresses[0],port:443});upstream.on('error',()=>client.destroy());upstream.setTimeout(10000,()=>upstream.destroy(new Error('egress connect timeout')));await once(upstream,'connect');
      if(client.destroyed){upstream.destroy();return;}
      upstream.setTimeout(30000,()=>client.destroy());client.setTimeout(30000,()=>client.destroy());
      const limiter=()=>new Transform({transform(chunk,encoding,callback){
        queue=queue.then(async()=>{while(credit<chunk.length)await reserve();credit-=chunk.length;callback(null,chunk);}).catch(error=>{callback(error);client.destroy();upstream.destroy();});
      }});
      const outgoing=limiter(),incoming=limiter();outgoing.on('error',()=>client.destroy());incoming.on('error',()=>client.destroy());
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');started=true;
      outgoing.pipe(upstream);if(head.length)outgoing.write(head);client.pipe(outgoing);upstream.pipe(incoming).pipe(client);
    })().catch(()=>{if(!client.destroyed){if(started)client.destroy();else client.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');}});
  });
}
