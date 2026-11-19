<!-- SPDX-License-Identifier: Apache-2.0 -->
# The keyholder page

A keyholder is a friend the owner can name, if they want one. The friend can shorten one leave request to 24 hours by approving it. They can't block, cancel or delay anything, and they see nothing about the owner or the Mac.

This folder is the page the friend uses. It's one static file, `index.html`, that runs entirely in their browser. It holds the friend's key as a passkey on their phone and sends nothing to anyone (register SD-155, SD-194 to SD-196).

## What it does

**Enrol.** The owner's Mac shows a QR code with the page's address. The friend opens it and taps **Create my key**. The phone makes an ES256 passkey for the page's own origin, and the page shows the **enrolment record** (credential ID and public key) as a QR picture and as text. The owner's Mac reads it with its camera, or the owner pastes the text. Then the two do one test approval, which changes nothing.

**Approve.** After the owner asks to leave, their Mac shows a **request code**. The friend scans it with the phone's camera or pastes it. The page says in one sentence what approving does, for example "Approving ends protection on Sam's Mac 24 hours from now", that the friend can't stop it either way, and that saying no or not answering is fine. If the friend approves, the passkey signs a challenge made from exactly the fields that sentence was built from, and the page shows the **approval code** for the owner to carry back.

The request code reaches the page only in the part of the address after `#`, which browsers never send to the host. The page reads it, then removes it from the address bar and the history entry. The page keeps nothing: no cookies, no storage of any kind. When it's closed, it's gone.

## Files

| File | What it is |
|---|---|
| `index.html` | The built page. This exact file is what gets hosted, and its hash is published |
| `core.js` | The codes, the passkey checks and the QR encoder. Plain functions with no access to the page. Inlined byte for byte |
| `src/page.html`, `src/page.css`, `src/page.js` | The page's markup, look and screens |
| `build.mjs` | Inlines the parts into `index.html` and writes the content security policy |
| `tests/` | Node's built-in test runner. `vectors.json` holds test vectors for the codes; `make-vectors.mjs` made them |
| `../spec/vectors/keyholder-challenge-v1.txt` | The challenge and approval vectors the keeper's tests read too; `tests/make-challenge-vectors.mjs` made them |

## Rebuild and test

Node 18 or newer. No dependencies, nothing to install.

```sh
node keyholder/build.mjs                 # writes index.html and prints its SHA-256
node keyholder/build.mjs --check         # fails if index.html is out of date
node --test keyholder/tests/*.test.mjs   # the tests (CI runs this too)
```

After changing anything in `core.js` or `src/`, rebuild and commit the new `index.html` with it. A test fails if `index.html` isn't exactly what the sources build.

## The hash rule (SD-155)

The SHA-256 of the exact bytes of `keyholder/index.html` is published in every release's notes and manifest. The hosted page must be that same file, byte for byte. A public job fetches the live page and compares (chapter 07, 7.13). If they ever differ, keyholders are told to wait until they match again.

- `node keyholder/build.mjs` prints the hash. So does `shasum -a 256 keyholder/index.html`.
- Any change to the page or its core changes the hash, so it's a new page for the next release.
- Host the file untouched. On GitHub Pages, add an empty `.nojekyll` file so nothing processes it.
- Git never changes line endings in this folder (`.gitattributes`), so every checkout has the same bytes and the same hash.

## How the page keeps to "sends nothing"

- The content security policy is in the file itself: `default-src 'none'`, scripts and the style allowed only by their SHA-256 hashes, `connect-src 'none'`, `form-action 'none'`, `base-uri 'none'`, images only from inline data, and Trusted Types, which Chromium browsers enforce.
- Nothing comes from another origin: no script, style, font, picture or frame. The favicon is an empty inline icon, so the browser doesn't ask the host for one. There are no links, and referrers are off.
- A policy in a meta tag can't forbid framing, so the page checks for itself and stops if it's inside another site.
- The tests check every one of these points in `index.html`.

## The codes

All three codes share one envelope and one text form.

