import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync,writeFileSync,readFileSync,rmSync,mkdirSync,existsSync,symlinkSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {Store} from '../src/store.mjs';
import {configuration} from './fixtures.mjs';
import {parseArgs,plan,reviewPatch,snapshot,logPages} from '../src/cli.mjs';

test('terminal plan computes four hosts for 200 agents and rejects unknown options',()=>{
 const config=configuration();const p=plan(config,{count:200,profile:'light',seconds:3600,maxCostMicros:50000000});
 assert.equal(p.hosts,4);assert.equal(p.computeEstimateMicros,8000000);assert.equal(p.rootless,true);
 assert.throws(()=>plan(config,{count:201,profile:'light',seconds:3600,maxCostMicros:50000000}));
 assert.throws(()=>parseArgs(['create','--insecure'],['--count']));
});
test('candidate review ignores host clean filters and includes tracked-but-ignored baseline files',async()=>{
 const root=mkdtempSync(join(tmpdir(),'sim-review-')),old=process.env.GIT_CONFIG_GLOBAL;
 try{const baseline=join(root,'baseline'),candidate=join(root,'candidate'),marker=join(root,'executed');mkdirSync(baseline);mkdirSync(candidate);
 for(const directory of [baseline,candidate]){writeFileSync(join(directory,'.gitignore'),'ignored.txt\n');writeFileSync(join(directory,'.gitattributes'),'*.txt filter=unsafe\n');}
 writeFileSync(join(baseline,'ignored.txt'),'before\n');writeFileSync(join(candidate,'ignored.txt'),'after\n');const global=join(root,'global');writeFileSync(global,'[filter "unsafe"]\n clean = touch '+marker+'; cat\n');process.env.GIT_CONFIG_GLOBAL=global;
 const patch=await reviewPatch(baseline,candidate,1024*1024);assert.match(patch,/-before\n\+after/);assert.equal(existsSync(marker),false);
 }finally{if(old===undefined)delete process.env.GIT_CONFIG_GLOBAL;else process.env.GIT_CONFIG_GLOBAL=old;rmSync(root,{recursive:true,force:true});}
});
test('snapshot refuses tracked children reached through an ignored directory symlink',async()=>{
 const root=mkdtempSync(join(tmpdir(),'sim-source-link-')),repo=join(root,'repo');mkdirSync(repo);mkdirSync(join(repo,'src'));mkdirSync(join(root,'outside'));
 const git=args=>execFileSync('/usr/bin/git',['-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','-C',repo,...args],{stdio:'ignore'});
 try{git(['init','-q']);writeFileSync(join(repo,'src/a.txt'),'safe');writeFileSync(join(repo,'.gitignore'),'/src\n');git(['add','-f','.']);git(['-c','user.name=fixture','-c','user.email=fixture@invalid','commit','-qm','baseline']);
 rmSync(join(repo,'src'),{recursive:true});writeFileSync(join(root,'outside/a.txt'),'OUTSIDE_SECRET');symlinkSync(join(root,'outside'),join(repo,'src'));
 await assert.rejects(()=>snapshot(repo,1048576),/symlink|nonregular/);
 }finally{rmSync(root,{recursive:true,force:true});}
});
test('CLI help and offline plan do not require credentials or initialize a remote session',()=>{
 const dir=mkdtempSync(join(tmpdir(),'sim-cli-'));
 try{
  const path=join(dir,'config.json');writeFileSync(path,JSON.stringify(configuration()));
  const entry=fileURLToPath(new URL('../bin/sim-fleet.mjs',import.meta.url));
  const help=execFileSync(process.execPath,[entry,'help'],{encoding:'utf8'});assert.match(help,/authorize/);
  const output=execFileSync(process.execPath,[entry,'plan','--config',path,'--count','200','--profile','light','--seconds','3600','--budget-micros','50000000'],{encoding:'utf8'});
  assert.equal(JSON.parse(output).hosts,4);
 }finally{rmSync(dir,{recursive:true,force:true});}
});

test('completed log retrieval drains every SQLite page in sequence',async()=>{
 const store=new Store(':memory:');try{for(let i=0;i<201;i++)store.appendLog('task-one',i,'ciphertext',100000);
 const api={request:async path=>({logs:store.logs('task-one',Number(new URL(path,'https://unused.invalid').searchParams.get('after'))),state:'completed'})};
 const rows=[];for await(const row of logPages(api,'task-one'))rows.push(row);assert.equal(rows.length,201);assert.equal(rows.at(-1).seq,200);
 }finally{store.close();}
});
