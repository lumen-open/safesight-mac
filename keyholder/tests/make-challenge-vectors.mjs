// SPDX-License-Identifier: Apache-2.0
// Writes spec/vectors/keyholder-challenge-v1.txt: the shared test vectors for the keyholder
// challenge (SD-306) and for the keeper's approval check (ES256 over a passkey assertion).
// The keeper's Rust tests and the keyholder page's tests both read this one file. It uses
// node:crypto only, so it is a second implementation beside both of them. The vectors are
// frozen once written; signatures come from a fixed test key but ECDSA draws a fresh nonce,
// so running this again gives other signatures (and other bytes) for the same inputs.
//   node keyholder/tests/make-challenge-vectors.mjs > spec/vectors/keyholder-challenge-v1.txt
import { createECDH, createHash, createPrivateKey, sign } from 'node:crypto';

const sha256 = bytes => new Uint8Array(createHash('sha256').update(bytes).digest());
const utf8 = text => new TextEncoder().encode(text);
const hex = bytes => Buffer.from(bytes).toString('hex');
const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};
const b64url = bytes => Buffer.from(bytes).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

// ----- The challenge (SD-306), format version 1 -----
// SHA-256 of, in order:
//   tag length (1) | tag (ASCII) | format version (1, = 1) | kind (1) | request ID (16) |
//   detail (2, big-endian) | label length (1) | label (UTF-8, 1 to 32) |
//   item count (1) | item hashes (32 each, 0 to 16) | nonce (32, the keeper's random bytes)
// The tag is APPROVAL_TAG for every real request and TEST_TAG for the test approval at
// enrolment (kind 0), so a test signature can never be a real approval.
const APPROVAL_TAG = 'SafeSightMac keyholder approval';
const TEST_TAG = 'SafeSightMac keyholder test approval';
const VERSION = 1;

function challenge({ kind, requestId, detail, label, items, nonce }) {
  const tag = utf8(kind === 0 ? TEST_TAG : APPROVAL_TAG);
  const labelBytes = utf8(label);
  return sha256(concat(
    Uint8Array.of(tag.length), tag, Uint8Array.of(VERSION), Uint8Array.of(kind), requestId,
    Uint8Array.of(detail >> 8, detail & 0xff), Uint8Array.of(labelBytes.length), labelBytes,
    Uint8Array.of(items.length), ...items, nonce,
  ));
}

const seq = (n, start) => Uint8Array.from({ length: n }, (_, i) => (start + i * 7) & 0xff);
const lines = [];
const block = fields => { for (const [k, v] of fields) lines.push(`${k}: ${v}`); lines.push(''); };

lines.push('# SPDX-License-Identifier: Apache-2.0');
lines.push('# Keyholder challenge and approval vectors, format version 1 (SD-306). Made by');
lines.push('# keyholder/tests/make-challenge-vectors.mjs with node:crypto. Read by the keeper');
lines.push('# (keeper/src/approval.rs) and the keyholder page (keyholder/tests). Bytes are hex.');
lines.push('# A block is "key: value" lines ending with a blank line. Frozen: do not regenerate.');
lines.push('');

const cases = [
  { name: 'exit', kind: 1, requestId: seq(16, 0), detail: 0, label: "Sam's Mac", items: [], nonce: sha256(utf8('nonce 1')) },
  { name: 'test', kind: 0, requestId: seq(16, 0), detail: 0, label: "Sam's Mac", items: [], nonce: sha256(utf8('nonce 1')) },
  { name: 'lower-wait-7', kind: 2, requestId: seq(16, 32), detail: 7, label: 'Mac de Zoé', items: [], nonce: sha256(utf8('nonce 3')) },
  { name: 'lower-wait-30', kind: 2, requestId: seq(16, 32), detail: 30, label: 'Mac de Zoé', items: [], nonce: sha256(utf8('nonce 3')) },
  { name: 'loosen-strict-cover-off', kind: 3, requestId: seq(16, 48), detail: 2, label: '東京のMac', items: [], nonce: sha256(utf8('nonce 4')) },
  { name: 'admin-window', kind: 4, requestId: seq(16, 64), detail: 0, label: 'Studio', items: [sha256(utf8('item 1')), sha256(utf8('item 2'))], nonce: sha256(utf8('nonce 5')) },
  { name: 'label-32-bytes', kind: 1, requestId: seq(16, 80), detail: 0, label: 'abcdefghijklmnopqrstuvwxyz012345', items: [], nonce: sha256(utf8('nonce 6')) },
];
for (const c of cases) {
  block([
    ['case', `challenge ${c.name}`],
    ['kind', c.kind],
    ['request_id', hex(c.requestId)],
    ['detail', c.detail],
    ['label', hex(utf8(c.label))],
    ['items', c.items.map(hex).join(',')],
    ['nonce', hex(c.nonce)],
    ['challenge', hex(challenge(c))],
  ]);
}

