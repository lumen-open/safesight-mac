// SPDX-License-Identifier: Apache-2.0
//! The keyholder's approval, keeper side (SD-053, SD-196, SD-306; chapter 03 section 8).
//!
//! Two parts:
//!
//! - **The challenge** the keyholder's passkey signs (SD-306: "the keyholder signs what
//!   they see"). It is SHA-256 over a fixed tag, the format version, the kind, the request
//!   ID, the detail (the new wait of a lowering, the setting of a loosening), the Mac label,
//!   the hashes of any named items and the keeper's 32 random bytes for this request. The
//!   keyholder page computes it from the fields it shows; the keeper computes it again
//!   from its own record of the request. The test approval at enrolment has a tag of its
//!   own, so a test signature can never stand for a real request. The keyholder page's
//!   tests and these tests read one vector file, `spec/vectors/keyholder-challenge-v1.txt`,
//!   made by a third implementation on `node:crypto`.
//! - **The check of an approval** (`Es256ApprovalVerifier`): the passkey's ES256 signature
//!   over the authenticator data and the SHA-256 of the client data, under the pinned
//!   public key; the pinned RP ID hash; "user present" and "user verified" set; client
//!   data that is exactly a `webauthn.get` for this challenge and the pinned origin, with
//!   `crossOrigin` absent or false and nothing that could restate the type, the challenge
//!   or the origin. That the approval names the open request, its kind matches and it is
//!   used once are the state machine's rules (`waits::WaitMachine::approval`).
//!
//! The signature check uses the `p256` crate (RustCrypto), the one crate added for this:
//! nothing on the fixed list of SD-021 does ECDSA on P-256, and an ECDSA verifier written
//! by hand would be one more thing for the second reader to prove. The `sha2` it uses is
//! the one already in the tree.

use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};
use sha2::{Digest, Sha256};

use crate::boundary::ApprovalVerifier;
use crate::constants::{is_exit_wait_option, EXIT_WAIT_MAX_DAYS};

/// The format version of the challenge, and of the request code it is built from.
pub const CHALLENGE_FORMAT_VERSION: u8 = 1;

/// The tag of every real request's challenge.
pub const APPROVAL_TAG: &str = "SafeSightMac keyholder approval";

/// The tag of the test approval at enrolment. Never accepted for a request.
pub const TEST_APPROVAL_TAG: &str = "SafeSightMac keyholder test approval";

/// The longest Mac label, in bytes of UTF-8.
// OPEN: register 8a (request code) - "a short label". Working value 32 bytes, as the
// keyholder page.
pub const MAC_LABEL_MAX: usize = 32;

/// The most item hashes an admin-window request names.
pub const ITEMS_MAX: usize = 16;

/// The authenticator data of an assertion: RP ID hash (32), flags (1), counter (4).
pub const AUTHENTICATOR_DATA_LEN: usize = 37;

/// The longest client data accepted, as the keyholder page caps it.
pub const CLIENT_DATA_MAX: usize = 1_024;

const FLAG_USER_PRESENT: u8 = 0x01;
const FLAG_USER_VERIFIED: u8 = 0x04;
const FLAG_ATTESTED_DATA: u8 = 0x40;
const FLAG_EXTENSION_DATA: u8 = 0x80;

/// The owner's label for this Mac, as the keyholder sees it. 1 to 32 bytes of UTF-8, no
/// leading or trailing space, and none of the characters that could make a page show
/// something other than what is signed: control characters, line and paragraph
/// separators, zero-width characters, the soft hyphen, the byte order mark, and the
/// characters that change text direction. The same rule as the keyholder page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MacLabel {
    bytes: [u8; MAC_LABEL_MAX],
    len: u8,
}

fn refused_in_label(c: char) -> bool {
    let u = c as u32;
    u <= 0x1F
        || (0x7F..=0x9F).contains(&u)
        || u == 0x00AD
        || u == 0x061C
        || u == 0x180E
        || (0x200B..=0x200F).contains(&u)
        || u == 0x2028
        || u == 0x2029
        || (0x202A..=0x202E).contains(&u)
        || (0x2060..=0x206F).contains(&u)
        || u == 0xFEFF
}

