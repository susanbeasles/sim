import { mkdirSync,writeFileSync,existsSync,lstatSync,constants,readFileSync,realpathSync,openSync,fstatSync,closeSync } from 'node:fs';
import { mkdir,writeFile,readFile,stat,readdir } from 'node:fs/promises';
import { join,dirname } from 'node:path';
import { canonical,requireThat,sha256,digest } from './canonical.mjs';

export function encodeBundle(files,baseCommit) {return Buffer.from(canonical({schema:1,baseCommit,files}));}
export function decodeBundle(bytes,maxBytes) {
  requireThat(bytes.length<=maxBytes,'bundle exceeds byte limit');const b=JSON.parse(bytes);
  requireThat(b.schema===1&&typeof b.baseCommit==='string'&&/^[a-f0-9]{40,64}$/.test(b.baseCommit)&&Array.isArray(b.files)&&b.files.length<=50000,'invalid source bundle');
  const paths=new Set();let total=0;
  for(const f of b.files){requireThat(typeof f.path==='string'&&f.path.length<=4096&&!f.path.includes('\\')&&!f.path.includes('\0')&&!f.path.startsWith('/')&&f.path.split('/').every(p=>p&&p!=='.'&&p!=='..'&&p.toLowerCase()!=='.git'),'unsafe bundle path');
    requireThat(!paths.has(f.path),'duplicate bundle path');paths.add(f.path);requireThat([420,493].includes(f.mode),'only regular files allowed');
    requireThat(typeof f.data==='string'&&/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(f.data),'invalid file encoding');
    total+=Buffer.byteLength(f.data,'base64');requireThat(total<=maxBytes,'expanded bundle exceeds byte limit');
  }
  for(const p of paths){const parts=p.split('/');parts.pop();while(parts.length){requireThat(!paths.has(parts.join('/')),'file conflicts with directory');parts.pop();}}
  return b;
}
export function extractBundle(bytes,destination,maxBytes) {
  const b=decodeBundle(bytes,maxBytes);requireThat(!existsSync(destination),'extraction destination must be new');mkdirSync(destination,{recursive:true,mode:0o700});
  for(const f of b.files){const path=join(destination,f.path);mkdirSync(dirname(path),{recursive:true,mode:0o700});writeFileSync(path,Buffer.from(f.data,'base64'),{flag:constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,mode:f.mode});}
  return b;
}
export function packDirectory(directory,paths,baseCommit,maxBytes) {
  let total=0;const files=[];
  const root=realpathSync(directory);
  for(const p of paths){
    requireThat(typeof p==='string'&&!p.includes('\\')&&!p.startsWith('/')&&p.split('/').every(x=>x&&x!=='.'&&x!=='..'&&x.toLowerCase()!=='.git'),'unsafe source path');
    const parts=p.split('/');let parent=root,missing=false;
    for(const component of parts.slice(0,-1)){parent=join(parent,component);let info;try{info=lstatSync(parent);}catch(error){if(error.code==='ENOENT'){missing=true;break;}throw error;}requireThat(info.isDirectory()&&!info.isSymbolicLink(),'source contains a symlink or nonregular ancestor');}
    if(missing)continue;
    const path=join(root,p);let info;try{info=lstatSync(path);}catch(error){if(error.code==='ENOENT')continue;throw error;}
    requireThat(info.isFile()&&!info.isSymbolicLink(),'source contains a nonregular file');
    const fd=openSync(path,constants.O_RDONLY|constants.O_NOFOLLOW);try{const actual=fstatSync(fd);requireThat(actual.isFile()&&actual.ino===info.ino&&actual.dev===info.dev,'source changed during snapshot');total+=actual.size;requireThat(total<=maxBytes,'source exceeds byte limit');const content=readFileSync(fd);requireThat(content.length===actual.size,'source changed during snapshot');files.push({path:p,mode:(actual.mode&0o111)?493:420,data:content.toString('base64')});}finally{closeSync(fd);}
  }
  const b=encodeBundle(files,baseCommit);decodeBundle(b,maxBytes);return b;
}
export class ArtifactStore {
  constructor(root,maxBytes,maxCacheBytes=32*1024*1024*1024){this.root=root;this.maxBytes=maxBytes;this.maxCacheBytes=maxCacheBytes;this.queue=Promise.resolve();}
  put(hash,bytes){const pending=this.queue.then(()=>this.write(hash,bytes));this.queue=pending.catch(()=>{});return pending;}
  async write(hash,bytes){
    sha256(hash);requireThat(bytes.length<=this.maxBytes&&digest(bytes)===hash,'artifact digest or size mismatch');await mkdir(this.root,{recursive:true,mode:0o700});
    const names=await readdir(this.root);if(names.includes(hash)){await this.get(hash);return hash;}
    requireThat(names.length<4096,'artifact cache quota exceeded');let size=0;for(const name of names)size+=(await stat(join(this.root,name))).size;requireThat(size+bytes.length<=this.maxCacheBytes,'artifact cache quota exceeded');
    await writeFile(join(this.root,hash),bytes,{flag:'wx',mode:0o600});return hash;
  }
  async get(hash){sha256(hash);const path=join(this.root,hash);requireThat((await stat(path)).size<=this.maxBytes,'artifact too large');const bytes=await readFile(path);requireThat(digest(bytes)===hash,'stored artifact digest mismatch');return bytes;}
}

