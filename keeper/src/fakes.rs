// SPDX-License-Identifier: Apache-2.0
//! Fake implementations of the boundary traits, for tests only. This module is compiled
//! only under `cfg(test)`: no fake clock, beacon or random source can reach a release.

use crate::boundary::{RandomSource, RandomUnavailable, RawClocks, RoundVerifier, TimeSource};
use crate::constants::{BEACON_CHAIN_HASH, BEACON_GENESIS_UNIX_SECONDS, BEACON_PERIOD_SECONDS};
use crate::records::RoundRecord;

/// A Mac's clocks, and the real time beside them.
///
/// `true_unix_ms` is the real time: it decides which round the fake beacon has reached.
/// `wall_unix_ms` is what the Mac's date and time says; a test can set it wrong.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FakeTime {
    pub boot_ms: u64,
    pub awake_ms: u64,
    pub true_unix_ms: u64,
    pub wall_unix_ms: u64,
}

impl FakeTime {
    /// A Mac whose date is right, at the moment the beacon reaches `round`.
    pub fn at_round(round: u64) -> FakeTime {
        let unix_ms = (BEACON_GENESIS_UNIX_SECONDS + BEACON_PERIOD_SECONDS * (round - 1)) * 1_000;
        FakeTime { boot_ms: 5_000_000, awake_ms: 4_000_000, true_unix_ms: unix_ms, wall_unix_ms: unix_ms }
    }

    /// Time passes with the Mac awake: every clock moves.
    pub fn pass_awake_ms(&mut self, ms: u64) {
        self.boot_ms += ms;
        self.awake_ms += ms;
        self.true_unix_ms += ms;
        self.wall_unix_ms += ms;
    }

    /// Time passes with the Mac asleep: the awake counter stands still.
    pub fn pass_asleep_ms(&mut self, ms: u64) {
        self.boot_ms += ms;
        self.true_unix_ms += ms;
        self.wall_unix_ms += ms;
    }

    /// Time passes with the Mac powered off: neither carried counter moves.
    pub fn pass_powered_off_ms(&mut self, ms: u64) {
        self.true_unix_ms += ms;
        self.wall_unix_ms += ms;
    }

    /// The newest round the beacon has really produced.
    pub fn true_round(&self) -> u64 {
        (self.true_unix_ms / 1_000 - BEACON_GENESIS_UNIX_SECONDS) / BEACON_PERIOD_SECONDS + 1
    }
}

impl TimeSource for FakeTime {
    fn boot_total_ms(&self) -> u64 {
        self.boot_ms
    }

    fn awake_total_ms(&self) -> u64 {
        self.awake_ms
    }

    fn wall_clock_unix_seconds(&self) -> u64 {
        self.wall_unix_ms / 1_000
    }
}

/// A stand-in for the public time beacon and for the check of its signature. Its
/// "signature" is a fixed pattern of the round number. It proves nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FakeBeacon;

impl FakeBeacon {
    pub fn signature(round: u64) -> [u8; 48] {
        let mut signature = [0u8; 48];
        let round_bytes = round.to_le_bytes();
        let mut i = 0;
        while i < 48 {
            signature[i] = round_bytes[i % 8] ^ (i as u8) ^ 0x5A;
            i += 1;
        }
        signature
    }

    /// The round record the app would hand to the keeper for `round`.
    pub fn record_bytes(round: u64) -> Vec<u8> {
        let record = RoundRecord { chain_hash: BEACON_CHAIN_HASH, round, signature: FakeBeacon::signature(round) };
        record.encode().unwrap()
    }
}

impl RoundVerifier for FakeBeacon {
    fn verify_round(&self, round: u64, signature: &[u8; 48]) -> bool {
        *signature == FakeBeacon::signature(round)
    }
}

/// Request IDs that are different each time and easy to read in a failed test.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FakeRandom {
    pub next: u8,
}

impl FakeRandom {
    pub fn new() -> FakeRandom {
        FakeRandom { next: 0 }
    }
}

impl RandomSource for FakeRandom {
    fn request_id(&mut self) -> Result<[u8; 16], RandomUnavailable> {
        self.next = self.next.wrapping_add(1);
        Ok([self.next; 16])
    }

    fn fill(&mut self, out: &mut [u8]) -> Result<(), RandomUnavailable> {
        self.next = self.next.wrapping_add(1);
        for byte in out.iter_mut() {
            *byte = self.next;
        }
        Ok(())
    }
}

/// A random source for the cryptographic tests: bytes that look random and are the same
/// on every run, so that a test can compare with a vector made by another implementation.
/// Call n of `fill` gives SHA-256("safesightmac test random" || seed || n as 4 bytes
/// little-endian || block as 4 bytes little-endian) for blocks 0, 1, ..., cut to length.
/// It holds no real secret and none of its output is one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SeededRandom {
    seed: u8,
    calls: u32,
}