impl MacLabel {
    pub fn new(label: &str) -> Option<MacLabel> {
        let bytes = label.as_bytes();
        if bytes.is_empty() || bytes.len() > MAC_LABEL_MAX {
            return None;
        }
        if label.trim() != label {
            return None;
        }
        if label.chars().any(refused_in_label) {
            return None;
        }
        let mut out = [0u8; MAC_LABEL_MAX];
        out[..bytes.len()].copy_from_slice(bytes);
        Some(MacLabel { bytes: out, len: bytes.len() as u8 })
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes[..self.len as usize]
    }
}

/// What a request asks for, as the challenge and the keyholder page name it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChallengeKind {
    /// The test approval at enrolment. Changes nothing.
    Test,
    Exit,
    /// A lowering of the wait to this many days.
    LowerWait { new_wait_days: u16 },
    /// A loosening of one setting, by its code (1 browser profile, 2 strict cover mode
    /// off, 3 detector rule to Balanced).
    LoosenSetting { setting_code: u16 },
    /// An admin window (SD-288). Not built in the keeper yet; here so that the shared
    /// vectors cover every kind the page knows.
    AdminWindow,
}

impl ChallengeKind {
    pub fn code(self) -> u8 {
        match self {
            ChallengeKind::Test => 0,
            ChallengeKind::Exit => 1,
            ChallengeKind::LowerWait { .. } => 2,
            ChallengeKind::LoosenSetting { .. } => 3,
            ChallengeKind::AdminWindow => 4,
        }
    }

    pub fn detail(self) -> u16 {
        match self {
            ChallengeKind::LowerWait { new_wait_days } => new_wait_days,
            ChallengeKind::LoosenSetting { setting_code } => setting_code,
            ChallengeKind::Test | ChallengeKind::Exit | ChallengeKind::AdminWindow => 0,
        }
    }

    fn detail_is_valid(self) -> bool {
        match self {
            ChallengeKind::LowerWait { new_wait_days } => {
                is_exit_wait_option(new_wait_days) && new_wait_days < EXIT_WAIT_MAX_DAYS
            }
            ChallengeKind::LoosenSetting { setting_code } => (1..=3).contains(&setting_code),
            ChallengeKind::Test | ChallengeKind::Exit | ChallengeKind::AdminWindow => true,
        }
    }
}

/// The fields a challenge binds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChallengeFields<'a> {
    pub kind: ChallengeKind,
    pub request_id: [u8; 16],
    pub mac_label: &'a MacLabel,
    /// Item hashes: 1 to 16 for an admin window, none for every other kind.
    pub items: &'a [[u8; 32]],
    /// The keeper's 32 random bytes for this request, kept with the request.
    pub nonce: [u8; 32],
}

/// The challenge of SD-306, format version 1: SHA-256 of
/// tag length (1) | tag | format version (1) | kind (1) | request ID (16) |
/// detail (2, big-endian) | label length (1) | label | item count (1) | items (32 each) |
/// nonce (32). None if the fields break a rule the keyholder page would refuse.
pub fn derive_challenge(fields: &ChallengeFields) -> Option<[u8; 32]> {
    if !fields.kind.detail_is_valid() {
        return None;
    }
    let items_allowed = match fields.kind {
        ChallengeKind::AdminWindow => !fields.items.is_empty() && fields.items.len() <= ITEMS_MAX,
        _ => fields.items.is_empty(),
    };
    if !items_allowed {
        return None;
    }
    let tag = match fields.kind {
        ChallengeKind::Test => TEST_APPROVAL_TAG,
        _ => APPROVAL_TAG,
    };
    let label = fields.mac_label.as_bytes();
    let mut hash = Sha256::new();
    hash.update([tag.len() as u8]);
    hash.update(tag.as_bytes());
    hash.update([CHALLENGE_FORMAT_VERSION, fields.kind.code()]);
    hash.update(fields.request_id);
    hash.update(fields.kind.detail().to_be_bytes());
    hash.update([label.len() as u8]);
    hash.update(label);
    hash.update([fields.items.len() as u8]);
    for item in fields.items.iter() {
        hash.update(item);
    }
    hash.update(fields.nonce);
    let mut out = [0u8; 32];
    out.copy_from_slice(hash.finalize().as_slice());
    Some(out)
}

