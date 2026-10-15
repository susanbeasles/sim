import { spawn } from 'node:child_process';
export function run(file,args,{input,timeout=30000,maxBytes=1048576,env,signal}={}) {
  return new Promise((resolve,reject)=>{
    const child=spawn(file,args,{env,signal,timeout,stdio:['pipe','pipe','pipe']});let size=0;const stdout=[],stderr=[];
    const collect=(target)=>(chunk)=>{size+=chunk.length;if(size>maxBytes){child.kill('SIGKILL');reject(new Error('subprocess output limit exceeded'));return;}target.push(chunk);};
    child.stdout.on('data',collect(stdout));child.stderr.on('data',collect(stderr));child.on('error',reject);
    child.on('close',(code,signal)=>{if(code!==0)reject(new Error('command failed: '+file+' (exit '+code+', signal '+signal+')'));else resolve({code,stdout:Buffer.concat(stdout).toString(),stderr:Buffer.concat(stderr).toString()});});
    child.stdin.on('error',()=>{});child.stdin.end(input);
  });
}

export async function stream(file,args,{input,onOutput,signal,maxBytes,timeout}) {
  const child=spawn(file,args,{signal,timeout,stdio:['pipe','pipe','pipe']});let size=0;
  const completion=new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',code=>resolve(code??1));});
  completion.catch(()=>{});child.stdin.on('error',()=>{});child.stdin.end(input);
  async function consume(readable){for await(const bytes of readable){size+=bytes.length;if(size>maxBytes)throw new Error('task output budget exceeded');await onOutput(bytes);}}
  try{await Promise.all([consume(child.stdout),consume(child.stderr)]);return await completion;}
  catch(e){child.kill('SIGKILL');await completion.catch(()=>{});throw e;}
}

