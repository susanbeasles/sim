import {request as httpsRequest} from 'node:https';
import {requireThat} from './canonical.mjs';

export class APIClient {
  constructor({url,token,ca,headers={}}){this.url=new URL(url);requireThat(this.url.protocol==='https:'&&!this.url.username&&!this.url.password,'HTTPS required');this.token=token;this.ca=ca;this.headers=headers;}
  async request(path,{method='GET',body,raw,rawResponse=false,headers={}}={}){
    requireThat(path.startsWith('/')&&!path.startsWith('//'),'invalid API path');const bytes=raw??(body===undefined?undefined:Buffer.from(JSON.stringify(body)));const auth=await this.token();
    return new Promise((resolve,reject)=>{const req=httpsRequest(new URL(path,this.url),{method,ca:this.ca,headers:{authorization:'Bearer '+auth,...this.headers,...headers,...(raw?{}:{'content-type':'application/json'}),...(bytes?{'content-length':bytes.length}:{})},timeout:30000},res=>{const chunks=[];let length=0;res.on('data',b=>{length+=b.length;if(length>96*1024*1024){res.destroy(new Error('response exceeds limit'));return;}chunks.push(b);});res.on('error',reject);res.on('end',()=>{const buffer=Buffer.concat(chunks);if(res.statusCode<200||res.statusCode>=300){reject(new Error('fleet API rejected request ('+res.statusCode+'): '+buffer.toString().slice(0,1000)));return;}if(rawResponse){resolve(buffer);return;}try{resolve(JSON.parse(buffer));}catch(e){reject(e);}});});req.on('error',reject);req.on('timeout',()=>req.destroy(new Error('fleet API timeout')));req.end(bytes);});
  }
}

