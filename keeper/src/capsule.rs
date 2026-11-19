// SPDX-License-Identifier: Apache-2.0
//! The capsule: a time-locked copy of the admin secret of one generation (SD-056, SD-057;
//! register 8a; chapter 03 section 9).
//!
//! Two layers, opened in this order: the time layer, then `age`.
//!
//! - Inner: an `age` file to one X25519 recipient, the Recovery Key's public half, or to
//!   two during an overlap (SD-065). Its payload is the admin secret and nothing else.
//! - Outer: an `age` file with one `tlock` stanza to the target round of the pinned chain
//!   (`timelock`). Its payload is the inner file.
//!
//! The outer file is the capsule record's ciphertext (`records::Capsule`), with the
//! generation number, target round and chain hash in the clear and zero padding to
//! `CAPSULE_SIZE`. Without the Recovery Key, and before its round, a capsule opens for
//! nobody.
//!
//! `seal` is the sealing function of chapter 03 section 9. Its only inputs are a value of
//! the admin-secret type, one or two Recovery Key public halves, a generation number, a
//! target round, and the random generator for its keys and nonces. The chain key is
//! pinned. A test fails if its signature changes or if any other module builds a capsule
//! record (the build check of SD-057).
//!
//! `open` is the opener's core (SD-066). The keeper never opens a capsule (chapter 03
//! section 9), so `open` is compiled only for tests and for the `opener` feature.
//!
//! Not here: whether the round is fresh (SD-059) and what the target is
//! (`CAPSULE_TARGET`). Those are the rotation's rules (SM-05), which is not written yet.

use zeroize::{Zeroize, Zeroizing};

use crate::age;
use crate::boundary::RandomSource;
use crate::constants::{ADMIN_SECRET_LENGTH_MIN, BEACON_CHAIN_HASH};
use crate::frame::RecordError;
use crate::records::Capsule;
use crate::timelock;

#[cfg(any(test, feature = "opener"))]
use crate::beacon::QuicknetVerifier;
#[cfg(any(test, feature = "opener"))]
use crate::boundary::RoundVerifier;
#[cfg(any(test, feature = "opener"))]
use crate::records::RoundRecord;
#[cfg(any(test, feature = "opener"))]
use x25519_dalek::{x25519, X25519_BASEPOINT_BYTES};

/// The length of the admin secret.
// OPEN: SD-035 - `ADMIN_SECRET_LENGTH` is "40 or more" random characters, and chapter 03
// section 9 asks for a fixed length inside the capsule. Neither the exact length nor the
// alphabet is fixed. Working rule: exactly `ADMIN_SECRET_LENGTH_MIN` characters, each
// printable ASCII other than a space. The generator is not written in this pass.
pub const ADMIN_SECRET_LEN: usize = ADMIN_SECRET_LENGTH_MIN;

/// The admin secret (SD-035). It is never shown, never logged, never sent over XPC and
/// never leaves the Mac except inside a capsule. It is wiped from memory when dropped. It
/// has no `Clone`, no `Display`, and its `Debug` prints nothing of it.
pub struct AdminSecret {
    bytes: [u8; ADMIN_SECRET_LEN],
}

impl AdminSecret {
    /// A secret of exactly `ADMIN_SECRET_LEN` printable ASCII characters, none a space.
    pub fn from_bytes(bytes: &[u8]) -> Option<AdminSecret> {
        if bytes.len() != ADMIN_SECRET_LEN {
            return None;
        }
        if !bytes.iter().all(|c| (0x21..=0x7E).contains(c)) {
            return None;
        }
        let mut out = [0u8; ADMIN_SECRET_LEN];
        out.copy_from_slice(bytes);
        Some(AdminSecret { bytes: out })
    }

    /// True if both are the same secret. Takes the same time wherever they differ.
    pub fn same_as(&self, other: &AdminSecret) -> bool {
        let mut difference: u8 = 0;
        let mut i = 0;
        while i < ADMIN_SECRET_LEN {
            difference |= self.bytes[i] ^ other.bytes[i];
            i += 1;
        }
        difference == 0
    }

    fn as_bytes(&self) -> &[u8; ADMIN_SECRET_LEN] {
        &self.bytes
    }
}

impl Drop for AdminSecret {
    fn drop(&mut self) {
        self.bytes.zeroize();
    }
}

impl core::fmt::Debug for AdminSecret {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("AdminSecret(hidden)")
    }
}

