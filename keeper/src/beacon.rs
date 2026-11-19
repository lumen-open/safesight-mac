// SPDX-License-Identifier: Apache-2.0
//! The real check of a beacon round's signature (SD-038, SD-043; chapter 03 section 2,
//! "The keeper's check of a round", step 4).
//!
//! drand quicknet signs, for round r, the SHA-256 of r as 8 big-endian bytes. The
//! signature is a point of G1 on BLS12-381 (48 bytes, compressed); the chain public key is
//! a point of G2 (96 bytes, compressed), pinned in `constants`. The message is hashed to
//! G1 as RFC 9380 says, with the scheme's tag. A round verifies when
//! e(signature, g2) = e(H(message), public key).
//!
//! Chapter 02 section 11 asks for the verification code of the published `drand` client
//! crate with every network feature off, and, if the crate cannot be built without HTTP,
//! for the check to be written against the pairing library directly. The client crate
//! fetches rounds over HTTP and the keeper has no network (SD-018), so the check is written
//! here against the pairing crates of the fixed list. Real quicknet rounds are its test
//! vectors.
//!
//! Every point read from outside is checked to be on the curve and in the prime-order
//! subgroup before it is used, and the point at infinity is refused.

use ark_bls12_381::{g1, Bls12_381, G1Affine, G1Projective, G2Affine};
use ark_ec::hashing::curve_maps::wb::WBMap;
use ark_ec::hashing::map_to_curve_hasher::MapToCurveBasedHasher;
use ark_ec::hashing::HashToCurve;
use ark_ec::pairing::Pairing;
use ark_ec::AffineRepr;
use ark_ff::field_hashers::DefaultFieldHasher;
use ark_serialize::CanonicalDeserialize;
use sha2::{Digest, Sha256};

use crate::boundary::RoundVerifier;
use crate::constants::{BEACON_DST, BEACON_PUBLIC_KEY};

/// RFC 9380 hash to G1: expand_message_xmd with SHA-256 at 128-bit security, then the
/// simplified SWU map through the 11-isogeny, then clearing the cofactor.
type G1Hasher = MapToCurveBasedHasher<G1Projective, DefaultFieldHasher<Sha256, 128>, WBMap<g1::Config>>;

/// The message the chain signs for `round`: SHA-256 of the round as 8 big-endian bytes.
/// It is also the identity a capsule is time-locked to (`timelock`).
pub fn round_message(round: u64) -> [u8; 32] {
    let digest = Sha256::digest(round.to_be_bytes());
    let mut out = [0u8; 32];
    out.copy_from_slice(digest.as_slice());
    out
}

/// Hashes `message` to G1 under the tag `dst` (RFC 9380).
pub(crate) fn hash_to_g1_with(dst: &[u8], message: &[u8]) -> Option<G1Affine> {
    let hasher = match G1Hasher::new(dst) {
        Ok(h) => h,
        Err(_) => return None,
    };
    match hasher.hash(message) {
        Ok(point) => Some(point),
        Err(_) => None,
    }
}

/// Hashes `message` to G1 under the chain's tag.
pub(crate) fn hash_to_g1(message: &[u8]) -> Option<G1Affine> {
    hash_to_g1_with(BEACON_DST, message)
}

/// The pinned chain public key as a point: on the curve, in the subgroup, not infinity.
pub(crate) fn pinned_public_key() -> Option<G2Affine> {
    let point = match G2Affine::deserialize_compressed(&BEACON_PUBLIC_KEY[..]) {
        Ok(p) => p,
        Err(_) => return None,
    };
    if point.is_zero() {
        return None;
    }
    Some(point)
}

/// A round signature as a point: on the curve, in the subgroup, not infinity.
pub(crate) fn signature_point(signature: &[u8; 48]) -> Option<G1Affine> {
    let point = match G1Affine::deserialize_compressed(&signature[..]) {
        Ok(p) => p,
        Err(_) => return None,
    };
    if point.is_zero() {
        return None;
    }
    Some(point)
}

/// The keeper's real check of a quicknet round, against the pinned key only. There is no
/// way to give it another key: a change of chain is a lock-core change (SD-043).
#[derive(Debug, Clone)]
pub struct QuicknetVerifier {
    public_key: G2Affine,
}

impl QuicknetVerifier {
    /// The verifier for the pinned chain. None only if the pinned key were not a valid
    /// point, which a test rules out.
    pub fn pinned() -> Option<QuicknetVerifier> {
        let public_key = pinned_public_key()?;
        Some(QuicknetVerifier { public_key })
    }
}

impl RoundVerifier for QuicknetVerifier {
    fn verify_round(&self, round: u64, signature: &[u8; 48]) -> bool {
        // The chain's first round is round 1.
        if round == 0 {
            return false;
        }
        let point = match signature_point(signature) {
            Some(p) => p,
            None => return false,
        };
        let hashed = match hash_to_g1(&round_message(round)) {
            Some(h) => h,
            None => return false,
        };
        let left = Bls12_381::pairing(point, G2Affine::generator());
        let right = Bls12_381::pairing(hashed, self.public_key);
        left == right
    }
}

