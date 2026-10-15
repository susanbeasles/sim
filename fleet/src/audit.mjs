import {canonical,digest,identifier,integer,requireThat} from './canonical.mjs';
import {accessToken} from './gcp.mjs';
export class GCSStorage {
  constructor(bucket,{fetcher=fetch,token=accessToken}={}){requireThat(/^[a-z0-9][a-z0-9._-]{2,220}$/.test(bucket),'invalid bucket');this.bucket=bucket;this.fetcher=fetcher;this.token=token;}
  async put(name,bytes){const url=new URL('https://storage.googleapis.com/upload/storage/v1/b/'+this.bucket+'/o');url.searchParams.set('uploadType','media');url.searchParams.set('ifGenerationMatch','0');url.searchParams.set('name',name);const result=await this.fetcher(url,{method:'POST',headers:{authorization:'Bearer '+await this.token(),'content-type':'application/octet-stream'},body:bytes,redirect:'error',signal:AbortSignal.timeout(30000)});requireThat(result.ok||result.status===412,'retained storage write failed');}
}
export class AuditCollector {
  constructor({store,storage,maxLogBytes}){this.store=store;this.storage=storage;this.maxLogBytes=maxLogBytes;this.queue=Promise.resolve();}
  append(record,now){const result=this.queue.then(()=>this.write(record,now));this.queue=result.catch(()=>{});return result;}
  async write(record,now){identifier(record.task);identifier(record.grant);identifier(record.host);integer(record.seq,0,1000000,'audit sequence');integer(record.generation,1,1000000,'lease generation');requireThat(typeof record.data==='string'&&record.data.length<=262144,'audit segment too large');
    const existing=this.store.logs(record.task,record.seq-1).find(e=>e.seq===record.seq);if(existing){requireThat(existing.data===canonical(record),'audit sequence collision');return{digest:digest(existing.data)};}
    const rows=this.store.db.prepare('SELECT seq,data FROM logs WHERE task=? ORDER BY seq').all(record.task);requireThat(record.seq===rows.length,'audit sequence gap');requireThat(rows.reduce((n,r)=>n+Buffer.byteLength(r.data),0)+Buffer.byteLength(canonical(record))<=this.maxLogBytes,'audit budget exceeded');
    const previous=rows.length?digest(rows.at(-1).data):'0'.repeat(64);const entry=Buffer.from(canonical({record,previous,at:now}));const hash=digest(entry);await this.storage.put(record.grant+'/'+record.task+'/'+record.seq+'-'+hash,entry);
    this.store.appendLog(record.task,record.seq,canonical(record),this.maxLogBytes);this.store.event('audit.received',{task:record.task,seq:record.seq,digest:hash},now);return{digest:digest(canonical(record)),objectDigest:hash};
  }
}
