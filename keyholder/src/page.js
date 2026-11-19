// SPDX-License-Identifier: Apache-2.0
// The keyholder page's screens. Everything happens here, in the keyholder's browser: the page
// makes a passkey, reads a request code, asks the passkey to sign it, and shows the result for
// the keyholder to hand back themself. It keeps nothing and sends nothing (SD-155, SD-194).
(() => {
  'use strict';
  const K = KeyholderCore;
  const $ = id => document.getElementById(id);
  const SCREENS = ['home', 'enrolled', 'paste', 'request', 'approved', 'declined', 'stopped'];

  // The request on screen. Held in memory only, and dropped once it is answered.
  let current = null;

  function show(name) {
    for (const s of SCREENS) $(`screen-${s}`).hidden = s !== name;
    window.scrollTo(0, 0);
    const heading = $(`screen-${name}`).querySelector('h1');
    if (heading) {
      heading.tabIndex = -1;
      heading.focus({ preventScroll: true });
    }
  }

  function stop(title, text) {
    $('stopped-title').textContent = title;
    $('stopped-text').textContent = text;
    show('stopped');
  }

  function setError(id, text) {
    const el = $(id);
    el.textContent = text || '';
    el.hidden = !text;
  }

  function busy(on) {
    for (const b of document.querySelectorAll('button')) b.disabled = on;
  }

  function random(n) {
    return crypto.getRandomValues(new Uint8Array(n));
  }

  const DAMAGED = 'That code looks incomplete or damaged. Ask them to show it again, or copy it again.';
  const CODE_MESSAGES = {
    empty: 'Paste the code first.',
    'too-long': "That's longer than any request code. Check that you copied only the code.",
    characters: "That doesn't look like a request code. Check that you copied all of it, and nothing else.",
    damaged: DAMAGED,
    malformed: DAMAGED,
    version: "That code was made by a different version of SafeSight Mac, so this page can't read it. Ask them to check their Mac for updates.",
  };

  function codeMessage(err) {
    if (err && err.reason === 'wrong-type') {
      return err.detail === 'enrolment' || err.detail === 'approval'
        ? "That's a code this page made for their Mac. A request code is the one their Mac shows you."
        : "That doesn't look like a request code.";
    }
    return (err && CODE_MESSAGES[err.reason]) || DAMAGED;
  }

  function passkeyMessage(err, making) {
    const name = err && err.name;
    if (name === 'NotAllowedError' || name === 'AbortError') {
      return making
        ? "No key was made. If you cancelled, that's fine. You can try again whenever you like."
        : "No key was used. If you cancelled, that's fine. If your phone found no key, this may not be the phone or browser you made it on.";
    }
    if (name === 'NotSupportedError') return "Your phone can't make the kind of key SafeSight Mac needs. Try another browser on this phone, or another phone.";
    if (name === 'SecurityError') return "Keys can't be made or used on this address.";
    if (name === 'InvalidStateError') return 'This phone already has that key.';
    if (err && err.reason === 'passkey') {
      return `Your phone answered in a way their Mac can't read, so nothing was made or approved. (${err.detail})`;
    }
    return `Something went wrong, and nothing was made or approved. (${(err && (err.detail || err.message)) || 'unknown'})`;
  }

  function showCode(prefix, text) {
    const qr = K.qr.encode(text);
    const n = String(qr.size + 8);
    $(`${prefix}-qr`).setAttribute('viewBox', `0 0 ${n} ${n}`);
    $(`${prefix}-qr-bg`).setAttribute('width', n);
    $(`${prefix}-qr-bg`).setAttribute('height', n);
    $(`${prefix}-qr-path`).setAttribute('d', K.qr.svgPath(qr, 4));
    $(`${prefix}-text`).value = text;
    $(`${prefix}-status`).textContent = '';
  }

  function clearCode(prefix) {
    $(`${prefix}-qr-path`).setAttribute('d', '');
    $(`${prefix}-text`).value = '';
    $(`${prefix}-status`).textContent = '';
  }

  async function copy(prefix) {
    const area = $(`${prefix}-text`);
    try {
      await navigator.clipboard.writeText(area.value);
      $(`${prefix}-status`).textContent = 'Copied.';
    } catch (e) {
      area.focus();
      area.select();
      $(`${prefix}-status`).textContent = "Selected. Use your phone's Copy to copy it.";
    }
  }

  // Enrolment (SD-195): make an ES256 passkey for this page's origin and show the enrolment code.
  async function createKey() {
    setError('home-error', '');
    busy(true);
    try {
      const rpId = location.hostname;
      const publicKey = K.createOptions({ rpId, userId: random(16), challenge: random(32), keyName: $('key-name').value });
      const cred = await navigator.credentials.create({ publicKey });
      if (!cred || !cred.response || !cred.response.attestationObject) throw new K.CodeError('passkey', 'no key came back');
      const r = cred.response;
      let spki = null;
      try {
        spki = typeof r.getPublicKey === 'function' ? r.getPublicKey() : null;
      } catch (e) {
        spki = null;
      }
      const result = await K.enrolmentFromCreate({
        rawId: cred.rawId,
        attestationObject: r.attestationObject,
        clientDataJSON: r.clientDataJSON,
        spki: spki ? new Uint8Array(spki) : null,
        rpId,
      });
      showCode('enrolled', result.code);
      show('enrolled');
    } catch (e) {
      setError('home-error', passkeyMessage(e, true));
    } finally {
      busy(false);
    }
  }

  // A request (SD-196): say plainly what is asked, then wait for the keyholder's answer.
  function openRequest(text) {
    const req = K.decodeRequestCode(K.extractCode(text));
    const test = req.kind === K.KIND.TEST;
    current = req;
    $('request-eyebrow').textContent = test ? 'Test' : 'Request';
    $('request-title').textContent = test ? `A test from ${req.label}` : `A request from ${req.label}`;
    $('request-ask').textContent = K.askText(req);
    $('request-real').hidden = test;
    $('request-approve').textContent = test ? 'Approve the test' : 'Approve with my key';
    setError('request-error', '');
    show('request');
  }

  async function approve() {
    const req = current;
    if (!req) {
      show('home');
      return;
    }
    setError('request-error', '');
    busy(true);
    try {
      const rpId = location.hostname;
      const cred = await navigator.credentials.get({ publicKey: K.getOptions({ rpId, challenge: req.challenge }) });
      if (!cred || !cred.response || !cred.response.signature) throw new K.CodeError('passkey', 'no signature came back');
      const r = cred.response;
      const code = await K.approvalFromGet({
        authenticatorData: r.authenticatorData,
        clientDataJSON: r.clientDataJSON,
        signature: r.signature,
        request: req,
        origin: location.origin,
        rpId,
      });
      const test = req.kind === K.KIND.TEST;
      $('approved-title').textContent = test ? 'Test approved' : 'Approved';
      $('approved-label').textContent = req.label;
      $('approved-real').hidden = test;
      $('approved-test').hidden = !test;
      showCode('approved', code);
      current = null;
      show('approved');
    } catch (e) {
      setError('request-error', passkeyMessage(e, false));
    } finally {
      busy(false);
    }
  }

  function readPasted() {
    setError('paste-error', '');
    try {
      openRequest($('paste-text').value);
      $('paste-text').value = '';
    } catch (e) {
      setError('paste-error', codeMessage(e));
    }
  }

  function goPaste() {
    setError('paste-error', '');
    show('paste');
  }

  // The request code travels only after "#" (SD-195). Read it, then take it out of the address
  // bar and this page's history entry.
  function takeFragment() {
    const raw = location.hash.length > 1 ? location.hash.slice(1) : '';
    if (location.hash) history.replaceState(null, '', location.pathname + location.search);
    return raw;
  }

  function openFromFragment() {
    const raw = takeFragment();
    if (!raw) return false;
    try {
      openRequest(raw);
    } catch (e) {
      goPaste();
      setError('paste-error', codeMessage(e));
    }
    return true;
  }

  function start() {
    const linked = takeFragment();
    // A policy set in a meta tag cannot forbid framing, so the page checks for itself.
    if (window.top !== window.self) {
      stop('Open this page on its own', "This page only works when it isn't inside another site. Open its address directly.");
      return;
    }
    if (K.PINNED_ORIGIN && location.origin !== K.PINNED_ORIGIN) {
      stop("This isn't the keyholder page's address", 'Keys for SafeSight Mac can only be made and used on the keyholder page itself.');
      return;
    }
    const supported = Boolean(window.isSecureContext && window.PublicKeyCredential &&
      navigator.credentials && navigator.credentials.create && navigator.credentials.get);
    if (!supported) {
      stop("This browser can't make passkeys", "Try your phone's main browser, such as Safari on an iPhone or Chrome on Android. The phone also needs a screen lock: a passcode, face or fingerprint.");
      return;
    }

    $('create-key').addEventListener('click', createKey);
    $('go-paste').addEventListener('click', goPaste);
    $('enrolled-paste').addEventListener('click', goPaste);
    $('enrolled-copy').addEventListener('click', () => copy('enrolled'));
    $('paste-read').addEventListener('click', readPasted);
    $('paste-back').addEventListener('click', () => show('home'));
    $('request-approve').addEventListener('click', approve);
    $('request-decline').addEventListener('click', () => {
      current = null;
      show('declined');
    });
    $('approved-copy').addEventListener('click', () => copy('approved'));
    $('approved-done').addEventListener('click', () => {
      clearCode('approved');
      show('home');
    });
    $('declined-home').addEventListener('click', () => show('home'));
    for (const id of ['enrolled-text', 'approved-text']) $(id).addEventListener('focus', e => e.target.select());
    window.addEventListener('hashchange', openFromFragment);

    if (!linked) {
      show('home');
      return;
    }
    try {
      openRequest(linked);
    } catch (e) {
      goPaste();
      setError('paste-error', codeMessage(e));
    }
  }

  start();
})();
