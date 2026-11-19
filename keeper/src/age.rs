// SPDX-License-Identifier: Apache-2.0
//! The `age` version 1 file format (age-encryption.org/v1), as far as a capsule uses it
//! (SD-056; chapter 03 section 9, "The two layers").
//!
//! An age file is a text header, then a binary payload:
//!
//! ```text
//! age-encryption.org/v1
//! -> <type> <arg> <arg>...
//! <body, base64 without padding, lines of 64 characters, the last one shorter>
//! --- <base64 of HMAC-SHA-256 over the header up to and including "---">
//! <16-byte nonce><payload sealed with ChaCha20-Poly1305 in the STREAM construction>
//! ```
//!
//! The 16-byte file key is wrapped once per stanza. The header key is HKDF-SHA-256 of the
//! file key with an empty salt and "header"; the payload key is HKDF-SHA-256 of the file
//! key with the nonce as salt and "payload". A capsule uses two stanza types: `X25519`,
//! to the Recovery Key's public half (the inner layer), and `tlock`, to a round of the
//! pinned chain (the outer layer, `timelock`). Its payloads are far below one 64 KiB
//! chunk, so the payload is always one final chunk.
//!
//! The writer is what the keeper uses. The reader is the opener's (SD-066). Chapter 03
//! section 9 says the keeper never parses a capsule it did not just make, so the reader is
//! compiled only for tests and for the opener feature, never into the keeper.
// OPEN: SD-021 - the register names the published `age` crate. It is not used: it brings a
// localisation stack (i18n-embed, fluent) into a root daemon for two stanza types, and,
// as far as could be told from here without the crate sources, one crate of that stack
// (`self_cell`) offers GPL-2.0 as one of its licence choices, which
// tools/check-licences.sh refuses as written. The format is written here from the
// published specification with the fixed-list crates, and pinned by vectors from a
// second, independent implementation. A vector from the reference `age` tools is still
// to be added, with the opener (ST-072).

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use x25519_dalek::{x25519, X25519_BASEPOINT_BYTES};
use zeroize::Zeroize;

/// The first line of every age version 1 file.
pub const VERSION_LINE: &[u8] = b"age-encryption.org/v1\n";
/// The size of a file key.
pub const FILE_KEY_LEN: usize = 16;
/// The size of a payload nonce.
pub const NONCE_LEN: usize = 16;
/// The ChaCha20-Poly1305 tag.
pub const TAG_LEN: usize = 16;
/// The size of one plaintext chunk of the STREAM construction.
pub const CHUNK_LEN: usize = 64 * 1024;
/// The label of the X25519 recipient's key step.
const X25519_LABEL: &[u8] = b"age-encryption.org/v1/X25519";

type HmacSha256 = Hmac<Sha256>;

// ---------------------------------------------------------------------------------------
// Base64, standard alphabet, no padding (RFC 4648 section 4). Decoding is strict: only
// the one canonical text of a byte string is accepted.
// ---------------------------------------------------------------------------------------

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub(crate) fn base64_encode(bytes: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::with_capacity((bytes.len() * 4 + 2) / 3);
    let mut i = 0;
    while i + 3 <= bytes.len() {
        let n = ((bytes[i] as u32) << 16) | ((bytes[i + 1] as u32) << 8) | (bytes[i + 2] as u32);
        out.push(ALPHABET[((n >> 18) & 63) as usize]);
        out.push(ALPHABET[((n >> 12) & 63) as usize]);
        out.push(ALPHABET[((n >> 6) & 63) as usize]);
        out.push(ALPHABET[(n & 63) as usize]);
        i += 3;
    }
    let rest = bytes.len() - i;
    if rest == 1 {
        let n = (bytes[i] as u32) << 16;
        out.push(ALPHABET[((n >> 18) & 63) as usize]);
        out.push(ALPHABET[((n >> 12) & 63) as usize]);
    } else if rest == 2 {
        let n = ((bytes[i] as u32) << 16) | ((bytes[i + 1] as u32) << 8);
        out.push(ALPHABET[((n >> 18) & 63) as usize]);
        out.push(ALPHABET[((n >> 12) & 63) as usize]);
        out.push(ALPHABET[((n >> 6) & 63) as usize]);
    }
    out
}

