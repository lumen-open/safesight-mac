// SPDX-License-Identifier: Apache-2.0
// Tests of the built opener page (SD-066): its policy and parts, and the WebAssembly core
// inside it, run through the page's own bridge (src/core.js) on the stored version 1
// capsule and real rounds of the time signal (ST-072). Every key and secret is made up.
//
//   node --test opener/tests/*.test.mjs                      tests opener/index.html
//   OPENER_PAGE=<file> node --test opener/tests/*.test.mjs   tests another build of the page
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assemble, describe, sources } from '../build.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const PAGE = process.env.OPENER_PAGE || join(here, '..', 'index.html');
const html = readFileSync(PAGE, 'utf8');
const VECTORS = readFileSync(join(here, '..', 'vectors', 'v1.txt'), 'utf8');

// ----- The page's parts -----

function only(re, what) {
  const all = [...html.matchAll(re)];
  assert.equal(all.length, 1, `exactly one ${what}`);
  return all[0][1];
}

const csp = only(/<meta http-equiv="Content-Security-Policy" content="([^"]*)">/g, 'policy');
const style = only(/<style>([\s\S]*?)<\/style>/g, 'style');
const wasmText = only(/<script type="application\/octet-stream" id="core-wasm">([\s\S]*?)<\/script>/g, 'core');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
const hash = (text) => `'sha256-${createHash('sha256').update(text, 'utf8').digest('base64')}'`;

const sandbox = {};
new Function('globalThis', scripts[0])(sandbox);
const core = await sandbox.OpenerCore.load(wasmText);
const wasm = sandbox.OpenerCore.fromBase64(wasmText);
const about = core.about();

// ----- The vectors -----

function vector(name) {
  for (const line of VECTORS.split('\n')) {
    if (line.startsWith(`${name} `)) return line.slice(name.length + 1);
  }
  throw new Error(`no ${name} in the vectors`);
}

const copyBytes = () => Uint8Array.from(Buffer.from(vector('base64'), 'base64'));
const answer = (round) => vector(`round ${round}`);
const signatureHex = (round) => JSON.parse(answer(round)).signature;

// Bech32 (BIP-173), as age writes keys, written here again so that the test does not
// trust the core's own encoder.
const CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
function polymod(values) {
  const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let chk = 1;
  for (const v of values) {
    const top = chk >>> 25;
    chk = (((chk & 0x1ffffff) << 5) ^ v) >>> 0;
    for (let i = 0; i < 5; i += 1) if ((top >>> i) & 1) chk = (chk ^ GEN[i]) >>> 0;
  }
  return chk;
}
function bech32(hrp, bytes) {
  const data = [];
  let acc = 0;
  let bits = 0;
  for (const b of bytes) {
    acc = (acc << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      data.push((acc >>> bits) & 31);
    }
    acc &= (1 << bits) - 1;
  }
  if (bits) data.push((acc << (5 - bits)) & 31);
  const values = [...[...hrp].map((c) => c.charCodeAt(0) >> 5), 0, ...[...hrp].map((c) => c.charCodeAt(0) & 31), ...data];
  const mod = polymod([...values, 0, 0, 0, 0, 0, 0]) ^ 1;
  const check = [0, 1, 2, 3, 4, 5].map((i) => (mod >>> (5 * (5 - i))) & 31);
  return `${hrp}1${[...data, ...check].map((v) => CHARSET[v]).join('')}`;
}
const keyText = (name) => bech32('age-secret-key-', Buffer.from(vector(name), 'hex')).toUpperCase();

// ----- Policy and parts -----

test('the policy allows exactly the inline parts, WebAssembly and the mirrors', () => {
  const rules = new Map(csp.split('; ').map((r) => {
    const [name, ...rest] = r.split(' ');
    return [name, rest];
  }));
  assert.deepEqual(rules.get('default-src'), ["'none'"]);
  assert.deepEqual(rules.get('script-src'), [hash(scripts[0]), hash(scripts[1]), "'wasm-unsafe-eval'"]);
  assert.deepEqual(rules.get('style-src'), [hash(style)]);
  assert.deepEqual(rules.get('connect-src'), about.mirrors);
  assert.deepEqual(about.mirrors, ['https://api.drand.sh', 'https://drand.cloudflare.com']);
  assert.deepEqual(rules.get('img-src'), ['data:']);
  assert.deepEqual(rules.get('base-uri'), ["'none'"]);
  assert.deepEqual(rules.get('form-action'), ["'none'"]);
  assert.deepEqual(rules.get('require-trusted-types-for'), ["'script'"]);
  assert.deepEqual(rules.get('trusted-types'), ["'none'"]);
  assert.equal(rules.size, 9);
});

