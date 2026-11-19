// SPDX-License-Identifier: Apache-2.0
// The passkey side: the options the page gives the browser, the challenge derived from the
// request's fields (SD-306), the enrolment and approval checks, and full round trips through a keeper
// check written independently in helpers.mjs. Real passkeys need a phone and a browser; here a
// P-256 key in Node stands in for the phone, built the way WebAuthn defines its output.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, test } from 'node:test';
import {
  K, ROOT, assertionFor, attestationFor, cbor, challengeOf, concat, hex, keeperCheck, makeAuthenticator, random,
} from './helpers.mjs';

const vectors = JSON.parse(readFileSync(join(ROOT, 'tests', 'vectors.json'), 'utf8'));
const rpId = 'keyholder.example';
const origin = 'https://keyholder.example';

async function rejects(promise, reason, detailPattern) {
  await assert.rejects(promise, err => {
    assert.equal(err.name, 'CodeError', String(err));
    assert.equal(err.reason, reason, `${err.reason}: ${err.detail}`);
    if (detailPattern) assert.match(err.detail, detailPattern);
    return true;
  });
}

const DETAIL = { 0: 0, 1: 0, 2: 7, 3: 2, 4: 0 };
function newRequest(kind = K.KIND.EXIT, items = []) {
  const fields = { kind, requestId: random(16), nonce: random(32), detail: DETAIL[kind], label: "Sam's Mac", items };
  return K.decodeRequestCode(K.encodeRequestCode(fields));
}

async function enrol(auth) {
  const att = attestationFor(auth, { rpId });
  const r = await K.enrolmentFromCreate({ ...att, spki: auth.spki, rpId });
  return K.decodeEnrolmentCode(r.code);
}

async function approveWith(auth, request, options = {}) {
  const a = assertionFor(auth, { rpId, origin, challenge: await K.deriveChallenge(request), ...options });
  return K.approvalFromGet({ ...a, request, origin, rpId });
}

describe('passkey options', () => {
  test('create: ES256 only, user verified, no attestation, a discoverable key on this site', () => {
    const userId = random(16);
    const challenge = random(32);
    const o = K.createOptions({ rpId, userId, challenge, keyName: "  Sam's Mac  " });
    assert.deepEqual(o.pubKeyCredParams, [{ type: 'public-key', alg: -7 }]);
    assert.equal(o.attestation, 'none');
    assert.equal(o.authenticatorSelection.userVerification, 'required');
    assert.equal(o.authenticatorSelection.residentKey, 'required');
    assert.equal(o.authenticatorSelection.requireResidentKey, true);
    assert.equal(o.authenticatorSelection.authenticatorAttachment, undefined);
    assert.equal(o.rp.id, rpId);
    assert.deepEqual(o.user.id, userId);
    assert.equal(o.user.name, "Sam's Mac");
    assert.deepEqual(o.challenge, challenge);
    assert.equal(o.extensions, undefined);
    assert.equal(K.createOptions({ rpId, userId, challenge, keyName: '' }).user.name, 'SafeSight Mac keyholder');
    assert.equal(K.createOptions({ rpId, userId, challenge, keyName: 'x'.repeat(100) }).user.name.length, 64);
    assert.throws(() => K.createOptions({ rpId, userId: random(8), challenge }), { name: 'CodeError' });
  });

  test("get: the challenge is the request's derived 32 bytes exactly, and nothing else is asked", async () => {
    const request = newRequest();
    const challenge = await K.deriveChallenge(request);
    const o = K.getOptions({ rpId, challenge });
    assert.ok(o.challenge instanceof Uint8Array);
    assert.equal(o.challenge.length, 32);
    assert.deepEqual(o.challenge, challenge);
    assert.notEqual(o.challenge, challenge, 'a copy, not the same buffer');
    assert.equal(o.userVerification, 'required');
    assert.deepEqual(o.allowCredentials, []);
    assert.equal(o.rpId, rpId);
    assert.equal(o.extensions, undefined);
    assert.throws(() => K.getOptions({ rpId, challenge: random(31) }), { name: 'CodeError' });
  });

  test("an admin window's challenge covers its items", async () => {
    const items = [random(32), random(32)];
    const request = newRequest(K.KIND.ADMIN_WINDOW, items);
    const challenge = await K.deriveChallenge(request);
    assert.deepEqual(challenge, challengeOf(request));
    assert.notDeepEqual(challenge, await K.deriveChallenge({ ...request, items: [items[1], items[0]] }));
    assert.notDeepEqual(challenge, await K.deriveChallenge({ ...request, items: [items[0]] }));
  });
});

