// SPDX-License-Identifier: Apache-2.0
//! The opener's core (SD-066; chapter 03 section 11, "The opener's steps").
//!
//! One core for both openers: the command-line tool (`src/bin/safesightmac-opener.rs`)
//! and the single-file page (`opener/wasm`, compiled to WebAssembly). Everything here is
//! pure: no file, no network, no clock. The front ends read the files, fetch or take the
//! round, read their own clock for display only, and say the words.
//!
//! The steps, in the chapter's order:
//!
//! 1. `inspect`: the capsule record (layout, format version, chain, checksum) and its
//!    outer layer; the generation and the target round, and the target as a time.
//! 2. `read_round`: the target round as a mirror answers it, as its signature alone
//!    pasted in from another device, or as a round record of register 8a.
//! 3 to 5. `open_time`: the round's signature against the pinned key, "not yet", the
//!    time layer (`capsule::open_time_layer`).
//! 6. `read_recovery_key`, then `open_with_key`: the Recovery Key, then the `age` layer.
//! 7. The admin secret, with `ADMIN_ACCOUNT_NAME` and `CLAIM_WINDOW_DAYS` for the next
//!    steps.
//!
//! Nothing here decides anything a round's signature does not: a wrong clock, a hostile
//! mirror or a pasted text can only fail to open a capsule, never open one early.
//!
//! Compiled only for tests and the `opener` feature: the keeper never opens a capsule.

use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

use crate::capsule::{self, AdminSecret, OpenError, RecoveryIdentity, TimeLayerOpened};
use crate::constants::{
    BEACON_CHAIN_HASH, BEACON_GENESIS_UNIX_SECONDS, BEACON_PERIOD_SECONDS, CAPSULE_SIZE, CLAIM_WINDOW_DAYS,
};
use crate::frame::MAGIC;
use crate::records::RoundRecord;

/// The opener's version: the lock core it is built from.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The beacon mirrors the opener may ask for one public round (SD-066; chapter 03
/// section 11, "Network": one kind of request, to a beacon mirror, for one round). Each
/// answers `GET <mirror>/<chain hash>/public/<round>` with the round as JSON.
// OPEN: SQ-12 - which mirrors are on the list, and who runs them, is not decided. Working
// list: two operators of the League of Entropy's published HTTP relays, Protocol Labs
// (api.drand.sh) and Cloudflare (drand.cloudflare.com); both served quicknet with an open
// cross-origin header when this was written. A wrong or hostile mirror can only fail to
// deliver: every round is checked against the pinned key.
pub const MIRRORS: [&str; 2] = ["https://api.drand.sh", "https://drand.cloudflare.com"];

/// The full name of the hidden admin account, which the next steps name (chapter 04,
/// "Naming"; chapter 03 section 11, step 7).
// OPEN: ST-054 - how the hidden admin account is reached at the login window (it is
// hidden, so it may not be in the list of accounts) is chapter 04's, to be proven by
// ST-054. The opener's next steps say to choose "Other..." and type this name if it is
// not listed, and follow whatever ST-054 finds.
pub const ADMIN_ACCOUNT_NAME: &str = "SafeSight Mac administrator";

/// `CLAIM_WINDOW` in days, for the next steps: the time from the Mac's first start in
/// which the holder can finish leaving (SD-064).
pub const CLAIM_DAYS: u64 = CLAIM_WINDOW_DAYS;

/// The most bytes the opener reads as a round. A mirror's answer is about 200.
pub const ROUND_INPUT_MAX: usize = 16 * 1024;

/// The most bytes the opener reads as a Recovery Key. The key is 74 characters; an `age`
/// identity file with its comment lines is about 190.
pub const KEY_INPUT_MAX: usize = 4 * 1024;

/// The most bytes the opener reads as a capsule file. A capsule is exactly `CAPSULE_SIZE`.
pub const CAPSULE_INPUT_MAX: usize = CAPSULE_SIZE;

// ---------------------------------------------------------------------------------------
// The chain, in the words and numbers the front ends need
// ---------------------------------------------------------------------------------------

/// The pinned chain hash as 64 lower-case hex digits.
pub fn chain_hash_hex() -> String {
    hex_text(&BEACON_CHAIN_HASH)
}

/// The address at which `mirror` publishes `round` of the pinned chain.
pub fn round_url(mirror: &str, round: u64) -> String {
    format!("{}/{}/public/{}", mirror, chain_hash_hex(), round)
}

/// The time `round` is published, in Unix seconds: genesis plus one period per round
/// after the first. None for round 0 or a round too far away to count.
pub fn round_unix_seconds(round: u64) -> Option<u64> {
    if round == 0 {
        return None;
    }
    let after = (round - 1).checked_mul(BEACON_PERIOD_SECONDS)?;
    BEACON_GENESIS_UNIX_SECONDS.checked_add(after)
}

// ---------------------------------------------------------------------------------------
// Step 1: the capsule
// ---------------------------------------------------------------------------------------

/// What the opener shows about a capsule before anything is opened.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CapsuleInfo {
    /// Which admin secret of the Mac it holds: the first is 1.
    pub generation: u64,
    /// The one round whose signature opens its time layer.
    pub target_round: u64,
    /// When that round is published, in Unix seconds (saturated for absurd rounds).
    pub target_unix_seconds: u64,
}

/// Step 1: reads a capsule file and checks it as far as can be done without a round:
/// the record's layout, format version, chain hash and checksum, and the one `tlock`
/// stanza of its outer layer.
pub fn inspect(capsule_bytes: &[u8]) -> Result<CapsuleInfo, OpenError> {
    let (capsule, _) = capsule::read_capsule(capsule_bytes)?;
    let target_unix_seconds = match round_unix_seconds(capsule.target_round) {
        Some(t) => t,
        None => u64::MAX,
    };
    Ok(CapsuleInfo { generation: capsule.generation, target_round: capsule.target_round, target_unix_seconds })
}

// ---------------------------------------------------------------------------------------
// Step 2: the round
// ---------------------------------------------------------------------------------------

/// One round, as given to the opener. Nothing in it is trusted until `open_time` has
/// checked its signature against the pinned key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RoundInput {
    pub chain_hash: [u8; 32],
    pub round: u64,
    pub signature: [u8; 48],
    /// False when only a signature was given and the round was taken to be the target.
    pub round_named: bool,
}

impl RoundInput {
    /// The round record of register 8a that the capsule core reads.
    pub fn record(&self) -> Result<Vec<u8>, OpenError> {
        let record = RoundRecord { chain_hash: self.chain_hash, round: self.round, signature: self.signature };
        match record.encode() {
            Ok(bytes) => Ok(bytes),
            Err(e) => Err(OpenError::Round(e)),
        }
    }
}

