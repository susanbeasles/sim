import { requireThat } from './canonical.mjs';
export async function body(req,maxBytes=1048576) {const chunks=[];let size=0;for await(const chunk of req){size+=chunk.length;requireThat(size<=maxBytes,'request body too large');chunks.push(chunk);}return Buffer.concat(chunks);}
export async function json(req,maxBytes){return JSON.parse((await body(req,maxBytes)).toString());}
export function send(res,status,data){res.writeHead(status,{'content-type':'application/json','cache-control':'no-store','x-content-type-options':'nosniff'});res.end(JSON.stringify(data));}
export function bearer(req){const value=req.headers.authorization;requireThat(typeof value==='string'&&value.startsWith('Bearer '),'authentication required');return value.slice(7);}
export function guarded(handler){return async(req,res)=>{try{await handler(req,res);}catch(e){if(res.headersSent){res.destroy();return;}send(res,/authentication|identity|subject|JWT|issuer|audience/.test(e.message)?401:400,{error:e.message});}};}

