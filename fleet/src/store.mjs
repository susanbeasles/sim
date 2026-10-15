import { DatabaseSync } from 'node:sqlite';
import { randomUUID, randomBytes } from 'node:crypto';
import { canonical, digest, requireThat } from './canonical.mjs';

export class Store {
  constructor(path) {
    this.db=new DatabaseSync(path);this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS challenges(nonce TEXT PRIMARY KEY,subject TEXT NOT NULL,expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS grants(id TEXT PRIMARY KEY,data TEXT NOT NULL,subject TEXT NOT NULL,submitted INTEGER NOT NULL DEFAULT 0,revoked INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY,grant_id TEXT NOT NULL REFERENCES grants(id),state TEXT NOT NULL,host TEXT,generation INTEGER NOT NULL DEFAULT 0,lease_until INTEGER,expires INTEGER NOT NULL,created INTEGER NOT NULL,token_hash TEXT,requests INTEGER NOT NULL DEFAULT 0,result TEXT,exit_code INTEGER);
      CREATE TABLE IF NOT EXISTS hosts(id TEXT PRIMARY KEY,name TEXT NOT NULL,zone TEXT NOT NULL,state TEXT NOT NULL,data TEXT NOT NULL,last_seen INTEGER NOT NULL,created INTEGER NOT NULL,idle_since INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,previous TEXT NOT NULL,digest TEXT UNIQUE NOT NULL,data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS logs(task TEXT NOT NULL,seq INTEGER NOT NULL,data TEXT NOT NULL,PRIMARY KEY(task,seq));
      CREATE TABLE IF NOT EXISTS network_usage(task TEXT PRIMARY KEY,bytes INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS inputs(task TEXT NOT NULL,seq INTEGER PRIMARY KEY AUTOINCREMENT,data TEXT NOT NULL);`);
  }
  close(){if(this.db){this.db.close();this.db=null;}}
  transaction(fn){this.db.exec('BEGIN IMMEDIATE');try{const result=fn();this.db.exec('COMMIT');return result;}catch(e){this.db.exec('ROLLBACK');throw e;}}
  event(kind,details,now){const previous=this.db.prepare('SELECT digest FROM events ORDER BY seq DESC LIMIT 1').get()?.digest??'0'.repeat(64);const data=canonical({kind,details,at:now});const hash=digest(previous+'\n'+data);this.db.prepare('INSERT INTO events(previous,digest,data) VALUES(?,?,?)').run(previous,hash,data);return hash;}
  paused(){return this.db.prepare("SELECT value FROM settings WHERE key='paused'").get()?.value==='true';}
  setPaused(value,now){return this.transaction(()=>{this.db.prepare("INSERT INTO settings VALUES('paused',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(String(value));this.event('fleet.paused',{value},now);});}
  challenge(nonce,subject,expires){this.db.prepare('DELETE FROM challenges WHERE expires<?').run(expires-600);this.db.prepare('INSERT INTO challenges VALUES(?,?,?)').run(nonce,subject,expires);}
  consumeChallenge(nonce,subject,now){return this.transaction(()=>{const row=this.db.prepare('SELECT * FROM challenges WHERE nonce=?').get(nonce);requireThat(row&&row.subject===subject&&row.expires>now,'expired, mismatched or consumed nonce');this.db.prepare('DELETE FROM challenges WHERE nonce=?').run(nonce);});}
  lose(id,reason,now){this.db.prepare("UPDATE tasks SET state='lost',token_hash=NULL WHERE id=?").run(id);this.event('task.lost',{task:id,reason},now);}
  authorize(grant,subject,now,maxFleetMicros=Number.MAX_SAFE_INTEGER){return this.transaction(()=>{const reserved=this.grants().filter(g=>!g.revoked&&g.expiresAt>now).reduce((sum,g)=>sum+g.maxCostMicros,0);requireThat(Number.isSafeInteger(reserved)&&reserved+grant.maxCostMicros<=maxFleetMicros,'concurrent fleet budget exceeded');const challenge=this.db.prepare('SELECT * FROM challenges WHERE nonce=?').get(grant.nonce);requireThat(challenge&&challenge.subject===subject&&challenge.expires>now,'expired, mismatched or consumed nonce');this.db.prepare('DELETE FROM challenges WHERE nonce=?').run(grant.nonce);this.db.prepare('INSERT INTO grants(id,data,subject) VALUES(?,?,?)').run(grant.id,canonical(grant),subject);this.event('grant.accepted',{grant:grant.id,digest:digest(grant)},now);return grant;});}
  grants(){return this.db.prepare('SELECT data,revoked FROM grants').all().map(r=>({...JSON.parse(r.data),revoked:!!r.revoked}));}
  grant(id){const row=this.db.prepare('SELECT data,revoked,subject,submitted FROM grants WHERE id=?').get(id);return row?{...JSON.parse(row.data),revoked:!!row.revoked,subject:row.subject,submitted:row.submitted}:null;}
  active(id,now){const g=this.grant(id);requireThat(g&&!g.revoked&&g.expiresAt>now,'grant inactive');return g;}
  submit(id,count,now){return this.transaction(()=>{const g=this.active(id,now);requireThat(Number.isSafeInteger(count)&&count>0&&g.submitted+count<=g.maxTasks,'task allowance exceeded');const list=[];for(let i=0;i<count;i++){const task='task-'+randomUUID();this.db.prepare("INSERT INTO tasks(id,grant_id,state,expires,created) VALUES(?,?,'queued',?,?)").run(task,id,Math.min(g.expiresAt,now+g.taskTTLSeconds),now);list.push(task);}this.db.prepare('UPDATE grants SET submitted=submitted+? WHERE id=?').run(count,id);this.event('tasks.submitted',{grant:id,count},now);return list;});}
  tasks(){return this.db.prepare('SELECT * FROM tasks ORDER BY created,id').all();}
  task(id){return this.db.prepare('SELECT * FROM tasks WHERE id=?').get(id)??null;}
  host(data,now){this.db.prepare('INSERT INTO hosts(id,name,zone,state,data,last_seen,created,idle_since) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,data=excluded.data,last_seen=excluded.last_seen').run(data.id,data.name,data.zone,data.state,canonical(data),now,now,now);}
  hosts(){return this.db.prepare('SELECT * FROM hosts ORDER BY created,id').all().map(h=>({...JSON.parse(h.data),state:h.state,lastSeen:h.last_seen,created:h.created,idleSince:h.idle_since}));}
  setHostState(id,state){this.db.prepare('UPDATE hosts SET state=? WHERE id=?').run(state,id);}
  lease(hostID,c,now,unlocked){return this.transaction(()=>{
    const h=this.hosts().find(h=>h.id===hostID);requireThat(h&&h.state==='ready'&&h.lastSeen>now-c.leaseSeconds,'host unavailable');
    const running=this.db.prepare("SELECT * FROM tasks WHERE host=? AND state='running'").all(hostID);let cpus=0,memory=0;
    for(const t of running){const p=c.profiles[this.grant(t.grant_id).profile];cpus+=p.cpus;memory+=p.memoryMiB;}
    const queued=this.db.prepare("SELECT * FROM tasks WHERE state='queued' AND expires>? ORDER BY created,id").all(now);
    for(const t of queued){const g=this.grant(t.grant_id);if((unlocked&&!unlocked.has(g.id))||g.revoked||g.expiresAt<=now||(h.grantID&&h.grantID!==g.id))continue;
      const total=this.db.prepare("SELECT count(*) AS n FROM tasks WHERE grant_id=? AND state='running'").get(g.id).n;
      const allRunning=this.db.prepare("SELECT count(*) AS n FROM tasks WHERE state='running'").get().n;
      if(total>=g.maxAgents||allRunning>=c.maxAgents)continue;const p=c.profiles[g.profile];
      if(cpus+p.cpus>h.cpus*c.cpuOvercommit||memory+p.memoryMiB>h.memoryMiB-c.reserveMemoryMiB)continue;
      const capability=randomBytes(32).toString('base64url');
      this.db.prepare("UPDATE tasks SET state='running',host=?,generation=generation+1,lease_until=?,token_hash=? WHERE id=?").run(hostID,Math.min(t.expires,now+c.leaseSeconds),digest(capability),t.id);
      this.db.prepare('UPDATE hosts SET idle_since=? WHERE id=?').run(now,hostID);this.event('task.leased',{task:t.id,host:hostID,generation:t.generation+1},now);
      return {...this.task(t.id),grant:g,capability};
    }return null;
  });}
  owned(id,host,generation,now){const t=this.task(id);requireThat(t&&t.host===host&&t.generation===generation&&t.state==='running'&&t.lease_until>now&&t.expires>now,'task lease rejected');this.active(t.grant_id,now);return t;}
  renew(id,host,generation,c,now){this.owned(id,host,generation,now);this.db.prepare('UPDATE tasks SET lease_until=min(expires,?) WHERE id=?').run(now+c.leaseSeconds,id);}
  finish(id,host,generation,exitCode,result,now){return this.transaction(()=>{this.owned(id,host,generation,now);this.db.prepare("UPDATE tasks SET state=?,exit_code=?,result=?,token_hash=NULL WHERE id=?").run(exitCode===0?'completed':'failed',exitCode,result?canonical(result):null,id);this.event('task.finished',{task:id,host,generation,exitCode,result},now);this.db.prepare('UPDATE hosts SET idle_since=? WHERE id=?').run(now,host);});}
  revoke(id,now){return this.transaction(()=>{requireThat(this.grant(id),'unknown grant');this.db.prepare('UPDATE grants SET revoked=1 WHERE id=?').run(id);this.db.prepare("UPDATE tasks SET state='cancelled',token_hash=NULL WHERE grant_id=? AND state IN ('running','queued')").run(id);this.event('grant.revoked',{grant:id},now);});}
  expire(now){return this.transaction(()=>{this.db.prepare("UPDATE tasks SET state=CASE WHEN state='running' THEN 'lost' ELSE 'expired' END,token_hash=NULL WHERE state IN ('running','queued') AND (expires<=? OR (state='running' AND lease_until<=?) OR grant_id IN (SELECT id FROM grants WHERE revoked=1))").run(now,now);});}
  reserveInference(id,capability,model,vendor,now){return this.transaction(()=>{const t=this.task(id);requireThat(t&&t.token_hash===digest(capability)&&t.state==='running'&&t.lease_until>now&&t.expires>now,'inference capability rejected');const g=this.active(t.grant_id,now);requireThat(g.model===model&&g.vendor===vendor&&t.requests<g.maxRequests,'inference model or request budget rejected');this.db.prepare('UPDATE tasks SET requests=requests+1 WHERE id=?').run(id);return g;});}
  reserveEgress(id,capability,bytes,c,now){return this.transaction(()=>{const t=this.task(id);requireThat(t&&t.token_hash===digest(capability)&&t.state==='running'&&t.lease_until>now&&t.expires>now,'network capability rejected');this.active(t.grant_id,now);requireThat(c.egressHosts.length>0&&Number.isSafeInteger(bytes)&&bytes>0&&bytes<=16*1024*1024,'network allocation rejected');const used=this.db.prepare('SELECT bytes FROM network_usage WHERE task=?').get(id)?.bytes??0;requireThat(used+bytes<=c.maxTaskEgressBytes,'task network budget exceeded');this.db.prepare('INSERT INTO network_usage VALUES(?,?) ON CONFLICT(task) DO UPDATE SET bytes=excluded.bytes').run(id,used+bytes);return{bytes,expiresAt:Math.min(t.lease_until,t.expires)};});}
  appendLog(task,seq,data,maxBytes){return this.transaction(()=>{const previous=this.db.prepare('SELECT data FROM logs WHERE task=? AND seq=?').get(task,seq);if(previous){requireThat(previous.data===data,'log sequence collision');return;}const last=this.db.prepare('SELECT max(seq) AS seq,coalesce(sum(length(data)),0) AS bytes FROM logs WHERE task=?').get(task);requireThat(seq===(last.seq??-1)+1,'log sequence gap');requireThat(last.bytes+Buffer.byteLength(data)<=maxBytes,'task log budget exceeded');this.db.prepare('INSERT INTO logs VALUES(?,?,?)').run(task,seq,data);});}
  logs(id,after=-1){return this.db.prepare('SELECT seq,data FROM logs WHERE task=? AND seq>? ORDER BY seq LIMIT 100').all(id,after);}
  input(id,data){this.db.prepare('INSERT INTO inputs(task,data) VALUES(?,?)').run(id,data);}
  takeInput(id){return this.transaction(()=>{const rows=this.db.prepare('SELECT seq,data FROM inputs WHERE task=? ORDER BY seq LIMIT 100').all(id);if(rows.length)this.db.prepare('DELETE FROM inputs WHERE task=? AND seq<=?').run(id,rows.at(-1).seq);return rows;});}
}
