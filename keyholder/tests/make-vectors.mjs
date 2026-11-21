// SPDX-License-Identifier: Apache-2.0
// Writes tests/vectors.json: fixed examples of every keyholder code, format version 1, for the
// tests here and for the app's and keeper's own readers. The vectors are frozen once written;
// run this again only for a format change. They were remade once, before anything shipped, when
// the request code body was redefined (SD-306: a nonce and a detail field in place of a carried
// challenge; each request's challenge is derived). Signatures come from a fresh test key each run.
//   node keyholder/tests/make-vectors.mjs
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { K, ROOT, assertionFor, concat, envelope, makeAuthenticator, sha256, textOf, toHex, utf8 } from './helpers.mjs';

const seq = (n, start) => Uint8Array.from({ length: n }, (_, i) => (start + i * 7) & 0xff);
const origin = 'https://keyholder.example';
const rpId = 'keyholder.example';

const requests = [
  { name: 'exit', kind: K.KIND.EXIT, requestId: seq(16, 0), nonce: sha256(utf8('vector nonce 1')), detail: 0, label: "Sam's Mac", items: [] },
  { name: 'test', kind: K.KIND.TEST, requestId: seq(16, 16), nonce: sha256(utf8('vector nonce 2')), detail: 0, label: 'Test Mac', items: [] },
  { name: 'lower-wait', kind: K.KIND.LOWER_WAIT, requestId: seq(16, 32), nonce: sha256(utf8('vector nonce 3')), detail: 30, label: 'Mac de Zoé', items: [] },
  {
    name: 'loosen-setting',
    kind: K.KIND.LOOSEN_SETTING,
    requestId: seq(16, 48),
    nonce: sha256(utf8('vector nonce 4')),
    detail: K.SETTING.STRICT_COVER_OFF,
    label: '東京のMac',
    items: [],
  },
  {
    name: 'admin-window',
    kind: K.KIND.ADMIN_WINDOW,
    requestId: seq(16, 64),
    nonce: sha256(utf8('vector nonce 5')),
    detail: 0,
    label: 'Studio',
    items: [sha256(utf8('item 1')), sha256(utf8('item 2'))],
  },
];
for (const r of requests) r.challenge = await K.deriveChallenge(r);

const auth = makeAuthenticator(20);
const enrolment = { name: 'enrolment', credentialId: auth.credentialId, publicKey: auth.raw };

const approvals = [
  { name: 'exit-approval', request: requests[0], extra: '' },
  {
    name: 'test-approval-with-extra-member',
    request: requests[1],
    extra: ',"other_keys_can_be_added_here":"do not compare clientDataJSON against a template. See the WebAuthn spec"',
  },
].map(({ name, request, extra }) => {
  const a = assertionFor(auth, { rpId, origin, challenge: request.challenge, extra });
  return { name, request: request.name, requestId: request.requestId, authenticatorData: a.authenticatorData, clientData: a.clientDataJSON, signature: a.signature };
});

const goodRequestBody = K.base32Decode(K.encodeRequestCode(requests[0])).slice(6, -4);
// The detail sits after kind (1), request ID (16) and nonce (32).
const withDetail = (body, detail) => {
  const b = body.slice();
  b[49] = detail >>> 8;
  b[50] = detail & 0xff;
  return b;
};
const invalid = [
  { decoder: 'request', reason: 'version', note: 'format version 2', text: textOf(envelope({ type: 2, version: 2, body: goodRequestBody })) },
  { decoder: 'request', reason: 'version', note: 'format version 0', text: textOf(envelope({ type: 2, version: 0, body: goodRequestBody })) },
  { decoder: 'request', reason: 'wrong-type', note: 'an enrolment record given as a request', text: K.encodeEnrolmentCode(enrolment) },
  { decoder: 'request', reason: 'damaged', note: 'magic changed', text: textOf(envelope({ type: 2, body: goodRequestBody, magic: [0x53, 0x4e] })) },
  { decoder: 'request', reason: 'malformed', note: 'unknown kind 5', text: textOf(envelope({ type: 2, body: concat(new Uint8Array([5]), goodRequestBody.slice(1)) })) },
  { decoder: 'request', reason: 'malformed', note: 'exit with a non-zero detail', text: textOf(envelope({ type: 2, body: withDetail(goodRequestBody, 1) })) },
  { decoder: 'request', reason: 'malformed', note: 'lower wait to 365 days', text: textOf(envelope({ type: 2, body: withDetail(concat(new Uint8Array([2]), goodRequestBody.slice(1)), 365) })) },
  { decoder: 'request', reason: 'malformed', note: 'loosen setting 4, which does not exist', text: textOf(envelope({ type: 2, body: withDetail(concat(new Uint8Array([3]), goodRequestBody.slice(1)), 4) })) },
  { decoder: 'request', reason: 'malformed', note: 'one extra byte at the end', text: textOf(envelope({ type: 2, body: concat(goodRequestBody, new Uint8Array([0])) })) },
  { decoder: 'request', reason: 'damaged', note: 'length field larger than the record', text: textOf(envelope({ type: 2, body: goodRequestBody, length: goodRequestBody.length + 1 })) },
  { decoder: 'request', reason: 'characters', note: 'a character outside the alphabet', text: `${K.encodeRequestCode(requests[0]).slice(0, -1)}0` },
  { decoder: 'approval', reason: 'wrong-type', note: 'a request code given as an approval', text: K.encodeRequestCode(requests[0]) },
  { decoder: 'enrolment', reason: 'malformed', note: 'public key not on the curve', text: textOf(envelope({ type: 1, body: concat(new Uint8Array([1, 9, 4]), new Uint8Array(64).fill(1)) })) },
];

const hexed = v => (v instanceof Uint8Array ? toHex(v) : v);
const out = {
  'SPDX-License-Identifier': 'Apache-2.0',
  about: 'Keyholder codes, format version 1. Byte fields are hex. A request\'s challenge is derived from its fields (SD-306); see spec/vectors/keyholder-challenge-v1.txt. Text is RFC 4648 base32, upper case, no padding. See keyholder/README.md.',
  origin,
  rpId,
  request: requests.map(r => ({
    name: r.name,
    kind: r.kind,
    requestId: hexed(r.requestId),
    nonce: hexed(r.nonce),
    detail: r.detail,
    label: r.label,
    items: r.items.map(hexed),
    challenge: hexed(r.challenge),
    clientDataPrefix: K.clientDataPrefix(r.challenge, origin),
    text: K.encodeRequestCode(r),
  })),
  enrolment: [{ name: enrolment.name, credentialId: hexed(enrolment.credentialId), publicKey: hexed(enrolment.publicKey), text: K.encodeEnrolmentCode(enrolment) }],
  approval: approvals.map(a => ({
    name: a.name,
    request: a.request,
    requestId: hexed(a.requestId),
    authenticatorData: hexed(a.authenticatorData),
    clientData: new TextDecoder().decode(a.clientData),
    signature: hexed(a.signature),
    signatureRaw: hexed(K.derToRawSignature(a.signature)),
    text: K.encodeApprovalCode(a),
  })),
  invalid,
};
writeFileSync(join(ROOT, 'tests', 'vectors.json'), `${JSON.stringify(out, null, 2)}\n`);
console.log('Wrote keyholder/tests/vectors.json');
