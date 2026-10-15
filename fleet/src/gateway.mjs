import {Readable} from 'node:stream';
import {pipeline} from 'node:stream/promises';
import {requireThat,integer} from './canonical.mjs';
import {json,send,guarded} from './http.mjs';
import {accessToken,identityToken} from './gcp.mjs';

export function createGateway({config,authorize,openaiToken,anthropicToken,fetcher=fetch,vertexProject,vertexRegion='us-east5',vertexToken=accessToken}){
  const active=new Map();let total=0;
  return guarded(async(req,res)=>{
    const url=new URL(req.url,'https://gateway.invalid');if(url.pathname==='/healthz'){send(res,200,{ok:true});return;}
    const routes={'/v1/responses':'codex','/v1/messages':'claude','/v1/messages/count_tokens':'claude'};const vendor=routes[url.pathname];requireThat(req.method==='POST'&&vendor,'unsupported model endpoint');
    const auth=req.headers.authorization?.replace(/^Bearer /,'')??req.headers['x-api-key'];requireThat(typeof auth==='string','authentication required');const separator=auth.indexOf('.');requireThat(separator>0,'invalid task capability');const task=auth.slice(0,separator),capability=auth.slice(separator+1);
    if(total>=Math.min(256,config.maxAgents*2)||(active.get(task)??0)>=2){res.setHeader('retry-after','1');send(res,429,{error:'gateway concurrency limit'});return;}
    total++;active.set(task,(active.get(task)??0)+1);try{
    const payload=await json(req,4*1024*1024);requireThat(typeof payload.model==='string'&&config.models[vendor].includes(payload.model),'model outside allowlist');
    const allowance=await authorize({task,capability,model:payload.model,vendor});
    const outputField=vendor==='codex'?'max_output_tokens':'max_tokens';if(url.pathname!=='/v1/messages/count_tokens'){payload[outputField]??=allowance.maxOutputTokens;integer(payload[outputField],1,allowance.maxOutputTokens,'output token budget');}
    const headers={'content-type':'application/json'};let upstream;
    if(vendor==='codex'){requireThat(openaiToken,'OpenAI federation is not configured');upstream='https://api.openai.com/v1/responses';headers.authorization='Bearer '+await openaiToken();}
    else if(vertexProject){requireThat(/^[a-z][a-z0-9-]+$/.test(vertexProject)&&/^[a-z0-9-]+$/.test(vertexRegion),'invalid Vertex location');
      const counting=url.pathname==='/v1/messages/count_tokens',model=payload.model;if(!counting)delete payload.model;
      payload.anthropic_version='vertex-2023-10-16';const route=counting?'count-tokens:rawPredict':encodeURIComponent(model)+':'+(payload.stream?'streamRawPredict':'rawPredict');
      upstream='https://'+vertexRegion+'-aiplatform.googleapis.com/v1/projects/'+vertexProject+'/locations/'+vertexRegion+'/publishers/anthropic/models/'+route;headers.authorization='Bearer '+await vertexToken();
      if(req.headers['anthropic-beta'])headers['anthropic-beta']=req.headers['anthropic-beta'];
    }else{requireThat(anthropicToken,'Claude backend is not configured');upstream='https://api.anthropic.com'+url.pathname;headers['x-api-key']=await anthropicToken();headers['anthropic-version']=req.headers['anthropic-version']??'2023-06-01';if(req.headers['anthropic-beta'])headers['anthropic-beta']=req.headers['anthropic-beta'];}
    const abort=new AbortController();res.on('close',()=>{if(!res.writableEnded)abort.abort();});
    const response=await fetcher(upstream,{method:'POST',headers,body:JSON.stringify(payload),redirect:'error',signal:AbortSignal.any([abort.signal,AbortSignal.timeout(600000)])});
    requireThat(response.status<300||response.status>=400,'provider redirect rejected');res.writeHead(response.status,{'content-type':response.headers.get('content-type')??'application/json','cache-control':'no-store',...(response.headers.get('retry-after')?{'retry-after':response.headers.get('retry-after')}:{})});
    if(response.body)await pipeline(Readable.fromWeb(response.body),res);else res.end();
    }finally{total--;const count=(active.get(task)??1)-1;if(count)active.set(task,count);else active.delete(task);}
  });
}

export function openaiFederation({providerID,serviceAccountID,audience='https://api.openai.com/v1',fetcher=fetch,subjectToken=()=>identityToken(audience)}){
  let cached,pending;
  async function exchange(){const response=await fetcher('https://auth.openai.com/oauth/token',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({grant_type:'urn:ietf:params:oauth:grant-type:token-exchange',subject_token_type:'urn:ietf:params:oauth:token-type:jwt',subject_token:await subjectToken(),identity_provider_id:providerID,service_account_id:serviceAccountID}),redirect:'error',signal:AbortSignal.timeout(15000)});requireThat(response.ok,'OpenAI workload federation rejected');const result=await response.json();requireThat(typeof result.access_token==='string'&&Number.isFinite(result.expires_in)&&result.expires_in>0&&result.expires_in<=86400,'invalid federation response');cached={token:result.access_token,until:Date.now()+result.expires_in*1000};return cached.token;}
  return async()=>{if(cached&&cached.until>Date.now()+60000)return cached.token;if(!pending)pending=exchange().finally(()=>{pending=undefined;});return pending;};
}
