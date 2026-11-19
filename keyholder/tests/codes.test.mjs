// SPDX-License-Identifier: Apache-2.0
// The three keyholder codes (register 8a): text form, envelope, round trips, shared vectors and
// every kind of refusal: malformed, oversized, damaged, wrong type and wrong version.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, test } from 'node:test';
import { K, ROOT, concat, envelope, hex, makeAuthenticator, random, textOf, toHex, utf8 } from './helpers.mjs';

const vectors = JSON.parse(readFileSync(join(ROOT, 'tests', 'vectors.json'), 'utf8'));

function refuses(fn, reason, detail) {
  assert.throws(fn, err => {
    assert.equal(err.name, 'CodeError', `expected a CodeError, got ${err}`);
    assert.equal(err.reason, reason, `expected "${reason}", got "${err.reason}" (${err.detail})`);
    if (detail !== undefined) assert.equal(err.detail, detail);
    return true;
  });
}

const goodRequest = () => ({ kind: K.KIND.EXIT, requestId: random(16), challenge: random(32), label: "Sam's Mac", items: [] });
const goodEnrolment = () => {
  const a = makeAuthenticator(32);
  return { credentialId: a.credentialId, publicKey: a.raw };
};
// A well-formed DER signature: SEQUENCE { INTEGER 1, INTEGER 1 }.
const SMALL_SIG = hex('3006020101020101');
const goodApproval = () => ({
  requestId: random(16),
  authenticatorData: concat(random(32), new Uint8Array([0x05, 0, 0, 0, 0])),
  clientData: utf8('{"type":"webauthn.get","challenge":"x","origin":"o"}'),
  signature: SMALL_SIG,
});
// Body bytes of a valid code, to change one field and re-wrap with a correct checksum.
const bodyOf = text => K.base32Decode(text).slice(6, -4);

describe('checksum and text form', () => {
  test('CRC-32 is the zlib/PNG checksum', () => {
    assert.equal(K.crc32(utf8('123456789')), 0xcbf43926);
    assert.equal(K.crc32(new Uint8Array(0)), 0);
  });

  test('base32 matches RFC 4648 without padding', () => {
    const rfc = { '': '', f: 'MY', fo: 'MZXQ', foo: 'MZXW6', foob: 'MZXW6YQ', fooba: 'MZXW6YTB', foobar: 'MZXW6YTBOI' };
    for (const [plain, coded] of Object.entries(rfc)) {
      assert.equal(K.base32Encode(utf8(plain)), coded);
      if (coded) assert.deepEqual(K.base32Decode(coded), utf8(plain));
    }
  });

  test('base32 round-trips every length and ignores case and separators', () => {
    for (let n = 1; n <= 80; n++) {
      const b = random(n);
      const t = K.base32Encode(b);
      assert.match(t, /^[A-Z2-7]+$/);
      assert.deepEqual(K.base32Decode(t), b);
      const spaced = t.toLowerCase().replace(/(.{4})/g, '$1 -\n');
      assert.deepEqual(K.base32Decode(spaced), b);
    }
  });

  test('base32 refuses foreign characters, impossible lengths and loose trailing bits', () => {
    for (const bad of ['MY=', 'M0', 'M1', 'M8', 'M9', 'MÝ', 'ßß', 'MZXW6+', 'MZ_XQ']) refuses(() => K.base32Decode(bad), 'characters');
    for (const bad of ['M', 'MZX', 'MZXW6Y']) refuses(() => K.base32Decode(bad), 'characters');
    refuses(() => K.base32Decode('MZ'), 'characters'); // "MY" is the only spelling of "f"
    refuses(() => K.base32Decode(''), 'empty');
    refuses(() => K.base32Decode(' \n - '), 'empty');
    refuses(() => K.base32Decode('A'.repeat(K.LIMITS.text + 1)), 'too-long');
  });

  test('base64url has no padding and uses - and _', () => {
    for (let n = 0; n <= 40; n++) {
      const b = random(n);
      assert.equal(K.base64url(b), Buffer.from(b).toString('base64url'));
    }
    assert.equal(K.base64url(new Uint8Array([0xfb, 0xff, 0xbf])), '-_-_');
  });

  test('a linked address gives only the part after #', () => {
    assert.equal(K.extractCode('https://keyholder.example/#ABC234'), 'ABC234');
    assert.equal(K.extractCode('  ABC234 \n'), 'ABC234');
    assert.equal(K.extractCode('#ABC234'), 'ABC234');
    assert.equal(K.extractCode(undefined), '');
  });
});

