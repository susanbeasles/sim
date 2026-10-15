import { randomUUID } from 'node:crypto';
import { identifier, requireThat } from './canonical.mjs';

const metadata='http://metadata.google.internal/computeMetadata/v1/';
export async function metadataValue(path){requireThat(/^[a-zA-Z0-9/%?=&._:-]+$/.test(path),'invalid metadata path');const response=await fetch(metadata+path,{headers:{'Metadata-Flavor':'Google'},redirect:'error',signal:AbortSignal.timeout(5000)});requireThat(response.ok,'metadata identity unavailable');return response.text();}
const identities=new Map();
export async function identityToken(audience){let entry=identities.get(audience);if(entry?.until>Date.now())return entry.value;if(!entry?.pending){entry={pending:metadataValue('instance/service-accounts/default/identity?format=full&audience='+encodeURIComponent(audience)).then(value=>{identities.set(audience,{value,until:Date.now()+120000});return value;}).catch(error=>{identities.delete(audience);throw error;})};identities.set(audience,entry);}return entry.pending;}
let token,pendingToken;
export async function accessToken(){if(token?.until>Date.now()+60000)return token.value;if(!pendingToken)pendingToken=(async()=>{const value=JSON.parse(await metadataValue('instance/service-accounts/default/token'));requireThat(typeof value.access_token==='string'&&Number.isFinite(value.expires_in)&&value.expires_in>0,'invalid metadata token');token={value:value.access_token,until:Date.now()+value.expires_in*1000};return token.value;})().finally(()=>{pendingToken=undefined;});return pendingToken;}

export class GCPProvider {
  constructor({config,fetcher=fetch,accessToken:tokens=accessToken}){this.config=config;this.fetcher=fetcher;this.tokens=tokens;}
  async request(path,{method='GET',body,query}={}){const url=new URL('https://compute.googleapis.com/compute/v1/projects/'+this.config.project+'/'+path);if(query)for(const[k,v]of Object.entries(query))url.searchParams.set(k,v);
    const response=await this.fetcher(url.toString(),{method,headers:{authorization:'Bearer '+await this.tokens(),'content-type':'application/json'},body:body?JSON.stringify(body):undefined,redirect:'error',signal:AbortSignal.timeout(30000)});
    if(!response.ok){const error=new Error('GCP operation failed ('+response.status+')');error.status=response.status;throw error;}const result=await response.json();requireThat(!result.error,'GCP operation error');return result;}
  zone(zone){requireThat(this.config.zones.includes(zone),'zone outside fleet');return 'zones/'+zone;}
  async create(host){identifier(host.name);identifier(host.grantID);const zone=this.zone(host.zone);return this.request(zone+'/instances',{method:'POST',query:{sourceInstanceTemplate:this.config.template,requestId:host.requestID??randomUUID()},body:{name:host.name,labels:{'sim-fleet':this.config.fleet,'sim-grant':host.grantID,'sim-expires-at':String(host.expiresAt)}}});}
  async describe(name,zone){identifier(name);return this.request(this.zone(zone)+'/instances/'+name);}
  async remove(host){identifier(host.name);const zone=this.zone(host.zone);let operation;
    try{operation=await this.request(zone+'/instances/'+host.name,{method:'DELETE',query:{requestId:randomUUID()}});}catch(error){if(error.status===404)return{status:'DONE'};throw error;}
    if(operation.status!=='DONE'){identifier(operation.name);operation=await this.request(zone+'/operations/'+operation.name+'/wait',{method:'POST'});}
    requireThat(operation.status==='DONE','host deletion still pending');return operation;
  }
  async list(){const hosts=[];for(const zone of this.config.zones){let pageToken;do{const data=await this.request(this.zone(zone)+'/instances',{query:{filter:'labels.sim-fleet = '+this.config.fleet,...(pageToken?{pageToken}:{})}});for(const vm of data.items??[])hosts.push({...vm,zone});pageToken=data.nextPageToken;}while(pageToken);}return hosts;}
  async verifyHost(name,zone,claims){const ce=claims.google?.compute_engine;requireThat(ce&&ce.project_id===this.config.project&&ce.zone===zone,'host identity missing compute claims');const vm=await this.describe(name,zone);requireThat(String(vm.id)===String(ce.instance_id)&&vm.name===name,'host instance identity mismatch');requireThat(vm.labels?.['sim-fleet']===this.config.fleet&&vm.metadata?.items?.some(i=>i.key==='sim-release-digest'&&i.value===this.config.releaseDigest),'host release provenance rejected');return vm;}
}