/// An approval code in the keeper's form: the app has read the page's code and converted
/// the signature from DER to the fixed 64 bytes (r, then s), as chapter 03 says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApprovalCode {
    pub request_id: [u8; 16],
    pub authenticator_data: [u8; AUTHENTICATOR_DATA_LEN],
    /// The client data exactly as the passkey signed it.
    pub client_data: Vec<u8>,
    pub signature: [u8; 64],
}

fn sha256(bytes: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    out.copy_from_slice(Sha256::digest(bytes).as_slice());
    out
}

/// Base64url with no padding, as WebAuthn writes the challenge in the client data.
pub fn base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity((bytes.len() * 4 + 2) / 3);
    let mut i = 0;
    while i + 3 <= bytes.len() {
        let n = ((bytes[i] as u32) << 16) | ((bytes[i + 1] as u32) << 8) | (bytes[i + 2] as u32);
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(ALPHABET[(n >> 6) as usize & 63] as char);
        out.push(ALPHABET[n as usize & 63] as char);
        i += 3;
    }
    let left = bytes.len() - i;
    if left == 1 {
        let n = (bytes[i] as u32) << 16;
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
    } else if left == 2 {
        let n = ((bytes[i] as u32) << 16) | ((bytes[i + 1] as u32) << 8);
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(ALPHABET[(n >> 6) as usize & 63] as char);
    }
    out
}

/// A key or string inside the client data: from an opening quote to the next quote. Keys
/// may hold no escape and no control character, so that what is compared is what a JSON
/// reader would see. Returns the content and the index after the closing quote.
fn read_plain_key(bytes: &[u8], at: usize) -> Option<(&[u8], usize)> {
    if bytes.get(at) != Some(&b'"') {
        return None;
    }
    let mut i = at + 1;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'"' {
            return Some((&bytes[at + 1..i], i + 1));
        }
        if b == b'\\' || b < 0x20 {
            return None;
        }
        i += 1;
    }
    None
}

fn is_hex_digit(b: u8) -> bool {
    b.is_ascii_hexdigit()
}

/// Skips one JSON value of the kinds a browser puts in client data: a string (with the
/// standard escapes), `true`, `false` or `null`. Anything else is refused. Returns the
/// index after it.
fn skip_value(bytes: &[u8], at: usize) -> Option<usize> {
    let rest = bytes.get(at..)?;
    if rest.starts_with(b"true") || rest.starts_with(b"null") {
        return Some(at + 4);
    }
    if rest.starts_with(b"false") {
        return Some(at + 5);
    }
    if rest.first() != Some(&b'"') {
        return None;
    }
    let mut i = at + 1;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'"' {
            return Some(i + 1);
        }
        if b < 0x20 {
            return None;
        }
        if b == b'\\' {
            let escaped = *bytes.get(i + 1)?;
            match escaped {
                b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' => i += 2,
                b'u' => {
                    let digits = bytes.get(i + 2..i + 6)?;
                    if !digits.iter().all(|d| is_hex_digit(*d)) {
                        return None;
                    }
                    i += 6;
                }
                _ => return None,
            }
            continue;
        }
        i += 1;
    }
    None
}