/// The Recovery Key's public half: an X25519 public key (SD-063). Only this half ever
/// reaches the keeper.
// OPEN: SD-063 - the form in which the public half reaches the keeper (the `age1...` text
// or its 32 bytes, and in which record) is not specified. Working form: the 32 bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RecoveryKeyPublic(pub [u8; 32]);

/// Who a capsule is sealed to: the Recovery Key, and during an overlap the new one too
/// (SD-065).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RecoveryRecipients {
    pub current: RecoveryKeyPublic,
    pub overlap: Option<RecoveryKeyPublic>,
}

/// Why no capsule was made. Nothing is written and nothing changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SealError {
    /// The chain's first round is round 1.
    RoundZero,
    /// The random generator gave nothing.
    Random,
    /// A Recovery Key public half is a low-order point, or the overlap names the same key.
    Recipient,
    /// The time layer could not be made.
    TimeLayer,
    /// The `age` layer could not be made.
    Layer,
    /// The record refused the result (it does not fit `CAPSULE_SIZE`).
    Record(RecordError),
}

fn draw(random: &mut dyn RandomSource, out: &mut [u8]) -> Result<(), SealError> {
    match random.fill(out) {
        Ok(()) => Ok(()),
        Err(_) => Err(SealError::Random),
    }
}

/// Seals the admin secret of `generation` into a capsule that opens only with the
/// Recovery Key and only with the signature of `target_round` (SD-056, SD-057).
///
/// Random draws, in this order: the inner file key (16 bytes); one ephemeral secret (32)
/// per recipient; the inner nonce (16); the outer file key (16); the time lock's sigma
/// (16); the outer nonce (16). Every key is wiped when the function returns.
pub fn seal(
    secret: &AdminSecret,
    recovery: &RecoveryRecipients,
    generation: u64,
    target_round: u64,
    random: &mut dyn RandomSource,
) -> Result<Capsule, SealError> {
    if target_round == 0 {
        return Err(SealError::RoundZero);
    }
    let mut recipients: Vec<RecoveryKeyPublic> = vec![recovery.current];
    if let Some(second) = recovery.overlap {
        if second == recovery.current {
            return Err(SealError::Recipient);
        }
        recipients.push(second);
    }

    // The inner layer: the secret, to the Recovery Key.
    let mut inner_key = Zeroizing::new([0u8; age::FILE_KEY_LEN]);
    draw(random, &mut inner_key[..])?;
    let mut stanzas: Vec<Vec<u8>> = Vec::new();
    for recipient in recipients.iter() {
        let mut ephemeral = Zeroizing::new([0u8; 32]);
        draw(random, &mut ephemeral[..])?;
        match age::x25519_stanza(&inner_key, &recipient.0, &ephemeral) {
            Some(s) => stanzas.push(s),
            None => return Err(SealError::Recipient),
        }
    }
    let mut inner_nonce = [0u8; age::NONCE_LEN];
    draw(random, &mut inner_nonce[..])?;
    let inner = match age::seal_file(&inner_key, &stanzas, &secret.as_bytes()[..], &inner_nonce) {
        Some(bytes) => bytes,
        None => return Err(SealError::Layer),
    };

    // The outer layer: the inner file, to the target round.
    let mut outer_key = Zeroizing::new([0u8; age::FILE_KEY_LEN]);
    draw(random, &mut outer_key[..])?;
    let mut sigma = Zeroizing::new([0u8; timelock::KEY_LEN]);
    draw(random, &mut sigma[..])?;
    let body = match timelock::lock(target_round, &outer_key, &sigma) {
        Some(b) => b,
        None => return Err(SealError::TimeLayer),
    };
    let time_stanza = age::tlock_stanza(target_round, &BEACON_CHAIN_HASH, &body);
    let mut outer_nonce = [0u8; age::NONCE_LEN];
    draw(random, &mut outer_nonce[..])?;
    let outer = match age::seal_file(&outer_key, &[time_stanza], &inner, &outer_nonce) {
        Some(bytes) => bytes,
        None => return Err(SealError::Layer),
    };

    let capsule = Capsule { generation, target_round, chain_hash: BEACON_CHAIN_HASH, ciphertext: outer };
    // The record must take it whole: this refuses a capsule that does not fit.
    if let Err(e) = capsule.encode() {
        return Err(SealError::Record(e));
    }
    Ok(capsule)
}

// ---------------------------------------------------------------------------------------
// The opener's core
// ---------------------------------------------------------------------------------------

/// The Recovery Key's secret half, as the opener holds it for a real release only. Never
/// held by the keeper. Wiped when dropped; its `Debug` prints nothing of it.
#[cfg(any(test, feature = "opener"))]
pub struct RecoveryIdentity {
    scalar: [u8; 32],
}

