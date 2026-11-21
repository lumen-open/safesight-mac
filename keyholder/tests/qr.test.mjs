// SPDX-License-Identifier: Apache-2.0
// The page's QR encoder (model 2, level M). Known values from the QR standard's tables, the
// structure of every version, and golden outputs. When the golden outputs were made, each one,
// and a code of every version 1 to 40 at its smallest and fullest, was decoded back to the exact
// text by Apple's CoreImage QR reader (CIDetector) on macOS. A change to the encoder that alters
// a golden hash must be checked that way again before the hash is updated. The five built from
// tests/vectors.json were remade when the request code body was redefined (SD-306), and each
// new one was decoded back to its exact text with CIDetector the same way before it was set here.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, test } from 'node:test';
import { K, ROOT, random } from './helpers.mjs';
import { createHash } from 'node:crypto';

const vectors = JSON.parse(readFileSync(join(ROOT, 'tests', 'vectors.json'), 'utf8'));
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const alnumText = n => Array.from(random(n), b => B32[b & 31]).join('');

// Largest alphanumeric text that fits each version at level M, from the data capacity.
function alnumCapacity(v) {
  const countBits = v <= 9 ? 9 : v <= 26 ? 11 : 13;
  const bits = K.qr.dataCodewords(v) * 8 - 4 - countBits;
  return Math.floor(bits / 11) * 2 + (bits % 11 >= 6 ? 1 : 0);
}

describe('QR tables and codes', () => {
  test('Reed-Solomon matches the standard worked example (HELLO WORLD, 1-M)', () => {
    const data = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17];
    assert.deepEqual(K.qr.rsEcc(data, 10), [196, 35, 39, 119, 235, 215, 231, 226, 93, 23]);
  });

  test('format bits for level M and all eight masks', () => {
    const known = ['101010000010010', '101000100100101', '101111001111100', '101101101001011',
      '100010111111001', '100000011001110', '100111110010111', '100101010100000'];
    known.forEach((bits, mask) => assert.equal(K.qr.formatBits(mask).toString(2).padStart(15, '0'), bits));
  });

  test('version bits for versions 7 to 40', () => {
    const known = [0x07c94, 0x085bc, 0x09a99, 0x0a4d3, 0x0bbf6, 0x0c762, 0x0d847, 0x0e60d, 0x0f928, 0x10b78,
      0x1145d, 0x12a17, 0x13532, 0x149a6, 0x15683, 0x168c9, 0x177ec, 0x18ec4, 0x191e1, 0x1afab, 0x1b08e,
      0x1cc1a, 0x1d33f, 0x1ed75, 0x1f250, 0x209d5, 0x216f0, 0x228ba, 0x2379f, 0x24b0b, 0x2542e, 0x26a64,
      0x27541, 0x28c69];
    known.forEach((bits, i) => assert.equal(K.qr.versionBits(i + 7), bits, `version ${i + 7}`));
  });

  test('data codewords at level M for versions 1 to 40', () => {
    const known = [16, 28, 44, 64, 86, 108, 124, 154, 182, 216, 254, 290, 334, 365, 415, 453, 507, 563, 627, 669,
      714, 782, 860, 914, 1000, 1062, 1128, 1193, 1267, 1373, 1455, 1541, 1631, 1725, 1812, 1914, 1992, 2102, 2216, 2334];
    known.forEach((n, i) => assert.equal(K.qr.dataCodewords(i + 1), n, `version ${i + 1}`));
  });

  test('alignment pattern positions', () => {
    const known = { 1: [], 2: [6, 18], 7: [6, 22, 38], 14: [6, 26, 46, 66], 15: [6, 26, 48, 70], 22: [6, 26, 50, 74, 98],
      32: [6, 34, 60, 86, 112, 138], 36: [6, 24, 50, 76, 102, 128, 154], 40: [6, 30, 58, 86, 114, 142, 170] };
    for (const [v, pos] of Object.entries(known)) assert.deepEqual(K.qr.alignmentPositions(Number(v)), pos, `version ${v}`);
  });

  test('the smallest version is chosen, matching the standard alphanumeric capacities', () => {
    const known = { 1: 20, 2: 38, 3: 61, 4: 90, 5: 122, 6: 154, 7: 178, 8: 221, 9: 262, 10: 311, 20: 970, 40: 3391 };
    for (const [v, cap] of Object.entries(known)) assert.equal(alnumCapacity(Number(v)), cap, `version ${v}`);
    for (const v of [1, 2, 9, 10, 26, 27, 39]) {
      assert.equal(K.qr.encode(alnumText(alnumCapacity(v))).version, v);
      assert.equal(K.qr.encode(alnumText(alnumCapacity(v) + 1)).version, v + 1);
    }
    assert.throws(() => K.qr.encode(alnumText(alnumCapacity(40) + 1)), { name: 'CodeError', message: /too-long/ });
  });
});

