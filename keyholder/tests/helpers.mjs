// SPDX-License-Identifier: Apache-2.0
// Shared helpers for the keyholder tests: load core.js exactly as the page inlines it, build
// test passkeys with Node's own crypto, and check approvals the way the keeper will (chapter 03
// section 8). Nothing here is used by the page.
import { createHash, createPublicKey, generateKeyPairSync, randomBytes, sign, verify, webcrypto } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

if (!globalThis.crypto) globalThis.crypto = webcrypto;

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
export const CORE_SOURCE = readFileSync(join(ROOT, 'core.js'), 'utf8');
// The same text the page runs, in this realm, so its bytes compare equal to ours.
export const K = new Function(`${CORE_SOURCE}\nreturn KeyholderCore;`)();

export const hex = s => new Uint8Array(Buffer.from(s, 'hex'));
export const toHex = b => Buffer.from(b).toString('hex');
export const utf8 = s => new TextEncoder().encode(s);
export const sha256 = b => new Uint8Array(createHash('sha256').update(b).digest());
export const random = n => new Uint8Array(randomBytes(n));
export function concat(...parts) {
  return new Uint8Array(Buffer.concat(parts.map(p => Buffer.from(p))));
}

// A raw record with any header, and a correct CRC-32, for building malformed codes.
export function envelope({ type, version = 1, body, magic = [0x53, 0x4d], length }) {
  const len = length == null ? body.length : length;
  const head = new Uint8Array([magic[0], magic[1], type, version, len >>> 8, len & 0xff]);
  const withBody = concat(head, body);
  const c = K.crc32(withBody);
  return concat(withBody, new Uint8Array([c >>> 24, (c >>> 16) & 0xff, (c >>> 8) & 0xff, c & 0xff]));
}
export const textOf = bytes => K.base32Encode(bytes);

// Decode the base32 text of a valid code back to its record bytes.
export const bytesOfText = text => K.base32Decode(text);

// A minimal CBOR writer: unsigned and negative integers, byte and text strings, arrays, maps.
export function cbor(value) {
  const head = (major, n) => {
    if (n < 24) return [(major << 5) | n];
    if (n < 0x100) return [(major << 5) | 24, n];
    if (n < 0x10000) return [(major << 5) | 25, n >>> 8, n & 0xff];
    return [(major << 5) | 26, (n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff];
  };
  if (typeof value === 'number') return new Uint8Array(value >= 0 ? head(0, value) : head(1, -1 - value));
  if (value instanceof Uint8Array) return concat(new Uint8Array(head(2, value.length)), value);
  if (typeof value === 'string') {
    const b = utf8(value);
    return concat(new Uint8Array(head(3, b.length)), b);
  }
  if (Array.isArray(value)) return concat(new Uint8Array(head(4, value.length)), ...value.map(cbor));
  if (value instanceof Map) {
    const parts = [new Uint8Array(head(5, value.size))];
    for (const [k, v] of value) parts.push(cbor(k), cbor(v));
    return concat(...parts);
  }
  throw new Error('cbor: unsupported value');
}

const SPKI_HEAD = hex('3059301306072a8648ce3d020106082a8648ce3d030107034200');

export function publicKeyFromRaw(raw) {
  return createPublicKey({ key: Buffer.from(concat(SPKI_HEAD, raw)), format: 'der', type: 'spki' });
}

// A test passkey: a P-256 key pair and a credential ID, as a phone would hold them.
export function makeAuthenticator(credentialIdLength = 20) {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const jwk = publicKey.export({ format: 'jwk' });
  const x = new Uint8Array(Buffer.from(jwk.x, 'base64url'));
  const y = new Uint8Array(Buffer.from(jwk.y, 'base64url'));
  return {
    privateKey,
    publicKey,
    x,
    y,
    raw: concat(new Uint8Array([4]), x, y),
    spki: new Uint8Array(publicKey.export({ format: 'der', type: 'spki' })),
    credentialId: random(credentialIdLength),
  };
}

// What navigator.credentials.create returns for that passkey, with attestation "none".
export function attestationFor(auth, { rpId, flags = 0x45, cose, credentialId, type = 'webauthn.create', origin = 'https://keyholder.example' }) {
  const id = credentialId || auth.credentialId;
  const key = cose || new Map([[1, 2], [3, -7], [-1, 1], [-2, auth.x], [-3, auth.y]]);
  const authData = concat(
    sha256(utf8(rpId)),
    new Uint8Array([flags, 0, 0, 0, 0]),
    new Uint8Array(16),
    new Uint8Array([id.length >>> 8, id.length & 0xff]),
    id,
    cbor(key),
  );
  const attestationObject = cbor(new Map([['fmt', 'none'], ['attStmt', new Map()], ['authData', authData]]));
  const clientDataJSON = utf8(JSON.stringify({ type, challenge: Buffer.from(random(32)).toString('base64url'), origin, crossOrigin: false }));
  return { rawId: auth.credentialId, attestationObject, clientDataJSON, authData };
}

// What navigator.credentials.get returns: authenticator data, the client data and a DER signature
// over authenticatorData || SHA-256(clientDataJSON), as WebAuthn defines it.
export function assertionFor(auth, { rpId, origin, challenge, flags = 0x05, counter = 0, extra = '', clientDataText }) {
  const authenticatorData = concat(
    sha256(utf8(rpId)),
    new Uint8Array([flags, (counter >>> 24) & 0xff, (counter >>> 16) & 0xff, (counter >>> 8) & 0xff, counter & 0xff]),
  );
  const text = clientDataText ||
    `{"type":"webauthn.get","challenge":"${Buffer.from(challenge).toString('base64url')}","origin":"${origin}","crossOrigin":false${extra}}`;
  const clientDataJSON = utf8(text);
  const signature = new Uint8Array(sign('sha256', concat(authenticatorData, sha256(clientDataJSON)), auth.privateKey));
  return { authenticatorData, clientDataJSON, signature };
}

// The keeper's check of an approval, in the order of chapter 03 section 8, written here
// independently of core.js. Returns 'ok' or the first step that fails.
export function keeperCheck({ approvalText, pin, request, origin, rpId }) {
  let a;
  try {
    a = K.decodeApprovalCode(approvalText);
  } catch (e) {
    return 'layout';
  }
  if (Buffer.compare(Buffer.from(a.requestId), Buffer.from(request.requestId)) !== 0) return 'request';
  if (Buffer.compare(Buffer.from(a.authenticatorData.subarray(0, 32)), Buffer.from(sha256(utf8(rpId)))) !== 0) return 'origin-hash';
  const flags = a.authenticatorData[32];
  if (!(flags & 0x01) || !(flags & 0x04)) return 'flags';
  const prefix = Buffer.from(
    `{"type":"webauthn.get","challenge":"${Buffer.from(request.challenge).toString('base64url')}","origin":"${origin}"`,
    'utf8',
  );
  if (Buffer.compare(Buffer.from(a.clientData.subarray(0, prefix.length)), prefix) !== 0) return 'prefix';
  const signed = concat(a.authenticatorData, sha256(a.clientData));
  if (!verify('sha256', Buffer.from(signed), publicKeyFromRaw(pin.publicKey), Buffer.from(a.signature))) return 'signature';
  return 'ok';
}
