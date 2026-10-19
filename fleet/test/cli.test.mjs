import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync,writeFileSync,readFileSync,rmSync,mkdirSync,existsSync,symlinkSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {Store} from '../src/store.mjs';
import {configuration} from './fixtures.mjs';
import {parseArgs,plan,reviewPatch,snapshot,logPages,hostGit,applyRemotePatch} from '../src/cli.mjs';

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
 const patch=await reviewPatch(baseline,candidate,1024*1024);assert.match(patch,/GIT binary patch/);assert.equal(existsSync(marker),false);
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

test('remote host Git refuses configured filters before status or apply can execute them',async()=>{
 const root=mkdtempSync(join(tmpdir(),'sim-import-filter-')),marker=join(root,'executed');
 const git=args=>execFileSync('/usr/bin/git',['-C',root,...args],{stdio:'ignore'});
 try{git(['init','-q']);git(['config','filter.unsafe.clean','touch '+marker+'; cat']);
 writeFileSync(join(root,'.gitattributes'),'*.txt filter=unsafe\n');writeFileSync(join(root,'payload.txt'),'candidate');
 for(const args of [['status','--porcelain'],['apply','--3way','--index','--binary','-']])
  await assert.rejects(()=>hostGit(root,args,{input:''}),/configured Git filters/);
 assert.equal(existsSync(marker),false);
 git(['config','--remove-section','filter.unsafe']);
 assert.match((await hostGit(root,['status','--porcelain'])).stdout,/payload/);
 }finally{rmSync(root,{recursive:true,force:true});}
});
test('fleet review binds raw bytes despite candidate EOL attributes',async()=>{
 const patches=[];
 for(const content of ['authorized\n','authorized\r\n']){
  const root=mkdtempSync(join(tmpdir(),'sim-raw-review-'));
  try{const baseline=join(root,'baseline'),candidate=join(root,'candidate');mkdirSync(baseline);mkdirSync(candidate);
   writeFileSync(join(candidate,'.gitattributes'),'payload.txt text eol=lf\n');writeFileSync(join(candidate,'payload.txt'),content);
   patches.push(await reviewPatch(baseline,candidate,1048576));
  }finally{rmSync(root,{recursive:true,force:true});}
 }
 assert.notEqual(patches[0],patches[1]);
});

test('real remote import rejects conversions and verifies exact staged and raw candidate bytes',async()=>{
 for(const scenario of ['plain','same-tree-new-head','candidate-base-mismatch','unchanged-attributes','invalid-utf8','autocrlf','global-filter','local-clean','local-smudge','local-process','info-ident','info-eol','info-crlf','info-encoding','candidate-attributes']){
  const root=mkdtempSync(join(tmpdir(),'sim-exact-import-')),oldGlobal=process.env.GIT_CONFIG_GLOBAL;
  try{
   const repo=join(root,'host'),review=join(root,'review'),candidate=join(root,'candidate'),marker=join(root,'filter-ran');
   for(const dir of [repo,review,candidate])mkdirSync(dir);
   const before=Buffer.from('BASELINE\n'),after=scenario==='invalid-utf8'?Buffer.from([255,10]):Buffer.from('CANDIDATE\r\n');
   for(const dir of [repo,review])writeFileSync(join(dir,'victim.txt'),before);
   writeFileSync(join(candidate,'victim.txt'),after);
   const git=args=>execFileSync('/usr/bin/git',['-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','-C',repo,...args],{encoding:'utf8',stdio:['pipe','pipe','pipe']});
   if(scenario==='unchanged-attributes')for(const dir of [repo,review,candidate])writeFileSync(join(dir,'.gitattributes'),'# no conversions\n');
   git(['init','-q']);git(['add','-A']);git(['-c','user.name=fixture','-c','user.email=fixture@invalid','commit','-qm','baseline']);
   const baseCommit=git(['rev-parse','HEAD']).trim();
   const baseline={schema:1,baseCommit,files:[{path:'victim.txt',mode:420,data:before.toString('base64')}]};
   const next={schema:1,baseCommit,files:[{path:'victim.txt',mode:420,data:after.toString('base64')}]};
   if(scenario==='unchanged-attributes')for(const tree of [baseline,next])tree.files.push({path:'.gitattributes',mode:420,data:Buffer.from('# no conversions\n').toString('base64')});
   if(scenario==='autocrlf')git(['config','core.autocrlf','true']);
   if(scenario==='global-filter'){
    const config=join(root,'global');writeFileSync(config,'[filter "unsafe"]\n clean = touch '+marker+'; cat\n smudge = touch '+marker+'; cat\n');process.env.GIT_CONFIG_GLOBAL=config;writeFileSync(join(repo,'.git/info/attributes'),'* filter=unsafe\n');
   }
   if(['local-clean','local-smudge','local-process'].includes(scenario)){
    git(['config','filter.unsafe.'+scenario.slice('local-'.length),'touch '+marker+'; cat']);
    writeFileSync(join(repo,'.git/info/attributes'),'* filter=unsafe\n');
   }
   if(scenario==='info-ident')writeFileSync(join(repo,'.git/info/attributes'),'* ident\n');
   if(scenario==='info-eol')writeFileSync(join(repo,'.git/info/attributes'),'* text eol=crlf\n');
   if(scenario==='info-crlf')writeFileSync(join(repo,'.git/info/attributes'),'* crlf=input\n');
   if(scenario==='info-encoding')writeFileSync(join(repo,'.git/info/attributes'),'* working-tree-encoding=UTF-16\n');
   if(scenario==='candidate-attributes'){
    const data=Buffer.from('*.txt working-tree-encoding=UTF-16\n');writeFileSync(join(candidate,'.gitattributes'),data);
    next.files.push({path:'.gitattributes',mode:420,data:data.toString('base64')});
   }
   if(scenario==='candidate-base-mismatch')next.baseCommit='0'.repeat(40);
   if(scenario==='same-tree-new-head')git(['-c','user.name=fixture','-c','user.email=fixture@invalid','commit','--allow-empty','-qm','different history']);
   const patch=await reviewPatch(review,candidate,1048576);
   if(['plain','unchanged-attributes','invalid-utf8','autocrlf'].includes(scenario)){
    await applyRemotePatch(repo,patch,baseline,next,1048576);
    assert.deepEqual(readFileSync(join(repo,'victim.txt')),after,scenario);
    assert.deepEqual(execFileSync('/usr/bin/git',['-C',repo,'show',':victim.txt']),after,scenario);
   }else{
    await assert.rejects(()=>applyRemotePatch(repo,patch,baseline,next,1048576),/configured Git filters|conversion attributes|attribute-file transactions|baseline commit/,scenario);
    assert.deepEqual(readFileSync(join(repo,'victim.txt')),before,scenario);
    assert.equal(git(['show',':victim.txt']),before.toString(),scenario);
   }
   assert.equal(existsSync(marker),false,scenario);
  }finally{if(oldGlobal===undefined)delete process.env.GIT_CONFIG_GLOBAL;else process.env.GIT_CONFIG_GLOBAL=oldGlobal;rmSync(root,{recursive:true,force:true});}
 }
});