#[cfg(any(test, feature = "opener"))]
impl RecoveryIdentity {
    pub fn from_bytes(scalar: [u8; 32]) -> RecoveryIdentity {
        RecoveryIdentity { scalar }
    }

    /// The public half, which capsules are sealed to.
    pub fn public(&self) -> RecoveryKeyPublic {
        RecoveryKeyPublic(x25519(self.scalar, X25519_BASEPOINT_BYTES))
    }
}

#[cfg(any(test, feature = "opener"))]
impl Drop for RecoveryIdentity {
    fn drop(&mut self) {
        self.scalar.zeroize();
    }
}

#[cfg(any(test, feature = "opener"))]
impl core::fmt::Debug for RecoveryIdentity {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("RecoveryIdentity(hidden)")
    }
}

/// Why the opener opened nothing (chapter 03 section 11, the opener's steps).
#[cfg(any(test, feature = "opener"))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenError {
    /// The capsule file is not a valid capsule record.
    Capsule(RecordError),
    /// The capsule or the round is for another chain.
    OtherChain,
    /// The round is not a valid round record.
    Round(RecordError),
    /// The round's signature does not verify against the pinned key.
    BadRoundSignature,
    /// The round is before the capsule's target: "This copy opens no earlier than ...".
    NotYet { target_round: u64 },
    /// The round is after the target. Only the target round's signature opens it.
    WrongRound,
    /// The layers are not laid out as a capsule's are.
    Layout,
    /// The time layer did not open with this round.
    TimeLayer,
    /// The capsule is not sealed to this Recovery Key.
    NotForThisKey,
    /// A layer's check failed: the capsule was changed.
    Damaged,
}