test('the page loads nothing from anywhere', () => {
  assert.equal(scripts.length, 2);
  assert.doesNotMatch(html, /<script[^>]*\ssrc=/i);
  assert.doesNotMatch(html, /<link[^>]*rel="?stylesheet/i);
  assert.doesNotMatch(html, /\s(src|href|action|poster|data)="(https?:)?\/\//i);
  assert.doesNotMatch(style, /@import|url\(/i);
  assert.doesNotMatch(html, /\son[a-z]+="/i, 'no inline event handlers');
  assert.doesNotMatch(scripts.join('\n'), /innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|new Function/);
  // The only addresses in the scripts are none: the mirrors come from the core.
  assert.doesNotMatch(scripts.join('\n'), /https?:\/\//);
});

test('the page is what its sources build, around the core it carries', async () => {
  assert.equal(assemble(wasm, await describe(wasm), sources()), html);
});

test('the core names its version, the account and the wait', () => {
  const cargo = readFileSync(join(here, '..', '..', 'keeper', 'Cargo.toml'), 'utf8');
  assert.equal(about.version, cargo.match(/^version = "([^"]+)"/m)[1]);
  assert.equal(about.chain, '52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971');
  assert.equal(about.account, 'SafeSight Mac administrator');
  assert.equal(about.claim_days, 7);
  assert.equal(about.secret_length, 40);
  assert.equal(about.key_opening, 'AGE-SECRET-KEY-1');
});

// ----- The steps, through the page's bridge -----

test('the stored version 1 copy opens with its round and its key', () => {
  core.clear();
  const info = core.inspect(copyBytes());
  assert.deepEqual(info, {
    generation: 3,
    target_round: 1000,
    target_time: 1692806364,
    urls: [
      'https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/public/1000',
      'https://drand.cloudflare.com/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/public/1000',
    ],
  });
  const opened = core.openTime(answer(1000));
  assert.equal(opened.error, undefined);
  assert.equal(opened.round, 1000);
  assert.equal(core.openKey(keyText('other-key')).error, 'not_for_this_key');
  const r = core.openKey(`  ${keyText('key')}\n`);
  assert.equal(r.secret, vector('secret'));
  assert.equal(r.secret.length, 40);
  core.clear();
  assert.equal(core.openKey(keyText('key')).error, 'not_ready');
});

test('the round is checked before anything opens', () => {
  core.clear();
  core.inspect(copyBytes());
  const early = core.openTime(answer(1));
  assert.equal(early.error, 'not_yet');
  assert.equal(early.round_time, 1692803367);
  assert.equal(early.target_time, 1692806364);
  assert.equal(core.openTime(answer(1001)).error, 'wrong_round');
  assert.equal(core.openTime('Requested future beacon').error, 'not_a_round');
  assert.equal(core.openTime('').error, 'not_a_round');
  const forged = core.openTime(JSON.stringify({ round: 1000, signature: signatureHex(1001) }));
  assert.equal(forged.error, 'bad_signature');
  assert.equal(forged.named, true);
  const bare = core.openTime(signatureHex(1001));
  assert.equal(bare.error, 'bad_signature');
  assert.equal(bare.named, false);
  const changed = answer(1000).replace('"signature":"b4', '"signature":"b5');
  assert.equal(core.openTime(changed).error, 'inconsistent');
  assert.equal(core.openTime('x'.repeat(16385)).error, 'not_a_round');
  // After all that, the key still cannot open anything.
  assert.equal(core.openKey(keyText('key')).error, 'not_ready');
  // The signature alone, pasted, is enough.
  assert.equal(core.openTime(`\n${signatureHex(1000)}\n`).error, undefined);
  assert.equal(core.openKey(keyText('key')).secret, vector('secret'));
});

test('a wrong key is named plainly', () => {
  core.clear();
  core.inspect(copyBytes());
  assert.equal(core.openTime(answer(1000)).error, undefined);
  const key = keyText('key');
  const typo = key.slice(0, 40) + (key[40] === 'Q' ? 'P' : 'Q') + key.slice(41);
  assert.equal(core.openKey(typo).error, 'typo');
  assert.equal(core.openKey(key.slice(0, 73)).error, 'typo');
  assert.equal(core.openKey('').error, 'empty');
  assert.equal(core.openKey('hunter2').error, 'not_a_key');
  assert.equal(core.openKey('x'.repeat(5000)).error, 'not_a_key');
  const publicHalf = 'age1x7gep5wumjutg2tp5lhj5t6d74vaxs4dk9nhcddjdld7p5mgwgmsfdgr3x';
  assert.equal(core.openKey(publicHalf).error, 'public_half');
  assert.equal(core.openKey(key.toLowerCase()).secret, vector('secret'));
});

test('what is not a good copy is named plainly', () => {
  core.clear();
  assert.equal(core.inspect(new Uint8Array(0)).error, 'not_a_copy');
  assert.equal(core.inspect(new TextEncoder().encode(answer(1000))).error, 'not_a_copy');
  assert.equal(core.inspect(new Uint8Array(5000)).error, 'not_a_copy');
  const damaged = copyBytes();
  damaged[900] ^= 1;
  assert.equal(core.inspect(damaged).error, 'damaged');
  const newer = copyBytes();
  newer[6] = 2;
  assert.equal(core.inspect(newer).error, 'newer_version');
  // A key given for a damaged copy opens nothing.
  assert.equal(core.openTime(answer(1000)).error, 'newer_version');
});
