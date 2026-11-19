// SPDX-License-Identifier: Apache-2.0
//! The time lock: encryption to one future round of the pinned chain (SD-056; chapter 03
//! section 9, the outer layer of a capsule).
//!
//! This is the published tlock scheme for a chain whose signatures are on G1: Boneh and
//! Franklin's identity-based encryption with the Fujisaki-Okamoto transform, as drand's
//! `ibe` package builds it (`EncryptCCAonG2`). The identity of round r is the message the
//! chain signs for r (`beacon::round_message`); the chain's signature of round r is the
//! private key for that identity. So nobody, not the keeper, not the project, can open a
//! time lock before the chain has published the round's signature.
//!
//! It encrypts 16 bytes, the file key of the outer `age` layer:
//!
//! - Q = H(identity) in G1; r = H3(sigma, key) as a scalar; U = r * g2.
//! - V = sigma XOR H2(e(Q, public key)^r); W = key XOR H4(sigma).
//! - The body is U (96 bytes, compressed), V (16), W (16): 128 bytes.
//!
//! To open with the round's signature s: sigma = V XOR H2(e(s, U)); key = W XOR H4(sigma);
//! and the result is accepted only if r * g2 = U for r = H3(sigma, key).
//!
//! H2 hashes the pairing value in the byte order of the Go library drand uses, which is
//! the reverse of the order this pairing crate writes; tlock's Rust and JavaScript ports
//! do the same. An independent implementation on the noble libraries gave the test vector
//! below, and a real round's signature opens a lock made here.
// OPEN: SD-021 - the register names the published `tlock` crate. That crate draws its own
// randomness inside the call; the keeper's randomness comes through `RandomSource`
// (boundary), so the scheme is written here against the pairing crates of the fixed list,
// and its output is pinned by a vector from a second implementation. A vector made by the
// Go reference (drand/tlock) is still to be added, with the opener page (ST-072).

use ark_bls12_381::{Bls12_381, Fr, G1Projective, G2Affine, G2Projective};
use ark_ec::pairing::{Pairing, PairingOutput};
use ark_ec::{AffineRepr, CurveGroup, Group};
use ark_ff::{BigInt, PrimeField};
use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use sha2::{Digest, Sha256};
use zeroize::Zeroize;

use crate::beacon::{hash_to_g1, pinned_public_key, round_message, signature_point};

/// The size of what a time lock carries: one file key.
pub const KEY_LEN: usize = 16;

/// The size of a time-lock body: U (96), V (16), W (16).
pub const BODY_LEN: usize = 96 + KEY_LEN + KEY_LEN;

/// The size of a pairing value as the Go library writes it.
const GT_LEN: usize = 576;

/// H2: the first 16 bytes of SHA-256("IBE-H2" || the pairing value).
fn h2(value: &PairingOutput<Bls12_381>) -> Option<[u8; KEY_LEN]> {
    let mut bytes: Vec<u8> = Vec::with_capacity(GT_LEN);
    if value.0.serialize_compressed(&mut bytes).is_err() {
        return None;
    }
    if bytes.len() != GT_LEN {
        return None;
    }
    // This crate writes the twelve base-field coefficients lowest first, each
    // little-endian; the Go library writes them highest first, each big-endian. The one
    // is the other read backwards.
    bytes.reverse();
    let mut hash = Sha256::new();
    hash.update(b"IBE-H2");
    hash.update(&bytes);
    let digest = hash.finalize();
    bytes.zeroize();
    let mut out = [0u8; KEY_LEN];
    out.copy_from_slice(&digest.as_slice()[..KEY_LEN]);
    Some(out)
}

/// H4: the first 16 bytes of SHA-256("IBE-H4" || sigma).
fn h4(sigma: &[u8; KEY_LEN]) -> [u8; KEY_LEN] {
    let mut hash = Sha256::new();
    hash.update(b"IBE-H4");
    hash.update(sigma);
    let digest = hash.finalize();
    let mut out = [0u8; KEY_LEN];
    out.copy_from_slice(&digest.as_slice()[..KEY_LEN]);
    out
}