/// After the fixed prefix: zero or more `,"key":value` members, then `}` and nothing
/// after it. `crossOrigin` must be `false`; a second `type`, `challenge` or `origin`, or a
/// `topOrigin` (which browsers add only for a cross-origin call), is refused.
fn members_after_prefix_are_allowed(rest: &[u8]) -> bool {
    let mut i = 0;
    loop {
        match rest.get(i) {
            Some(b'}') => return i + 1 == rest.len(),
            Some(b',') => i += 1,
            _ => return false,
        }
        let (key, next) = match read_plain_key(rest, i) {
            Some(found) => found,
            None => return false,
        };
        i = next;
        if rest.get(i) != Some(&b':') {
            return false;
        }
        i += 1;
        if key == b"crossOrigin" {
            if rest.get(i..).map(|r| r.starts_with(b"false")) != Some(true) {
                return false;
            }
            i += 5;
        } else if key == b"type" || key == b"challenge" || key == b"origin" || key == b"topOrigin" {
            return false;
        } else {
            i = match skip_value(rest, i) {
                Some(n) => n,
                None => return false,
            };
        }
    }
}

/// True if `client_data` is a `webauthn.get` for exactly `challenge` at exactly `origin`,
/// in the fixed form of chapter 03 section 8, step 5, with nothing after it that the rules
/// above refuse.
pub fn client_data_is_exact(client_data: &[u8], challenge: &[u8; 32], origin: &str) -> bool {
    if client_data.len() > CLIENT_DATA_MAX {
        return false;
    }
    let mut prefix = String::new();
    prefix.push_str("{\"type\":\"webauthn.get\",\"challenge\":\"");
    prefix.push_str(&base64url(challenge));
    prefix.push_str("\",\"origin\":\"");
    prefix.push_str(origin);
    prefix.push('"');
    let prefix = prefix.as_bytes();
    if client_data.len() < prefix.len() || &client_data[..prefix.len()] != prefix {
        return false;
    }
    members_after_prefix_are_allowed(&client_data[prefix.len()..])
}

/// An origin written into the fixed prefix as it is: `https://` and then only letters,
/// digits, dots, hyphens and a colon for a port. Nothing a JSON string would escape.
fn origin_is_plain(origin: &str) -> bool {
    let rest = match origin.strip_prefix("https://") {
        Some(r) => r,
        None => return false,
    };
    !rest.is_empty() && rest.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-' || b == b':')
}

/// The real check of an approval (SD-196, step 3 to 6 of chapter 03 section 8), against
/// one keyholder's pinned public key and the pinned page.
// OPEN: SQ-11 - the keyholder page's origin and RP ID are not chosen yet, so they are
// given here when the verifier is made. Once chosen they become constants of the lock
// core, and these two parameters go.
#[derive(Debug, Clone)]
pub struct Es256ApprovalVerifier {
    key: VerifyingKey,
    origin: String,
    rp_id_hash: [u8; 32],
}

impl Es256ApprovalVerifier {
    /// `public_key` is the P-256 point of the enrolment record, uncompressed (65 bytes).
    /// None if it is not a point of the curve, or the origin is not plain.
    pub fn new(public_key: &[u8; 65], origin: &str, rp_id: &str) -> Option<Es256ApprovalVerifier> {
        if public_key[0] != 0x04 || !origin_is_plain(origin) || rp_id.is_empty() {
            return None;
        }
        let key = VerifyingKey::from_sec1_bytes(&public_key[..]).ok()?;
        Some(Es256ApprovalVerifier { key, origin: origin.to_string(), rp_id_hash: sha256(rp_id.as_bytes()) })
    }
}