/// Why a round was not read. Nothing is kept.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoundInputError {
    /// More than `ROUND_INPUT_MAX` bytes.
    TooLarge,
    /// Not a round in any form the opener reads.
    NotARound,
    /// A mirror's answer whose `randomness` is not the SHA-256 of its signature.
    Inconsistent,
}

/// Step 2: reads a round in any of the forms the opener accepts, in this order:
///
/// - a round record of register 8a (it starts with the frame's magic);
/// - a mirror's JSON answer: an object with `round` (an integer from 1) and `signature`
///   (96 hex digits), and if present `randomness`, which must be the SHA-256 of the
///   signature. Other members with plain values are ignored; a repeated member is refused;
/// - otherwise, exactly one run of 96 hex digits anywhere in the text: the signature alone,
///   pasted in from another device, taken to be the signature of `target_round`.
///
/// The last form is lenient on purpose (a phone's browser may show the answer laid out
/// rather than as raw text). It cannot open anything early: the signature is checked for
/// the target round against the pinned key, and any other text fails that check.
pub fn read_round(input: &[u8], target_round: u64) -> Result<RoundInput, RoundInputError> {
    if input.len() > ROUND_INPUT_MAX {
        return Err(RoundInputError::TooLarge);
    }
    if input.len() >= 4 && input[..4] == MAGIC {
        return match RoundRecord::decode(input) {
            Ok(r) => Ok(RoundInput { chain_hash: r.chain_hash, round: r.round, signature: r.signature, round_named: true }),
            Err(_) => Err(RoundInputError::NotARound),
        };
    }
    if let Some(members) = json_object(input) {
        return round_from_json(&members);
    }
    match single_signature_run(input) {
        Some(signature) => {
            if target_round == 0 {
                return Err(RoundInputError::NotARound);
            }
            Ok(RoundInput { chain_hash: BEACON_CHAIN_HASH, round: target_round, signature, round_named: false })
        }
        None => Err(RoundInputError::NotARound),
    }
}

fn round_from_json(members: &[(&[u8], JsonValue<'_>)]) -> Result<RoundInput, RoundInputError> {
    let mut round: Option<u64> = None;
    let mut signature: Option<[u8; 48]> = None;
    let mut randomness: Option<[u8; 32]> = None;
    for (name, value) in members.iter() {
        match *name {
            b"round" => match value {
                JsonValue::Integer(n) if *n >= 1 => round = Some(*n),
                _ => return Err(RoundInputError::NotARound),
            },
            b"signature" => match value {
                JsonValue::Text(t) => {
                    let mut out = [0u8; 48];
                    if !hex_into(t, &mut out) {
                        return Err(RoundInputError::NotARound);
                    }
                    signature = Some(out);
                }
                _ => return Err(RoundInputError::NotARound),
            },
            b"randomness" => match value {
                JsonValue::Text(t) => {
                    let mut out = [0u8; 32];
                    if !hex_into(t, &mut out) {
                        return Err(RoundInputError::NotARound);
                    }
                    randomness = Some(out);
                }
                _ => return Err(RoundInputError::NotARound),
            },
            _ => {}
        }
    }
    let (round, signature) = match (round, signature) {
        (Some(r), Some(s)) => (r, s),
        _ => return Err(RoundInputError::NotARound),
    };
    if let Some(r) = randomness {
        let digest = Sha256::digest(signature);
        if digest.as_slice() != &r[..] {
            return Err(RoundInputError::Inconsistent);
        }
    }
    Ok(RoundInput { chain_hash: BEACON_CHAIN_HASH, round, signature, round_named: true })
}

/// The one run of exactly 96 hex digits in the text, if there is exactly one (repeats of
/// the same run count once). Runs of other lengths, such as the 64 digits of the
/// randomness, are ignored.
fn single_signature_run(input: &[u8]) -> Option<[u8; 48]> {
    let mut found: Option<[u8; 48]> = None;
    let mut i = 0;
    while i < input.len() {
        if !input[i].is_ascii_hexdigit() {
            i += 1;
            continue;
        }
        let start = i;
        while i < input.len() && input[i].is_ascii_hexdigit() {
            i += 1;
        }
        // A run that touches a letter or digit is part of a longer word, not a signature.
        let before_ok = start == 0 || !input[start - 1].is_ascii_alphanumeric();
        let after_ok = i == input.len() || !input[i].is_ascii_alphanumeric();
        if i - start == 96 && before_ok && after_ok {
            let mut sig = [0u8; 48];
            if !hex_into(&input[start..i], &mut sig) {
                return None;
            }
            match found {
                Some(previous) if previous != sig => return None,
                _ => found = Some(sig),
            }
        }
    }
    found
}

// ----- A strict reader for the one JSON shape a mirror answers with -----

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum JsonValue<'a> {
    /// A string with no escapes.
    Text(&'a [u8]),
    /// A non-negative integer that fits 64 bits.
    Integer(u64),
    /// `true`, `false` or `null`.
    Word,
}

struct Cursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn skip_space(&mut self) {
        while self.pos < self.bytes.len() && matches!(self.bytes[self.pos], b' ' | b'\t' | b'\n' | b'\r') {
            self.pos += 1;
        }
    }

    fn eat(&mut self, c: u8) -> bool {
        if self.pos < self.bytes.len() && self.bytes[self.pos] == c {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn text(&mut self) -> Option<&'a [u8]> {
        if !self.eat(b'"') {
            return None;
        }
        let start = self.pos;
        while self.pos < self.bytes.len() {
            let c = self.bytes[self.pos];
            if c == b'"' {
                let out = &self.bytes[start..self.pos];
                self.pos += 1;
                return Some(out);
            }
            // No escapes and no control characters: a mirror's answer has neither.
            if c == b'\\' || c < 0x20 {
                return None;
            }
            self.pos += 1;
        }
        None
    }

    fn integer(&mut self) -> Option<u64> {
        let start = self.pos;
        let mut value: u64 = 0;
        while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_digit() {
            let digit = (self.bytes[self.pos] - b'0') as u64;
            value = value.checked_mul(10)?.checked_add(digit)?;
            self.pos += 1;
        }
        let len = self.pos - start;
        if len == 0 || (len > 1 && self.bytes[start] == b'0') {
            return None;
        }
        Some(value)
    }

    fn word(&mut self) -> bool {
        for w in [&b"true"[..], &b"false"[..], &b"null"[..]].iter() {
            if self.bytes.len() - self.pos >= w.len() && &self.bytes[self.pos..self.pos + w.len()] == *w {
                self.pos += w.len();
                return true;
            }
        }
        false
    }

    fn value(&mut self) -> Option<JsonValue<'a>> {
        if self.pos >= self.bytes.len() {
            return None;
        }
        match self.bytes[self.pos] {
            b'"' => Some(JsonValue::Text(self.text()?)),
            b'0'..=b'9' => Some(JsonValue::Integer(self.integer()?)),
            _ => {
                if self.word() {
                    Some(JsonValue::Word)
                } else {
                    None
                }
            }
        }
    }
}

/// A JSON object of plain values, read strictly: strings without escapes, non-negative
/// integers, `true`, `false`, `null`. Anything else, a repeated name or trailing text is
/// None.
fn json_object(input: &[u8]) -> Option<Vec<(&[u8], JsonValue<'_>)>> {
    let mut c = Cursor { bytes: input, pos: 0 };
    c.skip_space();
    if !c.eat(b'{') {
        return None;
    }
    let mut members: Vec<(&[u8], JsonValue<'_>)> = Vec::new();
    c.skip_space();
    if !c.eat(b'}') {
        loop {
            c.skip_space();
            let name = c.text()?;
            c.skip_space();
            if !c.eat(b':') {
                return None;
            }
            c.skip_space();
            let value = c.value()?;
            if members.iter().any(|(n, _)| *n == name) {
                return None;
            }
            members.push((name, value));
            if members.len() > 16 {
                return None;
            }
            c.skip_space();
            if c.eat(b',') {
                continue;
            }
            if c.eat(b'}') {
                break;
            }
            return None;
        }
    }
    c.skip_space();
    if c.pos != input.len() {
        return None;
    }
    Some(members)
}

// ---------------------------------------------------------------------------------------
// Steps 3 to 5: the round's check and the time layer
// ---------------------------------------------------------------------------------------

/// Steps 3 to 5: checks the round's signature against the pinned key, refuses a round
/// before the target ("not yet") or after it, and opens the time layer.
pub fn open_time(capsule_bytes: &[u8], round: &RoundInput) -> Result<TimeLayerOpened, OpenError> {
    let record = round.record()?;
    capsule::open_time_layer(capsule_bytes, &record)
}

// ---------------------------------------------------------------------------------------
// Step 6: the Recovery Key
// ---------------------------------------------------------------------------------------

/// Why a Recovery Key was refused. Nothing of what was typed is kept.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyError {
    /// Nothing was given.
    Empty,
    /// The public half was given (it starts `age1`), not the Recovery Key.
    PublicHalf,
    /// Not shaped like a Recovery Key at all.
    NotAKey,
    /// Shaped like one, but a character is wrong, missing or extra: its check characters
    /// do not match.
    Typo,
}

/// The fixed opening of a Recovery Key, as `age` writes it (chapter 03 section 10).
pub const KEY_OPENING: &str = "AGE-SECRET-KEY-1";

/// The human-readable part of the key's Bech32 text (BIP-173), lower case.
const KEY_HRP: &[u8] = b"age-secret-key-";
/// The human-readable part of the public half's text.
const PUBLIC_HRP: &[u8] = b"age";
/// The Bech32 alphabet.
const BECH32_CHARSET: &[u8; 32] = b"qpzry9x8gf2tvdw0s3jn54khce6mua7l";
/// Characters of a key after its opening: 52 for the 32 bytes, 6 for the check.
const KEY_DATA_CHARS: usize = 58;

fn bech32_polymod(values: &[u8]) -> u32 {
    const GENERATOR: [u32; 5] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3];
    let mut check: u32 = 1;
    for v in values.iter() {
        let top = check >> 25;
        check = ((check & 0x01ff_ffff) << 5) ^ (*v as u32);
        let mut i = 0;
        while i < 5 {
            if (top >> i) & 1 == 1 {
                check ^= GENERATOR[i];
            }
            i += 1;
        }
    }
    check
}