// ----- Approvals: what the keeper's ES256 check accepts and refuses -----
// A fixed P-256 test key. It protects nothing.
const ecdh = createECDH('prime256v1');
ecdh.setPrivateKey(Buffer.from(sha256(utf8('keyholder test key 1'))));
const publicKey = new Uint8Array(ecdh.getPublicKey(null, 'uncompressed'));
const jwk = {
  kty: 'EC', crv: 'P-256',
  d: b64url(ecdh.getPrivateKey()), x: b64url(publicKey.subarray(1, 33)), y: b64url(publicKey.subarray(33, 65)),
};
const key = createPrivateKey({ key: jwk, format: 'jwk' });
const N = BigInt('0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551');

const origin = 'https://keyholder.example';
const rpId = 'keyholder.example';
const UP = 0x01, UV = 0x04;
const authData = (flags, id = rpId) => concat(sha256(utf8(id)), Uint8Array.of(flags), Uint8Array.of(0, 0, 0, 0));
const clientData = (ch, { type = 'webauthn.get', o = origin, extra = ',"crossOrigin":false' } = {}) =>
  utf8(`{"type":"${type}","challenge":"${b64url(ch)}","origin":"${o}"${extra}}`);
const signRaw = (ad, cd) => new Uint8Array(sign('sha256', concat(ad, sha256(cd)), { key, dsaEncoding: 'ieee-p1363' }));
const highS = raw => {
  const s = BigInt('0x' + hex(raw.subarray(32)));
  const t = (N - s).toString(16).padStart(64, '0');
  return concat(raw.subarray(0, 32), Uint8Array.from(Buffer.from(t, 'hex')));
};
const lowS = raw => {
  const s = BigInt('0x' + hex(raw.subarray(32)));
  return s > N / 2n ? highS(raw) : raw;
};

const exitChallenge = challenge(cases[0]);
const testChallenge = challenge(cases[1]);
const approvals = [];
const add = (name, valid, { ch = exitChallenge, expected = exitChallenge, ad = authData(UP | UV), cd, sig } = {}) => {
  const clientBytes = cd || clientData(ch);
  const signature = sig ? sig(ad, clientBytes) : signRaw(ad, clientBytes);
  approvals.push({ name, valid, expected, ad, cd: clientBytes, signature });
};

add('good', true, { sig: (ad, cd) => lowS(signRaw(ad, cd)) });
add('good high s', true, { sig: (ad, cd) => highS(lowS(signRaw(ad, cd))) });
add('good without crossOrigin', true, { cd: clientData(exitChallenge, { extra: '' }) });
add('good with an extra member', true, {
  cd: clientData(exitChallenge, { extra: ',"crossOrigin":false,"other_keys_can_be_added_here":"do not compare clientDataJSON against a template. See https://goo.gl/yabPex"' }),
});
add('cross origin', false, { cd: clientData(exitChallenge, { extra: ',"crossOrigin":true' }) });
add('top origin', false, { cd: clientData(exitChallenge, { extra: ',"crossOrigin":false,"topOrigin":"https://other.example"' }) });
add('second challenge member', false, { cd: clientData(exitChallenge, { extra: `,"challenge":"${b64url(testChallenge)}"` }) });
add('escaped key', false, { cd: clientData(exitChallenge, { extra: ',"cross\\u004frigin":true' }) });
add('not an object end', false, { cd: utf8(`{"type":"webauthn.get","challenge":"${b64url(exitChallenge)}","origin":"${origin}"`) });
add('text after the end', false, { cd: concat(clientData(exitChallenge), utf8(' ')) });
add('create, not get', false, { cd: clientData(exitChallenge, { type: 'webauthn.create' }) });
add('other origin', false, { cd: clientData(exitChallenge, { o: 'https://keyholder.example.evil' }) });
add('origin with a port', false, { cd: clientData(exitChallenge, { o: 'https://keyholder.example:8443' }) });
add('other rp id', false, { ad: authData(UP | UV, 'other.example') });
add('user not verified', false, { ad: authData(UP) });
add('user not present', false, { ad: authData(UV) });
add('attested data flag', false, { ad: authData(UP | UV | 0x40) });
add('extension data flag', false, { ad: authData(UP | UV | 0x80) });
add('test challenge for a request', false, { ch: testChallenge });
add('challenge of another request', false, { ch: challenge(cases[6]) });
add('signature changed', false, { sig: (ad, cd) => { const s = signRaw(ad, cd); s[10] ^= 1; return s; } });
add('signature over other data', false, { sig: (ad, cd) => signRaw(ad, concat(cd, utf8(' '))) });
add('signature s zero', false, { sig: (ad, cd) => { const s = signRaw(ad, cd); s.fill(0, 32); return s; } });
add('signature r is n', false, { sig: (ad, cd) => { const s = signRaw(ad, cd); s.set(Buffer.from(N.toString(16), 'hex'), 0); return s; } });

lines.push(`# The approval cases. Every case uses this key, origin and RP ID.`);
block([['public_key', hex(publicKey)], ['origin', origin], ['rp_id', rpId]]);
for (const a of approvals) {
  block([
    ['case', `approval ${a.name}`],
    ['valid', a.valid ? 'yes' : 'no'],
    ['expected_challenge', hex(a.expected)],
    ['authenticator_data', hex(a.ad)],
    ['client_data', hex(a.cd)],
    ['signature', hex(a.signature)],
  ]);
}
process.stdout.write(lines.join('\n'));
