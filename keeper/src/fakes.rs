// SPDX-License-Identifier: Apache-2.0
//! Fake implementations of the boundary traits, for tests only. This module is compiled
//! only under `cfg(test)`: no fake clock, beacon or random source can reach a release.

use crate::boundary::{RandomSource, RoundVerifier, TimeSource};
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
    fn request_id(&mut self) -> [u8; 16] {
        self.next = self.next.wrapping_add(1);
        [self.next; 16]
    }
}
