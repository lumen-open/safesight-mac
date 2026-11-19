// SPDX-License-Identifier: Apache-2.0
//! The keeper's clock: the high-water round, the estimate, round checking, the start-round
//! rule and tighten-time (SD-037 to SD-041; chapter 03 sections 2 and 3).
//!
//! This is the only module that reads the Mac's wall clock (invariant I3). It uses it in
//! two places and nowhere else: rule (b) of SD-039, where the wall clock may refuse a
//! round as a start round, and `tighten_round`, for acts that only tighten (SD-041).
//! The wall clock never matures a request, never shortens anything and is never a tamper
//! signal.
//!
//! `TimeSource` hands this module the carried totals; the carry across restarts and the
//! detection of a new boot are in `counters`, and the clock record's two slots on disk
//! are in `store`. `Clock::record` and `Clock::restore` turn this state into the clock
//! record and back.

use crate::boundary::{RoundVerifier, TimeSource};
use crate::counters::CounterState;
use crate::records::ClockRecord;
use crate::constants::{
    ANCHOR_CLOCK_TOLERANCE_ROUNDS, BEACON_CHAIN_HASH, BEACON_GENESIS_UNIX_SECONDS, BEACON_PERIOD_SECONDS,
    MS_PER_ROUND,
};
use crate::frame::RecordError;
use crate::records::RoundRecord;

/// The round implied by a wall-clock time: `floor((t - genesis) / BEACON_PERIOD) + 1`
/// (chapter 03 section 2). A time before the chain's genesis implies no round at all.
pub fn wall_clock_round(unix_seconds: u64) -> u64 {
    if unix_seconds < BEACON_GENESIS_UNIX_SECONDS {
        return 0;
    }
    (unix_seconds - BEACON_GENESIS_UNIX_SECONDS) / BEACON_PERIOD_SECONDS + 1
}

/// Why a round was dropped. A dropped round changes nothing and is never counted
/// against anyone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DropReason {
    /// Layout, length or checksum (step 1).
    Malformed(RecordError),
    /// Not the pinned chain (step 2).
    WrongChain,
    /// Below the high-water round (step 3).
    BelowHighWater,
    /// The signature does not verify (step 4).
    BadSignature,
}

/// A round the keeper verified and applied.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AcceptedRound {
    pub round: u64,
    /// The keeper's estimate just before this round was applied.
    pub estimate_before: u64,
    /// True if this round passes both rules of SD-039 and so may be a start round.
    pub may_start: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoundOutcome {
    Dropped(DropReason),
    Accepted(AcceptedRound),
}

/// The clock state of SD-037.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Clock {
    high_water_round: u64,
    high_water_signature: [u8; 48],
    high_water_boot_ms: u64,
    /// The estimate's base: a round, and the boot-counter value when it was taken. Equal
    /// to the high-water pair unless a round arrived below the estimate (I03-1).
    base_round: u64,
    base_boot_ms: u64,
    /// The highest readings seen, so that a counter source that misbehaves cannot move
    /// the estimate back.
    last_boot_ms: u64,
    last_awake_ms: u64,
    /// "Clock refusing rounds": the last round that could have been a start round was
    /// refused by rule (b). A fault with a fix, nothing more.
    clock_refuses_rounds: bool,
}

fn check_round(bytes: &[u8], verifier: &dyn RoundVerifier) -> Result<RoundRecord, DropReason> {
    let record = match RoundRecord::decode(bytes) {
        Ok(r) => r,
        Err(e) => return Err(DropReason::Malformed(e)),
    };
    if record.chain_hash != BEACON_CHAIN_HASH {
        return Err(DropReason::WrongChain);
    }
    if !verifier.verify_round(record.round, &record.signature) {
        return Err(DropReason::BadSignature);
    }
    Ok(record)
}