/// The values the Bech32 check runs over: the human-readable part expanded, then the
/// data. Wiped when dropped, since for a key the data is the key.
fn bech32_check_input(hrp: &[u8], data: &[u8]) -> Zeroizing<Vec<u8>> {
    let mut values = Zeroizing::new(Vec::with_capacity(hrp.len() * 2 + 1 + data.len() + 6));
    for c in hrp.iter() {
        values.push(c >> 5);
    }
    values.push(0);
    for c in hrp.iter() {
        values.push(c & 31);
    }
    values.extend_from_slice(data);
    values
}

/// Bech32 text (BIP-173), lower case, of `bytes` under `hrp` (lower case).
fn bech32_encode(hrp: &[u8], bytes: &[u8]) -> Zeroizing<Vec<u8>> {
    let mut data = Zeroizing::new(Vec::with_capacity(bytes.len() * 8 / 5 + 1));
    let mut acc: u32 = 0;
    let mut bits = 0;
    for b in bytes.iter() {
        acc = (acc << 8) | (*b as u32);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            data.push(((acc >> bits) & 31) as u8);
        }
        acc &= (1 << bits) - 1;
    }
    if bits > 0 {
        data.push(((acc << (5 - bits)) & 31) as u8);
    }
    acc.zeroize();
    let mut values = bech32_check_input(hrp, &data);
    values.extend_from_slice(&[0u8; 6]);
    let check = bech32_polymod(&values) ^ 1;
    let mut out = Zeroizing::new(Vec::with_capacity(hrp.len() + 1 + data.len() + 6));
    out.extend_from_slice(hrp);
    out.push(b'1');
    for v in data.iter() {
        out.push(BECH32_CHARSET[*v as usize]);
    }
    let mut i = 0;
    while i < 6 {
        out.push(BECH32_CHARSET[((check >> (5 * (5 - i))) & 31) as usize]);
        i += 1;
    }
    out
}

/// The Recovery Key's text form, as `age` writes it: `AGE-SECRET-KEY-1` and 58 more
/// characters, upper case. For the app that makes the key (chapter 03 section 10) and for
/// tests; the opener itself only reads keys.
pub fn recovery_key_text(identity: &RecoveryIdentity) -> Zeroizing<String> {
    let mut lower = bech32_encode(KEY_HRP, identity.scalar());
    lower.make_ascii_uppercase();
    let mut text = Zeroizing::new(String::with_capacity(lower.len()));
    for c in lower.iter() {
        text.push(*c as char);
    }
    text
}

/// The public half's text form, as `age` writes it: `age1` and 58 more characters.
pub fn public_key_text(identity: &RecoveryIdentity) -> String {
    let lower = bech32_encode(PUBLIC_HRP, &identity.public().0);
    lower.iter().map(|c| *c as char).collect()
}