/// H3: a scalar from sigma and the key. buffer = SHA-256("IBE-H3" || sigma || key); then
/// for i = 1, 2, ...: SHA-256(i as 2 bytes little-endian || buffer), top bit cleared, read
/// big-endian, until the value is below the group order.
fn h3(sigma: &[u8; KEY_LEN], key: &[u8; KEY_LEN]) -> Option<Fr> {
    let mut first = Sha256::new();
    first.update(b"IBE-H3");
    first.update(sigma);
    first.update(key);
    let buffer = first.finalize();
    let mut i: u16 = 1;
    while i < u16::MAX {
        let mut round = Sha256::new();
        round.update(i.to_le_bytes());
        round.update(buffer.as_slice());
        let mut bytes = [0u8; 32];
        bytes.copy_from_slice(round.finalize().as_slice());
        bytes[0] >>= 1;
        let mut limbs = [0u64; 4];
        let mut k = 0;
        while k < 4 {
            let mut limb = [0u8; 8];
            limb.copy_from_slice(&bytes[(3 - k) * 8..(4 - k) * 8]);
            limbs[k] = u64::from_be_bytes(limb);
            k += 1;
        }
        if let Some(scalar) = Fr::from_bigint(BigInt::new(limbs)) {
            return Some(scalar);
        }
        i += 1;
    }
    None
}

fn xor_into(out: &mut [u8], a: &[u8; KEY_LEN], b: &[u8; KEY_LEN]) {
    let mut i = 0;
    while i < KEY_LEN {
        out[i] = a[i] ^ b[i];
        i += 1;
    }
}

/// Locks `key` to `round` of the pinned chain, with `sigma` the 16 random bytes of the
/// scheme. None if the round is 0 or a curve step refuses.
///
/// Anyone who learns r, rQ, the pairing value or either mask can open the lock without
/// the round's signature, so each is wiped as soon as it is used. The curve types are
/// `Copy`, so a copy the arithmetic made on the stack may outlive this; the wipe is of
/// every value this function holds.
pub fn lock(round: u64, key: &[u8; KEY_LEN], sigma: &[u8; KEY_LEN]) -> Option<[u8; BODY_LEN]> {
    if round == 0 {
        return None;
    }
    let public_key = pinned_public_key()?;
    let identity = hash_to_g1(&round_message(round))?;
    let mut r = h3(sigma, key)?;
    let u = (G2Projective::generator() * r).into_affine();
    let mut r_identity = (G1Projective::from(identity) * r).into_affine();
    r.zeroize();
    // e(Q, P)^r, computed as e(rQ, P).
    let mut shared = Bls12_381::pairing(r_identity, public_key);
    r_identity.zeroize();
    let mask = h2(&shared);
    shared.zeroize();
    let mut mask = mask?;
    let mut key_mask = h4(sigma);

    let mut u_bytes: Vec<u8> = Vec::with_capacity(96);
    if u.serialize_compressed(&mut u_bytes).is_err() || u_bytes.len() != 96 {
        mask.zeroize();
        key_mask.zeroize();
        return None;
    }
    let mut body = [0u8; BODY_LEN];
    body[..96].copy_from_slice(&u_bytes);
    xor_into(&mut body[96..96 + KEY_LEN], sigma, &mask);
    xor_into(&mut body[96 + KEY_LEN..], key, &key_mask);
    mask.zeroize();
    key_mask.zeroize();
    Some(body)
}