**Envelope.** Magic `SM` (2 bytes), record type (1: enrolment `1`, request `2`, approval `3`), format version (1, now `1`), body length (2, big-endian), the body, then a CRC-32 (zlib/PNG) over everything before it (4, big-endian). It's checked in this order: magic, length, checksum, type, version. A code of another format version is refused, never guessed at. The envelope is the same in every version.

**Text.** RFC 4648 base32, upper case, no padding. Every character is in the QR code's alphanumeric set, so the QR pictures stay small. When reading, case is ignored and spaces, line breaks and hyphens are skipped. Anything else is refused, and so are trailing bits that aren't zero, so each code has exactly one spelling.

| Code (register 8a) | Made by | Body, in order |
|---|---|---|
| Enrolment record | This page | credential ID length (1) · credential ID (1 to 128) · public key, P-256 uncompressed (65) |
| Request code | The keeper | kind (1) · request ID (16) · nonce (32) · detail (2, big-endian) · label length (1) · Mac label, UTF-8 (1 to 32) · item count (1) · item hashes (32 each; 1 to 16 for an admin window, none otherwise) |
| Approval code | This page | request ID (16) · authenticator data (37) · client data length (2) · client data, exactly as signed (1 to 1024) · signature length (1) · ES256 signature, DER as the passkey made it (8 to 72) |

Kinds: `0` test, `1` exit, `2` lower wait, `3` loosen setting, `4` admin window.

The **detail** depends on the kind, and anything else is refused:

| Kind | Detail |
|---|---|
| `2` lower wait | The new wait in days: `7`, `30`, `90` or `182`. A year is the longest wait, so 365 is never a lowering |
| `3` loosen setting | `1` browser profile, `2` strict cover mode off, `3` detector rule to Balanced |
| `0` test, `1` exit, `4` admin window | `0` |

The **nonce** is 32 random bytes the keeper makes for each request. The request code carries no challenge.

The request code body was redefined in format version 1 before anything shipped, so no other version-1 request code exists. The vectors in `tests/vectors.json` were remade for the new body.

**The challenge** (SD-306) is what the passkey signs. The page makes it from the very fields it shows the friend, so an approval stands only for what was on their screen. It's the SHA-256 of:

```
tag length (1) | tag (ASCII) | format version (1, = 1) | kind (1) | request ID (16)
| detail (2, big-endian) | label length (1) | label (UTF-8) | item count (1)
| item hashes (32 each) | nonce (32)
```

The tag is `SafeSightMac keyholder approval` for kinds 1 to 4 and `SafeSightMac keyholder test approval` for kind 0, so a test approval can never count as a real one. `deriveChallenge` in `core.js` builds it. The keeper builds the same bytes from its own record of the request. Both sides test against one file, `spec/vectors/keyholder-challenge-v1.txt`, made by `tests/make-challenge-vectors.mjs` with `node:crypto` alone. It's frozen: never regenerate or edit it.

The page refuses to show or sign a request with any field it can't read. The words the friend sees are built only from the kind, the label, the detail and the item count.

The keeper checks that the client data begins with this fixed prefix (chapter 03 section 8, step 5), where the challenge is base64url with no padding:

```
{"type":"webauthn.get","challenge":"<challenge>","origin":"<page origin>"
```

Before showing an approval, the page runs the checks it can make without the pinned key: authenticator data of exactly 37 bytes, made for this site, with "user present" and "user verified" set, and client data that begins with the prefix built from the challenge it derived. So a phone that signs in some form the Mac can't accept is caught right away. The tests run the keeper's whole check, including the signature, against an independent version in `tests/helpers.mjs`.

**Address.** The owner's QR code for a request holds `<page address>#<request code>`. The page also accepts a pasted address or the code on its own.

## Not tested here

- **Real passkeys.** These tests run in Node, with a P-256 key standing in for the phone. They don't run a browser or make a real passkey. Whether common phones make ES256 passkeys on the page's origin, and sign client data that begins with the fixed prefix, is for ST-029 and ST-030 on real phones.
- **The page in a browser.** The screens are tested against a small stand-in for the browser, not rendered, and nobody has looked at the design on a phone yet.
- **QR reading.** The encoder's golden outputs, and a code of every version from 1 to 40, decoded back to the exact text with Apple's CoreImage reader when they were made. Reading them with a Mac's camera off a phone screen is for ST-029.
- For ST-029 to watch: iOS may ask the host for an `apple-touch-icon` if the friend adds the page to their home screen. The page itself makes no request after it loads. The page removes the request code from the address bar and its history entry, but a browser's own list of visited pages may still hold the address it was opened with.