/// Step 6: reads the Recovery Key as the owner pastes or types it: one `age` X25519
/// identity, `AGE-SECRET-KEY-1...` (chapter 03 section 10; SD-063).
///
/// Forgiving where that cannot open anything wrongly: spaces, tabs and line breaks
/// anywhere are dropped (a password manager may wrap the line); lines starting with `#`
/// are skipped (as in a key file written by `age-keygen`); all upper or all lower case
/// is accepted (BIP-173). Strict where it matters: the opening, the length, the alphabet,
/// the six check characters and the unused padding bits. Every copy of the key made here
/// is wiped.
pub fn read_recovery_key(text: &[u8]) -> Result<RecoveryIdentity, KeyError> {
    if text.len() > KEY_INPUT_MAX {
        return Err(KeyError::NotAKey);
    }
    let mut compact: Zeroizing<Vec<u8>> = Zeroizing::new(Vec::with_capacity(text.len()));
    let mut at_line_start = true;
    let mut in_comment = false;
    for c in text.iter() {
        if *c == b'\n' || *c == b'\r' {
            at_line_start = true;
            in_comment = false;
            continue;
        }
        if in_comment {
            continue;
        }
        if c.is_ascii_whitespace() {
            continue;
        }
        if at_line_start && *c == b'#' {
            in_comment = true;
            continue;
        }
        at_line_start = false;
        if !c.is_ascii_graphic() {
            return Err(KeyError::NotAKey);
        }
        compact.push(*c);
    }
    if compact.is_empty() {
        return Err(KeyError::Empty);
    }
    let has_upper = compact.iter().any(|c| c.is_ascii_uppercase());
    let has_lower = compact.iter().any(|c| c.is_ascii_lowercase());
    let mut lower = compact.clone();
    lower.make_ascii_lowercase();

    if !lower.starts_with(b"age-secret-key-") {
        if lower.starts_with(b"age1") {
            return Err(KeyError::PublicHalf);
        }
        return Err(KeyError::NotAKey);
    }
    // A key of another kind (for example a post-quantum `AGE-SECRET-KEY-PQ-1...`).
    if lower.len() <= KEY_HRP.len() || lower[KEY_HRP.len()] != b'1' {
        return Err(KeyError::NotAKey);
    }
    // From here on it is meant to be a Recovery Key: anything wrong is a typing mistake.
    if has_upper && has_lower {
        return Err(KeyError::Typo);
    }
    let data_text = &lower[KEY_HRP.len() + 1..];
    if data_text.len() != KEY_DATA_CHARS {
        return Err(KeyError::Typo);
    }
    let mut data: Zeroizing<Vec<u8>> = Zeroizing::new(Vec::with_capacity(KEY_DATA_CHARS));
    for c in data_text.iter() {
        match BECH32_CHARSET.iter().position(|x| x == c) {
            Some(v) => data.push(v as u8),
            None => return Err(KeyError::Typo),
        }
    }
    if bech32_polymod(&bech32_check_input(KEY_HRP, &data)) != 1 {
        return Err(KeyError::Typo);
    }
    // 52 values of 5 bits: 32 bytes and 4 padding bits, which must be zero.
    let mut scalar = Zeroizing::new([0u8; 32]);
    let mut acc: u32 = 0;
    let mut bits = 0;
    let mut n = 0;
    for v in data[..KEY_DATA_CHARS - 6].iter() {
        acc = (acc << 5) | (*v as u32);
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            if n >= 32 {
                return Err(KeyError::Typo);
            }
            scalar[n] = ((acc >> bits) & 0xFF) as u8;
            n += 1;
        }
        acc &= (1 << bits) - 1;
    }
    let padding_is_zero = acc == 0;
    acc.zeroize();
    if n != 32 || bits != 4 || !padding_is_zero {
        return Err(KeyError::Typo);
    }
    Ok(RecoveryIdentity::from_bytes(*scalar))
}

/// Steps 6 and 7: opens the `age` layer with the Recovery Key and returns the admin
/// secret, which the front end shows once and then wipes.
pub fn open_with_key(opened: &TimeLayerOpened, identity: &RecoveryIdentity) -> Result<AdminSecret, OpenError> {
    capsule::open_recovery_layer(opened, identity)
}

// ---------------------------------------------------------------------------------------
// Words and numbers for the command-line tool (the page uses the browser's own)
// ---------------------------------------------------------------------------------------

/// A number with thousands separated by commas: 12,345,678.
pub fn grouped(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// A Unix time as a plain date in UTC: "Wednesday 23 August 2023 at 15:59 UTC".
pub fn utc_date_text(unix_seconds: u64) -> String {
    const DAYS: [&str; 7] = ["Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday"];
    const MONTHS: [&str; 12] = [
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ];
    // Far beyond any real target: say so rather than print a meaningless year.
    if unix_seconds > 253_402_300_799 {
        return String::from("a date after the year 9999");
    }
    let days = unix_seconds / 86_400;
    let rest = unix_seconds % 86_400;
    let (year, month, day) = civil_from_days(days);
    format!(
        "{} {} {} {} at {:02}:{:02} UTC",
        DAYS[(days % 7) as usize],
        day,
        MONTHS[(month - 1) as usize],
        year,
        rest / 3_600,
        (rest % 3_600) / 60
    )
}

/// Days since 1970-01-01 to (year, month, day), for the proleptic Gregorian calendar
/// (H. Hinnant's `civil_from_days`, for days from 0).
fn civil_from_days(days: u64) -> (u64, u64, u64) {
    let z = days + 719_468;
    let era = z / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 };
    (year, month, day)
}

/// A length of time in rough plain words: "about 3 days", "about 5 hours".
pub fn rough_wait_text(seconds: u64) -> String {
    const MINUTE: u64 = 60;
    const HOUR: u64 = 3_600;
    const DAY: u64 = 86_400;
    fn count(n: u64, one: &str, many: &str) -> String {
        if n == 1 {
            format!("about 1 {}", one)
        } else {
            format!("about {} {}", grouped(n), many)
        }
    }
    if seconds < 2 * MINUTE {
        return String::from("a minute or two");
    }
    if seconds < 2 * HOUR {
        return count((seconds + MINUTE / 2) / MINUTE, "minute", "minutes");
    }
    if seconds < 2 * DAY {
        return count((seconds + HOUR / 2) / HOUR, "hour", "hours");
    }
    if seconds < 120 * DAY {
        return count((seconds + DAY / 2) / DAY, "day", "days");
    }
    if seconds < 730 * DAY {
        return count((seconds + 15 * DAY) / (30 * DAY), "month", "months");
    }
    count((seconds + 182 * DAY) / (365 * DAY), "year", "years")
}

fn hex_text(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes.iter() {
        text.push_str(&format!("{:02x}", byte));
    }
    text
}

/// Fills `out` from exactly `2 * out.len()` hex digits, either case.
fn hex_into(text: &[u8], out: &mut [u8]) -> bool {
    if text.len() != out.len() * 2 {
        return false;
    }
    let mut i = 0;
    while i < out.len() {
        let high = match hex_value(text[2 * i]) {
            Some(v) => v,
            None => return false,
        };
        let low = match hex_value(text[2 * i + 1]) {
            Some(v) => v,
            None => return false,
        };
        out[i] = (high << 4) | low;
        i += 1;
    }
    true
}