describe('request code', () => {
  test('round-trips every kind', () => {
    for (const kind of Object.values(K.KIND)) {
      const r = { ...goodRequest(), kind, items: kind === K.KIND.ADMIN_BATCH ? [random(32), random(32), random(32)] : [] };
      const back = K.decodeRequestCode(K.encodeRequestCode(r));
      assert.equal(back.version, 1);
      assert.equal(back.kind, kind);
      assert.equal(back.kindName, K.KIND_NAMES[kind]);
      assert.deepEqual(back.requestId, r.requestId);
      assert.deepEqual(back.challenge, r.challenge);
      assert.equal(back.label, r.label);
      assert.deepEqual(back.items, r.items);
    }
  });

  test('matches the shared vectors', () => {
    for (const v of vectors.request) {
      const fields = { kind: v.kind, requestId: hex(v.requestId), challenge: hex(v.challenge), label: v.label, items: v.items.map(hex) };
      assert.equal(K.encodeRequestCode(fields), v.text, v.name);
      const back = K.decodeRequestCode(v.text);
      assert.equal(back.kindName, v.name);
      assert.equal(toHex(back.requestId), v.requestId);
      assert.equal(toHex(back.challenge), v.challenge);
      assert.equal(back.label, v.label);
      assert.deepEqual(back.items.map(toHex), v.items);
      assert.equal(K.clientDataPrefix(back.challenge, vectors.origin), v.clientDataPrefix);
    }
  });

  test('the largest request fits, one more item or byte does not', () => {
    const big = { ...goodRequest(), kind: K.KIND.ADMIN_BATCH, label: 'M'.repeat(32), items: Array.from({ length: 16 }, () => random(32)) };
    const text = K.encodeRequestCode(big);
    assert.ok(text.length < K.LIMITS.text);
    assert.equal(K.decodeRequestCode(text).items.length, 16);
    refuses(() => K.encodeRequestCode({ ...big, items: [...big.items, random(32)] }), 'malformed');
    refuses(() => K.encodeRequestCode({ ...big, label: 'M'.repeat(33) }), 'malformed');
    // A 17-item batch wrapped by hand, with a correct checksum, is refused when read.
    const body = concat(bodyOf(text).slice(0, -(1 + 16 * 32)), new Uint8Array([17]), ...Array.from({ length: 17 }, () => random(32)));
    refuses(() => K.decodeRequestCode(textOf(envelope({ type: 2, body }))), 'malformed');
  });

  test('refuses wrong kinds, item counts and field sizes', () => {
    refuses(() => K.encodeRequestCode({ ...goodRequest(), kind: 5 }), 'malformed');
    refuses(() => K.encodeRequestCode({ ...goodRequest(), kind: K.KIND.ADMIN_BATCH, items: [] }), 'malformed');
    refuses(() => K.encodeRequestCode({ ...goodRequest(), kind: K.KIND.EXIT, items: [random(32)] }), 'malformed');
    refuses(() => K.encodeRequestCode({ ...goodRequest(), requestId: random(15) }), 'malformed');
    refuses(() => K.encodeRequestCode({ ...goodRequest(), challenge: random(31) }), 'malformed');
    refuses(() => K.encodeRequestCode({ ...goodRequest(), kind: K.KIND.ADMIN_BATCH, items: [random(31)] }), 'malformed');
    const body = bodyOf(K.encodeRequestCode(goodRequest()));
    for (const kind of [5, 6, 255]) refuses(() => K.decodeRequestCode(textOf(envelope({ type: 2, body: concat(new Uint8Array([kind]), body.slice(1)) }))), 'malformed');
    const withItem = concat(body.slice(0, -1), new Uint8Array([1]), random(32));
    refuses(() => K.decodeRequestCode(textOf(envelope({ type: 2, body: withItem }))), 'malformed');
    refuses(() => K.decodeRequestCode(textOf(envelope({ type: 2, body: body.slice(0, -1) }))), 'malformed');
    refuses(() => K.decodeRequestCode(textOf(envelope({ type: 2, body: concat(body, new Uint8Array([0])) }))), 'malformed');
  });

  test('accepts plain labels in any language and refuses misleading ones', () => {
    for (const label of ["Sam's Mac", 'Mac de Zoé', '東京のMac', '🍎 Mac', 'A', 'x'.repeat(32)]) {
      assert.equal(K.decodeRequestCode(K.encodeRequestCode({ ...goodRequest(), label })).label, label);
    }
    const refused = ['', ' ', ' Sam', 'Sam ', 'Sam\nMac', 'Sam\tMac', 'Sam\u0000', 'Sam‮CAM', 'Sam⁦x', 'Sam​Mac', '﻿Sam', 'Sam Mac', 'x'.repeat(33), 'é'.repeat(17)];
    for (const label of refused) refuses(() => K.encodeRequestCode({ ...goodRequest(), label }), 'malformed');
    // The same labels wrapped by hand are refused when read, as is text that is not UTF-8.
    const body = bodyOf(K.encodeRequestCode(goodRequest()));
    const head = body.slice(0, 1 + 16 + 32);
    const wrap = labelBytes => textOf(envelope({ type: 2, body: concat(head, new Uint8Array([labelBytes.length]), labelBytes, new Uint8Array([0])) }));
    for (const label of ['Sam‮CAM', ' Sam', 'Sam\u0007']) refuses(() => K.decodeRequestCode(wrap(utf8(label))), 'malformed');
    refuses(() => K.decodeRequestCode(wrap(new Uint8Array([0x53, 0xff, 0x4d]))), 'malformed');
    refuses(() => K.decodeRequestCode(wrap(new Uint8Array([0xef, 0xbb, 0xbf, 0x53]))), 'malformed');
    refuses(() => K.decodeRequestCode(wrap(new Uint8Array(0))), 'malformed');
  });

  test('says plainly what is asked', () => {
    const base = goodRequest();
    assert.match(K.askText({ ...base, kind: K.KIND.TEST }), /changes nothing/);
    assert.match(K.askText({ ...base, kind: K.KIND.EXIT }), /switch off the lock/);
    assert.match(K.askText({ ...base, kind: K.KIND.LOWER_WAIT }), /wait shorter/);
    assert.match(K.askText({ ...base, kind: K.KIND.LOOSEN_SETTING }), /settings/);
    assert.match(K.askText({ ...base, kind: K.KIND.ADMIN_BATCH, items: [random(32)] }), /an admin change/);
    assert.match(K.askText({ ...base, kind: K.KIND.ADMIN_BATCH, items: [random(32), random(32)] }), /2 admin changes/);
  });
});

