// SPDX-License-Identifier: Apache-2.0
// The challenge the passkey signs (SD-306): derived from every field the keyholder is shown,
// checked against the vectors the keeper reads too (spec/vectors/keyholder-challenge-v1.txt),
// and shown to change whenever any shown field changes.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, test } from 'node:test';
import {
  K, ROOT, assertionFor, challengeOf, concat, envelope, hex, keeperCheck, makeAuthenticator, random, rawToDer, sha256, textOf, toHex, utf8,
} from './helpers.mjs';

// The shared file: "key: value" lines in blocks that end with a blank line; "#" starts a comment.
function readBlocks(path) {
  const blocks = [];
  let current = null;
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (line.startsWith('#')) continue;
    if (line === '') {
      if (current) blocks.push(current);
      current = null;
      continue;
    }
    const at = line.indexOf(': ');
    assert.ok(at > 0, `a line in the vector file has no key: ${line}`);
    (current ||= {})[line.slice(0, at)] = line.slice(at + 2);
  }
  if (current) blocks.push(current);
  return blocks;
}

const VECTOR_FILE = join(ROOT, '..', 'spec', 'vectors', 'keyholder-challenge-v1.txt');
const blocks = readBlocks(VECTOR_FILE);
const challengeCases = blocks.filter(b => b.case && b.case.startsWith('challenge '));
const approvalCases = blocks.filter(b => b.case && b.case.startsWith('approval '));
const shared = blocks.find(b => b.public_key);
const fieldsOf = c => ({
  kind: Number(c.kind),
  requestId: hex(c.request_id),
  detail: Number(c.detail),
  label: new TextDecoder().decode(hex(c.label)),
  items: c.items ? c.items.split(',').map(hex) : [],
  nonce: hex(c.nonce),
});
const approvalCase = name => {
  const c = approvalCases.find(b => b.case === `approval ${name}`);
  assert.ok(c, `no approval case "${name}"`);
  return c;
};

// Body offsets: kind (0), request ID (1..17), nonce (17..49), detail (49..51), label length (51).
const bodyOf = text => K.base32Decode(text).slice(6, -4);
const rewrap = body => textOf(envelope({ type: 2, body }));

describe('the shared challenge vectors', () => {
  test('the file is there, with its licence line, and has every kind', () => {
    assert.match(readFileSync(VECTOR_FILE, 'utf8').split('\n')[0], /SPDX-License-Identifier: Apache-2\.0/);
    assert.ok(challengeCases.length >= 7);
    assert.deepEqual([...new Set(challengeCases.map(c => Number(c.kind)))].sort(), [0, 1, 2, 3, 4]);
    assert.ok(approvalCases.length >= 20);
  });

  test('deriveChallenge gives every challenge in the file, and so does the independent helper', async () => {
    for (const c of challengeCases) {
      const fields = fieldsOf(c);
      assert.equal(toHex(await K.deriveChallenge(fields)), c.challenge, c.case);
      assert.equal(toHex(challengeOf(fields)), c.challenge, c.case);
      // The same fields carried in a request code and read back give the same challenge.
      const back = K.decodeRequestCode(K.encodeRequestCode(fields));
      assert.equal(toHex(await K.deriveChallenge(back)), c.challenge, c.case);
    }
  });

  test("the page's prefix check accepts the good approvals and refuses the ones it can see are wrong", async () => {
    const exit = K.decodeRequestCode(K.encodeRequestCode(fieldsOf(challengeCases.find(c => c.case === 'challenge exit'))));
    const { origin, rp_id: rpId } = shared;
    const pin = { publicKey: hex(shared.public_key) };
    const page = c => K.approvalFromGet({
      authenticatorData: hex(c.authenticator_data), clientDataJSON: hex(c.client_data), signature: rawToDer(hex(c.signature)), request: exit, origin, rpId,
    });
    for (const name of ['good', 'good high s', 'good without crossOrigin', 'good with an extra member']) {
      const c = approvalCase(name);
      assert.equal(c.valid, 'yes');
      assert.equal(c.expected_challenge, toHex(await K.deriveChallenge(exit)));
      const text = await page(c);
      assert.equal(keeperCheck({ approvalText: text, pin, request: exit, origin, rpId }), 'ok', name);
    }
    for (const name of ['create, not get', 'other origin', 'origin with a port', 'test challenge for a request', 'challenge of another request']) {
      const c = approvalCase(name);
      assert.equal(c.valid, 'no');
      await assert.rejects(page(c), err => err.reason === 'passkey' && /client data/.test(err.detail), name);
    }
    for (const name of ['other rp id', 'user not verified', 'user not present', 'attested data flag', 'extension data flag']) {
      await assert.rejects(page(approvalCase(name)), { name: 'CodeError', reason: 'passkey' }, name);
    }
  });
});

