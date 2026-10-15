import {mkdtemp,mkdir,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {digest,requireThat} from './canonical.mjs';
import {seal,open} from './crypto.mjs';
import {extractBundle,decodeBundle} from './artifacts.mjs';

export function agentCommand(grant,config){
  const args=[...grant.args];
  if(grant.vendor==='codex')args.push('-c','model_provider="sim-fleet"','-c','model_providers.sim-fleet={name="SIM Fleet",base_url='+JSON.stringify(config.gatewayURL+'/v1')+',env_key="OPENAI_API_KEY",wire_api="responses",requires_openai_auth=false,supports_websockets=false}');
  args.push('--model',grant.model);return{vendor:grant.vendor,args};
}

export class Worker {
  constructor({config,api,runtime,host,root='/run/sim-worker',clock=()=>Math.floor(Date.now()/1000)}){this.config=config;this.api=api;this.runtime=runtime;this.host=host;this.root=root;this.clock=clock;this.running=new Map();}
  async execute(task){
    const key=Buffer.from(task.key,'base64');delete task.key;const abort=new AbortController();this.running.set(task.id,abort);
    await mkdir(this.root,{recursive:true,mode:0o700});const directory=await mkdtemp(join(this.root,'task-'));let timer,heartbeat=Promise.resolve(),evidence=Promise.resolve(),seq=0,failed;
    const request=(action,options={})=>this.api.request('/v1/tasks/'+task.id+'/'+action,{...options,headers:{'x-sim-host':this.host,'x-sim-generation':String(task.generation)}});
    const record=bytes=>{const segment=seal(bytes,key,'audit/'+task.id+'/'+seq);const index=seq++;evidence=evidence.then(()=>request('logs',{method:'POST',body:{seq:index,data:segment.toString('base64')}})).catch(error=>{failed=error;abort.abort(error);throw error;});return evidence;};
    const renew=async()=>{try{const result=await request('heartbeat',{method:'POST',body:{}});if(result.input?.length)await this.runtime.input(task,result.input);}catch(e){failed=e;abort.abort(e);throw e;}};
    try{
      // VM/template preparation can exceed a lease. Renew throughout startup.
      await renew();timer=setInterval(()=>{heartbeat=heartbeat.then(renew).catch(()=>{});},Math.max(1000,Math.floor(this.config.leaseSeconds*1000/3)));timer.unref();
      const ciphertext=await request('source',{rawResponse:true});requireThat(digest(ciphertext)===task.grant.sourceDigest,'source ciphertext mismatch');const plaintext=open(ciphertext,key,'source');requireThat(digest(plaintext)===task.grant.plaintextDigest,'source plaintext mismatch');extractBundle(plaintext,join(directory,'source'),this.config.maxArtifactBytes);
      await this.runtime.create(task,join(directory,'source'));
      abort.signal.throwIfAborted();task.command=agentCommand(task.grant,this.config);
      const capability=task.id+'.'+task.capability;
      const environment=task.grant.vendor==='codex'?{OPENAI_BASE_URL:this.config.gatewayURL+'/v1',OPENAI_API_KEY:capability,SIM_TASK_ID:task.id}:{ANTHROPIC_BASE_URL:this.config.gatewayURL,ANTHROPIC_AUTH_TOKEN:capability,SIM_TASK_ID:task.id};
      environment.NODE_EXTRA_CA_CERTS='/usr/local/share/ca-certificates/sim-fleet.crt';
      const proxy=new URL(this.config.gatewayURL);proxy.username=task.id;proxy.password=task.capability;
      for(const name of ['HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy'])environment[name]=proxy.toString();
      environment.NO_PROXY=environment.no_proxy=new URL(this.config.gatewayURL).hostname;environment.NODE_USE_ENV_PROXY='1';
      if(task.grant.vendor==='claude')environment.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1';
      const exitCode=await this.runtime.launch(task,environment,record,abort.signal);await evidence;requireThat(!failed,'audit or heartbeat failed');
      const resultPath=join(directory,'candidate.json');await this.runtime.collect(task,resultPath);const decoded=decodeBundle(await readFile(resultPath),this.config.maxArtifactBytes);decoded.baseCommit=decodeBundle(plaintext,this.config.maxArtifactBytes).baseCommit;const candidate=Buffer.from(JSON.stringify(decoded));abort.signal.throwIfAborted();
      const result=seal(candidate,key,'result/'+task.id);const uploaded=await request('artifact',{method:'PUT',raw:result});
      await record(Buffer.from(JSON.stringify({kind:'task.completed',exitCode,resultDigest:uploaded.digest})));await evidence;
      await request('finish',{method:'POST',body:{exitCode,result:uploaded}});
    }catch(e){await request('finish',{method:'POST',body:{exitCode:1,result:null}}).catch(()=>{});throw e;
    }finally{clearInterval(timer);abort.abort();await heartbeat.catch(()=>{});await evidence.catch(()=>{});await this.runtime.remove(task).catch(()=>{});key.fill(0);await rm(directory,{recursive:true,force:true});this.running.delete(task.id);}
  }
  async tick(){const result=await this.api.request('/v1/hosts/poll',{method:'POST',body:{host:this.host}});if(result.task){const promise=this.execute(result.task);promise.catch(e=>process.stderr.write('task failed: '+e.message+'\n'));}return result.task?.id??null;}
  stop(){for(const abort of this.running.values())abort.abort(new Error('worker stopping'));}
}

