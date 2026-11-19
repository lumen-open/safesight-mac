// SPDX-License-Identifier: Apache-2.0
// The built page: index.html is exactly what the sources build, holds exactly the current core,
// talks to nothing (SD-155: no outside origin, no network or storage interface, no form target,
// a strict policy that allows only its own inline parts), says what the register asks it to say
// (SD-194, SD-196), and its screens work, run here against a small stand-in for the browser.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, test } from 'node:test';
import { build, policy, sources } from '../build.mjs';
import { CORE_SOURCE, K, ROOT, assertionFor, attestationFor, keeperCheck, makeAuthenticator, random } from './helpers.mjs';

const html = readFileSync(join(ROOT, 'index.html'), 'utf8');
const src = sources();
const scripts = [...html.matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/gi)];
const styles = [...html.matchAll(/<style([^>]*)>([\s\S]*?)<\/style>/gi)];
const hashOf = text => `'sha256-${createHash('sha256').update(text, 'utf8').digest('base64')}'`;
const cspMatch = html.match(/<meta http-equiv="Content-Security-Policy" content="([^"]*)">/);
const csp = new Map((cspMatch ? cspMatch[1] : '').split(';').map(d => d.trim().split(/\s+/)).filter(d => d[0]).map(([k, ...v]) => [k, v]));

describe('index.html is built from the sources', () => {
  test('it is exactly what build.mjs makes from them', () => {
    assert.equal(html, build(), 'index.html is out of date: run node keyholder/build.mjs');
  });

  test('it holds exactly the current core.js, and the page script, each in its own element', () => {
    assert.equal(scripts.length, 2);
    assert.equal(scripts[0][2], CORE_SOURCE);
    assert.equal(scripts[1][2], src.page);
    assert.equal(styles.length, 1);
    assert.equal(styles[0][2], src.css);
  });

  test('every file starts with its licence line', () => {
    assert.ok(html.startsWith('<!-- SPDX-License-Identifier: Apache-2.0 -->\n'));
    for (const f of ['core.js', 'build.mjs', 'src/page.js', 'src/page.css', 'src/page.html', 'README.md',
      'tests/helpers.mjs', 'tests/make-vectors.mjs', 'tests/codes.test.mjs', 'tests/passkey.test.mjs', 'tests/qr.test.mjs', 'tests/page.test.mjs']) {
      assert.match(readFileSync(join(ROOT, f), 'utf8').split('\n')[0], /SPDX-License-Identifier: Apache-2\.0/, f);
    }
  });
});

