import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,rmSync,mkdirSync,symlinkSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {releaseManifest,verifyReleaseFiles} from '../src/release.mjs';

test('release verification catches changed, additional and symlinked executable payloads',async()=>{
 const root=mkdtempSync(join(tmpdir(),'sim-release-'));
 try{
  mkdirSync(join(root,'src'));writeFileSync(join(root,'src/a.mjs'),'export const value=1;');
  const manifest=await releaseManifest(root);assert.equal(manifest.files.length,1);await verifyReleaseFiles(root,manifest);
  writeFileSync(join(root,'src/a.mjs'),'export const value=2;');await assert.rejects(()=>verifyReleaseFiles(root,manifest));
  writeFileSync(join(root,'src/a.mjs'),'export const value=1;');writeFileSync(join(root,'src/extra.mjs'),'unexpected');await assert.rejects(()=>verifyReleaseFiles(root,manifest));
  rmSync(join(root,'src/extra.mjs'));symlinkSync('/etc/passwd',join(root,'src/link'));await assert.rejects(()=>verifyReleaseFiles(root,manifest));
 }finally{rmSync(root,{recursive:true,force:true});}
});

test('image bootstrap authenticates the release before executing bundled verifier code',()=>{
 const root=mkdtempSync(join(tmpdir(),'sim-bootstrap-'));
 try{mkdirSync(join(root,'bin'));writeFileSync(join(root,'bin/release.mjs'),'throw Error("untrusted verifier executed");');writeFileSync(join(root,'release.json'),'{}');
 const result=spawnSync('bash',[fileURLToPath(new URL('../deploy/install-host',import.meta.url)),'--verify-only',root,'0'.repeat(64),join(root,'public-key')],{encoding:'utf8'});
 assert.notEqual(result.status,0);assert.match(result.stderr,/release digest rejected/);assert.doesNotMatch(result.stderr,/untrusted verifier executed/);
 }finally{rmSync(root,{recursive:true,force:true});}
});
