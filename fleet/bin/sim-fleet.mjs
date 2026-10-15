#!/usr/bin/env node
import {main} from '../src/cli.mjs';
try{if(Number(process.versions.node.split('.')[0])!==24)throw new Error('Node 24 LTS is required');await main(process.argv.slice(2));}catch(error){process.stderr.write('sim fleet: '+error.message+'\n');process.exitCode=1;}