describe('enrolment record', () => {
  test('round-trips, and matches the shared vector', () => {
    for (const n of [1, 16, 20, 64, 128]) {
      const a = makeAuthenticator(n);
      const back = K.decodeEnrolmentCode(K.encodeEnrolmentCode({ credentialId: a.credentialId, publicKey: a.raw }));
      assert.equal(back.version, 1);
      assert.deepEqual(back.credentialId, a.credentialId);
      assert.deepEqual(back.publicKey, a.raw);
    }
    for (const v of vectors.enrolment) {
      assert.equal(K.encodeEnrolmentCode({ credentialId: hex(v.credentialId), publicKey: hex(v.publicKey) }), v.text);
      const back = K.decodeEnrolmentCode(v.text);
      assert.equal(toHex(back.credentialId), v.credentialId);
      assert.equal(toHex(back.publicKey), v.publicKey);
    }
  });

  test('refuses a bad key or credential ID', () => {
    const e = goodEnrolment();
    refuses(() => K.encodeEnrolmentCode({ ...e, credentialId: new Uint8Array(0) }), 'malformed');
    refuses(() => K.encodeEnrolmentCode({ ...e, credentialId: random(129) }), 'malformed');
    const compressed = concat(new Uint8Array([0x02]), e.publicKey.slice(1));
    refuses(() => K.encodeEnrolmentCode({ ...e, publicKey: compressed }), 'malformed');
    const offCurve = e.publicKey.slice();
    offCurve[64] ^= 1;
    refuses(() => K.encodeEnrolmentCode({ ...e, publicKey: offCurve }), 'malformed');
    refuses(() => K.encodeEnrolmentCode({ ...e, publicKey: concat(new Uint8Array([4]), new Uint8Array(64).fill(0xff)) }), 'malformed');
    refuses(() => K.encodeEnrolmentCode({ ...e, publicKey: e.publicKey.slice(0, 64) }), 'malformed');
    const body = bodyOf(K.encodeEnrolmentCode(e));
    refuses(() => K.decodeEnrolmentCode(textOf(envelope({ type: 1, body: concat(new Uint8Array([0]), body.slice(1)) }))), 'malformed');
    refuses(() => K.decodeEnrolmentCode(textOf(envelope({ type: 1, body: concat(new Uint8Array([129]), body.slice(1)) }))), 'malformed');
    refuses(() => K.decodeEnrolmentCode(textOf(envelope({ type: 1, body: body.slice(0, -1) }))), 'malformed');
    const badKey = body.slice();
    badKey[body.length - 1] ^= 1;
    refuses(() => K.decodeEnrolmentCode(textOf(envelope({ type: 1, body: badKey }))), 'malformed');
  });
});