/// Test data shared with the time-lock and capsule tests.
#[cfg(test)]
pub(crate) mod vectors {
    /// Real quicknet rounds, as published at api.drand.sh/<chain hash>/public/<round>.
    /// Fetched on 18 November 2026 for these tests only; the keeper never fetches.
    pub const ROUNDS: [(u64, &str); 5] = [
        (1, "b55e7cb2d5c613ee0b2e28d6750aabbb78c39dcc96bd9d38c2c2e12198df95571de8e8e402a0cc48871c7089a2b3af4b"),
        (1_000, "b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39"),
        (1_001, "b33bf3667cbd5a82de3a24b4e0e9fe5513cc1a0e840368c6e31f5fcfa79bea03f73896b25883abf2853d10337fb8fa41"),
        (12_345_678, "b0a199d51b7c29117d2155c4fc2322dbacd9d1e1f11da5b5c0e4e19947e4aaf634970e85eceef450681d27baa3a03f20"),
        (30_000_000, "81d2fc112b91932d9e4074a46b88c4dc78149b859660e0673c0bb9bd0caefdc9cc194e83de980441355b8ef44cc7a355"),
    ];

    pub fn unhex(text: &str) -> Vec<u8> {
        let digits: Vec<u8> = text.bytes().collect();
        assert_eq!(digits.len() % 2, 0);
        let mut out: Vec<u8> = Vec::new();
        let mut i = 0;
        while i < digits.len() {
            let pair = [digits[i], digits[i + 1]];
            let pair_text = std::str::from_utf8(&pair).unwrap();
            out.push(u8::from_str_radix(pair_text, 16).unwrap());
            i += 2;
        }
        out
    }

    pub fn hex(bytes: &[u8]) -> String {
        let mut text = String::new();
        for byte in bytes.iter() {
            text.push_str(&format!("{:02x}", byte));
        }
        text
    }

    /// The published signature of `round`, which must be one of `ROUNDS`.
    pub fn signature(round: u64) -> [u8; 48] {
        let mut i = 0;
        while i < ROUNDS.len() {
            if ROUNDS[i].0 == round {
                let bytes = unhex(ROUNDS[i].1);
                let mut out = [0u8; 48];
                out.copy_from_slice(&bytes);
                return out;
            }
            i += 1;
        }
        panic!("no vector for round {}", round);
    }

    /// The round record the app would hand over for a real round.
    pub fn record_bytes(round: u64) -> Vec<u8> {
        let record = crate::records::RoundRecord {
            chain_hash: crate::constants::BEACON_CHAIN_HASH,
            round,
            signature: signature(round),
        };
        record.encode().unwrap()
    }
}

#[cfg(test)]
mod tests {
    use super::vectors::{hex, record_bytes, signature, unhex, ROUNDS};
    use super::*;
    use crate::clock::{Clock, DropReason, RoundOutcome};
    use crate::constants::BEACON_CHAIN_HASH;
    use crate::fakes::FakeTime;
    use crate::records::RoundRecord;
    use ark_serialize::CanonicalSerialize;

    fn verifier() -> QuicknetVerifier {
        QuicknetVerifier::pinned().expect("the pinned key is a valid point")
    }

    #[test]
    fn the_pinned_key_is_a_point_of_the_subgroup() {
        let key = pinned_public_key().unwrap();
        let mut bytes = Vec::new();
        key.serialize_compressed(&mut bytes).unwrap();
        assert_eq!(bytes, BEACON_PUBLIC_KEY.to_vec());
    }

    // RFC 9380, appendix J.9.1, suite BLS12381G1_XMD:SHA-256_SSWU_RO_: the x coordinate
    // of the hash of "" and of "abc" (compressed form, flag bits set on the first byte).
    #[test]
    fn hashing_to_the_curve_matches_rfc_9380() {
        let dst = b"QUUX-V01-CS02-with-BLS12381G1_XMD:SHA-256_SSWU_RO_";
        let cases: [(&[u8], &str); 2] = [
            (b"", "852926add2207b76ca4fa57a8734416c8dc95e24501772c814278700eed6d1e4e8cf62d9c09db0fac349612b759e79a1"),
            (b"abc", "83567bc5ef9c690c2ab2ecdf6a96ef1c139cc0b2f284dca0a9a7943388a49a3aee664ba5379a7655d3c68900be2f6903"),
        ];
        for (message, expected) in cases.iter() {
            let point = hash_to_g1_with(&dst[..], message).unwrap();
            let mut bytes = Vec::new();
            point.serialize_compressed(&mut bytes).unwrap();
            assert_eq!(hex(&bytes), *expected);
        }
    }

    #[test]
    fn the_round_message_is_sha256_of_the_round_big_endian() {
        assert_eq!(hex(&round_message(1)), "cd2662154e6d76b2b2b92e70c0cac3ccf534f9b74eb5b89819ec509083d00a50");
        assert_eq!(hex(&round_message(1_000)), "f652498d092acd949bad74e40683bf3824fb817980504a0c7e6722cfc5a9c0a3");
    }

