// SPDX-License-Identifier: Apache-2.0
// The page's bridge to its WebAssembly core (opener/wasm, the keeper's opener core). No
// generated glue: it writes each input into the buffer the core hands out, calls one step,
// and reads one answer back. Every check is the core's; nothing here decides anything.
'use strict';
(function (root) {
  const SLOT = Object.freeze({ copy: 0, round: 1, key: 2 });
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  function fromBase64(text) {
    const raw = atob(String(text).replace(/[^A-Za-z0-9+/=]/g, ''));
    const bytes = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i += 1) bytes[i] = raw.charCodeAt(i);
    return bytes;
  }

  async function load(wasmBase64) {
    const { instance } = await WebAssembly.instantiate(fromBase64(wasmBase64), {});
    const x = instance.exports;

    // Writes `data` into the core's buffer for `slot`. False if the core refuses its size.
    function put(slot, data) {
      const ptr = x.ss_input(slot, data.length) >>> 0;
      if (ptr === 0) return false;
      new Uint8Array(x.memory.buffer, ptr, data.length).set(data);
      return true;
    }

    // A copy of the core's answer, as bytes.
    function raw() {
      const ptr = x.ss_output_ptr() >>> 0;
      const len = x.ss_output_len() >>> 0;
      return new Uint8Array(x.memory.buffer, ptr, len).slice();
    }

    function answer() {
      return JSON.parse(decoder.decode(raw()));
    }

    return Object.freeze({
      // The core's version, its mirrors and the words the next steps need.
      about() {
        x.ss_about();
        return answer();
      },
      // Step 1: the recovery copy's bytes.
      inspect(data) {
        if (!put(SLOT.copy, data)) return { error: 'not_a_copy' };
        x.ss_inspect();
        return answer();
      },
      // Steps 2 to 5: the time signal, as text or bytes.
      openTime(text) {
        const data = typeof text === 'string' ? encoder.encode(text) : text;
        if (!put(SLOT.round, data)) return { error: 'not_a_round' };
        x.ss_open_time();
        return answer();
      },
      // Steps 6 and 7: the Recovery Key. Returns { secret } or { error }.
      openKey(text) {
        const data = encoder.encode(String(text));
        const ok = put(SLOT.key, data);
        data.fill(0);
        if (!ok) return { error: 'not_a_key' };
        if (x.ss_open_key() === 0) {
          const out = raw();
          x.ss_clear_output();
          const secret = decoder.decode(out);
          out.fill(0);
          return { secret };
        }
        return answer();
      },
      // Wipes every buffer in the core.
      clear() {
        x.ss_clear();
      },
    });
  }

  root.OpenerCore = Object.freeze({ load, fromBase64 });
})(globalThis);