describe('the challenge and the fixed prefix (chapter 03 section 8, step 5)', () => {
  test('the prefix is the sign-in opening, the challenge in base64url, and the origin', () => {
    const challenge = random(32);
    const b64 = Buffer.from(challenge).toString('base64url');
    assert.equal(b64.length, 43);
    assert.equal(K.clientDataPrefix(challenge, origin), `{"type":"webauthn.get","challenge":"${b64}","origin":"${origin}"`);
  });

  test('every byte value is spelled as WebAuthn spells it, with no padding', () => {
    for (const fill of [0x00, 0xfb, 0xff, 0x3e, 0x3f]) {
      const challenge = new Uint8Array(32).fill(fill);
      const p = K.clientDataPrefix(challenge, origin);
      assert.ok(p.includes(`"challenge":"${Buffer.from(challenge).toString('base64url')}"`));
      assert.ok(!/[=+/]/.test(p.split('"challenge":"')[1].split('"')[0]));
    }
  });

  test('the shared vectors hold the prefix the keeper builds', () => {
    for (const v of vectors.request) {
      const b64 = Buffer.from(hex(v.challenge)).toString('base64url');
      assert.equal(v.clientDataPrefix, `{"type":"webauthn.get","challenge":"${b64}","origin":"${vectors.origin}"`);
    }
  });

  test('the shared approval vectors pass the keeper check under the shared enrolment key', () => {
    const pin = K.decodeEnrolmentCode(vectors.enrolment[0].text);
    for (const v of vectors.approval) {
      const request = K.decodeRequestCode(vectors.request.find(r => r.name === v.request).text);
      assert.equal(keeperCheck({ approvalText: v.text, pin, request, origin: vectors.origin, rpId: vectors.rpId }), 'ok', v.name);
    }
  });
});