impl Clock {
    /// The clock at Lock, built from the first verified round. The record is checked as
    /// any round is: layout, pinned chain, signature. That the round is fresh is Lock's
    /// own rule (SD-184) and is not checked here.
    pub fn at_lock(
        round_record: &[u8],
        verifier: &dyn RoundVerifier,
        time: &dyn TimeSource,
    ) -> Result<Clock, DropReason> {
        let record = check_round(round_record, verifier)?;
        let boot_now = time.boot_total_ms();
        Ok(Clock {
            high_water_round: record.round,
            high_water_signature: record.signature,
            high_water_boot_ms: boot_now,
            base_round: record.round,
            base_boot_ms: boot_now,
            last_boot_ms: boot_now,
            last_awake_ms: time.awake_total_ms(),
            clock_refuses_rounds: false,
        })
    }

    /// The clock at start-up, from the clock record read back from the store. The
    /// high-water round's signature is checked again, so the record proves itself
    /// (chapter 03 section 2). A record whose round does not verify is not adopted; what
    /// follows is SD-227's table ("clock record: none adopted").
    pub fn restore(record: &ClockRecord, verifier: &dyn RoundVerifier) -> Result<Clock, DropReason> {
        if !verifier.verify_round(record.high_water_round, &record.high_water_signature) {
            return Err(DropReason::BadSignature);
        }
        Ok(Clock {
            high_water_round: record.high_water_round,
            high_water_signature: record.high_water_signature,
            high_water_boot_ms: record.high_water_boot_ms,
            base_round: record.estimate_base_round,
            base_boot_ms: record.estimate_base_boot_ms,
            last_boot_ms: record.boot_total_ms,
            last_awake_ms: record.awake_total_ms,
            clock_refuses_rounds: false,
        })
    }

    /// The clock record to save now (every `COUNTER_SAVE` and at every verified round):
    /// this clock's rounds and estimate base, with the carried counters as they are now.
    /// The store refuses it unless it follows the record before it, so a total that
    /// would move back is never written.
    pub fn record(&self, sequence: u64, counters: &CounterState) -> ClockRecord {
        ClockRecord {
            sequence,
            high_water_round: self.high_water_round,
            high_water_signature: self.high_water_signature,
            high_water_boot_ms: self.high_water_boot_ms,
            estimate_base_round: self.base_round,
            estimate_base_boot_ms: self.base_boot_ms,
            boot_total_ms: counters.boot_total_ms,
            awake_total_ms: counters.awake_total_ms,
            last_boot_reading_ms: counters.last_boot_reading_ms,
            last_awake_reading_ms: counters.last_awake_reading_ms,
            boot_session: counters.boot_session,
        }
    }

    /// The highest round whose signature the keeper has verified. Never moves back.
    pub fn high_water_round(&self) -> u64 {
        self.high_water_round
    }

    /// The signature of the high-water round, kept so the clock record proves itself.
    pub fn high_water_signature(&self) -> [u8; 48] {
        self.high_water_signature
    }

    /// The boot-counter value when the high-water round was first verified.
    pub fn high_water_boot_ms(&self) -> u64 {
        self.high_water_boot_ms
    }

    /// True while rule (b) of SD-039 is refusing rounds as start rounds. The app then
    /// says "Set the date and time to automatic".
    pub fn clock_refuses_rounds(&self) -> bool {
        self.clock_refuses_rounds
    }

    /// The boot counter now. Never lower than a value this clock has already seen.
    pub fn boot_now_ms(&mut self, time: &dyn TimeSource) -> u64 {
        let reading = time.boot_total_ms();
        if reading > self.last_boot_ms {
            self.last_boot_ms = reading;
        }
        self.last_boot_ms
    }

    /// The awake counter now. Never lower than a value this clock has already seen.
    pub fn awake_now_ms(&mut self, time: &dyn TimeSource) -> u64 {
        let reading = time.awake_total_ms();
        if reading > self.last_awake_ms {
            self.last_awake_ms = reading;
        }
        self.last_awake_ms
    }

    fn estimate_at(&self, boot_now: u64) -> u64 {
        let elapsed_rounds = boot_now.saturating_sub(self.base_boot_ms) / MS_PER_ROUND;
        self.base_round.saturating_add(elapsed_rounds)
    }

