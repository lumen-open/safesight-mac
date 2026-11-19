// SPDX-License-Identifier: Apache-2.0
//! End-to-end tests of the command-line opener (SD-066): the real binary, run as an owner
//! would run it, on the stored version 1 capsule and on capsules sealed here, with real
//! rounds of the public time signal. Every key and secret is made up; none is real.
//!
//! Built only with the `opener` feature: `cargo test --features opener`.
#![cfg(feature = "opener")]

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use safesightmac_keeper::boundary::{RandomSource, RandomUnavailable};
use safesightmac_keeper::capsule::{seal, AdminSecret, RecoveryIdentity, RecoveryRecipients};
use safesightmac_keeper::opener::{public_key_text, recovery_key_text, round_url, MIRRORS};
use sha2::{Digest, Sha256};

const VECTORS: &str = include_str!("../../opener/vectors/v1.txt");
const OPENER: &str = env!("CARGO_BIN_EXE_safesightmac-opener");

// ----- Reading the stored vectors -----

fn vector(name: &str) -> String {
    for line in VECTORS.lines() {
        if let Some(rest) = line.strip_prefix(name) {
            if let Some(value) = rest.strip_prefix(' ') {
                return value.to_string();
            }
        }
    }
    panic!("no {} in the vectors", name);
}

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap()).collect()
}