impl ApprovalVerifier for Es256ApprovalVerifier {
    fn check_approval(&self, approval: &ApprovalCode, expected_challenge: &[u8; 32]) -> bool {
        let data = &approval.authenticator_data;
        if data[..32] != self.rp_id_hash[..] {
            return false;
        }
        let flags = data[32];
        if flags & FLAG_USER_PRESENT == 0 || flags & FLAG_USER_VERIFIED == 0 {
            return false;
        }
        // Exactly 37 bytes were signed: no attested credential and no extension data.
        if flags & (FLAG_ATTESTED_DATA | FLAG_EXTENSION_DATA) != 0 {
            return false;
        }
        if !client_data_is_exact(&approval.client_data, expected_challenge, &self.origin) {
            return false;
        }
        let signature = match Signature::from_slice(&approval.signature[..]) {
            Ok(s) => s,
            Err(_) => return false,
        };
        let mut message: Vec<u8> = Vec::with_capacity(AUTHENTICATOR_DATA_LEN + 32);
        message.extend_from_slice(data);
        message.extend_from_slice(&sha256(&approval.client_data));
        self.key.verify(&message, &signature).is_ok()
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::beacon::vectors::unhex;

    const VECTORS: &str = include_str!("../../spec/vectors/keyholder-challenge-v1.txt");

    type Block = Vec<(String, String)>;

    /// The vector file's blocks: "key: value" lines, a blank line between blocks, `#` for
    /// comments.
    pub fn blocks() -> Vec<Block> {
        let mut out: Vec<Block> = Vec::new();
        let mut current: Block = Vec::new();
        for line in VECTORS.lines() {
            if line.starts_with('#') {
                continue;
            }
            if line.trim().is_empty() {
                if !current.is_empty() {
                    out.push(current);
                    current = Vec::new();
                }
                continue;
            }
            let (key, value) = line.split_once(':').unwrap();
            current.push((key.trim().to_string(), value.trim().to_string()));
        }
        if !current.is_empty() {
            out.push(current);
        }
        out
    }

    pub fn field<'a>(block: &'a Block, key: &str) -> &'a str {
        for (k, v) in block.iter() {
            if k == key {
                return v;
            }
        }
        panic!("no field {} in {:?}", key, block);
    }

    fn fixed<const N: usize>(text: &str) -> [u8; N] {
        let bytes = unhex(text);
        assert_eq!(bytes.len(), N, "{}", text);
        let mut out = [0u8; N];
        out.copy_from_slice(&bytes);
        out
    }

    fn kind_of(code: u8, detail: u16) -> ChallengeKind {
        match code {
            0 => ChallengeKind::Test,
            1 => ChallengeKind::Exit,
            2 => ChallengeKind::LowerWait { new_wait_days: detail },
            3 => ChallengeKind::LoosenSetting { setting_code: detail },
            4 => ChallengeKind::AdminWindow,
            _ => panic!("kind {}", code),
        }
    }

    fn label_of(block: &Block) -> MacLabel {
        let bytes = unhex(field(block, "label"));
        MacLabel::new(std::str::from_utf8(&bytes).unwrap()).unwrap()
    }

    fn items_of(block: &Block) -> Vec<[u8; 32]> {
        let text = field(block, "items");
        if text.is_empty() {
            return Vec::new();
        }
        text.split(',').map(fixed::<32>).collect()
    }

    fn challenge_blocks() -> Vec<Block> {
        blocks().into_iter().filter(|b| b[0].0 == "case" && b[0].1.starts_with("challenge ")).collect()
    }

    #[test]
    fn the_challenge_matches_every_shared_vector() {
        let cases = challenge_blocks();
        assert_eq!(cases.len(), 7);
        for block in cases.iter() {
            let label = label_of(block);
            let items = items_of(block);
            let fields = ChallengeFields {
                kind: kind_of(field(block, "kind").parse().unwrap(), field(block, "detail").parse().unwrap()),
                request_id: fixed::<16>(field(block, "request_id")),
                mac_label: &label,
                items: &items,
                nonce: fixed::<32>(field(block, "nonce")),
            };
            let expected: [u8; 32] = fixed::<32>(field(block, "challenge"));
            assert_eq!(derive_challenge(&fields), Some(expected), "{}", field(block, "case"));
        }
    }

    #[test]
    fn every_field_the_keyholder_sees_changes_the_challenge() {
        let label = MacLabel::new("Sam's Mac").unwrap();
        let other_label = MacLabel::new("Sam's Mac 2").unwrap();
        let none: [[u8; 32]; 0] = [];
        let base = ChallengeFields {
            kind: ChallengeKind::Exit,
            request_id: [1; 16],
            mac_label: &label,
            items: &none[..],
            nonce: [2; 32],
        };
        let first = derive_challenge(&base).unwrap();
        let mut seen = vec![first];
        let mut variants: Vec<ChallengeFields> = Vec::new();
        let mut v = base;
        v.kind = ChallengeKind::Test;
        variants.push(v);
        let mut v = base;
        v.kind = ChallengeKind::LowerWait { new_wait_days: 7 };
        variants.push(v);
        let mut v = base;
        v.kind = ChallengeKind::LowerWait { new_wait_days: 30 };
        variants.push(v);
        let mut v = base;
        v.kind = ChallengeKind::LoosenSetting { setting_code: 1 };
        variants.push(v);
        let mut v = base;
        v.request_id[15] ^= 1;
        variants.push(v);
        let mut v = base;
        v.mac_label = &other_label;
        variants.push(v);
        let mut v = base;
        v.nonce[0] ^= 1;
        variants.push(v);
        for variant in variants.iter() {
            let challenge = derive_challenge(variant).unwrap();
            assert!(!seen.contains(&challenge), "{:?}", variant);
            seen.push(challenge);
        }
    }

    #[test]
    fn fields_the_page_would_refuse_give_no_challenge() {
        let label = MacLabel::new("Mac").unwrap();
        let item: [[u8; 32]; 1] = [[9u8; 32]];
        let none: [[u8; 32]; 0] = [];
        let base = ChallengeFields { kind: ChallengeKind::Exit, request_id: [1; 16], mac_label: &label, items: &none[..], nonce: [2; 32] };
        let mut v = base;
        v.kind = ChallengeKind::LowerWait { new_wait_days: 365 };
        assert_eq!(derive_challenge(&v), None);
        v.kind = ChallengeKind::LowerWait { new_wait_days: 14 };
        assert_eq!(derive_challenge(&v), None);
        v.kind = ChallengeKind::LoosenSetting { setting_code: 0 };
        assert_eq!(derive_challenge(&v), None);
        v.kind = ChallengeKind::LoosenSetting { setting_code: 4 };
        assert_eq!(derive_challenge(&v), None);
        let mut v = base;
        v.items = &item[..];
        assert_eq!(derive_challenge(&v), None);
        v.kind = ChallengeKind::AdminWindow;
        assert!(derive_challenge(&v).is_some());
        v.items = &none[..];
        assert_eq!(derive_challenge(&v), None);
    }

    #[test]
    fn the_mac_label_rule_is_the_pages() {
        assert!(MacLabel::new("Sam's Mac").is_some());
        assert!(MacLabel::new("東京のMac").is_some());
        assert!(MacLabel::new("abcdefghijklmnopqrstuvwxyz012345").is_some());
        assert!(MacLabel::new("abcdefghijklmnopqrstuvwxyz0123456").is_none());
        assert!(MacLabel::new("").is_none());
        assert!(MacLabel::new(" Mac").is_none());
        assert!(MacLabel::new("Mac ").is_none());
        assert!(MacLabel::new("   ").is_none());
        for refused in ["a\u{0}b", "a\nb", "a\u{7f}b", "a\u{85}b", "a\u{ad}b", "a\u{61c}b", "a\u{180e}b", "a\u{200b}b", "a\u{200f}b", "a\u{2028}b", "a\u{2029}b", "a\u{202e}b", "a\u{2066}b", "a\u{feff}b"].iter() {
            assert!(MacLabel::new(refused).is_none(), "{:?}", refused);
        }
        assert_eq!(MacLabel::new("Mac").unwrap().as_bytes(), b"Mac");
    }

    #[test]
    fn base64url_has_no_padding() {
        assert_eq!(base64url(b""), "");
        assert_eq!(base64url(b"f"), "Zg");
        assert_eq!(base64url(b"fo"), "Zm8");
        assert_eq!(base64url(b"foo"), "Zm9v");
        assert_eq!(base64url(b"foob"), "Zm9vYg");
        assert_eq!(base64url(&[0xfb, 0xff, 0xbf]), "-_-_");
        assert_eq!(base64url(&[0u8; 32]).len(), 43);
    }

    fn verifier_and_cases() -> (Es256ApprovalVerifier, Vec<Block>) {
        let all = blocks();
        let header = all.iter().find(|b| b[0].0 == "public_key").unwrap();
        let verifier = Es256ApprovalVerifier::new(
            &fixed::<65>(field(header, "public_key")),
            field(header, "origin"),
            field(header, "rp_id"),
        )
        .unwrap();
        let cases = all.into_iter().filter(|b| b[0].0 == "case" && b[0].1.starts_with("approval ")).collect();
        (verifier, cases)
    }

    fn code_of(block: &Block) -> ApprovalCode {
        ApprovalCode {
            request_id: [0; 16],
            authenticator_data: fixed::<37>(field(block, "authenticator_data")),
            client_data: unhex(field(block, "client_data")),
            signature: fixed::<64>(field(block, "signature")),
        }
    }

    // Each case was made by node:crypto. The good ones must pass and every other one fail,
    // for the reason its name gives.
    #[test]
    fn the_approval_check_agrees_with_every_shared_vector() {
        let (verifier, cases) = verifier_and_cases();
        assert_eq!(cases.len(), 24);
        let mut good = 0;
        for block in cases.iter() {
            let expected = fixed::<32>(field(block, "expected_challenge"));
            let valid = field(block, "valid") == "yes";
            let result = verifier.check_approval(&code_of(block), &expected);
            assert_eq!(result, valid, "{}", field(block, "case"));
            if valid {
                good += 1;
            }
        }
        assert_eq!(good, 4);
    }

    #[test]
    fn a_good_approval_fails_for_any_other_challenge_key_origin_or_bit() {
        let (verifier, cases) = verifier_and_cases();
        let block = cases.iter().find(|b| field(b, "case") == "approval good").unwrap();
        let code = code_of(block);
        let expected = fixed::<32>(field(block, "expected_challenge"));
        assert!(verifier.check_approval(&code, &expected));
        // Another challenge.
        let mut other = expected;
        other[31] ^= 1;
        assert!(!verifier.check_approval(&code, &other));
        // Another key: a point of the curve that is not the keyholder's.
        let all = blocks();
        let header = all.iter().find(|b| b[0].0 == "public_key").unwrap();
        let generator = fixed::<65>(concat!(
            "04",
            "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296",
            "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
        ));
        let stranger = Es256ApprovalVerifier::new(&generator, field(header, "origin"), field(header, "rp_id")).unwrap();
        assert!(!stranger.check_approval(&code, &expected));
        // Another origin or RP ID pinned.
        let elsewhere = Es256ApprovalVerifier::new(&fixed::<65>(field(header, "public_key")), "https://other.example", "keyholder.example").unwrap();
        assert!(!elsewhere.check_approval(&code, &expected));
        let other_rp = Es256ApprovalVerifier::new(&fixed::<65>(field(header, "public_key")), field(header, "origin"), "other.example").unwrap();
        assert!(!other_rp.check_approval(&code, &expected));
        // Any one bit of the signed bytes.
        let mut i = 0;
        while i < AUTHENTICATOR_DATA_LEN {
            let mut changed = code.clone();
            changed.authenticator_data[i] ^= 0x10;
            assert!(!verifier.check_approval(&changed, &expected), "authenticator data byte {}", i);
            i += 1;
        }
        let mut i = 0;
        while i < code.client_data.len() {
            let mut changed = code.clone();
            changed.client_data[i] ^= 0x01;
            assert!(!verifier.check_approval(&changed, &expected), "client data byte {}", i);
            i += 1;
        }
        let mut i = 0;
        while i < 64 {
            let mut changed = code.clone();
            changed.signature[i] ^= 0x01;
            assert!(!verifier.check_approval(&changed, &expected), "signature byte {}", i);
            i += 1;
        }
    }

    #[test]
    fn a_verifier_is_made_only_from_a_real_point_and_a_plain_origin() {
        let all = blocks();
        let header = all.iter().find(|b| b[0].0 == "public_key").unwrap();
        let key = fixed::<65>(field(header, "public_key"));
        assert!(Es256ApprovalVerifier::new(&key, "https://keyholder.example", "keyholder.example").is_some());
        let mut off_curve = key;
        off_curve[64] ^= 1;
        assert!(Es256ApprovalVerifier::new(&off_curve, "https://keyholder.example", "keyholder.example").is_none());
        let mut compressed_tag = key;
        compressed_tag[0] = 0x02;
        assert!(Es256ApprovalVerifier::new(&compressed_tag, "https://keyholder.example", "keyholder.example").is_none());
        assert!(Es256ApprovalVerifier::new(&[0u8; 65], "https://keyholder.example", "keyholder.example").is_none());
        assert!(Es256ApprovalVerifier::new(&key, "http://keyholder.example", "keyholder.example").is_none());
        assert!(Es256ApprovalVerifier::new(&key, "https://keyholder.example\"", "keyholder.example").is_none());
        assert!(Es256ApprovalVerifier::new(&key, "https://", "keyholder.example").is_none());
        assert!(Es256ApprovalVerifier::new(&key, "https://keyholder.example", "").is_none());
    }

    #[test]
    fn client_data_members_are_read_strictly() {
        let challenge = [7u8; 32];
        let c = base64url(&challenge);
        let origin = "https://keyholder.example";
        let make = |tail: &str| format!("{{\"type\":\"webauthn.get\",\"challenge\":\"{}\",\"origin\":\"{}\"{}", c, origin, tail).into_bytes();
        assert!(client_data_is_exact(&make("}"), &challenge, origin));
        assert!(client_data_is_exact(&make(",\"crossOrigin\":false}"), &challenge, origin));
        assert!(client_data_is_exact(&make(",\"crossOrigin\":false,\"x\":\"a\\\"b\\u00e9\"}"), &challenge, origin));
        assert!(client_data_is_exact(&make(",\"x\":null,\"y\":true}"), &challenge, origin));
        assert!(!client_data_is_exact(&make(",\"crossOrigin\":true}"), &challenge, origin));
        assert!(!client_data_is_exact(&make(",\"crossOrigin\":\"false\"}"), &challenge, origin));
        assert!(!client_data_is_exact(&make(",\"crossOrigin\":false,\"crossOrigin\":true}"), &challenge, origin));
        assert!(!client_data_is_exact(&make(",\"origin\":\"https://keyholder.example\"}"), &challenge, origin));
        assert!(!client_data_is_exact(&make(",\"type\":\"webauthn.get\"}"), &challenge, origin));
        assert!(!client_data_is_exact(&make(",\"topOrigin\":\"https://keyholder.example\"}"), &challenge, origin));
        assert!(!client_data_is_exact(&make(",\"x\":1}"), &challenge, origin));
        assert!(!client_data_is_exact(&make(",\"x\":\"a\\qb\"}"), &challenge, origin));
        assert!(!client_data_is_exact(&make(",\"x\":\"a\\u00zz\"}"), &challenge, origin));
        assert!(!client_data_is_exact(&make(",\"x\":\"unterminated}"), &challenge, origin));
        assert!(!client_data_is_exact(&make(", \"x\":null}"), &challenge, origin));
        assert!(!client_data_is_exact(&make("}}"), &challenge, origin));
        assert!(!client_data_is_exact(&make(""), &challenge, origin));
        assert!(!client_data_is_exact(&make(","), &challenge, origin));
        let mut long = make(",\"x\":\"");
        long.extend(std::iter::repeat(b'a').take(CLIENT_DATA_MAX));
        long.extend_from_slice(b"\"}");
        assert!(!client_data_is_exact(&long, &challenge, origin));
    }
}
