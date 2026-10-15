import { createHash } from 'node:crypto';

export function canonical(value) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return JSON.stringify(value);
  if (typeof value === 'number' && Number.isSafeInteger(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && Object.getPrototypeOf(value) === Object.prototype) {
    return '{' + Object.keys(value).sort().map(k => JSON.stringify(k) + ':' + canonical(value[k])).join(',') + '}';
  }
  throw new Error('manifest contains an unsupported value');
}
export function digest(value) {
  return createHash('sha256').update(Buffer.isBuffer(value) || typeof value === 'string' ? value : canonical(value)).digest('hex');
}
export function requireThat(condition, message) { if (!condition) throw new Error(message); }
export function integer(value, min, max, field) { requireThat(Number.isSafeInteger(value) && value >= min && value <= max, 'invalid ' + field); return value; }
export function identifier(value) { requireThat(typeof value === 'string' && /^[a-z][a-z0-9-]{0,62}$/.test(value),'invalid identifier'); return value; }
export function sha256(value) { requireThat(typeof value === 'string' && /^[a-f0-9]{64}$/.test(value),'invalid sha256'); return value; }
export function fields(value, allowed) { requireThat(value && Object.getPrototypeOf(value) === Object.prototype,'expected object'); for(const key of Object.keys(value)) requireThat(allowed.includes(key),'unknown field: '+key); }