fn base64(text: &str) -> Vec<u8> {
    let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::new();
    let (mut acc, mut bits) = (0u32, 0);
    for c in text.bytes().take_while(|c| *c != b'=') {
        acc = (acc << 6) | alphabet.iter().position(|x| *x == c).unwrap() as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    out
}

fn key32(text: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    out.copy_from_slice(&unhex(text));
    out
}

fn stored_copy() -> Vec<u8> {
    base64(&vector("base64"))
}

fn stored_secret() -> String {
    vector("secret")
}

fn key_text(scalar: [u8; 32]) -> String {
    recovery_key_text(&RecoveryIdentity::from_bytes(scalar)).to_string()
}

fn stored_key() -> String {
    key_text(key32(&vector("key")))
}

fn other_key() -> String {
    key_text(key32(&vector("other-key")))
}

/// The mirror's answer for one of the stored real rounds.
fn answer(round: u64) -> String {
    vector(&format!("round {}", round))
}

/// The signature in a stored answer.
fn signature_hex(round: u64) -> String {
    let a = answer(round);
    let start = a.find("\"signature\":\"").unwrap() + 13;
    a[start..start + 96].to_string()
}

// ----- Running the tool -----

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let dir = std::env::temp_dir().join(format!("safesightmac-opener-test-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Scratch(dir)
    }

    fn file(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.0.join(name);
        std::fs::write(&path, bytes).unwrap();
        path
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Run {
    status: i32,
    stdout: String,
    stderr: String,
}

fn run(args: &[&Path], extra: &[&str], stdin: &[u8]) -> Run {
    let mut command = Command::new(OPENER);
    for a in args.iter() {
        command.arg(a);
    }
    // Options go after the copy, as the tool's own help shows them.
    let mut i = 0;
    while i < extra.len() {
        command.arg(extra[i]);
        i += 1;
    }
    let mut child = command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    {
        let mut input = child.stdin.take().unwrap();
        let _ = input.write_all(stdin);
    }
    let out = child.wait_with_output().unwrap();
    Run {
        status: out.status.code().unwrap_or(-1),
        stdout: String::from_utf8(out.stdout).unwrap(),
        stderr: String::from_utf8(out.stderr).unwrap(),
    }
}

/// Runs with the copy, `--round <round file>`, and the key on standard input.
fn open(copy: &Path, round: &Path, key: &str) -> Run {
    let round_text = round.to_str().unwrap().to_string();
    run(&[copy], &["--round", &round_text], format!("{}\n", key).as_bytes())
}

/// No run ever shows the key it was given, or the secret on standard error.
fn assert_quiet(r: &Run, key: &str) {
    assert!(!r.stderr.contains(key), "the key was shown");
    assert!(!r.stdout.contains(key), "the key was shown");
    assert!(!r.stderr.contains(&stored_secret()), "the secret went to standard error");
}

/// A deterministic random source for sealing test capsules here.
struct Counter(u64);

impl RandomSource for Counter {
    fn request_id(&mut self) -> [u8; 16] {
        let mut out = [0u8; 16];
        let _ = self.fill(&mut out);
        out
    }

    fn fill(&mut self, out: &mut [u8]) -> Result<(), RandomUnavailable> {
        for chunk in out.chunks_mut(32) {
            self.0 += 1;
            let digest = Sha256::digest([b"opener cli test".as_slice(), &self.0.to_le_bytes()].concat());
            chunk.copy_from_slice(&digest[..chunk.len()]);
        }
        Ok(())
    }
}

const MADE_UP_SECRET: &[u8; 40] = b"Test-Only-Secret-Not-Real-0123456789abcd";

/// A copy sealed here to `target`, for one key or two.
fn sealed(target: u64, keys: &[[u8; 32]]) -> Vec<u8> {
    let secret = AdminSecret::from_bytes(MADE_UP_SECRET).unwrap();
    let current = RecoveryIdentity::from_bytes(keys[0]).public();
    let overlap = keys.get(1).map(|k| RecoveryIdentity::from_bytes(*k).public());
    let recipients = RecoveryRecipients { current, overlap };
    seal(&secret, &recipients, 5, target, &mut Counter(target)).unwrap().encode().unwrap()
}

// ----- The tests -----

#[test]
fn the_stored_copy_opens_with_its_round_and_key() {
    let s = Scratch::new("opens");
    let copy = s.file("copy.ssmc", &stored_copy());
    let round = s.file("round.json", answer(1_000).as_bytes());
    let r = open(&copy, &round, &stored_key());
    assert_eq!(r.status, 0, "{}", r.stderr);
    // The secret alone on standard output, once.
    assert_eq!(r.stdout, format!("{}\n", stored_secret()));
    assert!(r.stderr.contains("version 3 of its Mac's admin password"));
    assert!(r.stderr.contains("Wednesday 23 August 2023 at 15:59 UTC (time signal round 1,000)"));
    assert!(r.stderr.contains("\"SafeSight Mac administrator\""));
    assert!(r.stderr.contains("7 days from the Mac's first start"));
    assert!(r.stderr.contains("It is 40 characters long"));
    assert_quiet(&r, &stored_key());
}

#[test]
fn the_key_can_come_from_a_file_or_a_key_file_with_comments() {
    let s = Scratch::new("keyfile");
    let copy = s.file("copy.ssmc", &stored_copy());
    let round = s.file("round.json", answer(1_000).as_bytes());
    let identity = RecoveryIdentity::from_bytes(key32(&vector("key")));
    let key_file_text = format!("# created: 2026-11-19\n# public key: {}\n{}\n", public_key_text(&identity), stored_key());
    let key_file = s.file("key.txt", key_file_text.as_bytes());
    let round_text = round.to_str().unwrap().to_string();
    let key_text = key_file.to_str().unwrap().to_string();
    let r = run(&[&copy], &["--round", &round_text, "--key-file", &key_text], b"");
    assert_eq!(r.status, 0, "{}", r.stderr);
    assert_eq!(r.stdout, format!("{}\n", stored_secret()));
    assert_quiet(&r, &stored_key());

    // The same with the --option=value spelling, and the key in lower case.
    let lower = s.file("lower.txt", stored_key().to_lowercase().as_bytes());
    let r = run(
        &[&copy],
        &[&format!("--round={}", round_text), &format!("--key-file={}", lower.to_str().unwrap())],
        b"",
    );
    assert_eq!(r.status, 0, "{}", r.stderr);
}

#[test]
fn without_a_round_it_names_the_exact_addresses_to_download() {
    let s = Scratch::new("noround");
    let copy = s.file("copy.ssmc", &stored_copy());
    let r = run(&[&copy], &[], b"");
    assert_eq!(r.status, 3);
    assert_eq!(r.stdout, "");
    for m in MIRRORS.iter() {
        assert!(r.stderr.contains(&round_url(m, 1_000)), "{}", r.stderr);
    }
    assert!(r.stderr.contains(
        "https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/public/1000"
    ));
    assert!(r.stderr.contains("--round round.json"));
}

#[test]
fn a_copy_whose_time_has_not_come_says_when() {
    let s = Scratch::new("future");
    // Round 2,000,000,000 of the time signal is published in the year 2213.
    let copy = s.file("future.ssmc", &sealed(2_000_000_000, &[key32(&vector("key"))]));
    let r = run(&[&copy], &[], b"");
    assert_eq!(r.status, 3);
    assert!(r.stderr.contains("2213"), "{}", r.stderr);
    assert!(r.stderr.contains("By this computer's clock that is in about"));
    assert!(r.stderr.contains("not you, not anyone"));

    // A real round from before the target: not yet, with both dates.
    let round = s.file("round.json", answer(30_000_000).as_bytes());
    let r = open(&copy, &round, &stored_key());
    assert_eq!(r.status, 3, "{}", r.stderr);
    assert!(r.stderr.contains("Not yet. That time signal is round 30,000,000, from Tuesday 30 June 2026"));
    assert!(r.stderr.contains("round 2,000,000,000"));
    assert_eq!(r.stdout, "");
    assert_quiet(&r, &stored_key());

    // What a mirror answers for a round still to come.
    let early = s.file("early.txt", b"Requested future beacon\n");
    let r = open(&copy, &early, &stored_key());
    assert_eq!(r.status, 3, "{}", r.stderr);
    assert!(r.stderr.contains("doesn't exist yet"));
}

#[test]
fn an_earlier_round_is_not_yet_and_a_later_one_is_the_wrong_one() {
    let s = Scratch::new("rounds");
    let copy = s.file("copy.ssmc", &stored_copy());
    let early = s.file("r1.json", answer(1).as_bytes());
    let r = open(&copy, &early, &stored_key());
    assert_eq!(r.status, 3);
    assert!(r.stderr.contains("Not yet. That time signal is round 1, from Wednesday 23 August 2023 at 15:09 UTC"));
    assert_eq!(r.stdout, "");

    let late = s.file("r1001.json", answer(1_001).as_bytes());
    let r = open(&copy, &late, &stored_key());
    assert_eq!(r.status, 1);
    assert!(r.stderr.contains("This copy needs round 1,000 exactly"));
    assert_eq!(r.stdout, "");
}

#[test]
fn a_forged_or_changed_round_is_refused() {
    let s = Scratch::new("forged");
    let copy = s.file("copy.ssmc", &stored_copy());
    // Round 1000 claimed with round 1001's signature.
    let forged = format!("{{\"round\":1000,\"signature\":\"{}\"}}", signature_hex(1_001));
    let forged = s.file("forged.json", forged.as_bytes());
    let r = open(&copy, &forged, &stored_key());
    assert_eq!(r.status, 1);
    assert!(r.stderr.contains("doesn't check out"), "{}", r.stderr);
    assert_eq!(r.stdout, "");

    // The answer with one digit of its signature changed: its randomness no longer matches.
    let changed = answer(1_000).replacen("\"signature\":\"b4", "\"signature\":\"b5", 1);
    let changed = s.file("changed.json", changed.as_bytes());
    let r = open(&copy, &changed, &stored_key());
    assert_eq!(r.status, 1);
    assert!(r.stderr.contains("its parts don't match"), "{}", r.stderr);
}

#[test]
fn the_signature_alone_opens_it() {
    let s = Scratch::new("bare");
    let copy = s.file("copy.ssmc", &stored_copy());
    let bare = s.file("sig.txt", format!("{}\n", signature_hex(1_000)).as_bytes());
    let r = open(&copy, &bare, &stored_key());
    assert_eq!(r.status, 0, "{}", r.stderr);
    assert_eq!(r.stdout, format!("{}\n", stored_secret()));

    let wrong = s.file("sig1001.txt", signature_hex(1_001).as_bytes());
    let r = open(&copy, &wrong, &stored_key());
    assert_eq!(r.status, 1);
    assert!(r.stderr.contains("isn't the time signal's signature for round 1,000"), "{}", r.stderr);
}

#[test]
fn a_wrong_key_opens_nothing_and_says_why() {
    let s = Scratch::new("keys");
    let copy = s.file("copy.ssmc", &stored_copy());
    let round = s.file("round.json", answer(1_000).as_bytes());

    let r = open(&copy, &round, &other_key());
    assert_eq!(r.status, 1);
    assert!(r.stderr.contains("doesn't open this copy"));
    assert_eq!(r.stdout, "");
    assert_quiet(&r, &other_key());

    let mut typo = stored_key().into_bytes();
    typo[40] = if typo[40] == b'Q' { b'P' } else { b'Q' };
    let typo = String::from_utf8(typo).unwrap();
    let r = open(&copy, &round, &typo);
    assert_eq!(r.status, 1);
    assert!(r.stderr.contains("typing mistake"));
    assert_eq!(r.stdout, "");
    assert_quiet(&r, &typo);

    let public = public_key_text(&RecoveryIdentity::from_bytes(key32(&vector("key"))));
    let r = open(&copy, &round, &public);
    assert_eq!(r.status, 1);
    assert!(r.stderr.contains("public half"));

    let r = open(&copy, &round, "");
    assert_eq!(r.status, 1);
    assert!(r.stderr.contains("No Recovery Key was given"));

    let r = open(&copy, &round, "my password is hunter2");
    assert_eq!(r.status, 1);
    assert!(r.stderr.contains("isn't a Recovery Key"));
}

#[test]
fn a_key_on_the_command_line_is_refused_and_never_repeated() {
    let s = Scratch::new("argkey");
    let copy = s.file("copy.ssmc", &stored_copy());
    let key = stored_key();
    let r = run(&[&copy], &[&key], b"");
    assert_eq!(r.status, 2);
    assert!(r.stderr.contains("Don't put your Recovery Key on the command line"));
    assert_quiet(&r, &key);
    let r = run(&[&copy], &["--key-file", &key.to_lowercase()], b"");
    assert_eq!(r.status, 2);
    assert_quiet(&r, &key.to_lowercase());
}

#[test]
fn what_is_not_a_good_copy_is_refused() {
    let s = Scratch::new("badcopy");
    let round = s.file("round.json", answer(1_000).as_bytes());
    // The round file given as the copy.
    let r = open(&round, &round, &stored_key());
    assert_eq!(r.status, 1);
    assert!(r.stderr.contains("isn't a SafeSight Mac recovery copy"));

    let mut damaged = stored_copy();
    damaged[1_000] ^= 0x04;
    let damaged = s.file("damaged.ssmc", &damaged);
    let r = open(&damaged, &round, &stored_key());
    assert_eq!(r.status, 1);
    assert!(r.stderr.contains("is damaged"));
    assert_eq!(r.stdout, "");

    let big = s.file("big.ssmc", &vec![0u8; 10_000]);
    let r = open(&big, &round, &stored_key());
    assert_eq!(r.status, 1);
    assert!(r.stderr.contains("too big"));

    let missing = s.0.join("not-there.ssmc");
    let r = open(&missing, &round, &stored_key());
    assert_eq!(r.status, 1);
    assert!(r.stderr.contains("Couldn't open the recovery copy"));
}

#[test]
fn a_copy_made_during_a_key_change_opens_with_either_key() {
    let s = Scratch::new("overlap");
    let first = key32(&vector("key"));
    let second = key32(&vector("other-key"));
    let copy = s.file("two.ssmc", &sealed(12_345_678, &[first, second]));
    let round = s.file("round.json", answer(12_345_678).as_bytes());
    let expected = format!("{}\n", String::from_utf8(MADE_UP_SECRET.to_vec()).unwrap());
    for key in [key_text(first), key_text(second)].iter() {
        let r = open(&copy, &round, key);
        assert_eq!(r.status, 0, "{}", r.stderr);
        assert_eq!(r.stdout, expected);
        assert!(r.stderr.contains("Friday 25 October 2024 at 07:13 UTC"));
    }
    let r = open(&copy, &round, &key_text([0x55u8; 32]));
    assert_eq!(r.status, 1);
}

#[test]
fn help_version_and_wrong_use() {
    let help = Command::new(OPENER).arg("--help").output().unwrap();
    assert_eq!(help.status.code(), Some(0));
    let text = String::from_utf8(help.stderr).unwrap();
    assert!(text.contains("Usage:"));
    assert!(text.contains("Never put your Recovery Key on the command line"));

    let version = Command::new(OPENER).arg("--version").output().unwrap();
    assert_eq!(version.status.code(), Some(0));
    assert!(String::from_utf8(version.stderr).unwrap().starts_with("SafeSight Mac opener 0.0.1"));

    assert_eq!(Command::new(OPENER).output().unwrap().status.code(), Some(2));
    assert_eq!(Command::new(OPENER).args(["a", "b"]).output().unwrap().status.code(), Some(2));
    assert_eq!(Command::new(OPENER).args(["a", "--round"]).output().unwrap().status.code(), Some(2));
    assert_eq!(Command::new(OPENER).args(["a", "--fetch"]).output().unwrap().status.code(), Some(2));
}