describe('approval code', () => {
  test('round-trips, and matches the shared vectors', () => {
    const a = goodApproval();
    const back = K.decodeApprovalCode(K.encodeApprovalCode(a));
    assert.equal(back.version, 1);
    for (const f of ['requestId', 'authenticatorData', 'clientData', 'signature']) assert.deepEqual(back[f], a[f], f);
    for (const v of vectors.approval) {
      const fields = { requestId: hex(v.requestId), authenticatorData: hex(v.authenticatorData), clientData: utf8(v.clientData), signature: hex(v.signature) };
      assert.equal(K.encodeApprovalCode(fields), v.text, v.name);
      const got = K.decodeApprovalCode(v.text);
      assert.equal(toHex(got.requestId), v.requestId);
      assert.equal(toHex(got.authenticatorData), v.authenticatorData);
      assert.equal(new TextDecoder().decode(got.clientData), v.clientData);
      assert.equal(toHex(got.signature), v.signature);
      assert.equal(toHex(K.derToRawSignature(got.signature)), v.signatureRaw);
    }
  });

  test('the largest approval fits, and its QR code too', () => {
    // The longest DER signature: two 33-byte integers, 72 bytes in all.
    const big = { ...goodApproval(), clientData: random(K.LIMITS.clientData), signature: hex(`3046022100${'8f'.repeat(32)}022100${'8f'.repeat(32)}`) };
    assert.equal(big.signature.length, K.LIMITS.signatureMax);
    const text = K.encodeApprovalCode(big);
    assert.ok(text.length < K.LIMITS.text);
    assert.equal(K.decodeApprovalCode(text).clientData.length, K.LIMITS.clientData);
    assert.ok(K.qr.encode(text).version <= 40);
    refuses(() => K.encodeApprovalCode({ ...big, clientData: random(K.LIMITS.clientData + 1) }), 'malformed');
  });

  test('refuses missing flags, extra data and bad signatures', () => {
    const a = goodApproval();
    const flags = f => concat(a.authenticatorData.slice(0, 32), new Uint8Array([f, 0, 0, 0, 0]));
    refuses(() => K.encodeApprovalCode({ ...a, authenticatorData: flags(0x01) }), 'malformed'); // not verified
    refuses(() => K.encodeApprovalCode({ ...a, authenticatorData: flags(0x04) }), 'malformed'); // not present
    refuses(() => K.encodeApprovalCode({ ...a, authenticatorData: flags(0x45) }), 'malformed'); // attested data
    refuses(() => K.encodeApprovalCode({ ...a, authenticatorData: flags(0x85) }), 'malformed'); // extensions
    refuses(() => K.encodeApprovalCode({ ...a, authenticatorData: concat(flags(0x05), new Uint8Array([0])) }), 'malformed');
    refuses(() => K.encodeApprovalCode({ ...a, clientData: new Uint8Array(0) }), 'malformed');
    refuses(() => K.encodeApprovalCode({ ...a, requestId: random(17) }), 'malformed');
    const badSignatures = [
      '3006020101020100', // s = 0
      '30060201ff020101', // negative r
      '300702020001020101', // r not minimal
      '3007020101020101', // sequence length wrong
      '310602010102010101', // not a sequence
      '30060201010201', // cut short
      '3008020101020101ffff', // extra bytes
      `3026022100${'ff'.repeat(32)}020101`, // r >= n
      `3027022200${'8f'.repeat(33)}020101`, // r longer than 32 bytes
      '30',
    ];
    for (const s of badSignatures) refuses(() => K.encodeApprovalCode({ ...a, signature: hex(s) }), 'malformed');
    refuses(() => K.encodeApprovalCode({ ...a, signature: random(73) }), 'malformed');
    // The same faults wrapped by hand, with correct checksums, are refused when read.
    const body = bodyOf(K.encodeApprovalCode(a));
    const noUv = body.slice();
    noUv[16 + 32] = 0x01;
    refuses(() => K.decodeApprovalCode(textOf(envelope({ type: 3, body: noUv }))), 'malformed');
    const badSig = body.slice();
    badSig[body.length - 1] = 0x00;
    refuses(() => K.decodeApprovalCode(textOf(envelope({ type: 3, body: badSig }))), 'malformed');
    const zeroCd = concat(body.slice(0, 16 + 37), new Uint8Array([0, 0]), new Uint8Array([SMALL_SIG.length]), SMALL_SIG);
    refuses(() => K.decodeApprovalCode(textOf(envelope({ type: 3, body: zeroCd }))), 'malformed');
    refuses(() => K.decodeApprovalCode(textOf(envelope({ type: 3, body: concat(body, new Uint8Array([1])) }))), 'malformed');
  });
});