    /// The keeper's estimate of the present round: the base round plus the boot-counter
    /// time since it was taken. It can only lag real time, and it never moves back.
    /// Acts that loosen use this and the high-water round only (SD-041).
    pub fn estimate(&mut self, time: &dyn TimeSource) -> u64 {
        let boot_now = self.boot_now_ms(time);
        self.estimate_at(boot_now)
    }

    /// Tighten-time: the later of the estimate and the round implied by the wall clock
    /// (SD-041). For acts that only tighten, and for refusing. Never for an act that
    /// loosens, and never for writing something final (R1-lock-02).
    pub fn tighten_round(&mut self, time: &dyn TimeSource) -> u64 {
        let estimate = self.estimate(time);
        let wall = wall_clock_round(time.wall_clock_unix_seconds());
        if wall > estimate {
            wall
        } else {
            estimate
        }
    }

    /// The keeper's check of a round, in the order of chapter 03 section 2:
    /// (1) layout, length and checksum; (2) the pinned chain; (3) not below the
    /// high-water round; (4) the signature; (5) the new high-water round; (6) the
    /// estimate is re-based only by a round above it. Step 7, the request rules, is the
    /// caller's: the outcome says whether the round may be a start round (SD-039).
    pub fn offer_round(
        &mut self,
        round_record: &[u8],
        verifier: &dyn RoundVerifier,
        time: &dyn TimeSource,
    ) -> RoundOutcome {
        let record = match RoundRecord::decode(round_record) {
            Ok(r) => r,
            Err(e) => return RoundOutcome::Dropped(DropReason::Malformed(e)),
        };
        if record.chain_hash != BEACON_CHAIN_HASH {
            return RoundOutcome::Dropped(DropReason::WrongChain);
        }
        if record.round < self.high_water_round {
            return RoundOutcome::Dropped(DropReason::BelowHighWater);
        }
        if !verifier.verify_round(record.round, &record.signature) {
            return RoundOutcome::Dropped(DropReason::BadSignature);
        }

        let boot_now = self.boot_now_ms(time);
        let estimate_before = self.estimate_at(boot_now);

        // A round equal to the high-water round proves nothing new. It does not refresh
        // the moment the high-water round was verified.
        if record.round > self.high_water_round {
            self.high_water_round = record.round;
            self.high_water_signature = record.signature;
            self.high_water_boot_ms = boot_now;
        }
        if record.round > estimate_before {
            self.base_round = record.round;
            self.base_boot_ms = boot_now;
        }

        // SD-039. Rule (a): not below the estimate at that moment. Rule (b): not more
        // than the tolerance behind the round implied by the wall clock. Rule (b) can
        // only refuse.
        let rule_a = record.round >= estimate_before;
        let wall = wall_clock_round(time.wall_clock_unix_seconds());
        let rule_b = record.round.saturating_add(ANCHOR_CLOCK_TOLERANCE_ROUNDS) >= wall;
        if rule_a {
            self.clock_refuses_rounds = !rule_b;
        }

        RoundOutcome::Accepted(AcceptedRound { round: record.round, estimate_before, may_start: rule_a && rule_b })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fakes::{FakeBeacon, FakeTime};

    const R0: u64 = 1_000_000;

    fn clock_at(time: &FakeTime) -> Clock {
        Clock::at_lock(&FakeBeacon::record_bytes(R0), &FakeBeacon, time).unwrap()
    }

    fn accepted(outcome: RoundOutcome) -> AcceptedRound {
        match outcome {
            RoundOutcome::Accepted(a) => a,
            RoundOutcome::Dropped(reason) => panic!("dropped: {:?}", reason),
        }
    }

    #[test]
    fn the_wall_clock_round_follows_the_chain_formula() {
        let g = BEACON_GENESIS_UNIX_SECONDS;
        assert_eq!(wall_clock_round(0), 0);
        assert_eq!(wall_clock_round(g - 1), 0);
        assert_eq!(wall_clock_round(g), 1);
        assert_eq!(wall_clock_round(g + 2), 1);
        assert_eq!(wall_clock_round(g + 3), 2);
        assert_eq!(wall_clock_round(g + 3 * 28_800), 28_801);
        let time = FakeTime::at_round(R0);
        assert_eq!(wall_clock_round(time.wall_unix_ms / 1_000), R0);
        assert_eq!(time.true_round(), R0);
    }

    #[test]
    fn the_clock_at_lock_starts_on_a_checked_round() {
        let time = FakeTime::at_round(R0);
        let mut clock = clock_at(&time);
        assert_eq!(clock.high_water_round(), R0);
        assert_eq!(clock.high_water_signature(), FakeBeacon::signature(R0));
        assert_eq!(clock.high_water_boot_ms(), time.boot_ms);
        assert_eq!(clock.estimate(&time), R0);
        assert!(!clock.clock_refuses_rounds());

        assert_eq!(
            Clock::at_lock(&[1, 2, 3], &FakeBeacon, &time),
            Err(DropReason::Malformed(RecordError::TooShort))
        );
        let other_chain = RoundRecord { chain_hash: [9; 32], round: R0, signature: FakeBeacon::signature(R0) };
        assert_eq!(
            Clock::at_lock(&other_chain.encode().unwrap(), &FakeBeacon, &time),
            Err(DropReason::WrongChain)
        );
        let forged = RoundRecord { chain_hash: BEACON_CHAIN_HASH, round: R0, signature: [0; 48] };
        assert_eq!(
            Clock::at_lock(&forged.encode().unwrap(), &FakeBeacon, &time),
            Err(DropReason::BadSignature)
        );
    }

    #[test]
    fn a_dropped_round_changes_nothing() {
        let mut time = FakeTime::at_round(R0);
        let mut clock = clock_at(&time);
        time.pass_awake_ms(60_000);
        let _ = clock.estimate(&time);
        let before = clock.clone();

        assert_eq!(
            clock.offer_round(&[], &FakeBeacon, &time),
            RoundOutcome::Dropped(DropReason::Malformed(RecordError::TooShort))
        );
        let mut torn = FakeBeacon::record_bytes(R0 + 20);
        torn[50] ^= 1;
        assert_eq!(
            clock.offer_round(&torn, &FakeBeacon, &time),
            RoundOutcome::Dropped(DropReason::Malformed(RecordError::BadChecksum))
        );
        let mut oversized = FakeBeacon::record_bytes(R0 + 20);
        oversized.push(0);
        assert_eq!(
            clock.offer_round(&oversized, &FakeBeacon, &time),
            RoundOutcome::Dropped(DropReason::Malformed(RecordError::WrongLength))
        );
        let other_chain = RoundRecord { chain_hash: [9; 32], round: R0 + 20, signature: FakeBeacon::signature(R0 + 20) };
        assert_eq!(
            clock.offer_round(&other_chain.encode().unwrap(), &FakeBeacon, &time),
            RoundOutcome::Dropped(DropReason::WrongChain)
        );
        assert_eq!(
            clock.offer_round(&FakeBeacon::record_bytes(R0 - 1), &FakeBeacon, &time),
            RoundOutcome::Dropped(DropReason::BelowHighWater)
        );
        // A round number far ahead with a signature made for another round.
        let forged = RoundRecord {
            chain_hash: BEACON_CHAIN_HASH,
            round: R0 + 10_000_000,
            signature: FakeBeacon::signature(R0 + 20),
        };
        assert_eq!(
            clock.offer_round(&forged.encode().unwrap(), &FakeBeacon, &time),
            RoundOutcome::Dropped(DropReason::BadSignature)
        );

        assert_eq!(clock, before);
    }

    #[test]
    fn the_estimate_counts_the_boot_counter_and_not_the_date() {
        let mut time = FakeTime::at_round(R0);
        let mut clock = clock_at(&time);
        // Awake and asleep both count on the boot counter.
        time.pass_awake_ms(30_000);
        assert_eq!(clock.estimate(&time), R0 + 10);
        time.pass_asleep_ms(2_999);
        assert_eq!(clock.estimate(&time), R0 + 10);
        time.pass_asleep_ms(1);
        assert_eq!(clock.estimate(&time), R0 + 11);
        // Time powered off is not counted: the estimate lags.
        time.pass_powered_off_ms(86_400_000);
        assert_eq!(clock.estimate(&time), R0 + 11);
        // A date set far ahead moves nothing that loosens.
        time.wall_unix_ms += 400 * 86_400_000;
        assert_eq!(clock.estimate(&time), R0 + 11);
        assert_eq!(clock.high_water_round(), R0);
    }

    #[test]
    fn tighten_time_is_the_later_of_the_estimate_and_the_date() {
        let mut time = FakeTime::at_round(R0);
        let mut clock = clock_at(&time);
        assert_eq!(clock.tighten_round(&time), R0);
        // Powered off for a day: the estimate lags, the date does not.
        time.pass_powered_off_ms(86_400_000);
        assert_eq!(clock.estimate(&time), R0);
        assert_eq!(clock.tighten_round(&time), R0 + 28_800);
        // A date set back cannot pull tighten-time below the estimate.
        time.wall_unix_ms = 0;
        assert_eq!(clock.tighten_round(&time), R0);
        time.wall_unix_ms = (BEACON_GENESIS_UNIX_SECONDS + 30) * 1_000;
        assert_eq!(clock.tighten_round(&time), R0);
    }

    #[test]
    fn a_round_above_the_estimate_rebases_it_with_no_upper_bound() {
        let mut time = FakeTime::at_round(R0);
        let mut clock = clock_at(&time);
        time.pass_powered_off_ms(300 * 86_400_000);
        let latest = time.true_round();
        assert_eq!(latest, R0 + 300 * 28_800);
        let a = accepted(clock.offer_round(&FakeBeacon::record_bytes(latest), &FakeBeacon, &time));
        assert_eq!(a.round, latest);
        assert_eq!(a.estimate_before, R0);
        assert!(a.may_start);
        assert_eq!(clock.high_water_round(), latest);
        assert_eq!(clock.estimate(&time), latest);
        time.pass_awake_ms(3_000);
        assert_eq!(clock.estimate(&time), latest + 1);
    }

    #[test]
    fn a_round_below_the_estimate_raises_the_high_water_round_only() {
        let mut time = FakeTime::at_round(R0);
        let mut clock = clock_at(&time);
        time.pass_awake_ms(300_000);
        assert_eq!(clock.estimate(&time), R0 + 100);
        // An older round that is still above the high-water round.
        let a = accepted(clock.offer_round(&FakeBeacon::record_bytes(R0 + 40), &FakeBeacon, &time));
        assert_eq!(a.estimate_before, R0 + 100);
        assert!(!a.may_start);
        assert_eq!(clock.high_water_round(), R0 + 40);
        assert_eq!(clock.estimate(&time), R0 + 100);
        assert!(!clock.clock_refuses_rounds());
        // Rule (a) is "not below": a round equal to the estimate may start.
        let a = accepted(clock.offer_round(&FakeBeacon::record_bytes(R0 + 100), &FakeBeacon, &time));
        assert!(a.may_start);
        assert_eq!(clock.estimate(&time), R0 + 100);
    }

    #[test]
    fn a_repeated_high_water_round_proves_nothing_new() {
        let mut time = FakeTime::at_round(R0);
        let mut clock = clock_at(&time);
        let verified_at = clock.high_water_boot_ms();
        time.pass_awake_ms(600_000);
        let a = accepted(clock.offer_round(&FakeBeacon::record_bytes(R0), &FakeBeacon, &time));
        assert!(!a.may_start);
        assert_eq!(clock.high_water_round(), R0);
        assert_eq!(clock.high_water_boot_ms(), verified_at);
        assert_eq!(clock.estimate(&time), R0 + 200);
    }

    #[test]
    fn the_date_can_refuse_a_start_round_and_can_never_accept_one() {
        let mut time = FakeTime::at_round(R0);
        let mut clock = clock_at(&time);
        // Powered off for an hour. The estimate lags, so the old latest round passes
        // rule (a). The date says it is an hour old: rule (b) refuses it.
        time.pass_powered_off_ms(3_600_000);
        let a = accepted(clock.offer_round(&FakeBeacon::record_bytes(R0 + 1), &FakeBeacon, &time));
        assert!(!a.may_start);
        assert!(clock.clock_refuses_rounds());
        // Exactly the tolerance behind is still allowed; one round more is not.
        let wall = wall_clock_round(time.wall_unix_ms / 1_000);
        let a = accepted(clock.offer_round(
            &FakeBeacon::record_bytes(wall - ANCHOR_CLOCK_TOLERANCE_ROUNDS - 1),
            &FakeBeacon,
            &time,
        ));
        assert!(!a.may_start);
        let a = accepted(clock.offer_round(
            &FakeBeacon::record_bytes(wall - ANCHOR_CLOCK_TOLERANCE_ROUNDS),
            &FakeBeacon,
            &time,
        ));
        assert!(a.may_start);
        assert!(!clock.clock_refuses_rounds());

        // A date set far ahead refuses every real round as a start round.
        let mut time = FakeTime::at_round(R0);
        let mut clock = clock_at(&time);
        time.pass_awake_ms(30_000);
        time.wall_unix_ms += 86_400_000;
        let a = accepted(clock.offer_round(&FakeBeacon::record_bytes(time.true_round()), &FakeBeacon, &time));
        assert!(!a.may_start);
        assert!(clock.clock_refuses_rounds());
        // The round is still verified and still raises the high-water round.
        assert_eq!(clock.high_water_round(), R0 + 10);

        // A date set far back cannot make a round below the estimate into a start round.
        let mut time = FakeTime::at_round(R0);
        let mut clock = clock_at(&time);
        time.pass_awake_ms(300_000);
        time.wall_unix_ms = 0;
        let a = accepted(clock.offer_round(&FakeBeacon::record_bytes(R0 + 40), &FakeBeacon, &time));
        assert!(!a.may_start);
    }

    #[test]
    fn a_counter_that_reads_lower_cannot_move_the_estimate_back() {
        let mut time = FakeTime::at_round(R0);
        let mut clock = clock_at(&time);
        time.pass_awake_ms(300_000);
        assert_eq!(clock.estimate(&time), R0 + 100);
        assert_eq!(clock.awake_now_ms(&time), 4_300_000);
        time.boot_ms -= 200_000;
        time.awake_ms -= 200_000;
        assert_eq!(clock.estimate(&time), R0 + 100);
        assert_eq!(clock.boot_now_ms(&time), 5_300_000);
        assert_eq!(clock.awake_now_ms(&time), 4_300_000);
    }

    // Chapter 03 section 2, build order 4: for any sequence of rounds, sleeps and
    // power-offs, the estimate never exceeds real time and never moves back, and the
    // high-water round never moves back. A fixed pseudo-random sequence, so a failure
    // can be repeated.
    #[test]
    fn the_estimate_never_runs_ahead_of_real_time_and_never_moves_back() {
        let mut time = FakeTime::at_round(R0);
        let mut clock = clock_at(&time);
        let mut seed: u64 = 0x5AFE_51D3;
        let mut last_estimate = clock.estimate(&time);
        let mut last_high_water = clock.high_water_round();
        let mut step = 0;
        while step < 4_000 {
            seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            let choice = (seed >> 33) % 7;
            let amount = (seed >> 40) % 500_000;
            if choice == 0 {
                time.pass_awake_ms(amount);
            } else if choice == 1 {
                time.pass_asleep_ms(amount);
            } else if choice == 2 {
                time.pass_powered_off_ms(amount * 50);
            } else if choice == 3 {
                // The newest real round.
                let _ = clock.offer_round(&FakeBeacon::record_bytes(time.true_round()), &FakeBeacon, &time);
            } else if choice == 4 {
                // An old round, replayed.
                let back = amount % 5_000;
                let old = time.true_round().saturating_sub(back);
                if old >= 1 {
                    let _ = clock.offer_round(&FakeBeacon::record_bytes(old), &FakeBeacon, &time);
                }
            } else if choice == 5 {
                // The date is set wrong, forward or back.
                if amount % 2 == 0 {
                    time.wall_unix_ms += amount * 1_000;
                } else {
                    time.wall_unix_ms = time.wall_unix_ms.saturating_sub(amount * 1_000);
                }
            } else {
                // The date is set right again.
                time.wall_unix_ms = time.true_unix_ms;
            }
            let estimate = clock.estimate(&time);
            assert!(estimate <= time.true_round(), "the estimate ran ahead at step {}", step);
            assert!(estimate >= last_estimate, "the estimate moved back at step {}", step);
            assert!(clock.high_water_round() >= last_high_water);
            assert!(clock.high_water_round() <= time.true_round());
            last_estimate = estimate;
            last_high_water = clock.high_water_round();
            step += 1;
        }
    }

    // Invariant I3 (chapter 03 section 3): the wall clock appears in no code path outside
    // this module. A cheap build check until the real one exists: the other pure modules
    // never name the wall-clock call.
    #[test]
    fn only_this_module_reads_the_wall_clock() {
        let call = "wall_clock_unix_seconds";
        assert!(!include_str!("waits.rs").contains(call));
        assert!(!include_str!("records.rs").contains(call));
        assert!(!include_str!("frame.rs").contains(call));
        assert!(!include_str!("constants.rs").contains(call));
        assert!(!include_str!("lib.rs").contains(call));
        assert!(!include_str!("main.rs").contains(call));
        assert!(!include_str!("age.rs").contains(call));
        assert!(!include_str!("beacon.rs").contains(call));
        assert!(!include_str!("capsule.rs").contains(call));
        assert!(!include_str!("store.rs").contains(call));
        assert!(!include_str!("timelock.rs").contains(call));
        assert!(include_str!("clock.rs").contains(call));
        // `counters` implements `TimeSource` and so names the call: once to define it,
        // once to pass the raw reading on unchanged, once in the test that checks that.
        assert_eq!(include_str!("counters.rs").matches(call).count(), 3);
    }

    // The clock record is the clock's state and the counters, and the clock comes back
    // from it whole.
    #[test]
    fn the_clock_comes_back_from_its_record() {
        let mut time = FakeTime::at_round(R0);
        let mut clock = clock_at(&time);
        time.pass_awake_ms(300_000);
        let _ = clock.offer_round(&FakeBeacon::record_bytes(R0 + 40), &FakeBeacon, &time);
        let counters = CounterState {
            boot_total_ms: time.boot_ms,
            awake_total_ms: time.awake_ms,
            last_boot_reading_ms: 1_234,
            last_awake_reading_ms: 1_000,
            boot_session: [3u8; 16],
        };
        let record = clock.record(7, &counters);
        assert_eq!(record.sequence, 7);
        assert_eq!(record.high_water_round, R0 + 40);
        assert_eq!(record.estimate_base_round, R0);
        assert_eq!(record.boot_total_ms, time.boot_ms);
        assert_eq!(record.boot_session, [3u8; 16]);
        let bytes = record.encode().unwrap();

        let mut back = Clock::restore(&ClockRecord::decode(&bytes).unwrap(), &FakeBeacon).unwrap();
        assert_eq!(back.high_water_round(), R0 + 40);
        assert_eq!(back.estimate(&time), clock.estimate(&time));
        assert_eq!(back.record(7, &counters), record);

        // A record whose high-water signature does not verify is not adopted.
        let mut forged = record;
        forged.high_water_signature[0] ^= 1;
        assert_eq!(Clock::restore(&forged, &FakeBeacon), Err(DropReason::BadSignature));
    }
}