describe('the keyholder signs what they see (SD-306)', () => {
  const auth = makeAuthenticator();
  const origin = 'https://keyholder.example';
  const rpId = 'keyholder.example';
  const original = { kind: K.KIND.EXIT, requestId: random(16), nonce: random(32), detail: 0, label: "Sam's Mac", items: [] };
  const originalText = K.encodeRequestCode(original);

  async function approvalFor(request) {
    const a = assertionFor(auth, { rpId, origin, challenge: await K.deriveChallenge(request) });
    return K.approvalFromGet({ ...a, request, origin, rpId });
  }

  test('changing any shown field, with a correct checksum, gives another challenge and voids the approval', async () => {
    const body = bodyOf(originalText);
    const head = body.slice(0, 51);
    const label = utf8(original.label);
    const tail = (bytes, items = []) => concat(new Uint8Array([bytes.length]), bytes, new Uint8Array([items.length]), ...items);
    const withKindDetail = (kind, detail) => concat(new Uint8Array([kind]), head.slice(1, 49), new Uint8Array([detail >> 8, detail & 0xff]), tail(label));
    const crafted = {
      'kind and detail (lower wait)': withKindDetail(K.KIND.LOWER_WAIT, 7),
      'kind and detail (loosen a setting)': withKindDetail(K.KIND.LOOSEN_SETTING, 2),
      'kind (a test)': withKindDetail(K.KIND.TEST, 0),
      label: concat(head, tail(utf8("Alex's Mac"))),
      'request ID': concat(new Uint8Array([body[0]]), random(16), body.slice(17)),
      'kind and items (admin window)': concat(new Uint8Array([K.KIND.ADMIN_WINDOW]), head.slice(1), tail(label, [random(32)])),
    };
    const originalChallenge = await K.deriveChallenge(K.decodeRequestCode(originalText));
    const signedForOriginal = await approvalFor(K.decodeRequestCode(originalText));
    for (const [what, b] of Object.entries(crafted)) {
      const shown = K.decodeRequestCode(rewrap(b));
      const challenge = await K.deriveChallenge(shown);
      assert.notDeepEqual(challenge, originalChallenge, what);
      if (what !== 'request ID') assert.notEqual(K.askText(shown), K.askText(K.decodeRequestCode(originalText)), what);
      // A signature over what this code shows is no approval of the original request.
      const text = await approvalFor(shown);
      assert.notEqual(keeperCheck({ approvalText: text, pin: { publicKey: auth.raw }, request: original, origin, rpId }), 'ok', what);
      // And an approval of the original never passes the page's check for the crafted code.
      const a = K.decodeApprovalCode(signedForOriginal);
      await assert.rejects(
        K.approvalFromGet({ authenticatorData: a.authenticatorData, clientDataJSON: a.clientData, signature: a.signature, request: shown, origin, rpId }),
        err => err.reason === 'passkey' && /client data/.test(err.detail),
        what,
      );
    }
  });

  test('items in another order, or one changed, give another challenge', async () => {
    const items = [random(32), random(32), random(32)];
    const r = { kind: K.KIND.ADMIN_WINDOW, requestId: random(16), nonce: random(32), detail: 0, label: 'Studio', items };
    const c = await K.deriveChallenge(r);
    const changed = items.map(i => i.slice());
    changed[2][31] ^= 1;
    for (const other of [[items[1], items[0], items[2]], changed, items.slice(0, 2)]) assert.notDeepEqual(await K.deriveChallenge({ ...r, items: other }), c);
  });

  test('a test approval is never signed under the real tag', async () => {
    assert.equal(K.TEST_TAG, 'SafeSightMac keyholder test approval');
    assert.equal(K.APPROVAL_TAG, 'SafeSightMac keyholder approval');
    const preimage = (tag, f) => {
      const t = utf8(tag);
      const l = utf8(f.label);
      return sha256(concat(new Uint8Array([t.length]), t, new Uint8Array([1, f.kind]), f.requestId, new Uint8Array([f.detail >> 8, f.detail & 0xff]), new Uint8Array([l.length]), l, new Uint8Array([f.items.length]), ...f.items, f.nonce));
    };
    for (let i = 0; i < 20; i++) {
      const t = { kind: K.KIND.TEST, requestId: random(16), nonce: random(32), detail: 0, label: 'Test Mac', items: [] };
      const c = await K.deriveChallenge(t);
      assert.deepEqual(c, preimage(K.TEST_TAG, t));
      assert.notDeepEqual(c, preimage(K.APPROVAL_TAG, t));
      for (const kind of [1, 2, 3, 4]) {
        const real = { ...t, kind, detail: { 1: 0, 2: 7, 3: 1, 4: 0 }[kind], items: kind === 4 ? [random(32)] : [] };
        assert.deepEqual(await K.deriveChallenge(real), preimage(K.APPROVAL_TAG, real));
        assert.notDeepEqual(await K.deriveChallenge(real), c);
      }
    }
    // In the shared file, the test and exit cases differ only in kind, and so in tag.
    const byName = n => challengeCases.find(c => c.case === `challenge ${n}`);
    assert.notEqual(byName('test').challenge, byName('exit').challenge);
  });

  test('nothing that would not decode is ever given a challenge', async () => {
    const base = { kind: K.KIND.LOWER_WAIT, requestId: random(16), nonce: random(32), detail: 7, label: "Sam's Mac", items: [] };
    const bad = [
      { detail: 365 }, { detail: 0 }, { detail: undefined }, { kind: K.KIND.EXIT, detail: 7 }, { kind: K.KIND.LOOSEN_SETTING, detail: 4 },
      { kind: K.KIND.ADMIN_WINDOW, detail: 0, items: [] }, { kind: 5 }, { nonce: random(31) }, { nonce: undefined }, { requestId: random(15) },
      { label: '' }, { label: 'Sam\u202eCAM' }, { items: [random(32)] },
    ];
    for (const change of bad) await assert.rejects(K.deriveChallenge({ ...base, ...change }), { name: 'CodeError', reason: 'malformed' }, JSON.stringify(Object.keys(change)));
    // A carried "challenge" field is ignored: the challenge only ever comes from the fields.
    assert.deepEqual(await K.deriveChallenge({ ...base, challenge: random(32) }), await K.deriveChallenge(base));
  });
});