#[cfg(any(test, feature = "opener"))]
fn base64_value(c: u8) -> Option<u32> {
    match c {
        b'A'..=b'Z' => Some((c - b'A') as u32),
        b'a'..=b'z' => Some((c - b'a') as u32 + 26),
        b'0'..=b'9' => Some((c - b'0') as u32 + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

#[cfg(any(test, feature = "opener"))]
pub(crate) fn base64_decode(text: &[u8]) -> Option<Vec<u8>> {
    if text.len() % 4 == 1 {
        return None;
    }
    let mut out: Vec<u8> = Vec::with_capacity(text.len() * 3 / 4);
    let mut i = 0;
    while i + 4 <= text.len() {
        let n = (base64_value(text[i])? << 18)
            | (base64_value(text[i + 1])? << 12)
            | (base64_value(text[i + 2])? << 6)
            | base64_value(text[i + 3])?;
        out.push((n >> 16) as u8);
        out.push((n >> 8) as u8);
        out.push(n as u8);
        i += 4;
    }
    let rest = text.len() - i;
    if rest == 2 {
        let n = (base64_value(text[i])? << 18) | (base64_value(text[i + 1])? << 12);
        out.push((n >> 16) as u8);
    } else if rest == 3 {
        let n = (base64_value(text[i])? << 18) | (base64_value(text[i + 1])? << 12) | (base64_value(text[i + 2])? << 6);
        out.push((n >> 16) as u8);
        out.push((n >> 8) as u8);
    }
    // Canonical only: unused low bits must be zero, so the text is the one encoding.
    if base64_encode(&out) != text {
        return None;
    }
    Some(out)
}

// ---------------------------------------------------------------------------------------
// Key steps
// ---------------------------------------------------------------------------------------

fn hkdf_32(salt: &[u8], ikm: &[u8], info: &[u8]) -> Option<[u8; 32]> {
    let step = Hkdf::<Sha256>::new(Some(salt), ikm);
    let mut out = [0u8; 32];
    if step.expand(info, &mut out).is_err() {
        return None;
    }
    Some(out)
}

fn header_mac(file_key: &[u8; FILE_KEY_LEN], header: &[u8]) -> Option<HmacSha256> {
    let mut key = hkdf_32(&[], file_key, b"header")?;
    let mac = <HmacSha256 as KeyInit>::new_from_slice(&key);
    key.zeroize();
    let mut mac = match mac {
        Ok(m) => m,
        Err(_) => return None,
    };
    mac.update(header);
    Some(mac)
}

fn payload_cipher(file_key: &[u8; FILE_KEY_LEN], nonce: &[u8; NONCE_LEN]) -> Option<ChaCha20Poly1305> {
    let mut key = hkdf_32(nonce, file_key, b"payload")?;
    let cipher = <ChaCha20Poly1305 as KeyInit>::new_from_slice(&key);
    key.zeroize();
    match cipher {
        Ok(c) => Some(c),
        Err(_) => None,
    }
}

/// The STREAM nonce of chunk 0 when it is also the last chunk: an 11-byte big-endian
/// counter of zero, then the last-chunk flag 0x01.
fn single_chunk_nonce() -> [u8; 12] {
    let mut nonce = [0u8; 12];
    nonce[11] = 1;
    nonce
}

// ---------------------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------------------

/// Appends a stanza's body: base64 in lines of 64 characters, the last line shorter
/// (an empty line if the text is a whole number of lines).
fn push_body(out: &mut Vec<u8>, body: &[u8]) {
    let text = base64_encode(body);
    let mut i = 0;
    while i < text.len() {
        let end = if i + 64 < text.len() { i + 64 } else { text.len() };
        out.extend_from_slice(&text[i..end]);
        out.push(b'\n');
        i = end;
    }
    if text.len() % 64 == 0 {
        out.push(b'\n');
    }
}

/// One stanza: "-> type arg..." and its body.
fn stanza(kind: &[u8], args: &[&[u8]], body: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(b"-> ");
    out.extend_from_slice(kind);
    for arg in args.iter() {
        out.push(b' ');
        out.extend_from_slice(arg);
    }
    out.push(b'\n');
    push_body(&mut out, body);
    out
}

/// The X25519 stanza that wraps `file_key` to `recipient`, with `ephemeral` the 32 random
/// bytes of the ephemeral secret. None if the recipient gives an all-zero shared secret
/// (a low-order point), as the specification requires.
pub(crate) fn x25519_stanza(
    file_key: &[u8; FILE_KEY_LEN],
    recipient: &[u8; 32],
    ephemeral: &[u8; 32],
) -> Option<Vec<u8>> {
    let share = x25519(*ephemeral, X25519_BASEPOINT_BYTES);
    let mut shared = x25519(*ephemeral, *recipient);
    if shared == [0u8; 32] {
        return None;
    }
    let mut salt = [0u8; 64];
    salt[..32].copy_from_slice(&share);
    salt[32..].copy_from_slice(recipient);
    let wrap_key = hkdf_32(&salt, &shared, X25519_LABEL);
    shared.zeroize();
    let mut wrap_key = wrap_key?;
    let cipher = <ChaCha20Poly1305 as KeyInit>::new_from_slice(&wrap_key);
    wrap_key.zeroize();
    let cipher = match cipher {
        Ok(c) => c,
        Err(_) => return None,
    };
    let zero_nonce = [0u8; 12];
    let body = match cipher.encrypt(Nonce::from_slice(&zero_nonce), &file_key[..]) {
        Ok(b) => b,
        Err(_) => return None,
    };
    let share_text = base64_encode(&share);
    Some(stanza(b"X25519", &[&share_text[..]], &body))
}

/// The tlock stanza: "-> tlock <round> <chain hash in lower-case hex>" and the 128-byte
/// time-lock body (the published tlock format).
pub(crate) fn tlock_stanza(round: u64, chain_hash: &[u8; 32], body: &[u8]) -> Vec<u8> {
    let round_text = format!("{}", round);
    let mut hash_text = String::with_capacity(64);
    for byte in chain_hash.iter() {
        hash_text.push_str(&format!("{:02x}", byte));
    }
    stanza(b"tlock", &[round_text.as_bytes(), hash_text.as_bytes()], body)
}

/// A whole age file: the header with `stanzas` and its MAC, then `nonce` and the payload
/// sealed as one final STREAM chunk. The payload must be between 1 byte and one chunk.
pub(crate) fn seal_file(
    file_key: &[u8; FILE_KEY_LEN],
    stanzas: &[Vec<u8>],
    payload: &[u8],
    nonce: &[u8; NONCE_LEN],
) -> Option<Vec<u8>> {
    if payload.is_empty() || payload.len() > CHUNK_LEN || stanzas.is_empty() {
        return None;
    }
    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(VERSION_LINE);
    for s in stanzas.iter() {
        out.extend_from_slice(s);
    }
    out.extend_from_slice(b"---");
    let tag = header_mac(file_key, &out)?.finalize().into_bytes();
    out.push(b' ');
    out.extend_from_slice(&base64_encode(tag.as_slice()));
    out.push(b'\n');
    out.extend_from_slice(nonce);
    let cipher = payload_cipher(file_key, nonce)?;
    let chunk_nonce = single_chunk_nonce();
    let sealed = match cipher.encrypt(Nonce::from_slice(&chunk_nonce), payload) {
        Ok(s) => s,
        Err(_) => return None,
    };
    out.extend_from_slice(&sealed);
    Some(out)
}

// ---------------------------------------------------------------------------------------
// Reading: the opener's side only
// ---------------------------------------------------------------------------------------

/// The most stanzas the opener reads in one header. A capsule has one (outer) or one or
/// two (inner).
#[cfg(any(test, feature = "opener"))]
const STANZAS_MAX: usize = 4;

/// One stanza as read.
#[cfg(any(test, feature = "opener"))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ReadStanza {
    pub kind: Vec<u8>,
    pub args: Vec<Vec<u8>>,
    pub body: Vec<u8>,
}

/// An age file as read: its stanzas, the bytes its MAC covers, the MAC, the nonce and the
/// sealed payload. Nothing in it is trusted until `open_payload` has checked the MAC.
#[cfg(any(test, feature = "opener"))]
#[derive(Debug, Clone)]
pub(crate) struct ReadFile<'a> {
    pub stanzas: Vec<ReadStanza>,
    mac_input: &'a [u8],
    mac: Vec<u8>,
    nonce: [u8; NONCE_LEN],
    sealed: &'a [u8],
}

/// The next line, without its newline. A line must end in "\n" and hold only printable
/// ASCII.
#[cfg(any(test, feature = "opener"))]
fn next_line<'a>(bytes: &'a [u8], pos: &mut usize) -> Option<&'a [u8]> {
    let start = *pos;
    let mut i = start;
    while i < bytes.len() {
        let c = bytes[i];
        if c == b'\n' {
            *pos = i + 1;
            return Some(&bytes[start..i]);
        }
        if !(0x20..=0x7E).contains(&c) {
            return None;
        }
        i += 1;
    }
    None
}

