import {isIP} from 'node:net';
import { fields, identifier, integer, requireThat, sha256, digest } from './canonical.mjs';

export function validateConfig(c) {
  fields(c,['schema','fleet','project','region','zones','controllerURL','gatewayURL','audience','adminAudience','adminSubjects','workerSubject','gatewaySubject','template','releaseDigest','hardwarePublicKey','workerImage','sandboxTemplate','maxHosts','maxAgents','maxGrantSeconds','hostCPUs','hostMemoryMiB','reserveMemoryMiB','cpuOvercommit','idleSeconds','leaseSeconds','maxArtifactBytes','maxLogBytes','hostHourlyMicros','maxFleetMicros','models','profiles','egressHosts','maxTaskEgressBytes']);
  requireThat(c.schema===1,'unsupported config schema');
  for(const key of ['fleet','project','region']) identifier(c[key]);
  requireThat(Array.isArray(c.zones)&&c.zones.length>0&&c.zones.length<=6,'invalid zones');
  c.zones.forEach(z=>requireThat(typeof z==='string'&&z.startsWith(c.region+'-')&&/^[a-z0-9-]+$/.test(z),'zone outside region'));
  for(const key of ['controllerURL','gatewayURL','audience']) { const u=new URL(c[key]);requireThat(u.protocol==='https:'&&!u.username&&!u.password&&!u.search&&!u.hash,'HTTPS URL required'); }
  for(const key of ['controllerURL','gatewayURL']){const u=new URL(c[key]),[a,b]=u.hostname.split('.').map(Number);requireThat(isIP(u.hostname)===4&&(a===10||a===172&&b>=16&&b<=31||a===192&&b===168)&&c[key]===u.origin,'private management origin required');if(key==='gatewayURL')requireThat(a===10&&u.port==='7661','gateway must use private 10/8 IPv4 and port 7661');}
  if(c.adminAudience!==undefined)requireThat(typeof c.adminAudience==='string'&&c.adminAudience.length>0&&c.adminAudience.length<=2048,'invalid admin audience');
  requireThat(Array.isArray(c.adminSubjects)&&c.adminSubjects.length>0&&c.adminSubjects.every(x=>/^\d+$/.test(x)),'admin subject IDs required');
  for(const key of ['workerSubject','gatewaySubject']) requireThat(/^\d+$/.test(c[key]),'service account numeric subject required');
  requireThat(c.template.startsWith('projects/'+c.project+'/global/instanceTemplates/')&&/^[a-zA-Z0-9/-]+$/.test(c.template),'invalid instance template');
  sha256(c.releaseDigest);
  requireThat(typeof c.hardwarePublicKey==='string'&&/^sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com [A-Za-z0-9+/=]+(?: [^\r\n]*)?$/.test(c.hardwarePublicKey),'FIDO public key required');
  for(const key of ['workerImage','sandboxTemplate']) requireThat(typeof c[key]==='string'&&/^[a-z0-9][a-z0-9./:_-]+@sha256:[a-f0-9]{64}$/.test(c[key]),'image must be pinned by digest');
  for(const key of ['maxHosts','maxAgents','hostCPUs','hostMemoryMiB','maxGrantSeconds','maxArtifactBytes','maxLogBytes','hostHourlyMicros','maxFleetMicros']) integer(c[key],1,Number.MAX_SAFE_INTEGER,key);
  integer(c.reserveMemoryMiB,0,c.hostMemoryMiB-1,'reserve memory');integer(c.cpuOvercommit,1,4,'CPU overcommit');
  integer(c.leaseSeconds,15,600,'lease seconds');integer(c.idleSeconds,60,86400,'idle seconds');
  requireThat(Array.isArray(c.egressHosts)&&c.egressHosts.length<=100&&c.egressHosts.every(h=>typeof h==='string'&&/^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}:443$/.test(h)&&!h.endsWith('.internal:443')),'explicit HTTPS egress hosts required');
  integer(c.maxTaskEgressBytes,65536,16*1024*1024*1024,'task network budget');
  fields(c.models,['claude','codex']);
  for(const vendor of ['claude','codex']) requireThat(Array.isArray(c.models[vendor])&&c.models[vendor].length>0&&c.models[vendor].every(m=>typeof m==='string'&&/^[a-zA-Z0-9_.:/@-]{1,200}$/.test(m)),'invalid model allowlist');
  requireThat(c.profiles&&Object.keys(c.profiles).length>0,'profiles required');
  for(const [name,p]of Object.entries(c.profiles)) {identifier(name);fields(p,['cpus','memoryMiB','diskMiB','maxSeconds']);integer(p.cpus,1,c.hostCPUs,'profile CPUs');integer(p.memoryMiB,256,c.hostMemoryMiB-c.reserveMemoryMiB,'profile memory');integer(p.diskMiB,256,1048576,'profile disk');integer(p.maxSeconds,30,86400,'profile duration');}
  canonicalCost(c.maxHosts,c.maxGrantSeconds,c.hostHourlyMicros);
  return c;
}
export function canonicalCost(hosts,seconds,hourly) {const result=Math.ceil(hosts*seconds*hourly/3600);integer(result,0,Number.MAX_SAFE_INTEGER,'estimated compute cost');return result;}
export function requiredHosts(c,profile,count) {
  const p=c.profiles[profile];requireThat(p,'unknown resource profile');integer(count,1,c.maxAgents,'agent count');
  const slots=Math.min(Math.floor(c.hostCPUs*c.cpuOvercommit/p.cpus),Math.floor((c.hostMemoryMiB-c.reserveMemoryMiB)/p.memoryMiB));
  requireThat(slots>0,'profile does not fit a host');return Math.ceil(count/slots);
}
export function validateGrant(g,c,now) {
  fields(g,['schema','id','fleet','nonce','issuedAt','expiresAt','configDigest','brokerKeyDigest','maxAgents','maxHosts','maxTasks','maxCostMicros','vendor','model','profile','args','sourceDigest','plaintextDigest','keyEnvelope','ownerWrap','maxRequests','maxOutputTokens','taskTTLSeconds']);
  requireThat(g.schema===1&&g.fleet===c.fleet,'wrong grant fleet or schema');identifier(g.id);
  requireThat(typeof g.nonce==='string'&&/^[A-Za-z0-9_-]{43}$/.test(g.nonce),'invalid nonce');
  integer(g.issuedAt,now-300,now+30,'issuedAt');integer(g.expiresAt,now+1,now+c.maxGrantSeconds,'expiresAt');
  requireThat(g.expiresAt>g.issuedAt&&g.expiresAt-g.issuedAt<=c.maxGrantSeconds,'grant lifetime exceeds policy');
  requireThat(g.configDigest===digest(c),'configuration digest mismatch');sha256(g.brokerKeyDigest);sha256(g.sourceDigest);sha256(g.plaintextDigest);
  integer(g.maxAgents,1,c.maxAgents,'maxAgents');integer(g.maxHosts,1,c.maxHosts,'maxHosts');integer(g.maxTasks,1,c.maxAgents*100,'maxTasks');
  integer(g.maxCostMicros,1,c.maxFleetMicros,'maxCostMicros');
  requireThat(c.models[g.vendor]?.includes(g.model),'model outside allowlist');requireThat(c.profiles[g.profile],'unknown profile');
  requireThat(requiredHosts(c,g.profile,g.maxAgents)<=g.maxHosts,'grant cannot fit requested agents');
  requireThat(canonicalCost(g.maxHosts,g.expiresAt-now,c.hostHourlyMicros)<=g.maxCostMicros,'compute estimate exceeds authorized budget');
  integer(g.taskTTLSeconds,30,Math.min(g.expiresAt-now,c.profiles[g.profile].maxSeconds),'task TTL');integer(g.maxRequests,1,10000,'maxRequests');integer(g.maxOutputTokens,1,1000000,'maxOutputTokens');
  requireThat(Array.isArray(g.args)&&g.args.length<=100&&g.args.every(a=>typeof a==='string'&&Buffer.byteLength(a)<=65536&&!a.includes('\0')),'invalid agent argv');
  requireThat(g.keyEnvelope&&typeof g.keyEnvelope==='object'&&Buffer.byteLength(JSON.stringify(g.keyEnvelope))<=4096,'invalid key envelope');
  requireThat(typeof g.ownerWrap==='string'&&g.ownerWrap.length<=8192,'invalid owner key wrap');return g;
}