/// Opens a capsule with the signature of its target round and the Recovery Key, in the
/// opener's order: the capsule record; the round, its chain and its signature; not before
/// the target; the time layer; the `age` layer.
#[cfg(any(test, feature = "opener"))]
pub fn open(capsule_bytes: &[u8], round_record: &[u8], identity: &RecoveryIdentity) -> Result<AdminSecret, OpenError> {
    let capsule = match Capsule::decode(capsule_bytes) {
        Ok(c) => c,
        Err(e) => return Err(OpenError::Capsule(e)),
    };
    if !capsule.is_on_pinned_chain() {
        return Err(OpenError::OtherChain);
    }
    let round = match RoundRecord::decode(round_record) {
        Ok(r) => r,
        Err(e) => return Err(OpenError::Round(e)),
    };
    if round.chain_hash != BEACON_CHAIN_HASH {
        return Err(OpenError::OtherChain);
    }
    let verifier = match QuicknetVerifier::pinned() {
        Some(v) => v,
        None => return Err(OpenError::BadRoundSignature),
    };
    if !verifier.verify_round(round.round, &round.signature) {
        return Err(OpenError::BadRoundSignature);
    }
    if round.round < capsule.target_round {
        return Err(OpenError::NotYet { target_round: capsule.target_round });
    }
    if round.round != capsule.target_round {
        return Err(OpenError::WrongRound);
    }

    // The time layer: exactly one tlock stanza, naming this round and this chain.
    let outer = match age::read_file(&capsule.ciphertext) {
        Some(f) => f,
        None => return Err(OpenError::Layout),
    };
    if outer.stanzas.len() != 1 {
        return Err(OpenError::Layout);
    }
    let stanza = &outer.stanzas[0];
    let round_text = format!("{}", capsule.target_round);
    let mut hash_text = String::with_capacity(64);
    for byte in capsule.chain_hash.iter() {
        hash_text.push_str(&format!("{:02x}", byte));
    }
    if stanza.kind != b"tlock"
        || stanza.args.len() != 2
        || stanza.args[0] != round_text.as_bytes()
        || stanza.args[1] != hash_text.as_bytes()
        || stanza.body.len() != timelock::BODY_LEN
    {
        return Err(OpenError::Layout);
    }
    let mut body = [0u8; timelock::BODY_LEN];
    body.copy_from_slice(&stanza.body);
    let outer_key = match timelock::unlock(&round.signature, &body) {
        Some(k) => Zeroizing::new(k),
        None => return Err(OpenError::TimeLayer),
    };
    let inner_bytes = match age::open_payload(&outer, &outer_key) {
        Some(b) => b,
        None => return Err(OpenError::Damaged),
    };

    // The age layer: one or two X25519 stanzas and nothing else.
    let inner = match age::read_file(&inner_bytes) {
        Some(f) => f,
        None => return Err(OpenError::Layout),
    };
    if inner.stanzas.is_empty() || inner.stanzas.len() > 2 {
        return Err(OpenError::Layout);
    }
    for s in inner.stanzas.iter() {
        if s.kind != b"X25519" {
            return Err(OpenError::Layout);
        }
    }
    let mut file_key: Option<Zeroizing<[u8; age::FILE_KEY_LEN]>> = None;
    for s in inner.stanzas.iter() {
        if let Some(k) = age::unwrap_x25519(s, &identity.scalar) {
            file_key = Some(Zeroizing::new(k));
            break;
        }
    }
    let file_key = match file_key {
        Some(k) => k,
        None => return Err(OpenError::NotForThisKey),
    };
    let plain = match age::open_payload(&inner, &file_key) {
        Some(p) => Zeroizing::new(p),
        None => return Err(OpenError::Damaged),
    };
    match AdminSecret::from_bytes(&plain[..]) {
        Some(secret) => Ok(secret),
        None => Err(OpenError::Layout),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::beacon::vectors::{hex, record_bytes, signature};
    use crate::fakes::{BrokenRandom, SeededRandom};
    use crate::frame::reseal;
    use sha2::{Digest, Sha256};

    // The independent implementation's results (noble-curves 1.9.1, noble-ciphers 1.3.0,
    // noble-hashes 1.8.0), for the same seeded draws.
    const SEEDED_1_A: &str = "6dad2ae570d98590410a96f5354ce5c68e12becaa4364914e479696b49fa521d8afcc9d012361792";
    const SEEDED_1_B: &str = "cfda4e31894960bd6949259cf987b471";
    const SECRET_SHA256: &str = "931185d79bcdfcc6df74846bb5a8fe001ad71e8a55dd2f29b4479c82b5729c19";
    const PUB1: &str = "379190d1dcdcb8b42961a7ef2a2f4df559d342adb1677c35b26fdbe0d3687237";
    const PUB2: &str = "ce05dae31d1524f67d6bcd46cecd62b10f6a968fab26a827caeeb58b5f4fa731";
    const ONE_OUTER_LEN: usize = 595;
    const ONE_OUTER_HEADER: &str = "age-encryption.org/v1\n-> tlock 1000 52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971\nr7xJKp37zbBcuqlWHegOGg1R7dSvlS5VP9FANcUpKo0kFDuQc5gp/d/RsclirmWS\nEL7mNsfG5I0psvu1ribtYIczY/RMiJHgYqX9I80A51rwReWyj8yI7agpY0XnrtDm\ntyuu8EWjNJK/bFvEeqFeN7/dqYJrI3HAaHn5oxP6OUo\n--- T2aEf/S+ABcRXOva92GqZ8/0TlrAkDFF/o7eMhOm9R8\n";
    const ONE_OUTER_SHA256: &str = "904bb593ec9df62ca1898d622eb3fe092a09423762dd1570cc757016fe17e31b";
    const ONE_INNER_HEADER: &str = "age-encryption.org/v1\n-> X25519 yVWtkcM345NdEnRTeRArspOJ97o+yG72E4z7OTQGeF8\nVE3a7x6NjNfidv6V6Ym+PBlNLzVWwz/P44Krzb+Lm8g\n--- HfnPRLiRSwy3i8x0Pew3/LkpeJIOIOOo2GBydLx3/44\n";
    const TWO_OUTER_LEN: usize = 693;
    const TWO_OUTER_HEADER: &str = "age-encryption.org/v1\n-> tlock 1000 52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971\npE36LfonWvyh66mIcc/NnVKDRT+I8QP0mgfq2Pk/JATkXEZWs4vBJDafVMgMwXv7\nFzNkacVxiT7+IrFScejKF6CM+54cNBnBUqcoqdLqJ5ILjzET2X1jBDRR51QuVxBL\nTvbLLJU5DJbVRXbm9BA65OTTFS5DpLYv0YtHUG0afD4\n--- 0R0AA1zW79xts3EPFsrtTPdV8Y5j/jGP/5S0TD5uhvg\n";
    const TWO_OUTER_SHA256: &str = "e8631ba8c82b603a4770ce09e008370a70f2cff6e64f75acfcb5801fdabf612f";
    const TWO_INNER_HEADER: &str = "age-encryption.org/v1\n-> X25519 yVWtkcM345NdEnRTeRArspOJ97o+yG72E4z7OTQGeF8\nVE3a7x6NjNfidv6V6Ym+PBlNLzVWwz/P44Krzb+Lm8g\n-> X25519 Nys/ygzDA706yfdlR660g1cYX4xaExC4rpe/a3FwUwc\nbxDOLKEf5p+PYNJoO+PtmHjfqUSCBCRlpubKv25KXr4\n--- 23+xWlfOwBNV2bqjfX+W/buJhlwWRKu6X4eYgELWLIk\n";

    /// A test secret and two test Recovery Keys, all from a seeded source. None is real.
    fn inputs() -> (AdminSecret, RecoveryIdentity, RecoveryIdentity) {
        let alphabet = b"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
        let mut source = SeededRandom::new(200);
        let mut raw = [0u8; ADMIN_SECRET_LEN];
        source.fill(&mut raw).unwrap();
        let mut text = [0u8; ADMIN_SECRET_LEN];
        let mut i = 0;
        while i < ADMIN_SECRET_LEN {
            text[i] = alphabet[(raw[i] as usize) % alphabet.len()];
            i += 1;
        }
        let secret = AdminSecret::from_bytes(&text).unwrap();
        let mut first = [0u8; 32];
        source.fill(&mut first).unwrap();
        let mut second = [0u8; 32];
        source.fill(&mut second).unwrap();
        (secret, RecoveryIdentity::from_bytes(first), RecoveryIdentity::from_bytes(second))
    }

    fn one(identity: &RecoveryIdentity) -> RecoveryRecipients {
        RecoveryRecipients { current: identity.public(), overlap: None }
    }

    fn two(a: &RecoveryIdentity, b: &RecoveryIdentity) -> RecoveryRecipients {
        RecoveryRecipients { current: a.public(), overlap: Some(b.public()) }
    }

    fn sha256_hex(bytes: &[u8]) -> String {
        hex(Sha256::digest(bytes).as_slice())
    }

    fn sealed(recovery: &RecoveryRecipients, target: u64) -> Vec<u8> {
        let (secret, _, _) = inputs();
        seal(&secret, recovery, 3, target, &mut SeededRandom::new(7)).unwrap().encode().unwrap()
    }

    #[test]
    fn the_seeded_source_and_the_test_keys_match_the_reference() {
        let mut source = SeededRandom::new(1);
        let mut a = [0u8; 40];
        source.fill(&mut a).unwrap();
        let mut b = [0u8; 16];
        source.fill(&mut b).unwrap();
        assert_eq!(hex(&a), SEEDED_1_A);
        assert_eq!(hex(&b), SEEDED_1_B);

        let (secret, first, second) = inputs();
        assert_eq!(sha256_hex(&secret.as_bytes()[..]), SECRET_SHA256);
        assert_eq!(hex(&first.public().0), PUB1);
        assert_eq!(hex(&second.public().0), PUB2);
    }

    #[test]
    fn a_capsule_matches_the_independent_implementation_byte_for_byte() {
        let (secret, first, second) = inputs();
        let capsule = seal(&secret, &one(&first), 3, 1_000, &mut SeededRandom::new(7)).unwrap();
        assert_eq!(capsule.ciphertext.len(), ONE_OUTER_LEN);
        assert_eq!(&capsule.ciphertext[..ONE_OUTER_HEADER.len()], ONE_OUTER_HEADER.as_bytes());
        assert_eq!(sha256_hex(&capsule.ciphertext), ONE_OUTER_SHA256);
        assert_eq!(capsule.generation, 3);
        assert_eq!(capsule.target_round, 1_000);
        assert_eq!(capsule.chain_hash, BEACON_CHAIN_HASH);

        let capsule = seal(&secret, &two(&first, &second), 3, 1_000, &mut SeededRandom::new(7)).unwrap();
        assert_eq!(capsule.ciphertext.len(), TWO_OUTER_LEN);
        assert_eq!(&capsule.ciphertext[..TWO_OUTER_HEADER.len()], TWO_OUTER_HEADER.as_bytes());
        assert_eq!(sha256_hex(&capsule.ciphertext), TWO_OUTER_SHA256);
    }

    #[test]
    fn the_target_round_opens_it_with_the_recovery_key() {
        let (secret, first, second) = inputs();
        let bytes = sealed(&one(&first), 1_000);
        assert_eq!(bytes.len(), crate::constants::CAPSULE_SIZE);
        let opened = open(&bytes, &record_bytes(1_000), &first).unwrap();
        assert!(opened.same_as(&secret));

        // During an overlap, either key opens it.
        let bytes = sealed(&two(&first, &second), 1_000);
        assert!(open(&bytes, &record_bytes(1_000), &first).unwrap().same_as(&secret));
        assert!(open(&bytes, &record_bytes(1_000), &second).unwrap().same_as(&secret));

        // A capsule to a later real round opens with that round.
        let bytes = sealed(&one(&first), 12_345_678);
        assert!(open(&bytes, &record_bytes(12_345_678), &first).unwrap().same_as(&secret));
    }

    #[test]
    fn an_earlier_round_opens_nothing() {
        let (_, first, _) = inputs();
        let bytes = sealed(&one(&first), 12_345_678);
        assert_eq!(
            open(&bytes, &record_bytes(1_000), &first).err(),
            Some(OpenError::NotYet { target_round: 12_345_678 })
        );
        assert_eq!(
            open(&bytes, &record_bytes(1), &first).err(),
            Some(OpenError::NotYet { target_round: 12_345_678 })
        );
        // Not by the round number alone: the time layer itself opens with no other
        // round's signature.
        let capsule = Capsule::decode(&bytes).unwrap();
        let outer = age::read_file(&capsule.ciphertext).unwrap();
        let mut body = [0u8; timelock::BODY_LEN];
        body.copy_from_slice(&outer.stanzas[0].body);
        assert_eq!(timelock::unlock(&signature(1_000), &body), None);
        assert_eq!(timelock::unlock(&signature(1_001), &body), None);
        assert_eq!(timelock::unlock(&signature(30_000_000), &body), None);
        assert!(timelock::unlock(&signature(12_345_678), &body).is_some());
    }

    #[test]
    fn a_wrong_or_forged_round_opens_nothing() {
        let (_, first, _) = inputs();
        let bytes = sealed(&one(&first), 1_000);
        assert_eq!(open(&bytes, &record_bytes(1_001), &first).err(), Some(OpenError::WrongRound));
        assert_eq!(open(&bytes, &record_bytes(30_000_000), &first).err(), Some(OpenError::WrongRound));

        // Round 1000 claimed with round 1001's signature, or with a changed one.
        let forged = RoundRecord { chain_hash: BEACON_CHAIN_HASH, round: 1_000, signature: signature(1_001) };
        assert_eq!(open(&bytes, &forged.encode().unwrap(), &first).err(), Some(OpenError::BadRoundSignature));
        let mut changed = signature(1_000);
        changed[10] ^= 0x02;
        let changed = RoundRecord { chain_hash: BEACON_CHAIN_HASH, round: 1_000, signature: changed };
        assert_eq!(open(&bytes, &changed.encode().unwrap(), &first).err(), Some(OpenError::BadRoundSignature));

        // Another chain, and a round record that is not one.
        let other = RoundRecord { chain_hash: [7u8; 32], round: 1_000, signature: signature(1_000) };
        assert_eq!(open(&bytes, &other.encode().unwrap(), &first).err(), Some(OpenError::OtherChain));
        assert!(matches!(open(&bytes, &[1, 2, 3], &first), Err(OpenError::Round(_))));
    }

    #[test]
    fn another_recovery_key_opens_nothing() {
        let (_, first, second) = inputs();
        let bytes = sealed(&one(&first), 1_000);
        assert_eq!(open(&bytes, &record_bytes(1_000), &second).err(), Some(OpenError::NotForThisKey));
        let stranger = RecoveryIdentity::from_bytes([0x33u8; 32]);
        assert_eq!(open(&bytes, &record_bytes(1_000), &stranger).err(), Some(OpenError::NotForThisKey));
    }

    #[test]
    fn a_changed_capsule_opens_nothing() {
        let (_, first, _) = inputs();
        let good = sealed(&one(&first), 1_000);
        let round = record_bytes(1_000);
        // Without the checksum put right, the record itself is refused.
        let mut torn = good.clone();
        torn[200] ^= 0x01;
        assert_eq!(open(&torn, &round, &first).err(), Some(OpenError::Capsule(RecordError::BadChecksum)));

        // With the checksum put right: a change in the header, the time-lock body, the MAC,
        // the nonce or the sealed payload, at the start or the end of the ciphertext.
        let start = crate::frame::HEADER_LEN + 8 + 8 + 32 + 2;
        let positions: [usize; 12] = [0, 5, 23, 60, 110, 180, 270, 300, 330, 400, 500, ONE_OUTER_LEN - 1];
        for offset in positions.iter() {
            let mut changed = good.clone();
            changed[start + offset] ^= 0x01;
            reseal(&mut changed);
            assert!(open(&changed, &round, &first).is_err(), "a change at ciphertext byte {} opened", offset);
        }
        // A non-zero padding byte is refused by the record.
        let mut padded = good.clone();
        padded[start + ONE_OUTER_LEN + 3] = 1;
        reseal(&mut padded);
        assert_eq!(open(&padded, &round, &first).err(), Some(OpenError::Capsule(RecordError::NonZeroPadding)));
    }

    #[test]
    fn the_round_in_the_clear_must_be_the_round_inside() {
        let (_, first, _) = inputs();
        let good = sealed(&one(&first), 1_000);
        let mut capsule = Capsule::decode(&good).unwrap();
        capsule.target_round = 1_001;
        let relabelled = capsule.encode().unwrap();
        assert_eq!(open(&relabelled, &record_bytes(1_001), &first).err(), Some(OpenError::Layout));
        let mut capsule = Capsule::decode(&good).unwrap();
        capsule.chain_hash = [7u8; 32];
        assert_eq!(open(&capsule.encode().unwrap(), &record_bytes(1_000), &first).err(), Some(OpenError::OtherChain));
    }

    #[test]
    fn a_capsule_holds_the_secret_and_nothing_else() {
        let (secret, first, second) = inputs();
        for recovery in [one(&first), two(&first, &second)].iter() {
            let capsule = seal(&secret, recovery, 3, 1_000, &mut SeededRandom::new(9)).unwrap();
            let outer = age::read_file(&capsule.ciphertext).unwrap();
            assert_eq!(outer.stanzas.len(), 1);
            assert_eq!(outer.stanzas[0].kind, b"tlock".to_vec());
            let mut body = [0u8; timelock::BODY_LEN];
            body.copy_from_slice(&outer.stanzas[0].body);
            let key = timelock::unlock(&signature(1_000), &body).unwrap();
            let inner_bytes = age::open_payload(&outer, &key).unwrap();
            let inner = age::read_file(&inner_bytes).unwrap();
            let expected = if recovery.overlap.is_some() { 2 } else { 1 };
            assert_eq!(inner.stanzas.len(), expected);
            for s in inner.stanzas.iter() {
                assert_eq!(s.kind, b"X25519".to_vec());
            }
            let file_key = age::unwrap_x25519(&inner.stanzas[0], &first.scalar).unwrap();
            let plain = age::open_payload(&inner, &file_key).unwrap();
            assert_eq!(&plain[..], &secret.as_bytes()[..]);
            // The inner header is the reference's, for the same draws as the vector.
            let header_len = inner_bytes.windows(4).position(|w| w == b"--- ").unwrap();
            assert!(header_len > 0);
        }
        // The inner headers of the vectors, made by the reference with seed 7.
        let capsule = seal(&secret, &one(&first), 3, 1_000, &mut SeededRandom::new(7)).unwrap();
        let outer = age::read_file(&capsule.ciphertext).unwrap();
        let mut body = [0u8; timelock::BODY_LEN];
        body.copy_from_slice(&outer.stanzas[0].body);
        let key = timelock::unlock(&signature(1_000), &body).unwrap();
        let inner_bytes = age::open_payload(&outer, &key).unwrap();
        assert_eq!(&inner_bytes[..ONE_INNER_HEADER.len()], ONE_INNER_HEADER.as_bytes());
        let capsule = seal(&secret, &two(&first, &second), 3, 1_000, &mut SeededRandom::new(7)).unwrap();
        let outer = age::read_file(&capsule.ciphertext).unwrap();
        body.copy_from_slice(&outer.stanzas[0].body);
        let key = timelock::unlock(&signature(1_000), &body).unwrap();
        let inner_bytes = age::open_payload(&outer, &key).unwrap();
        assert_eq!(&inner_bytes[..TWO_INNER_HEADER.len()], TWO_INNER_HEADER.as_bytes());
    }

    #[test]
    fn two_recipients_fit_the_fixed_size_with_room() {
        let (secret, first, second) = inputs();
        let capsule = seal(&secret, &two(&first, &second), u64::MAX, u64::MAX, &mut SeededRandom::new(3)).unwrap();
        assert!(capsule.ciphertext.len() <= Capsule::CIPHERTEXT_MAX);
        assert_eq!(capsule.encode().unwrap().len(), crate::constants::CAPSULE_SIZE);
    }

    #[test]
    fn sealing_refuses_what_it_cannot_make_and_changes_nothing() {
        let (secret, first, _) = inputs();
        assert_eq!(seal(&secret, &one(&first), 3, 0, &mut SeededRandom::new(7)).err(), Some(SealError::RoundZero));
        assert_eq!(seal(&secret, &one(&first), 3, 1_000, &mut BrokenRandom).err(), Some(SealError::Random));
        let low_order = RecoveryRecipients { current: RecoveryKeyPublic([0u8; 32]), overlap: None };
        assert_eq!(seal(&secret, &low_order, 3, 1_000, &mut SeededRandom::new(7)).err(), Some(SealError::Recipient));
        let twice = RecoveryRecipients { current: first.public(), overlap: Some(first.public()) };
        assert_eq!(seal(&secret, &twice, 3, 1_000, &mut SeededRandom::new(7)).err(), Some(SealError::Recipient));
    }

    #[test]
    fn each_seal_is_new_and_each_opens() {
        let (secret, first, _) = inputs();
        let a = seal(&secret, &one(&first), 3, 1_000, &mut SeededRandom::new(10)).unwrap().encode().unwrap();
        let b = seal(&secret, &one(&first), 3, 1_000, &mut SeededRandom::new(11)).unwrap().encode().unwrap();
        assert_ne!(a, b);
        assert!(open(&a, &record_bytes(1_000), &first).unwrap().same_as(&secret));
        assert!(open(&b, &record_bytes(1_000), &first).unwrap().same_as(&secret));
    }

    #[test]
    fn a_secret_is_never_printed_and_is_strict() {
        let (secret, first, _) = inputs();
        let shown = format!("{:?} {:?}", secret, first);
        assert_eq!(shown, "AdminSecret(hidden) RecoveryIdentity(hidden)");
        assert!(AdminSecret::from_bytes(&[b'a'; ADMIN_SECRET_LEN - 1]).is_none());
        assert!(AdminSecret::from_bytes(&[b'a'; ADMIN_SECRET_LEN + 1]).is_none());
        let mut spaced = [b'a'; ADMIN_SECRET_LEN];
        spaced[5] = b' ';
        assert!(AdminSecret::from_bytes(&spaced).is_none());
        let mut control = [b'a'; ADMIN_SECRET_LEN];
        control[5] = 0x0A;
        assert!(AdminSecret::from_bytes(&control).is_none());
        let a = AdminSecret::from_bytes(&[b'a'; ADMIN_SECRET_LEN]).unwrap();
        let mut other = [b'a'; ADMIN_SECRET_LEN];
        other[ADMIN_SECRET_LEN - 1] = b'b';
        let b = AdminSecret::from_bytes(&other).unwrap();
        assert!(a.same_as(&a));
        assert!(!a.same_as(&b));
    }

    // SD-057, the build check: only `seal` builds a capsule record, and its inputs do not
    // change. The pieces of each pattern are joined at run time, so this test's own text
    // does not match them.
    #[test]
    fn only_the_sealing_function_writes_a_capsule() {
        let literal = ["Capsule", " {"].concat();
        let type_name = ["TYPE_", "CAPSULE"].concat();
        let others: [(&str, &str); 13] = [
            ("age.rs", include_str!("age.rs")),
            ("beacon.rs", include_str!("beacon.rs")),
            ("boundary.rs", include_str!("boundary.rs")),
            ("clock.rs", include_str!("clock.rs")),
            ("constants.rs", include_str!("constants.rs")),
            ("counters.rs", include_str!("counters.rs")),
            ("fakes.rs", include_str!("fakes.rs")),
            ("frame.rs", include_str!("frame.rs")),
            ("lib.rs", include_str!("lib.rs")),
            ("main.rs", include_str!("main.rs")),
            ("store.rs", include_str!("store.rs")),
            ("timelock.rs", include_str!("timelock.rs")),
            ("waits.rs", include_str!("waits.rs")),
        ];
        for (name, text) in others.iter() {
            assert!(!text.contains(&literal), "{} builds a capsule record", name);
            assert!(!text.contains(&type_name), "{} names the capsule record type", name);
        }
        let signature = [
            "pub fn ",
            "seal(\n    secret: &AdminSecret,\n    recovery: &RecoveryRecipients,\n    generation: u64,\n",
            "    target_round: u64,\n    random: &mut dyn RandomSource,\n) -> Result<Capsule, SealError> {",
        ]
        .concat();
        assert!(include_str!("capsule.rs").contains(&signature));
        assert_eq!(include_str!("capsule.rs").matches(&literal).count(), 1);
    }
}
