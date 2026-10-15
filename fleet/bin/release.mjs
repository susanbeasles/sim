#!/usr/bin/env node
import {readFile,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {releaseManifest,verifyReleaseFiles} from '../src/release.mjs';
import {verifyHardwareSignature} from '../src/auth.mjs';
import {canonical,digest,requireThat} from '../src/canonical.mjs';
try{
  const [command,root,publicKey,expectedDigest]=process.argv.slice(2);
  if(command==='manifest'){const bytes=canonical(await releaseManifest(root));await writeFile(join(root,'release.json'),bytes,{flag:'wx',mode:0o600});process.stdout.write(digest(bytes)+'\n');}
  else if(command==='verify'){const bytes=await readFile(join(root,'release.json'),'utf8');requireThat(digest(bytes)===expectedDigest,'release digest rejected');await verifyHardwareSignature(bytes,await readFile(join(root,'release.sig'),'utf8'),(await readFile(publicKey,'utf8')).trim());await verifyReleaseFiles(root,JSON.parse(bytes));process.stdout.write('verified release '+expectedDigest+'\n');}
  else throw new Error('usage: release.mjs manifest DIRECTORY | verify DIRECTORY PUBLIC_KEY EXPECTED_SHA256');
}catch(e){process.stderr.write(e.message+'\n');process.exitCode=1;}