fn hex_value(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::beacon::vectors::{hex, record_bytes, signature, unhex};
    use crate::capsule::{seal, RecoveryRecipients};
    use crate::clock::wall_clock_round;
    use crate::constants::BEACON_MIRRORS_MIN;
    use crate::fakes::SeededRandom;
    use crate::frame::{reseal, RecordError};
    use crate::records::Capsule;

    /// The stored version 1 capsules and the real rounds (ST-072).
    const VECTORS: &str = include_str!("../../opener/vectors/v1.txt");

    struct StoredCopy {
        name: String,
        generation: u64,
        target: u64,
        seed: u8,
        key: [u8; 32],
        other_key: [u8; 32],
        secret: String,
        sha256: String,
        bytes: Vec<u8>,
    }

    fn base64(text: &str) -> Vec<u8> {
        let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = Vec::new();
        let mut acc: u32 = 0;
        let mut bits = 0;
        for c in text.bytes() {
            if c == b'=' {
                break;
            }
            let v = alphabet.iter().position(|x| *x == c).expect("base64") as u32;
            acc = (acc << 6) | v;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                out.push(((acc >> bits) & 0xFF) as u8);
            }
        }
        out
    }

    fn key32(text: &str) -> [u8; 32] {
        let bytes = unhex(text);
        let mut out = [0u8; 32];
        out.copy_from_slice(&bytes);
        out
    }

    fn stored() -> Vec<StoredCopy> {
        let mut out = Vec::new();
        let mut current: Option<StoredCopy> = None;
        for line in VECTORS.lines() {
            if line.starts_with('#') || line.is_empty() {
                continue;
            }
            let (name, value) = line.split_once(' ').unwrap_or((line, ""));
            match name {
                "capsule" => {
                    current = Some(StoredCopy {
                        name: value.to_string(),
                        generation: 0,
                        target: 0,
                        seed: 0,
                        key: [0; 32],
                        other_key: [0; 32],
                        secret: String::new(),
                        sha256: String::new(),
                        bytes: Vec::new(),
                    })
                }
                "end" => out.push(current.take().unwrap()),
                "round" => {}
                _ => {
                    let c = current.as_mut().unwrap();
                    match name {
                        "generation" => c.generation = value.parse().unwrap(),
                        "target" => c.target = value.parse().unwrap(),
                        "sealed-with" => c.seed = value.trim_start_matches("seed ").parse().unwrap(),
                        "key" => c.key = key32(value),
                        "other-key" => c.other_key = key32(value),
                        "secret" => c.secret = value.to_string(),
                        "sha256" => c.sha256 = value.to_string(),
                        "base64" => c.bytes = base64(value),
                        other => panic!("unknown vector line {}", other),
                    }
                }
            }
        }
        assert!(current.is_none());
        out
    }

    /// A mirror's answer for one of the real rounds, as stored.
    fn mirror_answer(round: u64) -> String {
        for line in VECTORS.lines() {
            if let Some(rest) = line.strip_prefix("round ") {
                let (r, json) = rest.split_once(' ').unwrap();
                if r.parse::<u64>().unwrap() == round {
                    return json.to_string();
                }
            }
        }
        panic!("no stored answer for round {}", round);
    }

    fn sha256_hex(bytes: &[u8]) -> String {
        hex(Sha256::digest(bytes).as_slice())
    }

    /// The made-up secret and keys of the stored vectors, from the seeded source.
    fn seeded_inputs() -> (AdminSecret, RecoveryIdentity, RecoveryIdentity) {
        use crate::boundary::RandomSource;
        let alphabet = b"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
        let mut source = SeededRandom::new(200);
        let mut raw = [0u8; 40];
        source.fill(&mut raw).unwrap();
        let text: Vec<u8> = raw.iter().map(|b| alphabet[(*b as usize) % alphabet.len()]).collect();
        let mut first = [0u8; 32];
        source.fill(&mut first).unwrap();
        let mut second = [0u8; 32];
        source.fill(&mut second).unwrap();
        (
            AdminSecret::from_bytes(&text).unwrap(),
            RecoveryIdentity::from_bytes(first),
            RecoveryIdentity::from_bytes(second),
        )
    }

    // ----- ST-072: the stored version 1 capsules -----

    #[test]
    fn every_stored_version_1_capsule_opens_with_its_key_and_round() {
        let all = stored();
        assert!(!all.is_empty());
        for c in all.iter() {
            assert_eq!(c.bytes.len(), CAPSULE_SIZE, "{}", c.name);
            assert_eq!(sha256_hex(&c.bytes), c.sha256, "{}", c.name);
            let info = inspect(&c.bytes).unwrap();
            assert_eq!(info.generation, c.generation);
            assert_eq!(info.target_round, c.target);

            // The whole path a front end takes: the mirror's answer, the key's text.
            let round = read_round(mirror_answer(c.target).as_bytes(), info.target_round).unwrap();
            let opened = open_time(&c.bytes, &round).unwrap();
            assert_eq!(opened.generation(), c.generation);
            let text = recovery_key_text(&RecoveryIdentity::from_bytes(c.key));
            let identity = read_recovery_key(text.as_bytes()).unwrap();
            let secret = open_with_key(&opened, &identity).unwrap();
            assert_eq!(secret.reveal(), c.secret.as_bytes(), "{}", c.name);

            // The other made-up key opens nothing.
            let other = RecoveryIdentity::from_bytes(c.other_key);
            assert_eq!(open_with_key(&opened, &other).err(), Some(OpenError::NotForThisKey));
        }
    }

    // The stored capsule was put together from the independent implementation's output.
    // The keeper's own seal makes the same bytes from the same draws.
    #[test]
    fn the_keeper_seals_the_stored_capsule_byte_for_byte() {
        let (secret, first, _) = seeded_inputs();
        let c = &stored()[0];
        assert_eq!(c.name, "one-key-round-1000");
        assert_eq!(c.key, *first.scalar());
        assert_eq!(c.secret.as_bytes(), secret.reveal());
        let recipients = RecoveryRecipients { current: first.public(), overlap: None };
        let made = seal(&secret, &recipients, c.generation, c.target, &mut SeededRandom::new(c.seed)).unwrap();
        assert_eq!(made.encode().unwrap(), c.bytes);
    }

    // ----- Step 1 -----

    #[test]
    fn inspecting_names_the_generation_and_the_target_time() {
        let c = &stored()[0];
        let info = inspect(&c.bytes).unwrap();
        assert_eq!(info, CapsuleInfo { generation: 3, target_round: 1_000, target_unix_seconds: 1_692_806_364 });
        assert_eq!(utc_date_text(info.target_unix_seconds), "Wednesday 23 August 2023 at 15:59 UTC");
    }

    #[test]
    fn inspecting_refuses_what_is_not_a_good_capsule() {
        let good = stored()[0].bytes.clone();
        assert_eq!(inspect(&[]).err(), Some(OpenError::Capsule(RecordError::TooShort)));
        assert_eq!(inspect(b"not a capsule at all, just some text").err(), Some(OpenError::Capsule(RecordError::BadMagic)));
        assert_eq!(inspect(&good[..4_000]).err(), Some(OpenError::Capsule(RecordError::WrongLength)));
        assert_eq!(inspect(&record_bytes(1_000)).err(), Some(OpenError::Capsule(RecordError::WrongType)));

        let mut torn = good.clone();
        torn[300] ^= 0x10;
        assert_eq!(inspect(&torn).err(), Some(OpenError::Capsule(RecordError::BadChecksum)));

        // A newer format version: "update needed", not "damaged".
        let mut newer = good.clone();
        newer[6] = 2;
        reseal(&mut newer);
        assert_eq!(inspect(&newer).err(), Some(OpenError::Capsule(RecordError::UpdateNeeded)));

        // Another chain, and a target in the clear that is not the round inside.
        let mut capsule = Capsule::decode(&good).unwrap();
        capsule.chain_hash = [9u8; 32];
        assert_eq!(inspect(&capsule.encode().unwrap()).err(), Some(OpenError::OtherChain));
        let mut capsule = Capsule::decode(&good).unwrap();
        capsule.target_round = 1_001;
        assert_eq!(inspect(&capsule.encode().unwrap()).err(), Some(OpenError::Layout));

        // A changed byte in the outer header with the checksum put right.
        let mut changed = good.clone();
        changed[crate::frame::HEADER_LEN + 8 + 8 + 32 + 2 + 30] ^= 0x01;
        reseal(&mut changed);
        assert!(inspect(&changed).is_err());
    }

    // ----- Step 2 -----

    #[test]
    fn a_mirror_answer_reads_in_either_mirror_layout() {
        let api = mirror_answer(1_000);
        let r = read_round(api.as_bytes(), 1_000).unwrap();
        assert_eq!(r, RoundInput { chain_hash: BEACON_CHAIN_HASH, round: 1_000, signature: signature(1_000), round_named: true });

        // Cloudflare's order, spaces and line breaks, upper-case hex, an extra member.
        let sig = hex(&signature(1_001));
        let rnd = sha256_hex(&signature(1_001));
        let cloudflare = format!("{{\"round\":1001,\"signature\":\"{}\",\"randomness\":\"{}\"}}", sig, rnd);
        assert_eq!(read_round(cloudflare.as_bytes(), 1_000).unwrap().round, 1_001);
        let spaced = format!("\n  {{ \"round\" : 1001 ,\n \"signature\" : \"{}\", \"x\": null, \"y\": true }}\n", sig.to_uppercase());
        assert_eq!(read_round(spaced.as_bytes(), 1_000).unwrap().signature, signature(1_001));
        // drand's newer answer has no randomness.
        let v2 = format!("{{\"round\":1001,\"signature\":\"{}\"}}", sig);
        assert_eq!(read_round(v2.as_bytes(), 7).unwrap().round, 1_001);
    }

    #[test]
    fn a_signature_alone_is_taken_for_the_target_round() {
        let sig = hex(&signature(1_000));
        for text in [
            sig.clone(),
            format!("  {}\n", sig),
            sig.to_uppercase(),
            // As a phone's browser may lay the answer out.
            format!("round: 1000\nrandomness: {}\nsignature: {}\n", sha256_hex(&signature(1_000)), sig),
            format!("{}\n{}", sig, sig),
        ]
        .iter()
        {
            let r = read_round(text.as_bytes(), 1_000).unwrap();
            assert_eq!(r.round, 1_000);
            assert_eq!(r.signature, signature(1_000));
            assert!(!r.round_named);
        }
        // Two different signatures, a run of another length, or one inside a longer word.
        let two = format!("{} {}", sig, hex(&signature(1_001)));
        assert_eq!(read_round(two.as_bytes(), 1_000).err(), Some(RoundInputError::NotARound));
        assert_eq!(read_round(sig[..94].as_bytes(), 1_000).err(), Some(RoundInputError::NotARound));
        let word = format!("x{}", sig);
        assert_eq!(read_round(word.as_bytes(), 1_000).err(), Some(RoundInputError::NotARound));
        assert_eq!(read_round(sig.as_bytes(), 0).err(), Some(RoundInputError::NotARound));
    }

    #[test]
    fn a_round_record_reads_as_itself() {
        let r = read_round(&record_bytes(12_345_678), 1_000).unwrap();
        assert_eq!(r.round, 12_345_678);
        assert!(r.round_named);
        let mut torn = record_bytes(1_000);
        torn[20] ^= 1;
        assert_eq!(read_round(&torn, 1_000).err(), Some(RoundInputError::NotARound));
    }

    #[test]
    fn what_is_not_a_round_is_refused() {
        let sig = hex(&signature(1_000));
        assert_eq!(read_round(b"", 1_000).err(), Some(RoundInputError::NotARound));
        assert_eq!(read_round(b"Requested future beacon", 1_000).err(), Some(RoundInputError::NotARound));
        assert_eq!(read_round(b"{}", 1_000).err(), Some(RoundInputError::NotARound));
        assert_eq!(read_round(&vec![b' '; ROUND_INPUT_MAX + 1], 1_000).err(), Some(RoundInputError::TooLarge));
        // JSON that names round 0, or a signature of the wrong length.
        let zero = format!("{{\"round\":0,\"signature\":\"{}\"}}", sig);
        assert_eq!(read_round(zero.as_bytes(), 1_000).err(), Some(RoundInputError::NotARound));
        let short = format!("{{\"round\":1000,\"signature\":\"{}\"}}", &sig[..90]);
        assert_eq!(read_round(short.as_bytes(), 1_000).err(), Some(RoundInputError::NotARound));
        // A mirror answer whose randomness does not match its signature.
        let mismatched = format!("{{\"round\":1000,\"randomness\":\"{}\",\"signature\":\"{}\"}}", sha256_hex(b"x"), sig);
        assert_eq!(read_round(mismatched.as_bytes(), 1_000).err(), Some(RoundInputError::Inconsistent));
        // A repeated member is not a mirror's answer; with two signatures nothing is taken.
        let repeated = format!("{{\"round\":1000,\"signature\":\"{}\",\"signature\":\"{}\"}}", sig, hex(&signature(1_001)));
        assert_eq!(read_round(repeated.as_bytes(), 1_000).err(), Some(RoundInputError::NotARound));
        // JSON with a nested value or an escape is not read as JSON.
        assert!(json_object(br#"{"round":1000,"a":{"b":1}}"#).is_none());
        let escaped = [&br#"{"round":1000,"a":""#[..], &[0x5C][..], &br#"u0041"}"#[..]].concat();
        assert_eq!(escaped[19], b'\\');
        assert!(json_object(&escaped).is_none());
        assert!(json_object(br#"{"round":01000}"#).is_none());
        assert!(json_object(br#"{"round":18446744073709551616}"#).is_none());
        assert!(json_object(br#"{"round":1000} x"#).is_none());
        assert_eq!(json_object(br#" { } "#).unwrap().len(), 0);
    }

    // ----- Steps 3 to 5 -----

    #[test]
    fn the_time_layer_opens_only_with_the_target_round() {
        let c = &stored()[0];
        assert!(open_time(&c.bytes, &read_round(mirror_answer(1_000).as_bytes(), 1_000).unwrap()).is_ok());
        let bare = hex(&signature(1_000));
        assert!(open_time(&c.bytes, &read_round(bare.as_bytes(), 1_000).unwrap()).is_ok());

        // An earlier real round: not yet. A later one: the wrong round.
        let early = read_round(mirror_answer(1).as_bytes(), 1_000).unwrap();
        assert_eq!(open_time(&c.bytes, &early).err(), Some(OpenError::NotYet { target_round: 1_000 }));
        let late = read_round(mirror_answer(1_001).as_bytes(), 1_000).unwrap();
        assert_eq!(open_time(&c.bytes, &late).err(), Some(OpenError::WrongRound));

        // Round 1000 claimed with round 1001's signature; a bare signature of another round.
        let forged = format!("{{\"round\":1000,\"signature\":\"{}\"}}", hex(&signature(1_001)));
        let forged = read_round(forged.as_bytes(), 1_000).unwrap();
        assert_eq!(open_time(&c.bytes, &forged).err(), Some(OpenError::BadRoundSignature));
        let bare_other = read_round(hex(&signature(1_001)).as_bytes(), 1_000).unwrap();
        assert_eq!(open_time(&c.bytes, &bare_other).err(), Some(OpenError::BadRoundSignature));

        // A round record of another chain.
        let other = RoundRecord { chain_hash: [5u8; 32], round: 1_000, signature: signature(1_000) };
        let other = read_round(&other.encode().unwrap(), 1_000).unwrap();
        assert_eq!(open_time(&c.bytes, &other).err(), Some(OpenError::OtherChain));
    }

    #[test]
    fn a_capsule_sealed_to_a_later_round_waits_for_it() {
        let (secret, first, second) = seeded_inputs();
        let two = RecoveryRecipients { current: first.public(), overlap: Some(second.public()) };
        let bytes = seal(&secret, &two, 8, 12_345_678, &mut SeededRandom::new(41)).unwrap().encode().unwrap();
        let info = inspect(&bytes).unwrap();
        assert_eq!(utc_date_text(info.target_unix_seconds), "Friday 25 October 2024 at 07:13 UTC");
        for earlier in [1u64, 1_000, 1_001].iter() {
            let r = read_round(mirror_answer(*earlier).as_bytes(), info.target_round).unwrap();
            assert_eq!(open_time(&bytes, &r).err(), Some(OpenError::NotYet { target_round: 12_345_678 }));
        }
        let r = read_round(mirror_answer(12_345_678).as_bytes(), info.target_round).unwrap();
        let opened = open_time(&bytes, &r).unwrap();
        // During an overlap, either key opens it.
        assert!(open_with_key(&opened, &first).unwrap().same_as(&secret));
        assert!(open_with_key(&opened, &second).unwrap().same_as(&secret));
        let stranger = RecoveryIdentity::from_bytes([0x44u8; 32]);
        assert_eq!(open_with_key(&opened, &stranger).err(), Some(OpenError::NotForThisKey));
        assert_eq!(format!("{:?}", opened), "TimeLayerOpened(generation 8, round 12345678)");
    }

    // ----- Step 6 -----

    // BIP-173's valid strings, read with the same check the key reader uses.
    #[test]
    fn the_bech32_check_matches_bip_173() {
        let valid = [
            "A12UEL5L",
            "a12uel5l",
            "an83characterlonghumanreadablepartthatcontainsthenumber1andtheexcludedcharactersbio1tt5tgs",
            "abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw",
            "split1checkupstagehandshakeupstreamerranterredcaperred2y9e3w",
            "?1ezyfcl",
        ];
        for text in valid.iter() {
            let lower = text.to_ascii_lowercase();
            let sep = lower.rfind('1').unwrap();
            let data: Vec<u8> = lower[sep + 1..]
                .bytes()
                .map(|c| BECH32_CHARSET.iter().position(|x| *x == c).unwrap() as u8)
                .collect();
            assert_eq!(bech32_polymod(&bech32_check_input(lower[..sep].as_bytes(), &data)), 1, "{}", text);
            // One changed data character breaks the check.
            let mut changed = data.clone();
            changed[0] ^= 1;
            assert_ne!(bech32_polymod(&bech32_check_input(lower[..sep].as_bytes(), &changed)), 1, "{}", text);
        }
        // The encoder gives the reference's text for the same data.
        assert_eq!(&bech32_encode(b"a", &[])[..], b"a12uel5l");
    }

    // Known answers for the made-up first key of the vectors, made by a separate Bech32
    // implementation (BIP-173's reference, in Python), as `age` writes keys.
    #[test]
    fn the_key_text_is_the_one_age_writes() {
        let c = &stored()[0];
        let identity = RecoveryIdentity::from_bytes(c.key);
        let expected = [KEY_OPENING, "69MN9RV926XQU0GKMZYVXHCAXTE6Z4AML5H5QRMNJZQ9RKWH8WZQGAGEVX"].concat();
        assert_eq!(recovery_key_text(&identity).as_str(), expected);
        assert_eq!(expected.len(), 74);
        assert_eq!(public_key_text(&identity), "age1x7gep5wumjutg2tp5lhj5t6d74vaxs4dk9nhcddjdld7p5mgwgmsfdgr3x");
        assert_eq!(hex(&identity.public().0), "379190d1dcdcb8b42961a7ef2a2f4df559d342adb1677c35b26fdbe0d3687237");
    }

    #[test]
    fn a_recovery_key_reads_as_it_is_pasted() {
        let c = &stored()[0];
        let text = recovery_key_text(&RecoveryIdentity::from_bytes(c.key));
        let public = public_key_text(&RecoveryIdentity::from_bytes(c.key));
        let forms = [
            text.to_string(),
            format!("  {}\n", text.as_str()),
            text.to_lowercase(),
            // Wrapped by a password manager.
            format!("{}\n{}", &text[..40], &text[40..]),
            format!("{} {}", &text[..20], &text[20..]),
            // A key file as `age-keygen` writes it.
            format!("# created: 2026-11-19T00:00:00Z\n# public key: {}\n{}\n", public, text.as_str()),
        ];
        for form in forms.iter() {
            let identity = read_recovery_key(form.as_bytes()).unwrap();
            assert_eq!(identity.public(), RecoveryIdentity::from_bytes(c.key).public());
        }
    }

    #[test]
    fn a_wrong_recovery_key_is_named_plainly() {
        let c = &stored()[0];
        let text = recovery_key_text(&RecoveryIdentity::from_bytes(c.key)).to_string();
        let public = public_key_text(&RecoveryIdentity::from_bytes(c.key));

        assert_eq!(read_recovery_key(b"").err(), Some(KeyError::Empty));
        assert_eq!(read_recovery_key(b"  \n\t ").err(), Some(KeyError::Empty));
        assert_eq!(read_recovery_key(b"# only a comment\n").err(), Some(KeyError::Empty));
        assert_eq!(read_recovery_key(public.as_bytes()).err(), Some(KeyError::PublicHalf));
        assert_eq!(read_recovery_key(b"hello").err(), Some(KeyError::NotAKey));
        assert_eq!(read_recovery_key(b"AGE-SECRET-KEY-PQ-1QQQQ").err(), Some(KeyError::NotAKey));
        assert_eq!(read_recovery_key(&vec![b'A'; KEY_INPUT_MAX + 1]).err(), Some(KeyError::NotAKey));
        assert_eq!(read_recovery_key("AGE-SECRET-KEY-1\u{e9}".as_bytes()).err(), Some(KeyError::NotAKey));

        // Every single changed character after the opening is caught (BIP-173 detects any
        // one substitution), as are a dropped one, an extra one and mixed case.
        let opening = KEY_OPENING.len();
        for i in opening..text.len() {
            for replacement in [b'Q', b'P', b'Z', b'8'].iter() {
                let mut changed = text.clone().into_bytes();
                if changed[i] == *replacement {
                    continue;
                }
                changed[i] = *replacement;
                assert_eq!(read_recovery_key(&changed).err(), Some(KeyError::Typo), "position {}", i);
            }
            let mut dropped = text.clone().into_bytes();
            dropped.remove(i);
            assert_eq!(read_recovery_key(&dropped).err(), Some(KeyError::Typo));
        }
        let extra = format!("{}Q", text);
        assert_eq!(read_recovery_key(extra.as_bytes()).err(), Some(KeyError::Typo));
        let mut mixed = text.clone().into_bytes();
        mixed[30] = mixed[30].to_ascii_lowercase();
        if mixed[30] != text.as_bytes()[30] {
            assert_eq!(read_recovery_key(&mixed).err(), Some(KeyError::Typo));
        }
        // 'B', 'I', 'O' and '1' are not in the alphabet.
        let mut outside = text.clone().into_bytes();
        outside[40] = b'O';
        assert_eq!(read_recovery_key(&outside).err(), Some(KeyError::Typo));
    }

    #[test]
    fn a_key_with_padding_bits_set_is_refused() {
        // 52 data values whose last one carries a set padding bit, with a valid check.
        let mut data: Vec<u8> = vec![0u8; 52];
        data[51] = 0x01;
        let mut values = bech32_check_input(KEY_HRP, &data).to_vec();
        values.extend_from_slice(&[0u8; 6]);
        let check = bech32_polymod(&values) ^ 1;
        let mut text = String::from("age-secret-key-1");
        for v in data.iter() {
            text.push(BECH32_CHARSET[*v as usize] as char);
        }
        for i in 0..6 {
            text.push(BECH32_CHARSET[((check >> (5 * (5 - i))) & 31) as usize] as char);
        }
        assert_eq!(read_recovery_key(text.as_bytes()).err(), Some(KeyError::Typo));
        // The same with the bit clear reads.
        data[51] = 0x10;
        let mut values = bech32_check_input(KEY_HRP, &data).to_vec();
        values.extend_from_slice(&[0u8; 6]);
        let check = bech32_polymod(&values) ^ 1;
        let mut text = String::from("age-secret-key-1");
        for v in data.iter() {
            text.push(BECH32_CHARSET[*v as usize] as char);
        }
        for i in 0..6 {
            text.push(BECH32_CHARSET[((check >> (5 * (5 - i))) & 31) as usize] as char);
        }
        assert!(read_recovery_key(text.as_bytes()).is_ok());
    }

    // ----- The chain, the mirrors, the words -----

    #[test]
    fn round_times_and_addresses() {
        assert_eq!(round_unix_seconds(0), None);
        assert_eq!(round_unix_seconds(1), Some(BEACON_GENESIS_UNIX_SECONDS));
        assert_eq!(round_unix_seconds(1_000), Some(1_692_806_364));
        assert_eq!(round_unix_seconds(u64::MAX), None);
        for round in [1u64, 2, 1_000, 12_345_678, 30_000_000].iter() {
            assert_eq!(wall_clock_round(round_unix_seconds(*round).unwrap()), *round);
        }
        assert_eq!(
            round_url(MIRRORS[0], 1_000),
            "https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/public/1000"
        );
        assert_eq!(chain_hash_hex(), "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971");
    }

    #[test]
    fn at_least_two_mirrors_on_different_hosts() {
        assert!(MIRRORS.len() >= BEACON_MIRRORS_MIN);
        for (i, m) in MIRRORS.iter().enumerate() {
            assert!(m.starts_with("https://"));
            assert!(!m.ends_with('/'));
            assert_eq!(m.matches('/').count(), 2, "a mirror is an origin only");
            for other in MIRRORS[i + 1..].iter() {
                assert_ne!(m, other);
            }
        }
    }

    #[test]
    fn dates_and_durations_in_plain_words() {
        assert_eq!(utc_date_text(0), "Thursday 1 January 1970 at 00:00 UTC");
        assert_eq!(utc_date_text(951_782_400), "Tuesday 29 February 2000 at 00:00 UTC");
        assert_eq!(utc_date_text(1_709_164_799), "Wednesday 28 February 2024 at 23:59 UTC");
        assert_eq!(utc_date_text(1_709_164_800), "Thursday 29 February 2024 at 00:00 UTC");
        assert_eq!(utc_date_text(1_782_803_364), "Tuesday 30 June 2026 at 07:09 UTC");
        assert_eq!(utc_date_text(4_102_444_800), "Friday 1 January 2100 at 00:00 UTC");
        assert_eq!(utc_date_text(u64::MAX), "a date after the year 9999");
        assert_eq!(rough_wait_text(30), "a minute or two");
        assert_eq!(rough_wait_text(600), "about 10 minutes");
        assert_eq!(rough_wait_text(3 * 3_600), "about 3 hours");
        assert_eq!(rough_wait_text(41 * 86_400 + 5), "about 41 days");
        assert_eq!(rough_wait_text(200 * 86_400), "about 7 months");
        assert_eq!(rough_wait_text(3 * 365 * 86_400), "about 3 years");
        assert_eq!(grouped(1_000), "1,000");
        assert_eq!(grouped(12_345_678), "12,345,678");
        assert_eq!(grouped(999), "999");
        assert_eq!(ADMIN_ACCOUNT_NAME, "SafeSight Mac administrator");
        assert_eq!(CLAIM_DAYS, 7);
    }
}