    #[test]
    fn real_quicknet_rounds_verify() {
        let v = verifier();
        for (round, _) in ROUNDS.iter() {
            assert!(v.verify_round(*round, &signature(*round)), "round {} did not verify", round);
        }
    }

    #[test]
    fn a_signature_does_not_verify_for_another_round() {
        let v = verifier();
        for (round, _) in ROUNDS.iter() {
            let sig = signature(*round);
            assert!(!v.verify_round(round + 1, &sig));
            assert!(!v.verify_round(round - 1, &sig));
            assert!(!v.verify_round(round + 28_800, &sig));
        }
        assert!(!v.verify_round(1_001, &signature(1_000)));
        assert!(!v.verify_round(1_000, &signature(1_001)));
    }

    #[test]
    fn a_tampered_signature_does_not_verify() {
        let v = verifier();
        let good = signature(1_000);
        // One flipped bit anywhere: in the flag bits, in the coordinate, at the end.
        let positions: [(usize, u8); 7] = [(0, 0x80), (0, 0x20), (0, 0x01), (1, 0x10), (20, 0x04), (40, 0x40), (47, 0x01)];
        for (index, bit) in positions.iter() {
            let mut sig = good;
            sig[*index] ^= *bit;
            assert!(!v.verify_round(1_000, &sig), "a flip at byte {} verified", index);
        }
        // Another real round's signature in its place.
        assert!(!v.verify_round(1_000, &signature(12_345_678)));
    }

    #[test]
    fn garbage_the_identity_and_round_zero_do_not_verify() {
        let v = verifier();
        assert!(!v.verify_round(1_000, &[0u8; 48]));
        assert!(!v.verify_round(1_000, &[0xFFu8; 48]));
        let mut infinity = [0u8; 48];
        infinity[0] = 0xC0;
        assert!(!v.verify_round(1_000, &infinity));
        assert!(signature_point(&infinity).is_none());
        assert!(!v.verify_round(0, &signature(1)));
    }

    #[test]
    fn the_real_round_vectors_are_consistent() {
        // The published randomness of a round is the SHA-256 of its signature; the
        // vectors were checked against it when they were taken. Here: each is 48 bytes
        // and they are all different.
        let mut i = 0;
        while i < ROUNDS.len() {
            assert_eq!(unhex(ROUNDS[i].1).len(), 48);
            let mut j = i + 1;
            while j < ROUNDS.len() {
                assert_ne!(ROUNDS[i].1, ROUNDS[j].1);
                j += 1;
            }
            i += 1;
        }
    }

    // The clock's own order of checks, with the real verifier behind it.
    #[test]
    fn the_clock_takes_real_rounds_through_the_real_check() {
        let v = verifier();
        let mut time = FakeTime::at_round(1_000);
        let mut clock = Clock::at_lock(&record_bytes(1_000), &v, &time).unwrap();
        assert_eq!(clock.high_water_round(), 1_000);
        assert_eq!(clock.high_water_signature(), signature(1_000));

        time.pass_awake_ms(3_000);
        match clock.offer_round(&record_bytes(1_001), &v, &time) {
            RoundOutcome::Accepted(a) => assert_eq!(a.round, 1_001),
            RoundOutcome::Dropped(reason) => panic!("dropped: {:?}", reason),
        }
        assert_eq!(clock.high_water_round(), 1_001);

        // Round 12345678 claimed with round 1001's signature.
        let forged = RoundRecord { chain_hash: BEACON_CHAIN_HASH, round: 12_345_678, signature: signature(1_001) };
        assert_eq!(
            clock.offer_round(&forged.encode().unwrap(), &v, &time),
            RoundOutcome::Dropped(DropReason::BadSignature)
        );
        let mut tampered = signature(12_345_678);
        tampered[30] ^= 0x08;
        let tampered = RoundRecord { chain_hash: BEACON_CHAIN_HASH, round: 12_345_678, signature: tampered };
        assert_eq!(
            clock.offer_round(&tampered.encode().unwrap(), &v, &time),
            RoundOutcome::Dropped(DropReason::BadSignature)
        );
        assert_eq!(clock.high_water_round(), 1_001);

        // A real round far ahead is accepted, with no upper bound.
        match clock.offer_round(&record_bytes(30_000_000), &v, &time) {
            RoundOutcome::Accepted(a) => assert_eq!(a.round, 30_000_000),
            RoundOutcome::Dropped(reason) => panic!("dropped: {:?}", reason),
        }
        // And an older real round is now below the high-water round.
        assert_eq!(
            clock.offer_round(&record_bytes(12_345_678), &v, &time),
            RoundOutcome::Dropped(DropReason::BelowHighWater)
        );

        // Lock itself refuses a forged first round.
        assert_eq!(Clock::at_lock(&forged.encode().unwrap(), &v, &time), Err(DropReason::BadSignature));
    }
}
