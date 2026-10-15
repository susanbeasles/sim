import { randomBytes, createCipheriv, createDecipheriv, generateKeyPairSync, createPublicKey, diffieHellman, hkdfSync } from 'node:crypto';
import { requireThat } from './canonical.mjs';
export function recipient() {const {privateKey,publicKey}=generateKeyPairSync('x25519');return {privateKey,publicKey:publicKey.export({format:'der',type:'spki'}).toString('base64')};}
export function seal(data,key,purpose) {
  requireThat(key.length===32,'invalid encryption key');const nonce=randomBytes(12), cipher=createCipheriv('aes-256-gcm',key,nonce);cipher.setAAD(Buffer.from('sim-fleet-v1:'+purpose));
  return Buffer.concat([Buffer.from('SIMFLE01'),nonce,cipher.update(data),cipher.final(),cipher.getAuthTag()]);
}
export function open(bytes,key,purpose) {
  requireThat(bytes.length>=36&&bytes.subarray(0,8).toString()==='SIMFLE01','invalid encrypted artifact');
  const decipher=createDecipheriv('aes-256-gcm',key,bytes.subarray(8,20));decipher.setAAD(Buffer.from('sim-fleet-v1:'+purpose));decipher.setAuthTag(bytes.subarray(-16));
  return Buffer.concat([decipher.update(bytes.subarray(20,-16)),decipher.final()]);
}
function shared(privateKey,publicKey,context) {return Buffer.from(hkdfSync('sha256',diffieHellman({privateKey,publicKey:createPublicKey({key:Buffer.from(publicKey,'base64'),format:'der',type:'spki'})}),Buffer.alloc(0),Buffer.from('sim-fleet-key:'+context),32));}
export function wrapKey(key,publicKey,context) {const sender=recipient();return {publicKey:sender.publicKey,ciphertext:seal(key,shared(sender.privateKey,publicKey,context),context).toString('base64')};}
export function unwrapKey(envelope,privateKey,context) {const key=open(Buffer.from(envelope.ciphertext,'base64'),shared(privateKey,envelope.publicKey,context),context);requireThat(key.length===32,'invalid unwrapped key');return key;}