## OPEN

Places where the register leaves a detail open. Each one is marked `OPEN:` in `core.js`.

1. **Envelope sizes and checksum.** Register 8a names magic, type, version, length and checksum but not their sizes or the checksum function. Chosen: the envelope above, with CRC-32.
2. **Text alphabet.** Chapter 09 says "a base-32 alphabet with a checksum". Chosen: RFC 4648 base32. The checksum is the envelope's.
3. **Carried forms, not the keeper's fixed layouts.** The page's codes use length-prefixed fields with hard caps. The app pads them into the keeper's fixed layouts, as register 8a says it converts the approval. The caps are request ID 16 bytes, label 1 to 32 bytes, admin window 1 to 16 items, credential ID 1 to 128 bytes, client data 1 to 1024 bytes and signature 8 to 72 bytes. The keeper's fixed field sizes must be at least these.
4. **Kind codes.** The register names no kind for the test approval at enrolment. Chosen: kind `0` is a test.
5. **The challenge's formula.** Resolved by SD-306: the challenge is derived for every kind, from the kind, request ID, detail, label, item hashes and nonce, as above. The request code no longer carries one.
6. **Signature form.** It's carried as DER, as the passkey makes it. The app converts it to the fixed 64-byte form, as chapter 03 says. `core.js` has the strict converter (`derToRawSignature`).
7. **Which key signs.** Chapter 09 gives `allowCredentials` the one credential ID, but the request code doesn't carry it and the page keeps nothing. Chosen: an empty list, so the phone offers its keyholder keys for this site. If the friend picks the wrong one, the keeper refuses the approval. Adding the credential ID to the request code would let the phone pick it directly.
8. **User handle.** Chapter 09 suggests one fixed handle. Chosen: 16 random bytes for each new key, because a phone keeps one passkey per site and handle, so a fixed handle would let a second enrolment (for a second owner, or a fresh start) silently replace the first key. The friend can name the key, and only they see the name.
9. **Where the prefix stops.** The prefix ends at the quote that closes the origin and leaves out `,"crossOrigin":false`, since older browsers omit that member. The page refuses to run inside a frame instead. Whether the keeper's prefix includes it is the keeper's call.
10. **The pinned origin (SQ-11).** `PINNED_ORIGIN` in `core.js` is empty, so the page works on whatever origin serves it. Once it's set, the page refuses to make or use keys anywhere else, and the tests allow that one address and no other. A passkey belongs to a host name: on a shared `github.io` host, every Pages site of the same account shares it. A dedicated host name for the page is safer.
11. **Scanning inside the page.** Not built. The phone's own camera opens the request QR code as a link, and paste is always there. This also means the page never asks for the camera.
12. **QR error correction.** Level M. ST-029 may show that L, which gives a smaller code, reads better.
13. **Code sizes.** The register's `APPROVAL_CODE_SIZE` is "about 200" characters. A real approval is about 440 characters as text, or about 610 when Chrome adds its extra client-data member. That's a QR version 13 to 16, and paste works at any size. It could be cut by about 170 characters by leaving out the prefix the keeper builds anyway and carrying the 64-byte signature. That would be a change to register 8a. Request codes are about 120 characters (215 for a two-item admin window), and the enrolment record is about 150.
14. **The Mac label rule.** 1 to 32 bytes of UTF-8, with no leading or trailing space and none of these: control characters, line or paragraph separators, zero-width characters, the byte order mark, or the characters that change text direction. The app should apply the same rule when the owner types the label.
15. **Authenticator data must be exactly 37 bytes.** Chapter 03 reads the fixed first 37. An approval with extension data would be signed over more than that, so the page refuses it.
16. **No origin in the enrolment record.** Register 8a lists only version, credential ID and public key. The pin's origin hash comes from the lock core.
