#!/usr/bin/env node
import {readdir} from 'node:fs/promises';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const root=fileURLToPath(new URL('../',import.meta.url));
async function walk(path){const files=[];for(const entry of await readdir(path,{withFileTypes:true})){const item=join(path,entry.name);if(entry.isDirectory())files.push(...await walk(item));else files.push(item);}return files;}
for(const path of await walk(root)){if(path.endsWith('.mjs')){const result=spawnSync(process.execPath,['--check',path],{stdio:'inherit'});if(result.status!==0)process.exit(result.status??1);}}
const tests=(await walk(join(root,'test'))).filter(f=>f.endsWith('.test.mjs'));const result=spawnSync(process.execPath,['--disable-warning=ExperimentalWarning','--test',...tests],{stdio:'inherit'});process.exit(result.status??1);