describe('the envelope', () => {
  const samples = () => [
    ['request', K.encodeRequestCode(goodRequest()), K.decodeRequestCode],
    ['enrolment', K.encodeEnrolmentCode(goodEnrolment()), K.decodeEnrolmentCode],
    ['approval', K.encodeApprovalCode(goodApproval()), K.decodeApprovalCode],
  ];

  test('every single changed byte is caught as damage', () => {
    for (const [name, text, decode] of samples()) {
      const bytes = K.base32Decode(text);
      for (let i = 0; i < bytes.length; i++) {
        for (const x of [0x01, 0x80, 0xff]) {
          const b = bytes.slice();
          b[i] ^= x;
          refuses(() => decode(K.base32Encode(b)), 'damaged');
        }
      }
      assert.ok(name);
    }
  });

  test('a cut or lengthened code is refused', () => {
    for (const [, text, decode] of samples()) {
      const bytes = K.base32Decode(text);
      for (const n of [1, 4, 5, bytes.length - 10, bytes.length - 1]) refuses(() => decode(K.base32Encode(bytes.slice(0, n))), 'damaged');
      refuses(() => decode(K.base32Encode(concat(bytes, new Uint8Array([0])))), 'damaged');
      assert.throws(() => decode(text.slice(0, -1)), err => ['characters', 'damaged'].includes(err.reason));
    }
  });

  test('a code of another type says which type it is', () => {
    const [[, req], [, enr], [, appr]] = samples();
    refuses(() => K.decodeRequestCode(enr), 'wrong-type', 'enrolment');
    refuses(() => K.decodeRequestCode(appr), 'wrong-type', 'approval');
    refuses(() => K.decodeApprovalCode(req), 'wrong-type', 'request');
    refuses(() => K.decodeEnrolmentCode(req), 'wrong-type', 'request');
    refuses(() => K.decodeRequestCode(textOf(envelope({ type: 9, body: bodyOf(req) }))), 'wrong-type', 'unknown');
  });

  test('another format version is refused, never guessed at', () => {
    for (const [type, text, decode] of [[2, K.encodeRequestCode(goodRequest()), K.decodeRequestCode], [1, K.encodeEnrolmentCode(goodEnrolment()), K.decodeEnrolmentCode], [3, K.encodeApprovalCode(goodApproval()), K.decodeApprovalCode]]) {
      for (const version of [0, 2, 255]) refuses(() => decode(textOf(envelope({ type, version, body: bodyOf(text) }))), 'version');
    }
  });

  test('oversized codes are refused before they are read', () => {
    refuses(() => K.decodeRequestCode(textOf(envelope({ type: 2, body: random(K.LIMITS.body + 1) }))), 'damaged');
    refuses(() => K.decodeRequestCode('A'.repeat(K.LIMITS.text + 1)), 'too-long');
    refuses(() => K.decodeApprovalCode(`${K.encodeApprovalCode(goodApproval())}${' '.repeat(K.LIMITS.text)}`), 'too-long');
  });

  test('the shared invalid vectors are refused for the stated reason', () => {
    const decoders = { request: K.decodeRequestCode, enrolment: K.decodeEnrolmentCode, approval: K.decodeApprovalCode };
    for (const v of vectors.invalid) refuses(() => decoders[v.decoder](v.text), v.reason);
  });

  test('random text never decodes', () => {
    for (let i = 0; i < 300; i++) {
      const t = K.base32Encode(random(10 + (i % 120)));
      for (const decode of [K.decodeRequestCode, K.decodeEnrolmentCode, K.decodeApprovalCode]) assert.throws(() => decode(t), { name: 'CodeError' });
    }
  });
});

test('the vectors file carries its licence line', () => {
  assert.equal(vectors['SPDX-License-Identifier'], 'Apache-2.0');
});
