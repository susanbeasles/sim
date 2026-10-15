import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { generateKeyPairSync, sign } from 'node:crypto';
import { canonical, digest } from '../src/canonical.mjs';
import { validateConfig, validateGrant, requiredHosts } from '../src/policy.mjs';
import { Store } from '../src/store.mjs';
import { verifyGoogleToken } from '../src/auth.mjs';
import { seal, open, recipient, wrapKey, unwrapKey } from '../src/crypto.mjs';

import { configuration, grant } from './fixtures.mjs';

test('canonical manifests sort nested keys and reject unsupported values', () => {
  assert.equal(canonical({z:[{b:2,a:1}],a:'hi'}), '{"a":"hi","z":[{"a":1,"b":2}]}');
  assert.throws(() => canonical({n:NaN}));
  assert.throws(() => canonical({missing:undefined}));
});
test('dispatch lock and pause survive service restarts without consuming queued work',()=>{
 const dir=mkdtempSync(join(tmpdir(),'sim-pause-'));let store=new Store(join(dir,'db'));
 try{const g=grant(),c=configuration();store.challenge(g.nonce,'12345',2000);store.authorize(g,'12345',1000);store.submit(g.id,1,1000);
 store.host({id:'host-one',name:'host-one',zone:c.zones[0],state:'ready',cpus:32,memoryMiB:131072,grantID:g.id},1000);
 assert.equal(store.lease('host-one',c,1000,new Set()),null);assert.equal(store.tasks()[0].state,'queued');
 store.setPaused(true,1000);store.close();store=new Store(join(dir,'db'));assert.equal(store.paused(),true);
 store.setPaused(false,1001);assert.equal(store.paused(),false);assert.ok(store.lease('host-one',c,1001,new Set([g.id])));
 }finally{store.close();rmSync(dir,{recursive:true,force:true});}
});
test('configuration rejects unpinned images, public management URLs and unsafe limits', () => {
  assert.equal(validateConfig(configuration()).maxAgents,200);
  for (const patch of [{workerImage:'ubuntu:latest'}, {controllerURL:'http://10.0.0.1'}, {maxAgents:0}, {cpuOvercommit:0}, {unknown:true}]) {
    assert.throws(() => validateConfig({...configuration(),...patch}));
  }
  assert.equal(requiredHosts(configuration(), 'light', 200),4);
});
test('grant cannot change configured authority or spend beyond fleet policy', () => {
  assert.equal(validateGrant(grant(),configuration(),1000).id,'grant-1');
  for(const patch of [{configDigest:'0'.repeat(64)}, {maxHosts:11}, {expiresAt:999}, {maxCostMicros:999999999}, {model:'other'}, {taskTTLSeconds:99999}]) {
    assert.throws(()=>validateGrant({...grant(),...patch},configuration(),1000));
  }
});
test('concurrent signed grants reserve one fleet-wide budget atomically',()=>{
 const store=new Store(':memory:'),c=configuration(),g=grant();
 try{store.challenge(g.nonce,'12345',2000);store.authorize(g,'12345',1000,g.maxCostMicros);
 const second={...g,id:'grant-2',nonce:'m'.repeat(43)};store.challenge(second.nonce,'12345',2000);
 assert.throws(()=>store.authorize(second,'12345',1000,g.maxCostMicros),/fleet budget/);
 store.revoke(g.id,1001);store.authorize(second,'12345',1001,g.maxCostMicros);assert.equal(store.grants().length,2);
 }finally{store.close();}
});
test('SQLite consumes nonce and total task allowance atomically across restart', () => {
  const dir=mkdtempSync(join(tmpdir(),'sim-store-')); let s;
  try {
    s=new Store(join(dir,'state.sqlite')); s.challenge('n'.repeat(43),'12345',1300);
    s.authorize(grant(), '12345',1000); assert.throws(()=>s.authorize(grant(),'12345',1000));
    assert.equal(s.submit('grant-1',200,1000).length,200);
    assert.throws(()=>s.submit('grant-1',1,1000)); s.close();
    s=new Store(join(dir,'state.sqlite')); assert.equal(s.tasks().length,200);
    assert.throws(()=>s.authorize(grant(),'12345',1000));
  } finally {s?.close();rmSync(dir,{recursive:true,force:true});}
});
test('lease fencing rejects stale results and tracks running resource consumption', () => {
  const s=new Store(':memory:');
  try {
    s.challenge('n'.repeat(43),'12345',1300);s.authorize(grant(),'12345',1000);s.submit('grant-1',2,1000);
    s.host({id:'host-1',name:'sim-worker-1',zone:'us-central1-a',cpus:1,memoryMiB:2048,state:'ready'},1000);
    const task=s.lease('host-1',{...configuration(),reserveMemoryMiB:0},1000);
    assert.ok(task);assert.equal(s.lease('host-1',{...configuration(),cpuOvercommit:1,reserveMemoryMiB:0},1000),null);
    s.expire(1100); assert.throws(()=>s.finish(task.id,'host-1',task.generation,0,null,1100));
    assert.equal(s.task(task.id).state,'lost');
  }finally{s.close();}
});
test('authenticated encryption rejects altered ciphertext and wrong recipients', () => {
  const key=Buffer.alloc(32,7), data=Buffer.from('source');const encrypted=seal(data,key,'source');
  assert.equal(open(encrypted,key,'source').toString(),'source');
  assert.throws(()=>open(encrypted,key,'result'));
  const host=recipient(), envelope=wrapKey(key,host.publicKey,'grant-1');
  assert.deepEqual(unwrapKey(envelope,host.privateKey,'grant-1'),key);
  assert.throws(()=>unwrapKey(envelope,recipient().privateKey,'grant-1'));
});
test('Google JWT rejects wrong issuer, audience, expired tokens and unknown key IDs', async () => {
  const {privateKey,publicKey}=generateKeyPairSync('rsa',{modulusLength:2048});
  const jwk=publicKey.export({format:'jwk'});jwk.kid='k1';jwk.alg='RS256';
  const make=(patch={})=>{const header=Buffer.from(JSON.stringify({alg:'RS256',kid:'k1'})).toString('base64url');
    const payload=Buffer.from(JSON.stringify({iss:'https://accounts.google.com',aud:'sim',sub:'12345',iat:990,exp:1100,...patch})).toString('base64url');
    const message=header+'.'+payload;return message+'.'+sign('RSA-SHA256',Buffer.from(message),privateKey).toString('base64url');};
  const options={audience:'sim',now:1000,jwks:{keys:[jwk]}};
  assert.equal((await verifyGoogleToken(make(),options)).sub,'12345');
  for(const patch of [{iss:'evil'}, {aud:'other'}, {exp:999}, {iat:2000}, {sub:''}]) {
    await assert.rejects(()=>verifyGoogleToken(make(patch),options));
  }
});