describe('enrolment from a new passkey (SD-195)', () => {
  test('gives the credential ID and the uncompressed P-256 public key', async () => {
    const auth = makeAuthenticator(20);
    const att = attestationFor(auth, { rpId });
    const r = await K.enrolmentFromCreate({ ...att, spki: auth.spki, rpId });
    assert.deepEqual(r.credentialId, auth.credentialId);
    assert.deepEqual(r.publicKey, auth.raw);
    assert.equal(r.publicKey.length, 65);
    assert.equal(r.publicKey[0], 0x04);
    const back = K.decodeEnrolmentCode(r.code);
    assert.deepEqual(back.publicKey, auth.raw);
    assert.deepEqual(back.credentialId, auth.credentialId);
    // getPublicKey() is optional: browsers without it still enrol.
    const r2 = await K.enrolmentFromCreate({ ...att, spki: null, rpId });
    assert.equal(r2.code, r.code);
  });

  test('refuses a key for another site, without verification, or not ES256', async () => {
    const auth = makeAuthenticator();
    await rejects(K.enrolmentFromCreate({ ...attestationFor(auth, { rpId: 'other.example' }), rpId }), 'passkey', /another site/);
    await rejects(K.enrolmentFromCreate({ ...attestationFor(auth, { rpId, flags: 0x41 }), rpId }), 'passkey', /not verified/);
    await rejects(K.enrolmentFromCreate({ ...attestationFor(auth, { rpId, flags: 0x05 }), rpId }), 'passkey', /no credential data/);
    const rs256 = new Map([[1, 2], [3, -257], [-1, 1], [-2, auth.x], [-3, auth.y]]);
    await rejects(K.enrolmentFromCreate({ ...attestationFor(auth, { rpId, cose: rs256 }), rpId }), 'passkey', /not ES256/);
    const p384 = new Map([[1, 2], [3, -7], [-1, 2], [-2, auth.x], [-3, auth.y]]);
    await rejects(K.enrolmentFromCreate({ ...attestationFor(auth, { rpId, cose: p384 }), rpId }), 'passkey', /not ES256/);
    const offCurve = new Map([[1, 2], [3, -7], [-1, 1], [-2, auth.x], [-3, new Uint8Array(32).fill(7)]]);
    await rejects(K.enrolmentFromCreate({ ...attestationFor(auth, { rpId, cose: offCurve }), rpId }), 'passkey');
  });

  test('refuses mismatched IDs, keys or client data', async () => {
    const auth = makeAuthenticator();
    const att = attestationFor(auth, { rpId });
    await rejects(K.enrolmentFromCreate({ ...att, rawId: random(20), rpId }), 'passkey', /credential ID mismatch/);
    await rejects(K.enrolmentFromCreate({ ...att, spki: makeAuthenticator().spki, rpId }), 'passkey', /differ/);
    await rejects(K.enrolmentFromCreate({ ...attestationFor(auth, { rpId, type: 'webauthn.get' }), rpId }), 'passkey', /client data type/);
    await rejects(K.enrolmentFromCreate({ ...att, attestationObject: att.attestationObject.slice(0, 40), rpId }), 'passkey');
    await rejects(K.enrolmentFromCreate({ ...att, attestationObject: cbor(new Map([['fmt', 'none']])), rpId }), 'passkey');
    const longId = makeAuthenticator(129);
    await rejects(K.enrolmentFromCreate({ ...attestationFor(longId, { rpId }), rpId }), 'passkey', /129 bytes/);
  });
});