describe('the page sends nothing (SD-155)', () => {
  test('one strict policy, set before any script or style', () => {
    assert.equal(html.split('Content-Security-Policy').length, 2, 'exactly one policy');
    assert.ok(cspMatch);
    assert.ok(html.indexOf(cspMatch[0]) < html.search(/<style|<script/i));
    assert.equal(cspMatch[1], policy(src));
    assert.deepEqual(csp.get('default-src'), ["'none'"]);
    assert.deepEqual(csp.get('connect-src'), ["'none'"]);
    assert.deepEqual(csp.get('form-action'), ["'none'"]);
    assert.deepEqual(csp.get('base-uri'), ["'none'"]);
    assert.deepEqual(csp.get('img-src'), ['data:']);
    for (const d of ['script-src', 'style-src']) {
      assert.ok(csp.get(d).length > 0);
      for (const token of csp.get(d)) assert.match(token, /^'sha256-[A-Za-z0-9+/]{43}='$/, `${d} allows only hashes`);
    }
    for (const allowed of ['default-src', 'script-src', 'style-src', 'img-src', 'connect-src', 'base-uri', 'form-action', 'require-trusted-types-for', 'trusted-types']) {
      assert.ok(csp.has(allowed), allowed);
    }
    assert.equal(csp.size, 9, 'no other directive widens anything');
  });

  test('the policy allows exactly the inline script and style, and nothing loads by address', () => {
    assert.deepEqual([...csp.get('script-src')].sort(), scripts.map(s => hashOf(s[2])).sort());
    assert.deepEqual(csp.get('style-src'), styles.map(s => hashOf(s[2])));
    for (const s of scripts) assert.equal(s[1].trim(), '', 'no src or other attribute on a script');
    for (const s of styles) assert.equal(s[1].trim(), '');
  });

  test('no address of any other origin, and no attribute that loads anything', () => {
    let rest = html;
    if (K.PINNED_ORIGIN) rest = rest.split(K.PINNED_ORIGIN).join('');
    assert.doesNotMatch(rest, /https?:\/\//i);
    assert.doesNotMatch(rest, /\b(?:wss?|ftp|blob|filesystem|javascript):/i);
    // In the markup: no attribute that names something to load or submit to.
    const markup = html.replace(/<script>[\s\S]*?<\/script>|<style>[\s\S]*?<\/style>/g, '');
    assert.doesNotMatch(markup, /\s(?:src|srcset|action|formaction|poster|ping|background|manifest|xlink:href|data)\s*=/i);
    // In the scripts: no such attribute set from code either.
    for (const s of scripts) {
      assert.doesNotMatch(s[2], /setAttribute\(\s*['"`](?:src|srcset|href|action|formaction|poster|ping|data)['"`]/i);
      assert.doesNotMatch(s[2], /\.(?:src|srcset|href|action|formAction|poster|ping)\s*=/);
    }
    const hrefs = [...html.matchAll(/\bhref\s*=\s*"([^"]*)"/gi)].map(m => m[1]);
    assert.deepEqual(hrefs, ['data:,'], 'only the empty icon, so the browser asks the host for no favicon');
    for (const css of [markup, ...styles.map(s => s[2])]) assert.doesNotMatch(css, /(?<![\w-])url\s*\(|@import|image-set\s*\(/i);
  });

  test('no element that loads, submits, frames or links', () => {
    assert.doesNotMatch(html, /<(?:form|iframe|frame|frameset|object|embed|applet|img|picture|source|audio|video|track|base|a|area|portal)\b/i);
    assert.equal((html.match(/<link\b/gi) || []).length, 1);
    assert.match(html, /<link rel="icon" href="data:,">/);
    assert.doesNotMatch(html, /http-equiv="refresh"/i);
    assert.match(html, /<meta name="referrer" content="no-referrer">/);
  });

  test('no network, storage or markup-injection interface anywhere in the file', () => {
    const banned = [
      /\bfetch\b/, /\bXMLHttpRequest\b/, /\bWebSocket\b/, /\bsendBeacon\b/, /\bEventSource\b/, /\bWebTransport\b/,
      /\bRTCPeerConnection\b/, /\bRTCDataChannel\b/, /\bWorker\b/, /\bSharedWorker\b/, /\bserviceWorker\b/, /\bimportScripts\b/,
      /\bBroadcastChannel\b/, /\bpostMessage\b/, /\blocalStorage\b/, /\bsessionStorage\b/, /\bindexedDB\b/, /\bcookie\b/i,
      /\bcaches\b/, /\bCacheStorage\b/, /\binnerHTML\b/, /\bouterHTML\b/, /\binsertAdjacentHTML\b/, /document\.write/,
      /\beval\b/, /\bFunction\s*\(/, /\bimport\s*\(/, /\bwindow\.open\b/, /\blocation\.(?:href|assign|replace|reload)\b/,
      /\bnavigator\.share\b/, /\bcreateElement\b/, /\.src\b/, /\bnew Image\b/, /\brequestSubmit\b/, /\.submit\s*\(/,
      /\b(?:prefetch|preconnect|dns-prefetch|preload|modulepreload)\b/, /\bsetTimeout\s*\(\s*['"`]/, /\bsetInterval\b/,
    ];
    for (const pattern of banned) assert.doesNotMatch(html, pattern);
  });

  test('the fragment is taken out of the address bar, and the page refuses to run in a frame', () => {
    assert.match(src.page, /history\.replaceState\(null, '', location\.pathname \+ location\.search\)/);
    assert.match(src.page, /window\.top !== window\.self/);
    assert.doesNotMatch(src.page, /pushState/);
  });
});

describe('the words on the page', () => {
  const visible = src.template.replace(/<style>[\s\S]*?<\/style>|<script>[\s\S]*?<\/script>/g, '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');

  test('a keyholder can only shorten a wait, never block, and sees nothing else (SD-194, SD-196)', () => {
    for (const phrase of [
      'It then takes 24 hours instead of their full wait.',
      "You can't stop them leaving, and nobody can ask you to.",
      'Saying no, or not answering, is always fine.',
      "You won't see anything about them or their Mac, and you won't be told anything.",
      'This page sends nothing to anyone.',
      'If you approve, it takes 24 hours instead of their full wait.',
      "You can't stop this. Without your approval they can still do it, after their full wait. You can only make it sooner.",
      "Saying no, or not answering, is fine. This is all you'll see, and you won't be told what happens next.",
    ]) assert.ok(visible.includes(phrase), phrase);
  });

  test('no word the project never uses, and none that suggests watching or reporting', () => {
    const words = [/can't be bypassed/i, /100%/, /blocks all/i, /treats addiction/i, /nobody can ever unlock it/i,
      /\bmonitor/i, /\breport/i, /\bwatch/i, /accountab/i, /\btamper/i, /\battempt/i, /\bviolat/i, /\bporn/i, /\bexplicit\b/i];
    const askTexts = Object.values(K.KIND).map(kind => K.askText({ kind, items: [random(32), random(32)] }));
    for (const text of [visible, src.page, ...askTexts]) for (const w of words) assert.doesNotMatch(text, w);
  });
});

// ------------------------------------------------------------------------------------------------
// The screens, run against a small stand-in for the browser
// ------------------------------------------------------------------------------------------------

function fakeBrowser({ hash = '', framed = false, passkeys = true, auth = makeAuthenticator() } = {}) {
  const elements = new Map();
  for (const m of src.template.matchAll(/<(\w+)([^>]*?)\sid="([^"]+)"([^>]*)>/g)) {
    const [, tag, before, id, after] = m;
    const el = {
      id,
      tagName: tag.toUpperCase(),
      hidden: /\shidden\b/.test(` ${before} ${after}`),
      textContent: '',
      value: '',
      disabled: false,
      tabIndex: 0,
      attrs: {},
      listeners: {},
      setAttribute(k, v) { this.attrs[k] = String(v); },
      getAttribute(k) { return this.attrs[k]; },
      addEventListener(t, f) { (this.listeners[t] ||= []).push(f); },
      focus() {},
      select() {},
      querySelector(sel) { return sel === 'h1' ? this.heading : null; },
      async click() { for (const f of this.listeners.click || []) await f({ target: this }); },
    };
    elements.set(id, el);
  }
  for (const el of elements.values()) if (el.tagName === 'SECTION') el.heading = { focus() {}, tabIndex: 0 };
  const calls = { create: [], get: [], replaced: [] };
  const location = { hash, pathname: '/keyholder/', search: '', hostname: 'keyholder.example', origin: 'https://keyholder.example' };
  const win = { isSecureContext: true, scrollTo() {}, listeners: {}, addEventListener(t, f) { (this.listeners[t] ||= []).push(f); } };
  win.self = win;
  win.top = framed ? {} : win;
  if (passkeys) win.PublicKeyCredential = function PublicKeyCredential() {};
  const navigator = {
    clipboard: { writeText: async () => {} },
    credentials: {
      async create({ publicKey }) {
        calls.create.push(publicKey);
        const att = attestationFor(auth, { rpId: publicKey.rp.id, origin: location.origin });
        return { rawId: att.rawId.slice().buffer, response: { attestationObject: att.attestationObject.slice().buffer, clientDataJSON: att.clientDataJSON.slice().buffer, getPublicKey: () => auth.spki.slice().buffer } };
      },
      async get({ publicKey }) {
        calls.get.push(publicKey);
        const a = assertionFor(auth, { rpId: publicKey.rpId, origin: location.origin, challenge: publicKey.challenge });
        return { response: { authenticatorData: a.authenticatorData.slice().buffer, clientDataJSON: a.clientDataJSON.slice().buffer, signature: a.signature.slice().buffer } };
      },
    },
  };
  const history = { replaceState(state, title, url) { calls.replaced.push(url); location.hash = ''; } };
  const document = {
    getElementById: id => {
      if (!elements.has(id)) throw new Error(`no element #${id}`);
      return elements.get(id);
    },
    querySelectorAll: sel => (sel === 'button' ? [...elements.values()].filter(e => e.tagName === 'BUTTON') : []),
  };
  // eslint-disable-next-line no-new-func
  const run = new Function('KeyholderCore', 'window', 'document', 'navigator', 'location', 'history', 'crypto', src.page);
  run(K, win, document, navigator, location, history, globalThis.crypto);
  const $ = id => elements.get(id);
  const shown = () => [...elements.values()].filter(e => e.tagName === 'SECTION' && !e.hidden).map(e => e.id);
  return { $, shown, calls, location, win, auth };
}

function requestText(kind = K.KIND.EXIT, label = "Sam's Mac") {
  const fields = { kind, requestId: random(16), challenge: random(32), label, items: kind === K.KIND.ADMIN_BATCH ? [random(32)] : [] };
  return { fields, text: K.encodeRequestCode(fields) };
}

describe('the screens', () => {
  test('opens on the first screen when there is no request', () => {
    const b = fakeBrowser();
    assert.deepEqual(b.shown(), ['screen-home']);
    assert.deepEqual(b.calls.replaced, []);
  });

  test('stops inside a frame, or where passkeys are missing', () => {
    const framed = fakeBrowser({ framed: true, hash: `#${requestText().text}` });
    assert.deepEqual(framed.shown(), ['screen-stopped']);
    assert.match(framed.$('stopped-title').textContent, /on its own/);
    assert.deepEqual(framed.calls.replaced, ['/keyholder/'], 'the code still leaves the address bar');
    const old = fakeBrowser({ passkeys: false });
    assert.deepEqual(old.shown(), ['screen-stopped']);
    assert.match(old.$('stopped-title').textContent, /can't make passkeys/);
  });

  test('enrolment makes an ES256 key and shows its code as a QR picture and as text', async () => {
    const b = fakeBrowser();
    b.$('key-name').value = "Sam's Mac";
    await b.$('create-key').click();
    assert.deepEqual(b.shown(), ['screen-enrolled']);
    const opts = b.calls.create[0];
    assert.equal(opts.rp.id, 'keyholder.example');
    assert.deepEqual(opts.pubKeyCredParams, [{ type: 'public-key', alg: -7 }]);
    assert.equal(opts.user.name, "Sam's Mac");
    const rec = K.decodeEnrolmentCode(b.$('enrolled-text').value);
    assert.deepEqual(rec.publicKey, b.auth.raw);
    assert.deepEqual(rec.credentialId, b.auth.credentialId);
    assert.ok(b.$('enrolled-qr-path').attrs.d.length > 100);
    assert.equal(b.$('home-error').hidden, true);
  });

  test('a linked request is read from after #, removed from the address, shown, and approved', async () => {
    const { fields, text } = requestText();
    const b = fakeBrowser({ hash: `#${text}` });
    assert.deepEqual(b.calls.replaced, ['/keyholder/']);
    assert.equal(b.location.hash, '');
    assert.deepEqual(b.shown(), ['screen-request']);
    assert.equal(b.$('request-title').textContent, "A request from Sam's Mac");
    assert.equal(b.$('request-ask').textContent, "They've asked to leave. If you approve, their wait becomes 24 hours.");
    assert.equal(b.$('request-real').hidden, false);
    await b.$('request-approve').click();
    assert.deepEqual(b.calls.get[0].challenge, fields.challenge, 'the passkey signs the challenge exactly');
    assert.deepEqual(b.shown(), ['screen-approved']);
    assert.equal(b.$('approved-label').textContent, "Sam's Mac");
    const pin = { publicKey: b.auth.raw };
    const request = K.decodeRequestCode(text);
    assert.equal(keeperCheck({ approvalText: b.$('approved-text').value, pin, request, origin: 'https://keyholder.example', rpId: 'keyholder.example' }), 'ok');
    assert.ok(b.$('approved-qr-path').attrs.d.length > 100);
    await b.$('approved-done').click();
    assert.equal(b.$('approved-text').value, '', 'the code is cleared once done');
  });

  test('a test request says it changes nothing', async () => {
    const b = fakeBrowser({ hash: `#${requestText(K.KIND.TEST, 'Test Mac').text}` });
    assert.equal(b.$('request-title').textContent, 'A test from Test Mac');
    assert.match(b.$('request-ask').textContent, /changes nothing/);
    assert.equal(b.$('request-real').hidden, true);
    await b.$('request-approve').click();
    assert.equal(b.$('approved-title').textContent, 'Test approved');
    assert.equal(b.$('approved-test').hidden, false);
    assert.equal(b.$('approved-real').hidden, true);
  });

  test('a label is shown as text, never read as markup', () => {
    const b = fakeBrowser({ hash: `#${requestText(K.KIND.EXIT, '<img src=x onerror=1>').text}` });
    assert.equal(b.$('request-title').textContent, 'A request from <img src=x onerror=1>');
  });

  test('pasting works, and a bad or wrong code gets a plain message', async () => {
    const b = fakeBrowser();
    await b.$('go-paste').click();
    assert.deepEqual(b.shown(), ['screen-paste']);
    b.$('paste-text').value = 'NOT A CODE 0189';
    await b.$('paste-read').click();
    assert.equal(b.$('paste-error').hidden, false);
    assert.match(b.$('paste-error').textContent, /doesn't look like a request code/);
    const { text } = requestText();
    b.$('paste-text').value = `${text.slice(0, 40)}AAAA${text.slice(44)}`;
    await b.$('paste-read').click();
    assert.match(b.$('paste-error').textContent, /incomplete or damaged/);
    b.$('paste-text').value = K.encodeEnrolmentCode({ credentialId: random(16), publicKey: makeAuthenticator().raw });
    await b.$('paste-read').click();
    assert.match(b.$('paste-error').textContent, /A request code is the one their Mac shows you/);
    b.$('paste-text').value = `https://keyholder.example/keyholder/#${text.toLowerCase()}`;
    await b.$('paste-read').click();
    assert.deepEqual(b.shown(), ['screen-request']);
    assert.equal(b.$('paste-text').value, '');
  });

  test('a damaged linked code opens the paste screen with a message', () => {
    const b = fakeBrowser({ hash: '#ABCDEFG' });
    assert.deepEqual(b.shown(), ['screen-paste']);
    assert.equal(b.$('paste-error').hidden, false);
  });

  test('"Not now" changes nothing and forgets the request', async () => {
    const b = fakeBrowser({ hash: `#${requestText().text}` });
    await b.$('request-decline').click();
    assert.deepEqual(b.shown(), ['screen-declined']);
    await b.$('request-approve').click();
    assert.equal(b.calls.get.length, 0, 'nothing is signed after "Not now"');
    assert.deepEqual(b.shown(), ['screen-home']);
  });

  test('a cancelled passkey prompt is met calmly, and nothing is shown', async () => {
    const b = fakeBrowser({ hash: `#${requestText().text}` });
    const err = new Error('cancelled');
    err.name = 'NotAllowedError';
    b.calls.get.push = () => { throw err; };
    await b.$('request-approve').click();
    assert.deepEqual(b.shown(), ['screen-request']);
    assert.match(b.$('request-error').textContent, /No key was used/);
    assert.equal(b.$('approved-text').value, '');
  });

  test('a code opened while the page is open is read the same way', () => {
    const b = fakeBrowser();
    b.location.hash = `#${requestText(K.KIND.LOWER_WAIT).text}`;
    for (const f of b.win.listeners.hashchange) f();
    assert.deepEqual(b.shown(), ['screen-request']);
    assert.match(b.$('request-ask').textContent, /wait shorter/);
    assert.deepEqual(b.calls.replaced, ['/keyholder/']);
  });
});