describe('QR structure', () => {
  test('every version leaves exactly the standard number of data modules', () => {
    for (let v = 1; v <= 40; v++) {
      const qr = K.qr.encode(alnumText(alnumCapacity(v)));
      assert.equal(qr.version, v);
      assert.equal(qr.size, 17 + 4 * v);
      let free = 0;
      for (const f of qr.isFunction) free += f ? 0 : 1;
      assert.equal(free, K.qr.rawDataModules(v), `version ${v}`);
    }
  });

  test('finders, timing, dark module and both copies of the format bits', () => {
    for (const text of ['HELLO WORLD', vectors.approval[0].text, alnumText(1500)]) {
      const qr = K.qr.encode(text);
      const n = qr.size;
      const at = (r, c) => qr.modules[r * n + c];
      for (const [r0, c0] of [[0, 0], [0, n - 7], [n - 7, 0]]) {
        for (let r = 0; r < 7; r++) {
          for (let c = 0; c < 7; c++) {
            const ring = Math.max(Math.abs(r - 3), Math.abs(c - 3));
            assert.equal(at(r0 + r, c0 + c), ring === 2 ? 0 : 1);
          }
        }
      }
      for (let i = 8; i < n - 8; i++) {
        assert.equal(at(6, i), i % 2 === 0 ? 1 : 0);
        assert.equal(at(i, 6), i % 2 === 0 ? 1 : 0);
      }
      assert.equal(at(n - 8, 8), 1);
      let first = 0;
      let second = 0;
      for (let i = 0; i <= 5; i++) first |= at(i, 8) << i;
      first |= (at(7, 8) << 6) | (at(8, 8) << 7) | (at(8, 7) << 8);
      for (let i = 9; i < 15; i++) first |= at(8, 14 - i) << i;
      for (let i = 0; i < 8; i++) second |= at(8, n - 1 - i) << i;
      for (let i = 8; i < 15; i++) second |= at(n - 15 + i, 8) << i;
      assert.equal(first, second);
      assert.equal(first, K.qr.formatBits(qr.mask));
    }
  });

  test('the SVG path covers exactly the dark modules, inside the quiet zone', () => {
    const qr = K.qr.encode(vectors.enrolment[0].text);
    const d = K.qr.svgPath(qr, 4);
    let covered = 0;
    for (const m of d.matchAll(/M(\d+),(\d+)h(\d+)v1h-(\d+)z/g)) {
      const [x, y, w, back] = m.slice(1).map(Number);
      assert.equal(w, back);
      assert.ok(x >= 4 && y >= 4 && x + w <= qr.size + 4 && y < qr.size + 4);
      for (let c = x; c < x + w; c++) assert.equal(qr.modules[(y - 4) * qr.size + (c - 4)], 1);
      covered += w;
    }
    assert.equal(d.replace(/M\d+,\d+h\d+v1h-\d+z/g, ''), '');
    assert.equal(covered, qr.modules.reduce((a, b) => a + b, 0));
  });
});

test('golden outputs, each decoded by CoreImage when made', () => {
  const golden = [
    ['HELLO WORLD', 1, 0, '4c1240bbfb84568fca60ed756358070c8a58cda10a44492afe598922fc3a385b'],
    ['hello, keyholder', 2, 1, '4ba6bd5d6782c196b4c9b1f774d3837780764f9823d632c3f161433dc2b0ee9f'],
    [vectors.request[0].text, 5, 4, 'd9c4b19605b651c49a0331622c12e1b86a6a9c0e835c2fdfafb2be6d77f6b7da'],
    [vectors.request[4].text, 8, 3, '4e92e65a74fdddbd84667c9e8bffa2d25d63c3fe5a2ec1dba308a92eea0c4f3a'],
    [vectors.enrolment[0].text, 6, 4, '98fef0da298018d70ff8113193405a62192a829e32a754b394ddbf318da4346c'],
    [vectors.approval[0].text, 13, 5, '4f2bdd43b184d5a3b8a329e4f5a087eb55fa1f43d2c1c4f31e3686cac710a0bc'],
    [vectors.approval[1].text, 16, 6, 'f9b4d8f4a86aca16531baff2fca6dbf5375a177f390cb8771f55741ab2a99a33'],
  ];
  for (const [text, version, mask, hash] of golden) {
    const qr = K.qr.encode(text);
    assert.equal(qr.version, version);
    assert.equal(qr.mask, mask);
    assert.equal(createHash('sha256').update(qr.modules).digest('hex'), hash, text.slice(0, 20));
  }
});