/// Opens a time-lock body with the signature of its round. None if the signature or U is
/// not a valid point, or if the Fujisaki-Okamoto check fails: a signature of any other
/// round, or a body changed in any bit, opens nothing.
pub fn unlock(signature: &[u8; 48], body: &[u8; BODY_LEN]) -> Option<[u8; KEY_LEN]> {
    let private_key = signature_point(signature)?;
    let u = match G2Affine::deserialize_compressed(&body[..96]) {
        Ok(p) => p,
        Err(_) => return None,
    };
    if u.is_zero() {
        return None;
    }
    let mut shared = Bls12_381::pairing(private_key, u);
    let mask = h2(&shared);
    shared.zeroize();
    let mut mask = mask?;
    let mut v = [0u8; KEY_LEN];
    v.copy_from_slice(&body[96..96 + KEY_LEN]);
    let mut w = [0u8; KEY_LEN];
    w.copy_from_slice(&body[96 + KEY_LEN..]);

    let mut sigma = [0u8; KEY_LEN];
    xor_into(&mut sigma, &v, &mask);
    mask.zeroize();
    let mut key_mask = h4(&sigma);
    let mut key = [0u8; KEY_LEN];
    xor_into(&mut key, &w, &key_mask);
    key_mask.zeroize();

    let r = match h3(&sigma, &key) {
        Some(r) => r,
        None => {
            key.zeroize();
            sigma.zeroize();
            return None;
        }
    };
    sigma.zeroize();
    let check = (G2Projective::generator() * r).into_affine();
    if check != u {
        key.zeroize();
        return None;
    }
    Some(key)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::beacon::vectors::{hex, signature, unhex};

    const KEY: [u8; 16] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
    const SIGMA: [u8; 16] = [
        0xf0, 0xe1, 0xd2, 0xc3, 0xb4, 0xa5, 0x96, 0x87, 0x78, 0x69, 0x5a, 0x4b, 0x3c, 0x2d, 0x1e, 0x0f,
    ];

    // From an independent implementation of the same scheme on the noble libraries
    // (noble-curves 1.9.1, the library tlock's JavaScript port is built on), for round
    // 1000 of quicknet with the key and sigma above.
    const VECTOR_U: &str = "821c0b37bfe5ae95c1e10a1dbc536ff68e3340e6c1b5c4718f24097b1372389102e9a40d58a10417eb50a3eae2eda34901f7e260d6d85aecf69a51124f688f84d00b5507b3aa938a48b1d79bc3d16d28abdd0bd2a73c8554167669b89e2f9f76";
    const VECTOR_V: &str = "77782db43ab8d2e309c3b6131395949f";
    const VECTOR_W: &str = "461dd21a1e7d19695c5d908fe005c6a9";

    fn vector_body() -> [u8; BODY_LEN] {
        let mut body = [0u8; BODY_LEN];
        let mut bytes = unhex(VECTOR_U);
        bytes.extend_from_slice(&unhex(VECTOR_V));
        bytes.extend_from_slice(&unhex(VECTOR_W));
        body.copy_from_slice(&bytes);
        body
    }

    #[test]
    fn a_lock_matches_the_independent_vector() {
        let body = lock(1_000, &KEY, &SIGMA).unwrap();
        assert_eq!(hex(&body[..96]), VECTOR_U);
        assert_eq!(hex(&body[96..112]), VECTOR_V);
        assert_eq!(hex(&body[112..]), VECTOR_W);
    }

    #[test]
    fn the_real_round_signature_opens_the_lock() {
        assert_eq!(unlock(&signature(1_000), &vector_body()), Some(KEY));
        let body = lock(12_345_678, &KEY, &SIGMA).unwrap();
        assert_eq!(unlock(&signature(12_345_678), &body), Some(KEY));
    }

    #[test]
    fn another_round_opens_nothing() {
        let body = vector_body();
        assert_eq!(unlock(&signature(1_001), &body), None);
        assert_eq!(unlock(&signature(1), &body), None);
        assert_eq!(unlock(&signature(12_345_678), &body), None);
        // An early round cannot open a lock to a later one.
        let later = lock(12_345_678, &KEY, &SIGMA).unwrap();
        assert_eq!(unlock(&signature(1_000), &later), None);
        assert_eq!(unlock(&signature(1_001), &later), None);
    }

    #[test]
    fn a_changed_bit_anywhere_opens_nothing() {
        let good = vector_body();
        let sig = signature(1_000);
        let positions: [usize; 9] = [0, 1, 50, 95, 96, 103, 111, 112, 127];
        for index in positions.iter() {
            let mut body = good;
            body[*index] ^= 0x01;
            assert_eq!(unlock(&sig, &body), None, "a flip at byte {} opened", index);
        }
        let mut sig_flipped = sig;
        sig_flipped[47] ^= 0x01;
        assert_eq!(unlock(&sig_flipped, &good), None);
        assert_eq!(unlock(&[0u8; 48], &good), None);
    }

    // A build check, in the style of the capsule's: `lock` wipes r, rQ, the pairing value
    // and both masks. Each one opens the lock without the round's signature.
    #[test]
    fn lock_wipes_every_value_that_would_open_it() {
        let source = include_str!("timelock.rs");
        let start = source.find("pub fn lock(").unwrap();
        let end = source.find("pub fn unlock(").unwrap();
        let body = &source[start..end];
        for wipe in ["r.zeroize();", "r_identity.zeroize();", "shared.zeroize();", "mask.zeroize();", "key_mask.zeroize();"].iter() {
            assert!(body.contains(wipe), "lock does not call {}", wipe);
        }
        // Every early return after the masks exist wipes them first.
        let after_masks = &body[body.find("let mut key_mask").unwrap()..];
        assert_eq!(after_masks.matches("return None;").count(), 1);
        assert_eq!(after_masks.matches("key_mask.zeroize();").count(), 2);
    }

    #[test]
    fn round_zero_cannot_be_locked_to() {
        assert_eq!(lock(0, &KEY, &SIGMA), None);
    }

    #[test]
    fn each_sigma_gives_another_body_and_every_one_opens() {
        let mut other_sigma = SIGMA;
        other_sigma[0] ^= 0xFF;
        let a = lock(1_000, &KEY, &SIGMA).unwrap();
        let b = lock(1_000, &KEY, &other_sigma).unwrap();
        assert_ne!(a[..], b[..]);
        assert_eq!(unlock(&signature(1_000), &b), Some(KEY));
    }
}