describe('approval from a passkey signature (SD-196)', () => {
  test('a real-shaped signature becomes an approval the keeper accepts', async () => {
    const auth = makeAuthenticator();
    const pin = await enrol(auth);
    for (const kind of Object.values(K.KIND)) {
      const request = newRequest(kind, kind === K.KIND.ADMIN_WINDOW ? [random(32)] : []);
      const text = await approveWith(auth, request);
      const a = K.decodeApprovalCode(text);
      assert.deepEqual(a.requestId, request.requestId);
      assert.equal(keeperCheck({ approvalText: text, pin, request, origin, rpId }), 'ok');
    }
  });

  test("browsers that add members after the prefix still pass (Chrome's extra key, a top origin)", async () => {
    const auth = makeAuthenticator();
    const pin = await enrol(auth);
    const request = newRequest();
    for (const extra of [',"other_keys_can_be_added_here":"do not compare"', ',"topOrigin":"x"', '']) {
      const text = await approveWith(auth, request, { extra });
      assert.equal(keeperCheck({ approvalText: text, pin, request, origin, rpId }), 'ok');
    }
    const noCrossOrigin = `{"type":"webauthn.get","challenge":"${Buffer.from(challengeOf(request)).toString('base64url')}","origin":"${origin}"}`;
    const text = await approveWith(auth, request, { clientDataText: noCrossOrigin });
    assert.equal(keeperCheck({ approvalText: text, pin, request, origin, rpId }), 'ok');
  });

  test('the page refuses to hand over what the keeper would refuse', async () => {
    const auth = makeAuthenticator();
    const request = newRequest();
    const challenge = challengeOf(request);
    const b64 = Buffer.from(challenge).toString('base64url');
    const wrongChallenge = `{"type":"webauthn.get","challenge":"${Buffer.from(random(32)).toString('base64url')}","origin":"${origin}"}`;
    const wrongOrigin = `{"type":"webauthn.get","challenge":"${b64}","origin":"https://keyholder.example.evil"}`;
    const wrongType = `{"type":"webauthn.create","challenge":"${b64}","origin":"${origin}"}`;
    const reordered = `{"challenge":"${b64}","type":"webauthn.get","origin":"${origin}"}`;
    for (const clientDataText of [wrongChallenge, wrongOrigin, wrongType, reordered]) {
      await rejects(approveWith(auth, request, { clientDataText }), 'passkey', /client data/);
    }
    await rejects(approveWith(auth, request, { flags: 0x01 }), 'passkey', /not verified/);
    const a = assertionFor(auth, { rpId: 'other.example', origin, challenge });
    await rejects(K.approvalFromGet({ ...a, request, origin, rpId }), 'passkey', /another site/);
    const b = assertionFor(auth, { rpId, origin, challenge });
    await rejects(K.approvalFromGet({ ...b, authenticatorData: concat(b.authenticatorData, new Uint8Array([0xa0])), request, origin, rpId }), 'passkey', /38 bytes/);
    await rejects(K.approvalFromGet({ ...b, signature: hex('3006020101020100'), request, origin, rpId }), 'passkey');
  });

  test('the keeper refuses an approval for another request, another key or changed bytes', async () => {
    const auth = makeAuthenticator();
    const pin = await enrol(auth);
    const request = newRequest();
    const other = newRequest();
    const text = await approveWith(auth, request);
    assert.equal(keeperCheck({ approvalText: text, pin, request: other, origin, rpId }), 'request');
    // Same ID, new nonce (an old approval against a fresh request code): the prefix fails.
    assert.equal(keeperCheck({ approvalText: text, pin, request: { ...request, nonce: random(32) }, origin, rpId }), 'prefix');
    // Another pinned key: the signature fails.
    const otherPin = await enrol(makeAuthenticator());
    assert.equal(keeperCheck({ approvalText: text, pin: otherPin, request, origin, rpId }), 'signature');
    // Another pinned origin.
    assert.equal(keeperCheck({ approvalText: text, pin, request, origin: 'https://other.example', rpId: 'other.example' }), 'origin-hash');
    // Any byte changed inside a re-wrapped code breaks the signature.
    const a = K.decodeApprovalCode(text);
    const counter = a.authenticatorData.slice();
    counter[36] ^= 1;
    const changedCounter = K.encodeApprovalCode({ ...a, authenticatorData: counter });
    assert.equal(keeperCheck({ approvalText: changedCounter, pin, request, origin, rpId }), 'signature');
    const cd = a.clientData.slice();
    cd[cd.length - 2] ^= 1;
    assert.equal(keeperCheck({ approvalText: K.encodeApprovalCode({ ...a, clientData: cd }), pin, request, origin, rpId }), 'signature');
  });

  test('a full test approval at enrolment, then a real one, from one key', async () => {
    const auth = makeAuthenticator();
    const pin = await enrol(auth);
    const testRequest = newRequest(K.KIND.TEST);
    assert.equal(keeperCheck({ approvalText: await approveWith(auth, testRequest), pin, request: testRequest, origin, rpId }), 'ok');
    const exit = newRequest(K.KIND.EXIT);
    assert.equal(keeperCheck({ approvalText: await approveWith(auth, exit), pin, request: exit, origin, rpId }), 'ok');
  });

  test('the sizes the owner carries', async () => {
    const auth = makeAuthenticator();
    const request = newRequest();
    const text = await approveWith(auth, request);
    // About 440 characters with typical client data: far more than the register's "about 200".
    assert.ok(text.length > 380 && text.length < 520, `approval is ${text.length} characters`);
    assert.ok(K.qr.encode(text).version <= 16);
    const enrolment = K.encodeEnrolmentCode(await enrol(auth));
    assert.ok(enrolment.length < 200);
  });
});
