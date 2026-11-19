// SPDX-License-Identifier: Apache-2.0
// The opener page (SD-066; chapter 03 section 11): the steps, in plain words, over the
// WebAssembly core. The page reads the recovery copy and the Recovery Key on this device
// only. Its one request, made only when asked, is for the time signal of the copy's round,
// to a beacon mirror the core names; the Content-Security-Policy allows nothing else.
'use strict';
(function () {
  const $ = (id) => document.getElementById(id);
  const SCREENS = ['screen-loading', 'screen-old', 'screen-copy', 'screen-time', 'screen-key', 'screen-done', 'screen-cleared'];
  const STEP_OF = { 'screen-copy': 1, 'screen-time': 2, 'screen-key': 3, 'screen-done': 4, 'screen-cleared': 4 };
  const FETCH_TIMEOUT_MS = 15000;

  let core = null;
  let about = null;
  let copy = null;

  // ----- Small helpers -----

  function show(id, focus) {
    for (const s of SCREENS) $(s).hidden = s !== id;
    const step = STEP_OF[id] || 0;
    const steps = $('steps');
    steps.hidden = step === 0;
    for (const li of steps.children) {
      const n = Number(li.dataset.step);
      li.classList.toggle('done', n < step);
      li.classList.toggle('now', n === step);
      if (n === step) li.setAttribute('aria-current', 'step');
      else li.removeAttribute('aria-current');
    }
    window.scrollTo(0, 0);
    if (focus !== false) {
      const heading = $(id).querySelector('h1');
      if (heading) heading.focus({ preventScroll: true });
    }
  }

  function say(el, text) {
    el.textContent = text || '';
    el.hidden = !text;
  }

  const num = (n) => Number(n).toLocaleString();
  const nowSeconds = () => Math.floor(Date.now() / 1000);

  const DATE = new Intl.DateTimeFormat(undefined, {
    weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
    hour: 'numeric', minute: '2-digit', timeZoneName: 'short',
  });

  function when(seconds) {
    if (!Number.isFinite(seconds) || seconds <= 0 || seconds > 8.6e12) return 'a date very far in the future';
    return DATE.format(new Date(seconds * 1000));
  }

  function roughly(seconds) {
    const MIN = 60, HOUR = 3600, DAY = 86400;
    const count = (n, one, many) => (n === 1 ? `about 1 ${one}` : `about ${num(n)} ${many}`);
    if (seconds < 2 * MIN) return 'a minute or two';
    if (seconds < 2 * HOUR) return count(Math.round(seconds / MIN), 'minute', 'minutes');
    if (seconds < 2 * DAY) return count(Math.round(seconds / HOUR), 'hour', 'hours');
    if (seconds < 120 * DAY) return count(Math.round(seconds / DAY), 'day', 'days');
    if (seconds < 730 * DAY) return count(Math.round(seconds / (30 * DAY)), 'month', 'months');
    return count(Math.round(seconds / (365 * DAY)), 'year', 'years');
  }

  async function readFile(file, max) {
    if (!file || file.size > max) return null;
    return new Uint8Array(await file.arrayBuffer());
  }

  // ----- Words -----

  const COPY_WORDS = {
    not_a_copy: "That file isn't a SafeSight Mac recovery copy. Look for the file saved beside this page, in the folder you chose for recovery copies.",
    newer_version: 'That copy was made by a newer SafeSight Mac than this page knows. Use the opener saved beside it, or the newest one from the SafeSight Mac release page.',
    other_chain: "That copy is tied to another time signal than the one SafeSight Mac uses, so this page can't open it. It may come from a test version.",
    damaged: 'That copy is damaged: part of it has changed since SafeSight Mac saved it. Try another copy of it, for example from a backup.',
  };

  function roundWords(r) {
    switch (r.error) {
      case 'not_yet':
        return `Not yet. That time signal is from ${when(r.round_time)}, and this copy opens no earlier than ${when(r.target_time)}. Until then nothing can open it.`;
      case 'wrong_round':
        return `That time signal is for round ${num(r.round)}, from ${when(r.round_time)}. This copy needs round ${num(r.target_round)} exactly: use the address above.`;
      case 'bad_signature':
        return r.named
          ? "That time signal doesn't check out: it isn't signed by the public time service. It may be damaged or not genuine. Get it again from the address above."
          : `That isn't the time signal for round ${num(r.target_round)}. Open the address above, copy everything it shows, and paste it again.`;
      case 'inconsistent':
        return "That time signal has been changed: its parts don't match. Get it again from the address above.";
      case 'other_round_chain':
        return 'That time signal is from another time service. Use the address above.';
      case 'not_a_round':
        return "That isn't the time signal. Open the address above and copy everything it shows. If it says “Requested future beacon” or shows nothing, that moment hasn't come yet.";
      default:
        return COPY_WORDS[r.error] || COPY_WORDS.damaged;
    }
  }

  function keyWords(code) {
    const opening = about.key_opening;
    switch (code) {
      case 'empty':
        return 'Paste your Recovery Key first.';
      case 'public_half':
        return `That's the public half of a key (it starts with age1). Your Recovery Key starts with ${opening}. Look for the entry named “SafeSight Mac Recovery Key”.`;
      case 'not_a_key':
        return `That isn't a Recovery Key. It's one line of 74 characters that starts with ${opening}, saved in your password manager as “SafeSight Mac Recovery Key” and your Mac's name.`;
      case 'typo':
        return 'That Recovery Key has a typing mistake: a character is wrong, missing or extra. Copy it again from your password manager.';
      case 'not_for_this_key':
        return "This Recovery Key doesn't open this copy. Check it's the key for this Mac. If you ever replaced your Recovery Key, try the other one: a copy saved before the change opens with the old key.";
      case 'not_ready':
        return 'Something went out of step. Choose your recovery copy again.';
      default:
        return "This copy is damaged inside: it doesn't open even with the right key. Try another copy of it, for example from a backup.";
    }
  }

  const SYMBOLS = {
    '!': 'exclamation mark', '"': 'double quote', '#': 'hash', '$': 'dollar sign', '%': 'percent sign',
    '&': 'ampersand', "'": 'apostrophe', '(': 'opening bracket', ')': 'closing bracket', '*': 'asterisk',
    '+': 'plus sign', ',': 'comma', '-': 'hyphen', '.': 'full stop', '/': 'slash', ':': 'colon',
    ';': 'semicolon', '<': 'less-than sign', '=': 'equals sign', '>': 'greater-than sign',
    '?': 'question mark', '@': 'at sign', '[': 'opening square bracket', '\\': 'backslash',
    ']': 'closing square bracket', '^': 'caret', '_': 'underscore', '`': 'backtick',
    '{': 'opening curly bracket', '|': 'vertical bar', '}': 'closing curly bracket', '~': 'tilde',
  };

  function spoken(c) {
    if (c >= 'A' && c <= 'Z') return `capital ${c}`;
    if (c >= 'a' && c <= 'z') return `small ${c}`;
    if (c >= '0' && c <= '9') return `digit ${c}`;
    return SYMBOLS[c] || 'symbol';
  }

  // ----- Step 1: the recovery copy -----

  async function takeCopy(file) {
    say($('copy-error'), '');
    let bytes = null;
    try {
      bytes = await readFile(file, 1 << 20);
    } catch (e) {
      say($('copy-error'), "This device couldn't read that file. Try choosing it again.");
      return;
    }
    if (!bytes) {
      if (file) say($('copy-error'), COPY_WORDS.not_a_copy);
      return;
    }
    const r = core.inspect(bytes);
    bytes.fill(0);
    if (r.error) {
      say($('copy-error'), COPY_WORDS[r.error] || COPY_WORDS.damaged);
      return;
    }
    copy = r;
    showTime();
  }

  // ----- Step 2: the time signal -----

  function showTime() {
    $('time-when').textContent = when(copy.target_time);
    $('time-detail').textContent = `Time signal round ${num(copy.target_round)} · version ${copy.generation} of your Mac's admin password`;
    $('paste-url').textContent = copy.urls[0];
    $('paste-url-2').textContent = copy.urls[1] || '';
    $('fetch-note').textContent = `This asks a public time service for one number: the signal for round ${num(copy.target_round)}. Nothing about you or your Mac is sent.`;
    const wait = copy.target_time - nowSeconds();
    const early = wait > 0;
    $('time-title').textContent = early ? 'Not yet' : 'Its time has come';
    $('time-lead').textContent = early
      ? `That's ${roughly(wait)} from now, by this device's clock. Until then nothing can open this copy: not you, not anyone, not the people who made SafeSight Mac. Please come back after that date.`
      : 'That moment has passed. Next, this page needs one public number from it, called the time signal. It is the same for everyone and says nothing about you.';
    $('not-yet-box').hidden = !early;
    $('time-get').hidden = early;
    $('paste-box').open = false;
    $('round-text').value = '';
    say($('time-error'), '');
    say($('fetch-status'), '');
    show('screen-time');
  }

  // Gives the core one candidate; on success moves to the key. Returns the core's answer.
  function tryRound(input) {
    const r = core.openTime(input);
    if (!r.error) {
      say($('time-error'), '');
      showKey();
    }
    return r;
  }

  async function fetchRound() {
    const button = $('fetch-round');
    button.disabled = true;
    say($('time-error'), '');
    say($('fetch-status'), 'Asking the time service…');
    let refused = null;
    let notThere = false;
    try {
      for (const url of copy.urls) {
        let response;
        const stopper = new AbortController();
        const timer = setTimeout(() => stopper.abort(), FETCH_TIMEOUT_MS);
        try {
          response = await fetch(url, {
            cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer', redirect: 'error', signal: stopper.signal,
          });
        } catch (e) {
          continue;
        } finally {
          clearTimeout(timer);
        }
        if (response.status === 200) {
          const text = await response.text();
          if (text.length > 16384) continue;
          const r = tryRound(text);
          if (!r.error) return;
          refused = r;
          continue;
        }
        if (response.status === 404 || response.status === 425) notThere = true;
      }
      say($('fetch-status'), '');
      if (refused) {
        say($('time-error'), roundWords(refused));
      } else if (notThere && copy.target_time > nowSeconds()) {
        say($('time-error'), `The time service says that moment hasn't come yet. This copy opens no earlier than ${when(copy.target_time)}.`);
      } else if (notThere) {
        say($('time-error'), "The time service doesn't have that signal yet. Wait a minute and try again, or paste it from another device.");
      } else {
        say($('time-error'), "Couldn't reach the time service. Check this device's internet connection and try again, or paste the time signal from another device.");
      }
    } finally {
      button.disabled = false;
    }
  }

  function checkPasted() {
    const text = $('round-text').value;
    if (!text.trim()) {
      say($('time-error'), 'Paste the time signal first, or choose the downloaded file.');
      return;
    }
    const r = tryRound(text);
    if (r.error) say($('time-error'), roundWords(r));
  }

  async function takeRoundFile(file) {
    let bytes = null;
    try {
      bytes = await readFile(file, 16384);
    } catch (e) {
      bytes = null;
    }
    if (!bytes) {
      say($('time-error'), "That file isn't the time signal. Open the address above and save or copy what it shows.");
      return;
    }
    const r = tryRound(bytes);
    if (r.error) say($('time-error'), roundWords(r));
  }

  // ----- Step 3: the Recovery Key -----

  function showKey() {
    const input = $('key-input');
    input.value = '';
    input.type = 'password';
    $('key-show').setAttribute('aria-pressed', 'false');
    $('key-show').textContent = 'Show';
    $('key-hint').textContent = `One line that starts with ${about.key_opening}.`;
    say($('key-error'), '');
    show('screen-key');
  }

  function openKey() {
    const input = $('key-input');
    const text = input.value;
    input.value = '';
    const r = core.openKey(text);
    if (typeof r.secret === 'string') {
      showDone(r.secret);
      return;
    }
    say($('key-error'), keyWords(r.error));
    input.focus();
  }

  // ----- The admin secret and the next steps -----

  function showDone(secret) {
    const box = $('secret');
    box.textContent = '';
    for (let i = 0; i < secret.length; i += 4) {
      const group = document.createElement('span');
      group.textContent = secret.slice(i, i + 4);
      box.appendChild(group);
    }
    box.setAttribute('aria-label', `The password, ${secret.length} characters`);
    $('secret-facts').textContent = `${secret.length} characters and no spaces. Capital and small letters are different.`;

    const list = $('spelled');
    list.textContent = '';
    Array.from(secret).forEach((c, i) => {
      const item = document.createElement('li');
      const pos = document.createElement('span');
      pos.className = 'pos';
      pos.textContent = String(i + 1);
      const ch = document.createElement('span');
      ch.className = 'ch';
      ch.textContent = c;
      const words = document.createElement('span');
      words.className = 'say';
      words.textContent = spoken(c);
      item.append(pos, ch, words);
      list.appendChild(item);
    });
    list.hidden = true;
    $('spell').setAttribute('aria-expanded', 'false');
    $('spell').textContent = 'Spell it out';
    $('next-account').textContent = about.account;
    $('next-days').textContent = `${about.claim_days} days`;
    show('screen-done');
  }

  function clearAll() {
    if (core) core.clear();
    $('secret').textContent = '';
    $('spelled').textContent = '';
    $('key-input').value = '';
    $('round-text').value = '';
    $('copy-file').value = '';
    $('round-file').value = '';
    copy = null;
  }

  // ----- Wiring -----

  function wire() {
    $('copy-file').addEventListener('change', (e) => takeCopy(e.target.files && e.target.files[0]));
    const drop = $('copy-drop');
    drop.addEventListener('dragover', (e) => {
      e.preventDefault();
      drop.classList.add('dragging');
    });
    drop.addEventListener('dragleave', () => drop.classList.remove('dragging'));
    drop.addEventListener('drop', (e) => {
      e.preventDefault();
      drop.classList.remove('dragging');
      takeCopy(e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0]);
    });
    // A file dropped anywhere else must not replace the page.
    window.addEventListener('dragover', (e) => e.preventDefault());
    window.addEventListener('drop', (e) => e.preventDefault());

    $('check-anyway').addEventListener('click', () => {
      $('not-yet-box').hidden = true;
      $('time-get').hidden = false;
      $('fetch-round').focus();
    });
    $('fetch-round').addEventListener('click', fetchRound);
    $('check-round').addEventListener('click', checkPasted);
    $('round-file').addEventListener('change', (e) => takeRoundFile(e.target.files && e.target.files[0]));
    $('time-back').addEventListener('click', () => {
      clearAll();
      show('screen-copy');
    });

    $('key-show').addEventListener('click', () => {
      const input = $('key-input');
      const showing = input.type === 'text';
      input.type = showing ? 'password' : 'text';
      $('key-show').setAttribute('aria-pressed', String(!showing));
      $('key-show').textContent = showing ? 'Show' : 'Hide';
      input.focus();
    });
    $('open-key').addEventListener('click', openKey);
    $('key-input').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        openKey();
      }
    });

    $('spell').addEventListener('click', () => {
      const list = $('spelled');
      list.hidden = !list.hidden;
      $('spell').setAttribute('aria-expanded', String(!list.hidden));
      $('spell').textContent = list.hidden ? 'Spell it out' : 'Hide the spelling';
    });
    $('clear').addEventListener('click', () => {
      clearAll();
      show('screen-cleared');
    });
    $('again').addEventListener('click', () => show('screen-copy'));
    window.addEventListener('pagehide', clearAll);
  }

  async function start() {
    try {
      core = await globalThis.OpenerCore.load($('core-wasm').textContent);
      about = core.about();
    } catch (e) {
      show('screen-old', false);
      return;
    }
    $('foot-version').textContent = `SafeSight Mac opener ${about.version}`;
    wire();
    show('screen-copy', false);
  }

  start();
})();
