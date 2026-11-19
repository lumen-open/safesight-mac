// SPDX-License-Identifier: Apache-2.0
// The keyholder page's core: reading and writing the three codes (enrolment record, request code,
// approval code), the passkey options, the checks made before a code is shown, and a small QR
// encoder. Plain functions with no access to the page, so the tests load this file as it is.
// build.mjs inlines it into index.html byte for byte. Register: section 8a, SD-155, SD-194 to
// SD-196; chapter 03 section 8; chapter 09 section 14.
'use strict';

const KeyholderCore = (() => {
  // ---------------------------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------------------------

  const FORMAT_VERSION = 1;

  // OPEN: the envelope sizes. Register 8a says every record starts with magic, record type,
  // format version and length, and ends with a checksum, but gives no sizes. Here: magic "SM"
  // (2 bytes), type (1), version (1), body length (2, big-endian), body, CRC-32 (4, big-endian)
  // over everything before it. The envelope stays the same in every format version.
  const MAGIC = [0x53, 0x4d];
  const TYPE = Object.freeze({ ENROLMENT: 1, REQUEST: 2, APPROVAL: 3 });
  const TYPE_NAMES = Object.freeze({ 1: 'enrolment', 2: 'request', 3: 'approval' });

  // OPEN: kind codes. The register lists exit, lower wait, loosen setting and admin window; it
  // names no kind for the test approval at enrolment (SD-195), so the test gets kind 0.
  const KIND = Object.freeze({ TEST: 0, EXIT: 1, LOWER_WAIT: 2, LOOSEN_SETTING: 3, ADMIN_WINDOW: 4 });
  const KIND_NAMES = Object.freeze(['test', 'exit', 'lower-wait', 'loosen-setting', 'admin-window']);

  // The detail field (SD-306). Lower wait: the new wait in days, one of these (a year is the
  // longest wait, so it can never be a lowering). Loosen setting: which setting. Every other
  // kind: zero.
  const WAIT_DAYS = Object.freeze([7, 30, 90, 182]);
  const SETTING = Object.freeze({ BROWSER_PROFILE: 1, STRICT_COVER_OFF: 2, DETECTOR_BALANCED: 3 });

  // The challenge's domain tags (SD-306). A test approval is signed under its own tag, so it can
  // never stand for a real one.
  const APPROVAL_TAG = 'SafeSightMac keyholder approval';
  const TEST_TAG = 'SafeSightMac keyholder test approval';

  // OPEN: field sizes. The page's codes are carried forms with hard caps; the app pads them into
  // the keeper's fixed layouts (register 8a: "converted by the app to the fixed layout").
  const LIMITS = Object.freeze({
    text: 4096, // characters accepted in a pasted or linked code, separators included
    body: 2048, // bytes in a record body
    requestId: 16, // OPEN: the register gives no size for a request ID
    nonce: 32, // the keeper's random bytes for one request
    challenge: 32, // SHA-256 of the signed fields (SD-306)
    labelBytes: 32, // OPEN: "a short label"; UTF-8 bytes
    items: 16, // OPEN: the most items one admin window can name
    itemHash: 32, // SHA-256
    credentialId: 128, // OPEN: the keeper pins a fixed-size, zero-padded field
    publicKey: 65, // P-256, uncompressed (chapter 03 section 8)
    authenticatorData: 37, // chapter 03 section 8: the fixed first 37 bytes
    clientData: 1024, // OPEN: the keeper's fixed-size padded field
    signatureMin: 8,
    signatureMax: 72, // DER form of an ES256 signature
  });

  // OPEN (SQ-11): the pinned page origin is not chosen yet. While it is empty the page works on
  // whatever origin serves it. Once set, the page refuses to make or use keys anywhere else.
  const PINNED_ORIGIN = '';

  const FLAG_UP = 0x01; // user present
  const FLAG_UV = 0x04; // user verified
  const FLAG_AT = 0x40; // attested credential data included
  const FLAG_ED = 0x80; // extension data included

  // ---------------------------------------------------------------------------------------------
  // Errors
  // ---------------------------------------------------------------------------------------------

  // reason is one of: empty, too-long, characters, damaged, wrong-type, version, malformed,
  // passkey. detail is for people debugging, never shown as the main message.
  class CodeError extends Error {
    constructor(reason, detail) {
      super(detail ? `${reason}: ${detail}` : reason);
      this.name = 'CodeError';
      this.reason = reason;
      this.detail = detail || '';
    }
  }
  function fail(reason, detail) {
    throw new CodeError(reason, detail);
  }

  // ---------------------------------------------------------------------------------------------
  // Bytes
  // ---------------------------------------------------------------------------------------------

  function bytesOf(value, what) {
    if (value instanceof Uint8Array) return value;
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    return fail('malformed', `${what} is not bytes`);
  }
  function concat(parts) {
    let total = 0;
    for (const p of parts) total += p.length;
    const out = new Uint8Array(total);
    let at = 0;
    for (const p of parts) {
      out.set(p, at);
      at += p.length;
    }
    return out;
  }
  function equalBytes(a, b) {
    if (a.length !== b.length) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
    return diff === 0;
  }
  function toHex(bytes) {
    let s = '';
    for (const b of bytes) s += b.toString(16).padStart(2, '0');
    return s;
  }
  function utf8Encode(text) {
    return new TextEncoder().encode(text);
  }
  function utf8Decode(bytes) {
    try {
      return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
    } catch (e) {
      return fail('malformed', 'text is not UTF-8');
    }
  }
  async function sha256(bytes) {
    return new Uint8Array(await globalThis.crypto.subtle.digest('SHA-256', bytes));
  }

  // CRC-32 as in zlib and PNG (reflected, polynomial 0xEDB88320).
  const CRC_TABLE = (() => {
    const table = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      table[n] = c >>> 0;
    }
    return table;
  })();
  function crc32(bytes) {
    let c = 0xffffffff;
    for (const b of bytes) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  }

  // ---------------------------------------------------------------------------------------------
  // Text form
  // ---------------------------------------------------------------------------------------------

  // OPEN: the alphabet. Chapter 09 says "a base-32 alphabet with a checksum". Here: RFC 4648
  // base32, upper case, no padding. Every character is in the QR code's alphanumeric set. When
  // reading, case is ignored and spaces, line breaks and hyphens are skipped; anything else is
  // refused, as are unused trailing bits that are not zero, so each code has one spelling.
  const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  function base32Encode(bytes) {
    let out = '';
    let acc = 0;
    let bits = 0;
    for (const b of bytes) {
      acc = ((acc << 8) | b) & 0xfff;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out += B32[(acc >>> bits) & 31];
      }
    }
    if (bits > 0) out += B32[(acc << (5 - bits)) & 31];
    return out;
  }

  function base32Decode(text) {
    if (typeof text !== 'string') fail('empty');
    if (text.length > LIMITS.text) fail('too-long');
    if (/[^A-Za-z2-7\s-]/.test(text)) fail('characters');
    const clean = text.replace(/[\s-]+/g, '').toUpperCase();
    if (!clean) fail('empty');
    const out = new Uint8Array(Math.floor((clean.length * 5) / 8));
    let acc = 0;
    let bits = 0;
    let n = 0;
    for (let i = 0; i < clean.length; i++) {
      acc = ((acc << 5) | B32.indexOf(clean[i])) & 0xfff;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out[n++] = (acc >>> bits) & 0xff;
      }
    }
    if (bits >= 5 || (acc & ((1 << bits) - 1)) !== 0) fail('characters', 'the code ends wrongly');
    return out;
  }

  function base64url(bytes) {
    const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    let out = '';
    let i = 0;
    for (; i + 2 < bytes.length; i += 3) {
      const v = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out += abc[v >>> 18] + abc[(v >>> 12) & 63] + abc[(v >>> 6) & 63] + abc[v & 63];
    }
    if (i < bytes.length) {
      const v = (bytes[i] << 16) | ((i + 1 < bytes.length ? bytes[i + 1] : 0) << 8);
      out += abc[v >>> 18] + abc[(v >>> 12) & 63];
      if (i + 1 < bytes.length) out += abc[(v >>> 6) & 63];
    }
    return out;
  }

  // A request code may arrive as the whole page address (from the owner's QR code) or as the
  // code alone. Only the part after "#" is ever read (SD-195: the host never receives it).
  function extractCode(input) {
    const text = String(input == null ? '' : input).trim();
    const hash = text.lastIndexOf('#');
    return hash >= 0 ? text.slice(hash + 1) : text;
  }

  // ---------------------------------------------------------------------------------------------
  // The envelope
  // ---------------------------------------------------------------------------------------------

  function encodeRecord(type, body) {
    if (body.length > LIMITS.body) fail('malformed', 'body too long');
    const out = new Uint8Array(6 + body.length + 4);
    out[0] = MAGIC[0];
    out[1] = MAGIC[1];
    out[2] = type;
    out[3] = FORMAT_VERSION;
    out[4] = body.length >>> 8;
    out[5] = body.length & 0xff;
    out.set(body, 6);
    const c = crc32(out.subarray(0, 6 + body.length));
    out[6 + body.length] = c >>> 24;
    out[7 + body.length] = (c >>> 16) & 0xff;
    out[8 + body.length] = (c >>> 8) & 0xff;
    out[9 + body.length] = c & 0xff;
    return out;
  }

  // Checks run in this order: magic, length, checksum, type, version. A damaged code is reported
  // as damaged before anything inside it is believed.
  function decodeRecord(bytes, type) {
    if (bytes.length < 10 || bytes[0] !== MAGIC[0] || bytes[1] !== MAGIC[1]) fail('damaged', 'not a keyholder code');
    const len = (bytes[4] << 8) | bytes[5];
    if (len > LIMITS.body) fail('damaged', 'length field too large');
    if (bytes.length !== 10 + len) fail('damaged', 'length does not match');
    const stored = ((bytes[6 + len] << 24) | (bytes[7 + len] << 16) | (bytes[8 + len] << 8) | bytes[9 + len]) >>> 0;
    if (stored !== crc32(bytes.subarray(0, 6 + len))) fail('damaged', 'checksum does not match');
    if (bytes[2] !== type) fail('wrong-type', TYPE_NAMES[bytes[2]] || 'unknown');
    if (bytes[3] !== FORMAT_VERSION) fail('version', `format version ${bytes[3]}`);
    return bytes.slice(6, 6 + len);
  }

  function reader(body) {
    let pos = 0;
    const r = {
      take(n, what) {
        if (pos + n > body.length) fail('malformed', `${what} cut short`);
        const v = body.slice(pos, pos + n);
        pos += n;
        return v;
      },
      u8(what) {
        return r.take(1, what)[0];
      },
      u16(what) {
        const b = r.take(2, what);
        return (b[0] << 8) | b[1];
      },
      end() {
        if (pos !== body.length) fail('malformed', 'extra bytes at the end');
      },
    };
    return r;
  }

  function fixed(value, size, what) {
    const b = bytesOf(value, what);
    if (b.length !== size) fail('malformed', `${what} must be ${size} bytes`);
    return b;
  }

  // ---------------------------------------------------------------------------------------------
  // The Mac label
  // ---------------------------------------------------------------------------------------------

  // OPEN: the label rule. 1 to 32 bytes of UTF-8, no leading or trailing space, and none of:
  // control characters, line or paragraph separators, zero-width characters, the byte order mark,
  // or the characters that change text direction. The app should apply the same rule when the
  // owner types the label, so a label can never make the page show something misleading.
  const LABEL_REFUSED = /[\p{Cc}\p{Zl}\p{Zp}­؜᠎​-‏‪-‮⁠-⁯﻿]/u;

  function checkLabel(label) {
    if (typeof label !== 'string') fail('malformed', 'label is not text');
    const n = utf8Encode(label).length;
    if (n < 1 || n > LIMITS.labelBytes) fail('malformed', 'label length');
    if (label.trim() !== label || label.trim() === '') fail('malformed', 'label spacing');
    if (LABEL_REFUSED.test(label)) fail('malformed', 'label has a refused character');
    return label;
  }

  // ---------------------------------------------------------------------------------------------
  // P-256 and signatures
  // ---------------------------------------------------------------------------------------------

  const P256_P = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffffn;
  const P256_B = 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604bn;
  const P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;

  function bigFrom(bytes) {
    let v = 0n;
    for (const b of bytes) v = (v << 8n) | BigInt(b);
    return v;
  }

  // An uncompressed P-256 point: 0x04, then X and Y, each 32 bytes, on the curve.
  function checkPublicKey(key) {
    const k = fixed(key, LIMITS.publicKey, 'public key');
    if (k[0] !== 0x04) fail('malformed', 'public key is not uncompressed');
    const x = bigFrom(k.subarray(1, 33));
    const y = bigFrom(k.subarray(33, 65));
    if (x >= P256_P || y >= P256_P) fail('malformed', 'public key out of range');
    const p = P256_P;
    const lhs = (y * y) % p;
    const rhs = (((x * x) % p) * x - 3n * x + P256_B) % p;
    if (lhs !== (rhs + p) % p) fail('malformed', 'public key is not on the curve');
    return k;
  }

  // Strict DER: SEQUENCE { INTEGER r, INTEGER s }, minimal lengths, both in 1..n-1.
  // Returns the fixed 64-byte form (r then s). The page carries the DER bytes as the passkey made
  // them; the app converts (chapter 03 section 8). This function checks the form either way.
  function derToRawSignature(der) {
    const d = bytesOf(der, 'signature');
    if (d.length < LIMITS.signatureMin || d.length > LIMITS.signatureMax) fail('malformed', 'signature length');
    if (d[0] !== 0x30 || d[1] !== d.length - 2) fail('malformed', 'signature is not a DER sequence');
    let pos = 2;
    const out = new Uint8Array(64);
    for (let part = 0; part < 2; part++) {
      if (pos + 2 > d.length || d[pos] !== 0x02) fail('malformed', 'signature integer missing');
      const len = d[pos + 1];
      pos += 2;
      if (len < 1 || len > 33 || pos + len > d.length) fail('malformed', 'signature integer length');
      let v = d.subarray(pos, pos + len);
      pos += len;
      if (v[0] & 0x80) fail('malformed', 'signature integer is negative');
      if (v.length > 1 && v[0] === 0 && !(v[1] & 0x80)) fail('malformed', 'signature integer not minimal');
      if (v[0] === 0 && v.length > 1) v = v.subarray(1);
      if (v.length > 32) fail('malformed', 'signature integer too large');
      const n = bigFrom(v);
      if (n === 0n || n >= P256_N) fail('malformed', 'signature integer out of range');
      out.set(v, part * 32 + (32 - v.length));
    }
    if (pos !== d.length) fail('malformed', 'signature has extra bytes');
    return out;
  }

  // The SPKI form returned by getPublicKey() for a P-256 key: a fixed 26-byte head, then the point.
  const SPKI_P256_HEAD = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
    0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
  ];
  function spkiToRawP256(spki) {
    const s = bytesOf(spki, 'public key');
    if (s.length !== SPKI_P256_HEAD.length + 65) fail('passkey', 'public key is not P-256');
    for (let i = 0; i < SPKI_P256_HEAD.length; i++) if (s[i] !== SPKI_P256_HEAD[i]) fail('passkey', 'public key is not P-256');
    return passkeyKey(s.slice(SPKI_P256_HEAD.length));
  }

  // ---------------------------------------------------------------------------------------------
  // A small CBOR reader, enough for a passkey's attestation object and its COSE key
  // ---------------------------------------------------------------------------------------------

  function cborRead(bytes, start, depth) {
    if (depth > 8) fail('passkey', 'CBOR nested too deeply');
    let pos = start;
    const need = n => {
      if (pos + n > bytes.length) fail('passkey', 'CBOR cut short');
    };
    need(1);
    const head = bytes[pos++];
    const major = head >>> 5;
    const info = head & 31;
    let arg;
    if (info < 24) arg = info;
    else if (info === 24) {
      need(1);
      arg = bytes[pos++];
    } else if (info === 25) {
      need(2);
      arg = (bytes[pos] << 8) | bytes[pos + 1];
      pos += 2;
    } else if (info === 26) {
      need(4);
      arg = ((bytes[pos] << 24) | (bytes[pos + 1] << 16) | (bytes[pos + 2] << 8) | bytes[pos + 3]) >>> 0;
      pos += 4;
    } else fail('passkey', 'CBOR length form not supported');
    switch (major) {
      case 0:
        return { value: arg, end: pos };
      case 1:
        return { value: -1 - arg, end: pos };
      case 2:
        need(arg);
        return { value: bytes.slice(pos, pos + arg), end: pos + arg };
      case 3:
        need(arg);
        return { value: utf8Decode(bytes.subarray(pos, pos + arg)), end: pos + arg };
      case 4: {
        if (arg > 64) fail('passkey', 'CBOR array too long');
        const list = [];
        for (let i = 0; i < arg; i++) {
          const item = cborRead(bytes, pos, depth + 1);
          list.push(item.value);
          pos = item.end;
        }
        return { value: list, end: pos };
      }
      case 5: {
        if (arg > 64) fail('passkey', 'CBOR map too long');
        const map = new Map();
        for (let i = 0; i < arg; i++) {
          const k = cborRead(bytes, pos, depth + 1);
          const v = cborRead(bytes, k.end, depth + 1);
          if (typeof k.value !== 'number' && typeof k.value !== 'string') fail('passkey', 'CBOR map key type');
          if (map.has(k.value)) fail('passkey', 'CBOR map key repeated');
          map.set(k.value, v.value);
          pos = v.end;
        }
        return { value: map, end: pos };
      }
      case 7:
        if (info === 20) return { value: false, end: pos };
        if (info === 21) return { value: true, end: pos };
        if (info === 22) return { value: null, end: pos };
        return fail('passkey', 'CBOR simple value not supported');
      default:
        return fail('passkey', 'CBOR type not supported');
    }
  }

  // The authenticator data a passkey returns: rpIdHash (32), flags (1), counter (4), and, when the
  // AT flag is set, AAGUID (16), credential ID length (2), credential ID and the COSE public key.
  function parseAuthenticatorData(data) {
    const a = bytesOf(data, 'authenticator data');
    if (a.length < 37) fail('passkey', 'authenticator data too short');
    const out = {
      rpIdHash: a.slice(0, 32),
      flags: a[32],
      signCount: ((a[33] << 24) | (a[34] << 16) | (a[35] << 8) | a[36]) >>> 0,
      length: a.length,
    };
    if (out.flags & FLAG_AT) {
      if (a.length < 55) fail('passkey', 'attested data too short');
      const idLen = (a[53] << 8) | a[54];
      if (55 + idLen > a.length) fail('passkey', 'credential ID cut short');
      out.credentialId = a.slice(55, 55 + idLen);
      const key = cborRead(a, 55 + idLen, 0);
      out.credentialPublicKey = key.value;
      out.attestedEnd = key.end;
    }
    return out;
  }

  // COSE_Key for ES256: kty 2 (EC2), alg -7 (ES256), crv 1 (P-256), x (-2) and y (-3).
  function coseToRawP256(cose) {
    if (!(cose instanceof Map)) fail('passkey', 'public key is not a COSE key');
    if (cose.get(1) !== 2 || cose.get(3) !== -7 || cose.get(-1) !== 1) fail('passkey', 'the key is not ES256');
    const x = cose.get(-2);
    const y = cose.get(-3);
    if (!(x instanceof Uint8Array) || !(y instanceof Uint8Array) || x.length !== 32 || y.length !== 32) fail('passkey', 'public key coordinates');
    return passkeyKey(concat([new Uint8Array([0x04]), x, y]));
  }

  // A key that came from the passkey: a fault in it is the phone's, reported as such.
  function passkeyKey(raw) {
    try {
      return checkPublicKey(raw);
    } catch (e) {
      return fail('passkey', e.detail || e.message);
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Enrolment record (register 8a: format version; credential ID; public key)
  // Body: credential ID length (1) | credential ID (1..128) | public key (65)
  // ---------------------------------------------------------------------------------------------

  function encodeEnrolmentCode(fields) {
    const id = bytesOf(fields.credentialId, 'credential ID');
    if (id.length < 1 || id.length > LIMITS.credentialId) fail('malformed', 'credential ID length');
    const key = checkPublicKey(fields.publicKey);
    return base32Encode(encodeRecord(TYPE.ENROLMENT, concat([new Uint8Array([id.length]), id, key])));
  }

  function decodeEnrolmentCode(text) {
    const r = reader(decodeRecord(base32Decode(text), TYPE.ENROLMENT));
    const idLen = r.u8('credential ID length');
    if (idLen < 1 || idLen > LIMITS.credentialId) fail('malformed', 'credential ID length');
    const credentialId = r.take(idLen, 'credential ID');
    const publicKey = checkPublicKey(r.take(LIMITS.publicKey, 'public key'));
    r.end();
    return { version: FORMAT_VERSION, credentialId, publicKey };
  }

  // ---------------------------------------------------------------------------------------------
  // Request code (register 8a: format version; request ID; Mac label; kind; for an admin window,
  // the item hashes; SD-306: the detail and the keeper's nonce). Made by the keeper.
  // Body: kind (1) | request ID (16) | nonce (32) | detail (2, big-endian) | label length (1)
  //       | label (1..32) | item count (1) | item hashes (32 each; 1..16 for an admin window,
  //       none otherwise)
  // The code carries no challenge. The page derives it from these fields (deriveChallenge), so
  // the passkey signs exactly what the keyholder is shown.
  // ---------------------------------------------------------------------------------------------

  function checkKind(kind) {
    if (!Number.isInteger(kind) || kind < 0 || kind >= KIND_NAMES.length) fail('malformed', 'unknown kind');
    return kind;
  }

  function checkDetail(kind, detail) {
    if (!Number.isInteger(detail) || detail < 0 || detail > 0xffff) fail('malformed', 'detail out of range');
    if (kind === KIND.LOWER_WAIT) {
      if (!WAIT_DAYS.includes(detail)) fail('malformed', 'not a wait that can be lowered to');
    } else if (kind === KIND.LOOSEN_SETTING) {
      if (!Object.values(SETTING).includes(detail)) fail('malformed', 'unknown setting');
    } else if (detail !== 0) fail('malformed', 'this kind carries no detail');
    return detail;
  }

  function checkItems(kind, items) {
    if (kind === KIND.ADMIN_WINDOW) {
      if (items.length < 1 || items.length > LIMITS.items) fail('malformed', 'item count');
    } else if (items.length !== 0) fail('malformed', 'only an admin window carries items');
  }

  // Every field of a request, checked by the one set of rules the decoder uses. Returns the
  // fields as bytes, ready to be encoded or hashed.
  function requestFields(fields) {
    const kind = checkKind(fields.kind);
    const requestId = fixed(fields.requestId, LIMITS.requestId, 'request ID');
    const nonce = fixed(fields.nonce, LIMITS.nonce, 'nonce');
    const detail = checkDetail(kind, fields.detail);
    const label = utf8Encode(checkLabel(fields.label));
    const items = Array.from(fields.items || [], h => fixed(h, LIMITS.itemHash, 'item hash'));
    checkItems(kind, items);
    return { kind, requestId, nonce, detail, label, items };
  }

  function encodeRequestCode(fields) {
    const f = requestFields(fields);
    const body = concat([
      new Uint8Array([f.kind]),
      f.requestId,
      f.nonce,
      new Uint8Array([f.detail >>> 8, f.detail & 0xff]),
      new Uint8Array([f.label.length]),
      f.label,
      new Uint8Array([f.items.length]),
      ...f.items,
    ]);
    return base32Encode(encodeRecord(TYPE.REQUEST, body));
  }

  function decodeRequestCode(text) {
    const r = reader(decodeRecord(base32Decode(text), TYPE.REQUEST));
    const kind = checkKind(r.u8('kind'));
    const requestId = r.take(LIMITS.requestId, 'request ID');
    const nonce = r.take(LIMITS.nonce, 'nonce');
    const detail = checkDetail(kind, r.u16('detail'));
    const labelLen = r.u8('label length');
    if (labelLen < 1 || labelLen > LIMITS.labelBytes) fail('malformed', 'label length');
    const label = checkLabel(utf8Decode(r.take(labelLen, 'label')));
    const count = r.u8('item count');
    if (count > LIMITS.items) fail('malformed', 'item count');
    const items = [];
    for (let i = 0; i < count; i++) items.push(r.take(LIMITS.itemHash, 'item hash'));
    checkItems(kind, items);
    r.end();
    return Object.freeze({
      version: FORMAT_VERSION, kind, kindName: KIND_NAMES[kind], requestId, nonce, detail, label, items: Object.freeze(items),
    });
  }

  // The challenge the passkey signs (SD-306): SHA-256 of
  //   tag length (1) | tag (ASCII) | format version (1) | kind (1) | request ID (16)
  //   | detail (2, big-endian) | label length (1) | label (UTF-8) | item count (1)
  //   | item hashes (32 each) | nonce (32)
  // with TEST_TAG for kind 0 and APPROVAL_TAG for every other kind. Every field the keyholder is
  // shown is in it, so an approval stands only for what was on their screen. The keeper builds
  // the same bytes from its own record of the request. Shared vectors:
  // spec/vectors/keyholder-challenge-v1.txt.
  async function deriveChallenge(request) {
    const f = requestFields(request);
    const tag = utf8Encode(f.kind === KIND.TEST ? TEST_TAG : APPROVAL_TAG);
    const input = concat([
      new Uint8Array([tag.length]),
      tag,
      new Uint8Array([FORMAT_VERSION, f.kind]),
      f.requestId,
      new Uint8Array([f.detail >>> 8, f.detail & 0xff]),
      new Uint8Array([f.label.length]),
      f.label,
      new Uint8Array([f.items.length]),
      ...f.items,
      f.nonce,
    ]);
    return sha256(input);
  }

  // ---------------------------------------------------------------------------------------------
  // Approval code (register 8a: format version; request ID; authenticator data; the
  // client-data bytes; ES256 signature). Made by the page.
  // Body: request ID (16) | authenticator data (37) | client data length (2) | client data
  //       | signature length (1) | signature (DER, 8..72)
  // ---------------------------------------------------------------------------------------------

  function checkAssertionFlags(authenticatorData) {
    const a = bytesOf(authenticatorData, 'authenticator data');
    if (a.length !== LIMITS.authenticatorData) fail('malformed', 'authenticator data must be 37 bytes');
    const flags = a[32];
    if (!(flags & FLAG_UP)) fail('malformed', 'user-present flag missing');
    if (!(flags & FLAG_UV)) fail('malformed', 'user-verified flag missing');
    if (flags & (FLAG_AT | FLAG_ED)) fail('malformed', 'unexpected attested or extension data');
    return a;
  }

  function encodeApprovalCode(fields) {
    const requestId = fixed(fields.requestId, LIMITS.requestId, 'request ID');
    const authenticatorData = checkAssertionFlags(fields.authenticatorData);
    const clientData = bytesOf(fields.clientData, 'client data');
    if (clientData.length < 1 || clientData.length > LIMITS.clientData) fail('malformed', 'client data length');
    const signature = bytesOf(fields.signature, 'signature');
    derToRawSignature(signature);
    const body = concat([
      requestId,
      authenticatorData,
      new Uint8Array([clientData.length >>> 8, clientData.length & 0xff]),
      clientData,
      new Uint8Array([signature.length]),
      signature,
    ]);
    return base32Encode(encodeRecord(TYPE.APPROVAL, body));
  }

  function decodeApprovalCode(text) {
    const r = reader(decodeRecord(base32Decode(text), TYPE.APPROVAL));
    const requestId = r.take(LIMITS.requestId, 'request ID');
    const authenticatorData = checkAssertionFlags(r.take(LIMITS.authenticatorData, 'authenticator data'));
    const cdLen = r.u16('client data length');
    if (cdLen < 1 || cdLen > LIMITS.clientData) fail('malformed', 'client data length');
    const clientData = r.take(cdLen, 'client data');
    const sigLen = r.u8('signature length');
    const signature = r.take(sigLen, 'signature');
    derToRawSignature(signature);
    r.end();
    return { version: FORMAT_VERSION, requestId, authenticatorData, clientData, signature };
  }

  // ---------------------------------------------------------------------------------------------
  // Passkey options and the checks made before a code is shown
  // ---------------------------------------------------------------------------------------------

  const TIMEOUT_MS = 300000;

  // navigator.credentials.create: ES256 only, user verification required, attestation "none",
  // a discoverable credential (chapter 09 section 14; chapter 07 section 7.13).
  // OPEN: the user handle is 16 random bytes made fresh for each key, not one fixed handle: a
  // phone keeps one passkey per site and handle, so a fixed handle would let a second enrolment
  // (for a second owner, or a fresh start) silently replace the first key.
  function createOptions({ rpId, userId, challenge, keyName }) {
    const name = String(keyName || '').trim().slice(0, 64) || 'SafeSight Mac keyholder';
    return {
      rp: { id: rpId, name: 'SafeSight Mac keyholder' },
      user: { id: fixed(userId, 16, 'user handle'), name, displayName: name },
      challenge: fixed(challenge, 32, 'challenge'),
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      authenticatorSelection: { residentKey: 'required', requireResidentKey: true, userVerification: 'required' },
      attestation: 'none',
      excludeCredentials: [],
      timeout: TIMEOUT_MS,
    };
  }

  // navigator.credentials.get: the challenge is the one deriveChallenge gives for the request on
  // screen (SD-306), passed as it is.
  // OPEN: chapter 09 says allowCredentials holds the one credential ID, but the request code
  // carries none and the page keeps nothing, so the list is empty and the phone offers its
  // keyholder keys for this site. Picking the wrong key gives an approval the keeper refuses.
  function getOptions({ rpId, challenge }) {
    return {
      rpId,
      challenge: new Uint8Array(fixed(challenge, LIMITS.challenge, 'challenge')),
      allowCredentials: [],
      userVerification: 'required',
      timeout: TIMEOUT_MS,
    };
  }

  // The fixed prefix the keeper compares (chapter 03 section 8, step 5): the fixed opening of a
  // passkey sign-in assertion, the challenge in its text form (base64url, no padding), and the
  // page origin, up to and including the quote that closes the origin.
  // OPEN: whether the keeper's prefix should also hold ',"crossOrigin":false'. Older browsers
  // leave that member out, so the prefix stops after the origin. The page refuses to run inside a
  // frame instead, since a policy set in a meta tag cannot forbid framing.
  function clientDataPrefix(challenge, origin) {
    const c = base64url(fixed(challenge, LIMITS.challenge, 'challenge'));
    return `{"type":"webauthn.get","challenge":"${c}","origin":"${origin}"`;
  }

  function startsWith(bytes, prefix) {
    const p = utf8Encode(prefix);
    return bytes.length >= p.length && equalBytes(bytes.subarray(0, p.length), p);
  }

  // From navigator.credentials.create's result to the enrolment code. Checks that the key is
  // ES256, made for this site, with the user verified, and that the credential ID matches.
  async function enrolmentFromCreate({ rawId, attestationObject, clientDataJSON, spki, rpId }) {
    let att;
    try {
      att = cborRead(bytesOf(attestationObject, 'attestation object'), 0, 0).value;
    } catch (e) {
      return fail('passkey', 'attestation object could not be read');
    }
    if (!(att instanceof Map) || !(att.get('authData') instanceof Uint8Array)) fail('passkey', 'attestation object has no authenticator data');
    const ad = parseAuthenticatorData(att.get('authData'));
    if (!equalBytes(ad.rpIdHash, await sha256(utf8Encode(rpId)))) fail('passkey', 'key made for another site');
    if (!(ad.flags & FLAG_UP) || !(ad.flags & FLAG_UV)) fail('passkey', 'user not verified');
    if (!ad.credentialId) fail('passkey', 'no credential data');
    const id = bytesOf(rawId, 'credential ID');
    if (!equalBytes(ad.credentialId, id)) fail('passkey', 'credential ID mismatch');
    if (id.length < 1 || id.length > LIMITS.credentialId) fail('passkey', `credential ID is ${id.length} bytes`);
    const publicKey = coseToRawP256(ad.credentialPublicKey);
    if (spki) {
      if (!equalBytes(spkiToRawP256(spki), publicKey)) fail('passkey', 'the two forms of the public key differ');
    }
    if (clientDataJSON) {
      let cd;
      try {
        cd = JSON.parse(utf8Decode(bytesOf(clientDataJSON, 'client data')));
      } catch (e) {
        return fail('passkey', 'client data could not be read');
      }
      if (!cd || cd.type !== 'webauthn.create') fail('passkey', 'client data type');
    }
    return { credentialId: id, publicKey, code: encodeEnrolmentCode({ credentialId: id, publicKey }) };
  }

  // From navigator.credentials.get's result to the approval code. Runs the checks the keeper
  // will run that need no pinned key (chapter 03 section 8, steps 3 to 5), so the keyholder is
  // told at once if their phone signs in a form the Mac cannot accept. The prefix is built from
  // the challenge derived again here from the request's own fields, never from anything carried.
  async function approvalFromGet({ authenticatorData, clientDataJSON, signature, request, origin, rpId }) {
    const a = bytesOf(authenticatorData, 'authenticator data');
    if (a.length !== LIMITS.authenticatorData) fail('passkey', `authenticator data is ${a.length} bytes, not 37`);
    if (!equalBytes(a.subarray(0, 32), await sha256(utf8Encode(rpId)))) fail('passkey', 'signed for another site');
    if (!(a[32] & FLAG_UP) || !(a[32] & FLAG_UV)) fail('passkey', 'user not verified');
    const cd = bytesOf(clientDataJSON, 'client data');
    const challenge = await deriveChallenge(request);
    if (!startsWith(cd, clientDataPrefix(challenge, origin))) fail('passkey', 'client data does not start as the Mac expects');
    try {
      return encodeApprovalCode({ requestId: request.requestId, authenticatorData: a, clientData: cd, signature });
    } catch (e) {
      return fail('passkey', e.detail || e.message);
    }
  }

  // What approving does, in plain words, built only from the signed fields (SD-196, SD-306):
  // the kind, the Mac label, the detail and the item count. One effect, stated once.
  const SETTING_TEXT = Object.freeze({
    [SETTING.BROWSER_PROFILE]: 'remove its browser profile',
    [SETTING.STRICT_COVER_OFF]: 'turn strict cover mode off',
    [SETTING.DETECTOR_BALANCED]: 'set its detector rule to Balanced',
  });

  function askText(request) {
    const f = requestFields(request);
    const label = request.label;
    switch (f.kind) {
      case KIND.TEST:
        return `This only checks that your key works with ${label}. Approving it changes nothing.`;
      case KIND.EXIT:
        return `Approving ends protection on ${label} 24 hours from now.`;
      case KIND.LOWER_WAIT:
        return `Approving lets ${label} lower its wait to ${f.detail} days, 24 hours from now.`;
      case KIND.LOOSEN_SETTING:
        return `Approving lets ${label} ${SETTING_TEXT[f.detail]}, 24 hours from now.`;
      case KIND.ADMIN_WINDOW:
        return `Approving gives ${label} administrator time 24 hours from now, for ${f.items.length === 1 ? '1 item' : `${f.items.length} items`}.`;
      default:
        return fail('malformed', 'unknown kind');
    }
  }

  // ---------------------------------------------------------------------------------------------
  // QR codes (model 2, error correction level M, alphanumeric or byte mode, versions 1 to 40)
  // ---------------------------------------------------------------------------------------------

  // OPEN: error correction level M; ST-029 may show that L (a smaller code) reads better.
  // Error correction codewords per block and number of blocks, level M, versions 1 to 40.
  const QR_ECC_PER_BLOCK = [
    10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
    26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28,
  ];
  const QR_BLOCKS = [
    1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
    17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49,
  ];
  const QR_ALNUM = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

  // Galois field GF(2^8) with the QR polynomial x^8 + x^4 + x^3 + x^2 + 1.
  const GF_EXP = new Uint8Array(512);
  const GF_LOG = new Uint8Array(256);
  (() => {
    let x = 1;
    for (let i = 0; i < 255; i++) {
      GF_EXP[i] = x;
      GF_LOG[x] = i;
      x <<= 1;
      if (x & 0x100) x ^= 0x11d;
    }
    for (let i = 255; i < 512; i++) GF_EXP[i] = GF_EXP[i - 255];
  })();
  function gfMul(a, b) {
    return a === 0 || b === 0 ? 0 : GF_EXP[GF_LOG[a] + GF_LOG[b]];
  }

  // The generator polynomial (x - a^0)(x - a^1)...(x - a^(n-1)), highest power first.
  function rsGenerator(n) {
    let g = [1];
    for (let i = 0; i < n; i++) {
      const next = new Array(g.length + 1).fill(0);
      for (let j = 0; j < g.length; j++) {
        next[j] ^= g[j];
        next[j + 1] ^= gfMul(g[j], GF_EXP[i]);
      }
      g = next;
    }
    return g;
  }

  // The n error correction codewords for a block of data codewords.
  function rsEcc(data, n) {
    const gen = rsGenerator(n);
    const rem = new Array(n).fill(0);
    for (const d of data) {
      const factor = d ^ rem[0];
      rem.shift();
      rem.push(0);
      if (factor !== 0) for (let j = 0; j < n; j++) rem[j] ^= gfMul(gen[j + 1], factor);
    }
    return rem;
  }

  function qrRawDataModules(v) {
    let n = (16 * v + 128) * v + 64;
    if (v >= 2) {
      const a = Math.floor(v / 7) + 2;
      n -= (25 * a - 10) * a - 55;
      if (v >= 7) n -= 36;
    }
    return n;
  }
  function qrTotalCodewords(v) {
    return Math.floor(qrRawDataModules(v) / 8);
  }
  function qrDataCodewords(v) {
    return qrTotalCodewords(v) - QR_ECC_PER_BLOCK[v - 1] * QR_BLOCKS[v - 1];
  }
  function qrAlignmentPositions(v) {
    if (v === 1) return [];
    const count = Math.floor(v / 7) + 2;
    const step = Math.floor((v * 8 + count * 3 + 5) / (count * 4 - 4)) * 2;
    const out = [];
    for (let pos = v * 4 + 10; out.length < count - 1; pos -= step) out.unshift(pos);
    out.unshift(6);
    return out;
  }

  // Split the data codewords into blocks, add each block's error correction, and interleave.
  function qrInterleave(data, v) {
    const blocks = QR_BLOCKS[v - 1];
    const ecc = QR_ECC_PER_BLOCK[v - 1];
    const total = qrTotalCodewords(v);
    const shortBlocks = blocks - (total % blocks);
    const shortData = Math.floor(total / blocks) - ecc;
    const parts = [];
    let at = 0;
    for (let b = 0; b < blocks; b++) {
      const len = shortData + (b < shortBlocks ? 0 : 1);
      const chunk = data.slice(at, at + len);
      at += len;
      parts.push({ data: chunk, ecc: rsEcc(chunk, ecc) });
    }
    const out = [];
    for (let i = 0; i <= shortData; i++) for (const p of parts) if (i < p.data.length) out.push(p.data[i]);
    for (let i = 0; i < ecc; i++) for (const p of parts) out.push(p.ecc[i]);
    return out;
  }

  // 15 format bits: level M (00) and the mask, BCH(15,5), masked with 101010000010010.
  function qrFormatBits(mask) {
    const data = mask & 7;
    let rem = data;
    for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
    return ((data << 10) | (rem & 0x3ff)) ^ 0x5412;
  }
  // 18 version bits for versions 7 and up, BCH(18,6).
  function qrVersionBits(v) {
    let rem = v;
    for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
    return (v << 12) | (rem & 0xfff);
  }

  const QR_MASKS = [
    (r, c) => (r + c) % 2 === 0,
    r => r % 2 === 0,
    (r, c) => c % 3 === 0,
    (r, c) => (r + c) % 3 === 0,
    (r, c) => (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0,
    (r, c) => ((r * c) % 2) + ((r * c) % 3) === 0,
    (r, c) => (((r * c) % 2) + ((r * c) % 3)) % 2 === 0,
    (r, c) => (((r + c) % 2) + ((r * c) % 3)) % 2 === 0,
  ];

  function qrPenalty(m, size) {
    let score = 0;
    const at = (line, i, j) => (line === 0 ? m[i * size + j] : m[j * size + i]);
    for (let line = 0; line < 2; line++) {
      for (let i = 0; i < size; i++) {
        let run = 0;
        let prev = -1;
        for (let j = 0; j < size; j++) {
          const v = at(line, i, j);
          if (v === prev) {
            run++;
            if (run === 5) score += 3;
            else if (run > 5) score += 1;
          } else {
            prev = v;
            run = 1;
          }
        }
        // A finder-like 1:1:3:1:1 run with four light modules on one side (outside is light).
        const light = (j0, j1) => {
          for (let j = j0; j < j1; j++) if (j >= 0 && j < size && at(line, i, j) === 1) return false;
          return true;
        };
        for (let j = 0; j + 7 <= size; j++) {
          if (at(line, i, j) === 1 && at(line, i, j + 1) === 0 && at(line, i, j + 2) === 1 && at(line, i, j + 3) === 1 &&
              at(line, i, j + 4) === 1 && at(line, i, j + 5) === 0 && at(line, i, j + 6) === 1 &&
              (light(j - 4, j) || light(j + 7, j + 11))) score += 40;
        }
      }
    }
    for (let r = 0; r + 1 < size; r++) {
      for (let c = 0; c + 1 < size; c++) {
        const v = m[r * size + c];
        if (v === m[r * size + c + 1] && v === m[(r + 1) * size + c] && v === m[(r + 1) * size + c + 1]) score += 3;
      }
    }
    let dark = 0;
    for (const v of m) dark += v;
    const total = size * size;
    score += Math.floor(Math.abs(dark * 20 - total * 10) / total) * 10;
    return score;
  }

  // Returns { version, size, modules, isFunction }: modules[row * size + col] is 1 for dark.
  function qrEncode(text) {
    const s = String(text);
    const alnum = /^[0-9A-Z $%*+\-./:]*$/.test(s);
    const bytes = alnum ? null : utf8Encode(s);
    const count = alnum ? s.length : bytes.length;
    const dataBits = alnum ? Math.floor(s.length / 2) * 11 + (s.length % 2) * 6 : bytes.length * 8;
    const countBits = v => (alnum ? (v <= 9 ? 9 : v <= 26 ? 11 : 13) : v <= 9 ? 8 : 16);
    let version = 0;
    for (let v = 1; v <= 40; v++) {
      if (4 + countBits(v) + dataBits <= qrDataCodewords(v) * 8) {
        version = v;
        break;
      }
    }
    if (!version) fail('too-long', 'too much for one QR code');
    const capacity = qrDataCodewords(version);

    const bits = [];
    const put = (value, n) => {
      for (let i = n - 1; i >= 0; i--) bits.push((value >>> i) & 1);
    };
    put(alnum ? 0b0010 : 0b0100, 4);
    put(count, countBits(version));
    if (alnum) {
      for (let i = 0; i + 1 < s.length; i += 2) put(QR_ALNUM.indexOf(s[i]) * 45 + QR_ALNUM.indexOf(s[i + 1]), 11);
      if (s.length % 2) put(QR_ALNUM.indexOf(s[s.length - 1]), 6);
    } else for (const b of bytes) put(b, 8);
    put(0, Math.min(4, capacity * 8 - bits.length));
    put(0, (8 - (bits.length % 8)) % 8);
    const codewords = [];
    for (let i = 0; i < bits.length; i += 8) {
      let b = 0;
      for (let j = 0; j < 8; j++) b = (b << 1) | bits[i + j];
      codewords.push(b);
    }
    for (let pad = 0xec; codewords.length < capacity; pad ^= 0xec ^ 0x11) codewords.push(pad);
    const stream = qrInterleave(codewords, version);

    const size = version * 4 + 17;
    const base = new Uint8Array(size * size);
    const isFunction = new Uint8Array(size * size);
    const set = (r, c, d) => {
      base[r * size + c] = d ? 1 : 0;
      isFunction[r * size + c] = 1;
    };
    for (let i = 0; i < size; i++) {
      set(6, i, i % 2 === 0);
      set(i, 6, i % 2 === 0);
    }
    for (const [r0, c0] of [[0, 0], [0, size - 7], [size - 7, 0]]) {
      for (let dr = -1; dr <= 7; dr++) {
        for (let dc = -1; dc <= 7; dc++) {
          const r = r0 + dr;
          const c = c0 + dc;
          if (r < 0 || c < 0 || r >= size || c >= size) continue;
          const ring = Math.max(Math.abs(dr - 3), Math.abs(dc - 3));
          set(r, c, ring !== 2 && ring <= 3);
        }
      }
    }
    const align = qrAlignmentPositions(version);
    const last = align[align.length - 1];
    for (const r of align) {
      for (const c of align) {
        if ((r === 6 && c === 6) || (r === 6 && c === last) || (r === last && c === 6)) continue;
        for (let dr = -2; dr <= 2; dr++) for (let dc = -2; dc <= 2; dc++) set(r + dr, c + dc, Math.max(Math.abs(dr), Math.abs(dc)) !== 1);
      }
    }
    const drawFormat = (target, mask) => {
      const f = qrFormatBits(mask);
      const b = i => ((f >>> i) & 1) === 1;
      const put2 = (r, c, d) => {
        target[r * size + c] = d ? 1 : 0;
        isFunction[r * size + c] = 1;
      };
      for (let i = 0; i <= 5; i++) put2(i, 8, b(i));
      put2(7, 8, b(6));
      put2(8, 8, b(7));
      put2(8, 7, b(8));
      for (let i = 9; i < 15; i++) put2(8, 14 - i, b(i));
      for (let i = 0; i < 8; i++) put2(8, size - 1 - i, b(i));
      for (let i = 8; i < 15; i++) put2(size - 15 + i, 8, b(i));
      put2(size - 8, 8, true);
    };
    drawFormat(base, 0); // reserves the format areas; redrawn for each mask below
    if (version >= 7) {
      const vb = qrVersionBits(version);
      for (let i = 0; i < 18; i++) {
        const d = ((vb >>> i) & 1) === 1;
        const a = size - 11 + (i % 3);
        const b = Math.floor(i / 3);
        set(b, a, d);
        set(a, b, d);
      }
    }

    // Data: two-module columns from the right, alternating up and down, skipping column 6.
    let bit = 0;
    const totalBits = stream.length * 8;
    let upward = true;
    for (let col = size - 1; col > 0; col -= 2) {
      if (col === 6) col = 5;
      for (let k = 0; k < size; k++) {
        const r = upward ? size - 1 - k : k;
        for (const c of [col, col - 1]) {
          const idx = r * size + c;
          if (isFunction[idx]) continue;
          if (bit < totalBits) base[idx] = (stream[bit >>> 3] >>> (7 - (bit & 7))) & 1;
          bit++;
        }
      }
      upward = !upward;
    }

    let best = null;
    let bestScore = Infinity;
    for (let mask = 0; mask < 8; mask++) {
      const m = base.slice();
      for (let r = 0; r < size; r++) {
        for (let c = 0; c < size; c++) {
          const idx = r * size + c;
          if (!isFunction[idx] && QR_MASKS[mask](r, c)) m[idx] ^= 1;
        }
      }
      drawFormat(m, mask);
      const score = qrPenalty(m, size);
      if (score < bestScore) {
        bestScore = score;
        best = { mask, modules: m };
      }
    }
    return { version, size, mask: best.mask, modules: best.modules, isFunction };
  }

  // An SVG path for the dark modules, with a quiet zone of `margin` modules on every side.
  function qrSvgPath(qr, margin) {
    const q = margin == null ? 4 : margin;
    let d = '';
    for (let r = 0; r < qr.size; r++) {
      let c = 0;
      while (c < qr.size) {
        if (!qr.modules[r * qr.size + c]) {
          c++;
          continue;
        }
        const startCol = c;
        while (c < qr.size && qr.modules[r * qr.size + c]) c++;
        d += `M${startCol + q},${r + q}h${c - startCol}v1h-${c - startCol}z`;
      }
    }
    return d;
  }

  return Object.freeze({
    FORMAT_VERSION,
    TYPE,
    KIND,
    KIND_NAMES,
    WAIT_DAYS,
    SETTING,
    APPROVAL_TAG,
    TEST_TAG,
    LIMITS,
    PINNED_ORIGIN,
    CodeError,
    crc32,
    base32Encode,
    base32Decode,
    base64url,
    extractCode,
    toHex,
    checkLabel,
    checkPublicKey,
    derToRawSignature,
    spkiToRawP256,
    cborRead,
    parseAuthenticatorData,
    coseToRawP256,
    encodeEnrolmentCode,
    decodeEnrolmentCode,
    encodeRequestCode,
    decodeRequestCode,
    deriveChallenge,
    encodeApprovalCode,
    decodeApprovalCode,
    createOptions,
    getOptions,
    clientDataPrefix,
    enrolmentFromCreate,
    approvalFromGet,
    askText,
    qr: Object.freeze({
      encode: qrEncode,
      svgPath: qrSvgPath,
      rsEcc,
      formatBits: qrFormatBits,
      versionBits: qrVersionBits,
      dataCodewords: qrDataCodewords,
      rawDataModules: qrRawDataModules,
      alignmentPositions: qrAlignmentPositions,
    }),
  });
})();
