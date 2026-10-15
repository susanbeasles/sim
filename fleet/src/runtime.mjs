import {fileURLToPath} from 'node:url';
import {join,dirname} from 'node:path';
import {run as execute,stream} from './process.mjs';
import {identifier,requireThat} from './canonical.mjs';

const guestDirectory=fileURLToPath(new URL('../guest/',import.meta.url));
export class SBXRuntime {
  constructor({config,run=execute,executable='/usr/local/bin/sbx'}){this.config=config;this.run=run;this.executable=executable;}
  name(task){identifier(task.id);requireThat(Number.isInteger(task.generation)&&task.generation>0,'invalid lease generation');return 'sim-'+task.id+'-'+task.generation;}
  async call(args,options){return this.run(this.executable,args,options);}
  async preflight(){await this.run('/usr/bin/test',['-r','/dev/kvm']);await this.run('/usr/bin/test',['-w','/dev/kvm']);await this.call(['version']);await this.call(['policy','init','deny-all']);}
  async exec(task,args,options){return this.call(['exec','--user','root',this.name(task),...args],options);}
  async create(task,source){const p=this.config.profiles[task.grant.profile];requireThat(p,'unknown profile');const name=this.name(task);
    await this.call(['create','--name',name,'--skills','off','--cpus',String(p.cpus),'--memory',p.memoryMiB+'MiB','--template',this.config.sandboxTemplate,'shell'],{timeout:120000});
    try{
      const gateway=new URL(this.config.gatewayURL);
      await this.call(['policy','allow','network','--sandbox',name,gateway.host]);
      for(const destination of ['169.254.0.0/16','127.0.0.0/8','::1/128','fe80::/10'])await this.call(['policy','deny','network','--sandbox',name,destination]);
      await this.exec(task,['mkdir','-p','/usr/local/libexec/sim-guest','/var/lib/sim-input']);
      await this.call(['cp',guestDirectory+'/.',name+':/usr/local/libexec/sim-guest/']);
      await this.call(['cp',source,name+':/var/lib/sim-input/source']);
      await this.exec(task,['/usr/local/libexec/sim-guest/setup',task.id,this.config.workerImage,gateway.hostname,String(p.diskMiB),String(p.cpus),String(p.memoryMiB)],{timeout:120000});
    }catch(e){await this.remove(task).catch(()=>{});throw e;}
  }
  async launch(task,environment,onOutput,signal){
    return stream(this.executable,['exec','--user','root',this.name(task),'/usr/local/libexec/sim-guest/supervise',task.id],{input:JSON.stringify({...task.command,environment,maxLogBytes:this.config.maxLogBytes,maxDiskBytes:this.config.profiles[task.grant.profile].diskMiB*1024*1024}),timeout:Math.max(1,(task.expires-Math.floor(Date.now()/1000))*1000),signal,maxBytes:this.config.maxLogBytes,onOutput});
  }
  async input(task,entries){for(const entry of entries)await this.exec(task,['/usr/local/libexec/sim-guest/input',String(entry.seq),entry.data],{maxBytes:4096});}
  async collect(task,destination){await this.exec(task,['/usr/local/libexec/sim-guest/export',task.id],{timeout:30000,maxBytes:4096});await this.call(['cp',this.name(task)+':/var/lib/sim-output/candidate.json',destination],{timeout:30000});}
  async remove(task){await this.call(['rm','--force',this.name(task)],{timeout:60000});}
}

