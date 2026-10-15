import { createPublicKey, verify } from 'node:crypto';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { requireThat } from './canonical.mjs';

let keyCache;
export async function verifyGoogleToken(token,{audience,now=Math.floor(Date.now()/1000),jwks,fetcher=fetch}) {
  requireThat(typeof token==='string'&&token.length<=16384,'invalid identity token');const parts=token.split('.');requireThat(parts.length===3,'invalid JWT');
  const h=JSON.parse(Buffer.from(parts[0],'base64url')),p=JSON.parse(Buffer.from(parts[1],'base64url'));
  requireThat(h.alg==='RS256'&&typeof h.kid==='string'&&!h.jku&&!h.jwk&&!h.x5u,'invalid JWT algorithm or key reference');
  if(!jwks){if(!keyCache||keyCache.expires<=now){const response=await fetcher('https://www.googleapis.com/oauth2/v3/certs',{redirect:'error',signal:AbortSignal.timeout(10000)});requireThat(response.ok,'Google signing keys unavailable');keyCache={data:await response.json(),expires:now+300};}jwks=keyCache.data;}
  const key=jwks.keys.find(k=>k.kid===h.kid&&k.kty==='RSA'&&(!k.alg||k.alg==='RS256'));
  requireThat(key&&verify('RSA-SHA256',Buffer.from(parts[0]+'.'+parts[1]),createPublicKey({key,format:'jwk'}),Buffer.from(parts[2],'base64url')),'JWT signature rejected');
  requireThat(['https://accounts.google.com','accounts.google.com'].includes(p.iss),'wrong issuer');requireThat(p.aud===audience,'wrong audience');
  requireThat(typeof p.sub==='string'&&/^\d+$/.test(p.sub),'invalid subject');
  requireThat(Number.isInteger(p.exp)&&p.exp>now&&Number.isInteger(p.iat)&&p.iat<=now+30&&p.exp-p.iat<=7200,'expired or invalid identity token');return p;
}
export async function verifyHardwareSignature(manifest,signature,publicKey) {
  requireThat(/^sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com [A-Za-z0-9+/=]+(?: [^\r\n]*)?$/.test(publicKey),'hardware FIDO key required');
  requireThat(typeof signature==='string'&&signature.length<16384,'invalid signature');
  const dir=await mkdtemp(join(tmpdir(),'sim-fleet-verify-'));
  try {
    await writeFile(join(dir,'allowed'),'sim-owner '+publicKey+'\n',{mode:0o600});await writeFile(join(dir,'signature'),signature,{mode:0o600});
    await new Promise((resolve,reject)=>{const child=spawn('/usr/bin/ssh-keygen',['-Y','verify','-f',join(dir,'allowed'),'-I','sim-owner','-n','agent-control','-s',join(dir,'signature')],{stdio:['pipe','ignore','pipe'],timeout:10000});
      let error='';child.stderr.on('data',b=>{if(error.length<4096)error+=b;});child.on('error',reject);child.on('close',code=>code===0?resolve():reject(new Error('hardware signature rejected: '+error)));child.stdin.on('error',()=>{});child.stdin.end(manifest);});
  }finally{await rm(dir,{recursive:true,force:true});}
}