/// An argument or type: one or more printable ASCII characters other than a space.
#[cfg(any(test, feature = "opener"))]
fn is_word(word: &[u8]) -> bool {
    !word.is_empty() && word.iter().all(|c| (0x21..=0x7E).contains(c))
}

/// Reads an age version 1 file strictly. None for anything else.
#[cfg(any(test, feature = "opener"))]
pub(crate) fn read_file(bytes: &[u8]) -> Option<ReadFile<'_>> {
    let mut pos = 0;
    let first = next_line(bytes, &mut pos)?;
    if first != &VERSION_LINE[..VERSION_LINE.len() - 1] {
        return None;
    }
    let mut stanzas: Vec<ReadStanza> = Vec::new();
    loop {
        let line_start = pos;
        let line = next_line(bytes, &mut pos)?;
        if line.len() >= 4 && &line[..4] == b"--- " {
            let mac = base64_decode(&line[4..])?;
            if mac.len() != 32 || stanzas.is_empty() {
                return None;
            }
            let rest = &bytes[pos..];
            if rest.len() < NONCE_LEN + TAG_LEN + 1 {
                return None;
            }
            let mut nonce = [0u8; NONCE_LEN];
            nonce.copy_from_slice(&rest[..NONCE_LEN]);
            return Some(ReadFile {
                stanzas,
                mac_input: &bytes[..line_start + 3],
                mac,
                nonce,
                sealed: &rest[NONCE_LEN..],
            });
        }
        if line.len() < 3 || &line[..3] != b"-> " {
            return None;
        }
        let mut words = line[3..].split(|c| *c == b' ');
        let kind = match words.next() {
            Some(k) => k,
            None => return None,
        };
        if !is_word(kind) {
            return None;
        }
        let mut args: Vec<Vec<u8>> = Vec::new();
        for word in words {
            if !is_word(word) {
                return None;
            }
            args.push(word.to_vec());
        }
        let mut body_text: Vec<u8> = Vec::new();
        loop {
            let body_line = next_line(bytes, &mut pos)?;
            if body_line.len() > 64 {
                return None;
            }
            body_text.extend_from_slice(body_line);
            if body_line.len() < 64 {
                break;
            }
        }
        let body = base64_decode(&body_text)?;
        stanzas.push(ReadStanza { kind: kind.to_vec(), args, body });
        if stanzas.len() > STANZAS_MAX {
            return None;
        }
    }
}