impl SeededRandom {
    pub fn new(seed: u8) -> SeededRandom {
        SeededRandom { seed, calls: 0 }
    }
}

impl RandomSource for SeededRandom {
    fn request_id(&mut self) -> Result<[u8; 16], RandomUnavailable> {
        let mut out = [0u8; 16];
        self.fill(&mut out)?;
        Ok(out)
    }

    fn fill(&mut self, out: &mut [u8]) -> Result<(), RandomUnavailable> {
        use sha2::{Digest, Sha256};
        let mut filled = 0;
        let mut block: u32 = 0;
        while filled < out.len() {
            let mut hash = Sha256::new();
            hash.update(b"safesightmac test random");
            hash.update([self.seed]);
            hash.update(self.calls.to_le_bytes());
            hash.update(block.to_le_bytes());
            let digest = hash.finalize();
            let take = if out.len() - filled < 32 { out.len() - filled } else { 32 };
            out[filled..filled + take].copy_from_slice(&digest.as_slice()[..take]);
            filled += take;
            block += 1;
        }
        self.calls += 1;
        Ok(())
    }
}

/// A random generator that has failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BrokenRandom;

impl RandomSource for BrokenRandom {
    fn request_id(&mut self) -> Result<[u8; 16], RandomUnavailable> {
        Err(RandomUnavailable)
    }

    fn fill(&mut self, _out: &mut [u8]) -> Result<(), RandomUnavailable> {
        Err(RandomUnavailable)
    }
}

/// A fresh, private scratch folder for one test, removed when the test ends. Inside the
/// system's temporary folder; nothing is written anywhere else.
#[derive(Debug)]
pub struct TestDir {
    pub path: std::path::PathBuf,
}

impl TestDir {
    pub fn new(name: &str) -> TestDir {
        use std::os::unix::fs::DirBuilderExt;
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let number = NEXT.fetch_add(1, Ordering::SeqCst);
        // The real path, with no link in it (on macOS the temporary folder is under /var,
        // a link to /private/var), so that the store's checks of every parent folder run.
        let base = std::fs::canonicalize(std::env::temp_dir()).unwrap();
        let path = base.join(format!(
            "safesightmac-keeper-test-{}-{}-{}",
            std::process::id(),
            number,
            name
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        // The mode asked for is narrowed by the process's mask; set it exactly.
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        TestDir { path }
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

/// A Mac's raw clocks across boots, and the real time beside them. Each boot starts both
/// raw clocks at zero and takes a new boot identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FakeMac {
    pub continuous_ms: u64,
    pub absolute_ms: u64,
    pub boot_session: [u8; 16],
    pub true_unix_ms: u64,
    pub wall_unix_ms: u64,
}

impl FakeMac {
    /// A Mac whose date is right, at the moment the beacon reaches `round`, booted
    /// `uptime_ms` ago and awake all that time.
    pub fn booted_at_round(round: u64, uptime_ms: u64) -> FakeMac {
        let unix_ms = (BEACON_GENESIS_UNIX_SECONDS + BEACON_PERIOD_SECONDS * (round - 1)) * 1_000;
        FakeMac {
            continuous_ms: uptime_ms,
            absolute_ms: uptime_ms,
            boot_session: [0xB0; 16],
            true_unix_ms: unix_ms,
            wall_unix_ms: unix_ms,
        }
    }

    pub fn pass_awake_ms(&mut self, ms: u64) {
        self.continuous_ms += ms;
        self.absolute_ms += ms;
        self.true_unix_ms += ms;
        self.wall_unix_ms += ms;
    }

    pub fn pass_asleep_ms(&mut self, ms: u64) {
        self.continuous_ms += ms;
        self.true_unix_ms += ms;
        self.wall_unix_ms += ms;
    }

    /// Switched off for `off_ms`, then switched on: a new boot.
    pub fn power_cycle(&mut self, off_ms: u64) {
        self.true_unix_ms += off_ms;
        self.wall_unix_ms += off_ms;
        self.continuous_ms = 0;
        self.absolute_ms = 0;
        let mut i = 0;
        while i < 16 {
            self.boot_session[i] = self.boot_session[i].wrapping_add((i as u8) + 1);
            i += 1;
        }
    }
}

impl RawClocks for FakeMac {
    fn continuous_ms(&self) -> u64 {
        self.continuous_ms
    }

    fn absolute_ms(&self) -> u64 {
        self.absolute_ms
    }

    fn boot_session(&self) -> [u8; 16] {
        self.boot_session
    }

    fn wall_clock_unix_seconds(&self) -> u64 {
        self.wall_unix_ms / 1_000
    }
}
