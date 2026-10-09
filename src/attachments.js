// Шифрование вложений по спецификации Matrix (AES-CTR 256, v2).
const b64 = buf => {
  const bytes = new Uint8Array(buf);
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/=+$/, '');
};
const norm = s => String(s || '').replace(/-/g, '+').replace(/_/g, '/').replace(/=+$/, '');
const unb64 = s => {
  s = norm(s);
  while (s.length % 4) s += '=';
  return Uint8Array.from(atob(s), c => c.charCodeAt(0));
};

export async function encryptAttachment(plain) {
  const key = await crypto.subtle.generateKey({ name: 'AES-CTR', length: 256 }, true, ['encrypt', 'decrypt']);
  const iv = new Uint8Array(16);
  crypto.getRandomValues(iv.subarray(0, 8));
  const data = await crypto.subtle.encrypt({ name: 'AES-CTR', counter: iv, length: 64 }, key, plain);
  const jwk = await crypto.subtle.exportKey('jwk', key);
  const sha = await crypto.subtle.digest('SHA-256', data);
  return {
    data,
    info: {
      v: 'v2',
      key: { alg: 'A256CTR', ext: true, k: jwk.k, key_ops: ['encrypt', 'decrypt'], kty: 'oct' },
      iv: b64(iv),
      hashes: { sha256: b64(sha) },
    },
  };
}

export async function decryptAttachment(data, info) {
  if (info?.hashes?.sha256) {
    const h = b64(await crypto.subtle.digest('SHA-256', data));
    if (h !== norm(info.hashes.sha256)) throw new Error('Контрольная сумма файла не совпадает');
  }
  const jwk = { ...info.key, key_ops: ['encrypt', 'decrypt'], ext: true };
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'AES-CTR' }, false, ['encrypt', 'decrypt']);
  return crypto.subtle.decrypt({ name: 'AES-CTR', counter: unb64(info.iv), length: 64 }, key, data);
}

// Экспорт/импорт ключей комнат в стандартном формате Matrix
// («MEGOLM SESSION DATA»: PBKDF2-SHA512 → AES-256-CTR + HMAC-SHA256) — совместим с Element.
const b64std = u8 => {
  let s = '';
  for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
  return btoa(s);
};
async function megolmKeys(pass, salt, rounds) {
  const base = await crypto.subtle.importKey('raw', new TextEncoder().encode(pass), 'PBKDF2', false, ['deriveBits']);
  const bits = new Uint8Array(await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-512', salt, iterations: rounds }, base, 512));
  const aes = await crypto.subtle.importKey('raw', bits.slice(0, 32), { name: 'AES-CTR' }, false, ['encrypt', 'decrypt']);
  const hmac = await crypto.subtle.importKey('raw', bits.slice(32), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
  return { aes, hmac };
}
export async function encryptKeyExport(json, pass, rounds = 500000) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const iv = crypto.getRandomValues(new Uint8Array(16));
  iv[8] &= 0x7f;
  const { aes, hmac } = await megolmKeys(pass, salt, rounds);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-CTR', counter: iv, length: 64 }, aes, new TextEncoder().encode(json)));
  const body = new Uint8Array(37 + ct.length + 32);
  body[0] = 1; body.set(salt, 1); body.set(iv, 17);
  new DataView(body.buffer).setUint32(33, rounds);
  body.set(ct, 37);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', hmac, body.subarray(0, 37 + ct.length)));
  body.set(mac, 37 + ct.length);
  const b = b64std(body), lines = [];
  for (let i = 0; i < b.length; i += 96) lines.push(b.slice(i, i + 96));
  return '-----BEGIN MEGOLM SESSION DATA-----\n' + lines.join('\n') + '\n-----END MEGOLM SESSION DATA-----\n';
}
export async function decryptKeyExport(text, pass) {
  const m = /-----BEGIN MEGOLM SESSION DATA-----([\s\S]*?)-----END MEGOLM SESSION DATA-----/.exec(String(text));
  if (!m) throw new Error('Это не файл ключей Matrix');
  const body = unb64(m[1].replace(/\s+/g, ''));
  if (body[0] !== 1 || body.length < 69) throw new Error('Неподдерживаемая версия файла ключей');
  const salt = body.slice(1, 17), iv = body.slice(17, 33);
  const rounds = new DataView(body.buffer, body.byteOffset).getUint32(33);
  const ct = body.slice(37, body.length - 32), mac = body.slice(body.length - 32);
  const { aes, hmac } = await megolmKeys(pass, salt, rounds);
  if (!(await crypto.subtle.verify('HMAC', hmac, mac, body.slice(0, body.length - 32)))) throw new Error('Неверный пароль или файл повреждён');
  return new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-CTR', counter: iv, length: 64 }, aes, ct));
}
