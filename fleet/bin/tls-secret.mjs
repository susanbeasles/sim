#!/usr/bin/env node
import {mkdir,writeFile,readFile} from 'node:fs/promises';
import {join} from 'node:path';
import {X509Certificate,createPrivateKey} from 'node:crypto';
import {accessToken} from '../src/gcp.mjs';
import {requireThat} from '../src/canonical.mjs';
try{
  let [secret,directory]=process.argv.slice(2);if(secret==='--service'){const settings=JSON.parse(await readFile(directory,'utf8'));if(!settings.tlsSecret)process.exit(0);secret=settings.tlsSecret;directory='/etc/sim-fleet/tls';}requireThat(/^projects\/[a-z0-9-]+\/secrets\/[a-z0-9-]+$/.test(secret),'invalid TLS secret resource');
  const response=await fetch('https://secretmanager.googleapis.com/v1/'+secret+'/versions/latest:access',{headers:{authorization:'Bearer '+await accessToken()},redirect:'error',signal:AbortSignal.timeout(10000)});requireThat(response.ok,'TLS secret unavailable');
  const value=await response.json(),data=JSON.parse(Buffer.from(value.payload.data,'base64'));const cert=new X509Certificate(data.certificate),key=createPrivateKey(data.privateKey),ca=new X509Certificate(await readFile('/etc/sim-fleet/ca.crt'));
  requireThat(cert.checkPrivateKey(key)&&cert.verify(ca.publicKey),'TLS certificate or private key rejected');await mkdir(directory,{recursive:true,mode:0o700});await writeFile(join(directory,'cert.pem'),data.certificate,{mode:0o600});await writeFile(join(directory,'key.pem'),data.privateKey,{mode:0o600});
}catch(e){process.stderr.write('TLS bootstrap: '+e.message+'\n');process.exitCode=1;}