/// Checks the header MAC with `file_key`, then opens the payload. A payload of more than
/// one chunk is refused: no capsule has one.
#[cfg(any(test, feature = "opener"))]
pub(crate) fn open_payload(file: &ReadFile<'_>, file_key: &[u8; FILE_KEY_LEN]) -> Option<Vec<u8>> {
    let mac = header_mac(file_key, file.mac_input)?;
    if mac.verify_slice(&file.mac).is_err() {
        return None;
    }
    if file.sealed.len() > CHUNK_LEN + TAG_LEN {
        return None;
    }
    let cipher = payload_cipher(file_key, &file.nonce)?;
    let chunk_nonce = single_chunk_nonce();
    match cipher.decrypt(Nonce::from_slice(&chunk_nonce), file.sealed) {
        Ok(plain) => {
            if plain.is_empty() {
                None
            } else {
                Some(plain)
            }
        }
        Err(_) => None,
    }
}

/// Unwraps the file key from an X25519 stanza with the identity (the Recovery Key's
/// secret scalar). None if the stanza is not for this identity.
#[cfg(any(test, feature = "opener"))]
pub(crate) fn unwrap_x25519(stanza: &ReadStanza, identity: &[u8; 32]) -> Option<[u8; FILE_KEY_LEN]> {
    if stanza.kind != b"X25519" || stanza.args.len() != 1 || stanza.body.len() != FILE_KEY_LEN + TAG_LEN {
        return None;
    }
    let share_bytes = base64_decode(&stanza.args[0])?;
    if share_bytes.len() != 32 {
        return None;
    }
    let mut share = [0u8; 32];
    share.copy_from_slice(&share_bytes);
    let mut shared = x25519(*identity, share);
    if shared == [0u8; 32] {
        return None;
    }
    let recipient = x25519(*identity, X25519_BASEPOINT_BYTES);
    let mut salt = [0u8; 64];
    salt[..32].copy_from_slice(&share);
    salt[32..].copy_from_slice(&recipient);
    let wrap_key = hkdf_32(&salt, &shared, X25519_LABEL);
    shared.zeroize();
    let mut wrap_key = wrap_key?;
    let cipher = <ChaCha20Poly1305 as KeyInit>::new_from_slice(&wrap_key);
    wrap_key.zeroize();
    let cipher = match cipher {
        Ok(c) => c,
        Err(_) => return None,
    };
    let zero_nonce = [0u8; 12];
    let mut plain = match cipher.decrypt(Nonce::from_slice(&zero_nonce), &stanza.body[..]) {
        Ok(p) => p,
        Err(_) => return None,
    };
    if plain.len() != FILE_KEY_LEN {
        plain.zeroize();
        return None;
    }
    let mut key = [0u8; FILE_KEY_LEN];
    key.copy_from_slice(&plain);
    plain.zeroize();
    Some(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_rfc_4648_without_padding() {
        let cases: [(&[u8], &[u8]); 7] = [
            (b"", b""),
            (b"f", b"Zg"),
            (b"fo", b"Zm8"),
            (b"foo", b"Zm9v"),
            (b"foob", b"Zm9vYg"),
            (b"fooba", b"Zm9vYmE"),
            (b"foobar", b"Zm9vYmFy"),
        ];
        for (plain, text) in cases.iter() {
            assert_eq!(base64_encode(plain), text.to_vec());
            assert_eq!(base64_decode(text), Some(plain.to_vec()));
        }
        assert_eq!(base64_encode(&[0xFB, 0xFF]), b"+/8".to_vec());
    }

    #[test]
    fn base64_decoding_accepts_only_the_canonical_text() {
        // Padding, a stray length, unused bits that are not zero, other characters.
        assert_eq!(base64_decode(b"Zg=="), None);
        assert_eq!(base64_decode(b"Z"), None);
        assert_eq!(base64_decode(b"Zh"), None);
        assert_eq!(base64_decode(b"Zm9"), None);
        assert_eq!(base64_decode(b"Zm-v"), None);
        assert_eq!(base64_decode(b"Zm9v\n"), None);
        assert_eq!(base64_decode(b"Zm 9"), None);
        // Every byte string of a few lengths survives the round trip.
        let mut length = 0;
        while length < 70 {
            let bytes: Vec<u8> = (0..length).map(|i| (i * 37 + 11) as u8).collect();
            assert_eq!(base64_decode(&base64_encode(&bytes)), Some(bytes));
            length += 1;
        }
    }

    #[test]
    fn a_body_is_wrapped_at_64_columns_with_a_shorter_last_line() {
        let mut out = Vec::new();
        push_body(&mut out, &[7u8; 128]);
        let text = String::from_utf8(out).unwrap();
        let lines: Vec<&str> = text.split('\n').collect();
        assert_eq!(lines.len(), 4);
        assert_eq!(lines[0].len(), 64);
        assert_eq!(lines[1].len(), 64);
        assert_eq!(lines[2].len(), 43);
        assert_eq!(lines[3], "");
        // 48 bytes are exactly one line of 64: an empty line follows.
        let mut out = Vec::new();
        push_body(&mut out, &[7u8; 48]);
        assert_eq!(out.len(), 64 + 1 + 1);
        assert_eq!(out[64], b'\n');
        assert_eq!(out[65], b'\n');
    }

    fn sample_file(file_key: &[u8; 16]) -> Vec<u8> {
        let identity = [0x42u8; 32];
        let recipient = x25519(identity, X25519_BASEPOINT_BYTES);
        let s = x25519_stanza(file_key, &recipient, &[0x17u8; 32]).unwrap();
        seal_file(file_key, &[s], b"a payload of a few bytes", &[0x09u8; 16]).unwrap()
    }

    #[test]
    fn a_file_reads_back_and_opens() {
        let file_key = [0x5Au8; 16];
        let bytes = sample_file(&file_key);
        let file = read_file(&bytes).unwrap();
        assert_eq!(file.stanzas.len(), 1);
        assert_eq!(file.stanzas[0].kind, b"X25519".to_vec());
        let unwrapped = unwrap_x25519(&file.stanzas[0], &[0x42u8; 32]).unwrap();
        assert_eq!(unwrapped, file_key);
        assert_eq!(open_payload(&file, &file_key), Some(b"a payload of a few bytes".to_vec()));
        // Another identity, another file key.
        assert_eq!(unwrap_x25519(&file.stanzas[0], &[0x43u8; 32]), None);
        assert_eq!(open_payload(&file, &[0x5Bu8; 16]), None);
    }

    #[test]
    fn every_changed_byte_is_refused() {
        let file_key = [0x5Au8; 16];
        let bytes = sample_file(&file_key);
        let mut i = 0;
        while i < bytes.len() {
            let mut damaged = bytes.clone();
            damaged[i] ^= 0x01;
            let opened = match read_file(&damaged) {
                None => None,
                Some(file) => match unwrap_x25519(&file.stanzas[0], &[0x42u8; 32]) {
                    None => None,
                    Some(key) => open_payload(&file, &key),
                },
            };
            assert_eq!(opened, None, "a flip at byte {} was accepted", i);
            i += 1;
        }
        // Cut short, or with a byte added.
        assert!(read_file(&bytes[..bytes.len() - 1]).map(|f| open_payload(&f, &file_key)).flatten().is_none());
        let mut longer = bytes.clone();
        longer.push(0);
        assert!(read_file(&longer).map(|f| open_payload(&f, &file_key)).flatten().is_none());
    }

    #[test]
    fn a_low_order_recipient_is_refused() {
        assert_eq!(x25519_stanza(&[1u8; 16], &[0u8; 32], &[0x17u8; 32]), None);
        let mut one = [0u8; 32];
        one[0] = 1;
        assert_eq!(x25519_stanza(&[1u8; 16], &one, &[0x17u8; 32]), None);
    }

    #[test]
    fn the_header_reader_is_strict() {
        let file_key = [0x5Au8; 16];
        let good = sample_file(&file_key);
        assert!(read_file(&good).is_some());
        let text_end = good.iter().position(|c| *c == b'\n').unwrap();
        // Another version line.
        let mut other = good.clone();
        other[text_end - 1] = b'2';
        assert!(read_file(&other).is_none());
        // A carriage return before a newline.
        let mut cr = good.clone();
        cr.insert(text_end, b'\r');
        assert!(read_file(&cr).is_none());
        // No stanza at all.
        let mut none = VERSION_LINE.to_vec();
        none.extend_from_slice(b"--- ");
        none.extend_from_slice(&base64_encode(&[0u8; 32]));
        none.push(b'\n');
        none.extend_from_slice(&[0u8; 40]);
        assert!(read_file(&none).is_none());
        // Two spaces between words.
        let mut doubled = good.clone();
        let arrow = good.windows(3).position(|w| w == b"-> ").unwrap();
        doubled.insert(arrow + 9, b' ');
        assert!(read_file(&doubled).is_none());
    }

    #[test]
    fn a_tlock_stanza_has_the_published_form() {
        let s = tlock_stanza(1_000, &crate::constants::BEACON_CHAIN_HASH, &[0u8; 128]);
        let text = String::from_utf8(s).unwrap();
        assert!(text.starts_with(
            "-> tlock 1000 52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971\n"
        ));
        let lines: Vec<&str> = text.split('\n').collect();
        assert_eq!(lines.len(), 5);
        assert_eq!(lines[1].len(), 64);
        assert_eq!(lines[3].len(), 43);
    }
}
