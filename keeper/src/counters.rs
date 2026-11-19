// SPDX-License-Identifier: Apache-2.0
//! The two carried counters across restarts, and the detection of a new boot (SD-037;
//! chapter 03 section 2, "The counters" and "The clock record").
//!
//! The Mac's continuous clock (it counts sleep) and absolute clock (it does not) restart
//! from zero at each boot. The keeper keeps two carried totals: the boot counter and the
//! awake counter. Each save of the clock record stores both totals, the raw readings they
//! were taken at, and the identifier of the boot those readings belong to. At the next
//! start the keeper adds what each raw clock has counted since that save:
//!
//! | Boot identifier | Reading against the saved one | Counted since the save |
//! |---|---|---|
//! | same | not lower | the difference: the same boot, so nothing is lost |
//! | another | lower | the whole reading: a new boot, counted from its start |
//! | another | not lower | the difference only |
//! | same | lower | nothing |
//!
//! Time powered off is not counted, and nor is the time between the last save and a
//! power-off: at most one `COUNTER_SAVE`. The last two rows are where the two signs of a
//! new boot disagree.
// OPEN: chapter 03 section 2 ("A new boot") - what to do when the lower reading and the
// boot identifier disagree is not specified. The rows above count the smaller amount in
// both cases, which can only make a wait longer.
//!
//! Every row counts no more than the time that really passed, given only that within one
//! boot a raw clock never runs fast and that at a new boot it starts from zero (to be
//! proven by ST-004 on each tested macOS). So a wait can only run long (SL-013). A total
//! never moves back, even if a raw clock does.
//!
//! `CarriedClock` is the `TimeSource` the core reads. The date passes through it to
//! `clock` unchanged; this module never looks at it (invariant I3).

use std::cell::Cell;

use crate::boundary::{RawClocks, TimeSource};
use crate::records::ClockRecord;

/// The counters as the clock record carries them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CounterState {
    pub boot_total_ms: u64,
    pub awake_total_ms: u64,
    pub last_boot_reading_ms: u64,
    pub last_awake_reading_ms: u64,
    pub boot_session: [u8; 16],
}

impl CounterState {
    /// The counters in a clock record read back from the store.
    pub fn from_record(record: &ClockRecord) -> CounterState {
        CounterState {
            boot_total_ms: record.boot_total_ms,
            awake_total_ms: record.awake_total_ms,
            last_boot_reading_ms: record.last_boot_reading_ms,
            last_awake_reading_ms: record.last_awake_reading_ms,
            boot_session: record.boot_session,
        }
    }
}

/// How this start relates to the boot of the last save.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BootSeen {
    /// The same boot: the keeper restarted, the Mac did not.
    SameBoot,
    /// A new boot: another identifier and a lower reading.
    NewBoot,
    /// The two signs disagree. The smaller amount was counted.
    Unclear,
}

/// What one raw clock has counted since the save, by the table in the module text.
pub fn counted_since(saved_reading: u64, reading: u64, same_boot_identifier: bool) -> u64 {
    if reading >= saved_reading {
        reading - saved_reading
    } else if !same_boot_identifier {
        reading
    } else {
        0
    }
}

/// Whether a start is in the boot of the save, from the continuous clock and the boot
/// identifier together.
pub fn boot_seen(saved: &CounterState, continuous_reading: u64, boot_session: [u8; 16]) -> BootSeen {
    let same = saved.boot_session == boot_session;
    let lower = continuous_reading < saved.last_boot_reading_ms;
    match (same, lower) {
        (true, false) => BootSeen::SameBoot,
        (false, true) => BootSeen::NewBoot,
        _ => BootSeen::Unclear,
    }
}

/// One carried total: a base total at a base reading. A reading below the base (a raw
/// clock that moved back) moves the base down to it, with the total held where it was,
/// so the total never moves back and only forward movement is ever counted.
#[derive(Debug)]
struct Carried {
    base_total: Cell<u64>,
    base_reading: Cell<u64>,
}

impl Carried {
    fn new(total: u64, reading: u64) -> Carried {
        Carried { base_total: Cell::new(total), base_reading: Cell::new(reading) }
    }

    /// The total at `reading`, which then becomes the base, so that a later lower reading
    /// holds this total and counts on from there.
    fn read(&self, reading: u64) -> u64 {
        let base_reading = self.base_reading.get();
        let total = if reading >= base_reading {
            self.base_total.get().saturating_add(reading - base_reading)
        } else {
            self.base_total.get()
        };
        self.base_total.set(total);
        self.base_reading.set(reading);
        total
    }
}

/// The carried boot and awake counters over the Mac's raw clocks: the `TimeSource` the
/// core reads.
#[derive(Debug)]
pub struct CarriedClock<R: RawClocks> {
    raw: R,
    boot: Carried,
    awake: Carried,
    boot_session: [u8; 16],
    seen: BootSeen,
}

impl<R: RawClocks> CarriedClock<R> {
    /// At Lock: both totals start at zero, from the readings now.
    pub fn at_lock(raw: R) -> CarriedClock<R> {
        let boot = Carried::new(0, raw.continuous_ms());
        let awake = Carried::new(0, raw.absolute_ms());
        let boot_session = raw.boot_session();
        CarriedClock { raw, boot, awake, boot_session, seen: BootSeen::SameBoot }
    }

    /// At a start after Lock, from the counters of the last clock record saved.
    pub fn resume(raw: R, saved: &CounterState) -> CarriedClock<R> {
        let continuous = raw.continuous_ms();
        let absolute = raw.absolute_ms();
        let boot_session = raw.boot_session();
        let same = boot_session == saved.boot_session;
        let seen = boot_seen(saved, continuous, boot_session);
        let boot_total = saved.boot_total_ms.saturating_add(counted_since(saved.last_boot_reading_ms, continuous, same));
        let awake_total =
            saved.awake_total_ms.saturating_add(counted_since(saved.last_awake_reading_ms, absolute, same));
        CarriedClock {
            raw,
            boot: Carried::new(boot_total, continuous),
            awake: Carried::new(awake_total, absolute),
            boot_session,
            seen,
        }
    }

    /// How this start related to the boot of the last save.
    pub fn boot_seen(&self) -> BootSeen {
        self.seen
    }

    /// The counters to save now, with the readings they were taken at and this boot's
    /// identifier.
    pub fn snapshot(&self) -> CounterState {
        let continuous = self.raw.continuous_ms();
        let absolute = self.raw.absolute_ms();
        CounterState {
            boot_total_ms: self.boot.read(continuous),
            awake_total_ms: self.awake.read(absolute),
            last_boot_reading_ms: continuous,
            last_awake_reading_ms: absolute,
            boot_session: self.boot_session,
        }
    }

    #[cfg(test)]
    pub(crate) fn raw_mut(&mut self) -> &mut R {
        &mut self.raw
    }
}

impl<R: RawClocks> TimeSource for CarriedClock<R> {
    fn boot_total_ms(&self) -> u64 {
        self.boot.read(self.raw.continuous_ms())
    }

    fn awake_total_ms(&self) -> u64 {
        self.awake.read(self.raw.absolute_ms())
    }

    fn wall_clock_unix_seconds(&self) -> u64 {
        self.raw.wall_clock_unix_seconds()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::Clock;
    use crate::constants::COUNTER_SAVE_SECONDS;
    use crate::fakes::{FakeBeacon, FakeMac, TestDir};
    use crate::store::Store;

    const R0: u64 = 1_000_000;
    const SAVE_MS: u64 = COUNTER_SAVE_SECONDS * 1_000;

    #[test]
    fn the_counting_table() {
        assert_eq!(counted_since(1_000, 1_500, true), 500);
        assert_eq!(counted_since(1_000, 300, false), 300);
        assert_eq!(counted_since(1_000, 1_500, false), 500);
        assert_eq!(counted_since(1_000, 300, true), 0);
        assert_eq!(counted_since(1_000, 1_000, true), 0);
        let saved = CounterState {
            boot_total_ms: 9,
            awake_total_ms: 9,
            last_boot_reading_ms: 1_000,
            last_awake_reading_ms: 900,
            boot_session: [1u8; 16],
        };
        assert_eq!(boot_seen(&saved, 1_500, [1u8; 16]), BootSeen::SameBoot);
        assert_eq!(boot_seen(&saved, 300, [2u8; 16]), BootSeen::NewBoot);
        assert_eq!(boot_seen(&saved, 1_500, [2u8; 16]), BootSeen::Unclear);
        assert_eq!(boot_seen(&saved, 300, [1u8; 16]), BootSeen::Unclear);
    }

    #[test]
    fn a_restart_in_the_same_boot_loses_nothing() {
        let mac = FakeMac::booted_at_round(R0, 600_000);
        let mut carried = CarriedClock::at_lock(mac);
        carried.raw_mut().pass_awake_ms(90_000);
        carried.raw_mut().pass_asleep_ms(30_000);
        let saved = carried.snapshot();
        assert_eq!(saved.boot_total_ms, 120_000);
        assert_eq!(saved.awake_total_ms, 90_000);
        // The keeper stops 40 seconds later and starts again 20 seconds after that.
        carried.raw_mut().pass_awake_ms(60_000);
        let mac = carried.raw_mut().clone();
        let resumed = CarriedClock::resume(mac, &saved);
        assert_eq!(resumed.boot_seen(), BootSeen::SameBoot);
        assert_eq!(resumed.boot_total_ms(), 180_000);
        assert_eq!(resumed.awake_total_ms(), 150_000);
    }

    #[test]
    fn a_new_boot_counts_from_its_start_and_not_the_time_off() {
        let mac = FakeMac::booted_at_round(R0, 600_000);
        let mut carried = CarriedClock::at_lock(mac);
        carried.raw_mut().pass_awake_ms(300_000);
        let saved = carried.snapshot();
        assert_eq!(saved.boot_total_ms, 300_000);
        // 30 seconds after the save, the Mac is switched off for a day; the keeper starts
        // 20 seconds into the next boot.
        carried.raw_mut().pass_awake_ms(30_000);
        carried.raw_mut().power_cycle(86_400_000);
        carried.raw_mut().pass_awake_ms(20_000);
        let mac = carried.raw_mut().clone();
        let resumed = CarriedClock::resume(mac, &saved);
        assert_eq!(resumed.boot_seen(), BootSeen::NewBoot);
        assert_eq!(resumed.boot_total_ms(), 320_000);
        assert_eq!(resumed.awake_total_ms(), 320_000);
        // The 30 seconds before the switch-off are lost: less than one counter save.
        assert!(30_000 <= SAVE_MS);
    }

    #[test]
    fn when_the_signs_disagree_the_smaller_amount_is_counted() {
        let saved = CounterState {
            boot_total_ms: 50_000,
            awake_total_ms: 40_000,
            last_boot_reading_ms: 10_000,
            last_awake_reading_ms: 10_000,
            boot_session: [1u8; 16],
        };
        // Another boot identifier, and a reading that is not lower.
        let mut mac = FakeMac::booted_at_round(R0, 25_000);
        mac.boot_session = [2u8; 16];
        let resumed = CarriedClock::resume(mac, &saved);
        assert_eq!(resumed.boot_seen(), BootSeen::Unclear);
        assert_eq!(resumed.boot_total_ms(), 65_000);
        // The same identifier, and a lower reading.
        let mut mac = FakeMac::booted_at_round(R0, 4_000);
        mac.boot_session = [1u8; 16];
        let resumed = CarriedClock::resume(mac, &saved);
        assert_eq!(resumed.boot_seen(), BootSeen::Unclear);
        assert_eq!(resumed.boot_total_ms(), 50_000);
        assert_eq!(resumed.awake_total_ms(), 40_000);
    }

    #[test]
    fn a_raw_clock_that_moves_back_never_moves_a_total_back() {
        let mac = FakeMac::booted_at_round(R0, 600_000);
        let mut carried = CarriedClock::at_lock(mac);
        carried.raw_mut().pass_awake_ms(100_000);
        assert_eq!(carried.boot_total_ms(), 100_000);
        assert_eq!(carried.awake_total_ms(), 100_000);
        carried.raw_mut().continuous_ms -= 50_000;
        carried.raw_mut().absolute_ms -= 50_000;
        assert_eq!(carried.boot_total_ms(), 100_000);
        assert_eq!(carried.awake_total_ms(), 100_000);
        // Only movement after that counts again.
        carried.raw_mut().pass_awake_ms(10_000);
        assert_eq!(carried.boot_total_ms(), 110_000);
        let saved = carried.snapshot();
        assert_eq!(saved.boot_total_ms, 110_000);
    }

    #[test]
    fn the_date_passes_through_unread() {
        let mut mac = FakeMac::booted_at_round(R0, 600_000);
        mac.wall_unix_ms = 1_234_567_000;
        let carried = CarriedClock::at_lock(mac);
        assert_eq!(carried.wall_clock_unix_seconds(), 1_234_567);
    }

    // For any mix of awake time, sleep, power-offs, keeper restarts and raw clocks moving
    // back, with a save every `COUNTER_SAVE`: the boot total never exceeds the real time
    // the Mac was on since Lock, the awake total never exceeds the real time awake, no
    // total moves back while the keeper runs or below the last save across a restart, and
    // a stop loses at most what was counted since the last save.
    #[test]
    fn the_carried_counters_never_run_ahead_and_never_move_back() {
        let mut real_on_ms: u64 = 0;
        let mut real_awake_ms: u64 = 0;
        let mut power_offs: u64 = 0;
        let mut restarts: u64 = 0;
        let mut moves_back: u64 = 0;
        let mac = FakeMac::booted_at_round(R0, 600_000);
        let lock_true_ms = mac.true_unix_ms;
        let mut carried = CarriedClock::at_lock(mac);
        let mut saved = carried.snapshot();
        let mut since_save: u64 = 0;
        let mut last_boot = 0;
        let mut last_awake = 0;
        let mut seed: u64 = 0xC0_DE_5A_FE;
        let mut step = 0;
        while step < 5_000 {
            seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            let choice = (seed >> 33) % 6;
            let amount = (seed >> 40) % 40_000;
            if choice == 0 {
                carried.raw_mut().pass_awake_ms(amount);
                real_on_ms += amount;
                real_awake_ms += amount;
                since_save += amount;
            } else if choice == 1 {
                carried.raw_mut().pass_asleep_ms(amount * 10);
                real_on_ms += amount * 10;
                since_save += amount * 10;
            } else if choice == 2 {
                // The Mac is switched off; the keeper starts again in the next boot.
                carried.raw_mut().power_cycle(amount * 100);
                power_offs += 1;
                let mac = carried.raw_mut().clone();
                carried = CarriedClock::resume(mac, &saved);
                assert!(carried.boot_total_ms() >= saved.boot_total_ms);
                last_boot = saved.boot_total_ms;
                last_awake = saved.awake_total_ms;
                since_save = 0;
            } else if choice == 3 {
                // The keeper stops and starts again in the same boot.
                restarts += 1;
                let mac = carried.raw_mut().clone();
                carried = CarriedClock::resume(mac, &saved);
                assert!(carried.boot_total_ms() >= saved.boot_total_ms);
                last_boot = saved.boot_total_ms;
                last_awake = saved.awake_total_ms;
            } else if choice == 4 && amount % 7 == 0 {
                // A raw clock reads lower than it did.
                moves_back += 1;
                let back = amount % 3_000;
                let raw = carried.raw_mut();
                raw.continuous_ms = raw.continuous_ms.saturating_sub(back);
                raw.absolute_ms = raw.absolute_ms.saturating_sub(back);
            }
            if since_save >= SAVE_MS || choice == 5 {
                saved = carried.snapshot();
                since_save = 0;
            }
            let boot = carried.boot_total_ms();
            let awake = carried.awake_total_ms();
            let real_since_lock = carried.raw_mut().true_unix_ms - lock_true_ms;
            assert!(boot <= real_since_lock, "the boot total ran ahead at step {}", step);
            assert!(boot <= real_on_ms, "the boot total counted time off at step {}", step);
            assert!(awake <= real_awake_ms, "the awake total counted sleep at step {}", step);
            assert!(boot >= last_boot, "the boot total moved back at step {}", step);
            assert!(awake >= last_awake, "the awake total moved back at step {}", step);
            last_boot = boot;
            last_awake = awake;
            step += 1;
        }
        assert!(power_offs > 100 && restarts > 100 && moves_back > 10);
        // A stop loses at most what was counted since the last save, less than one
        // `COUNTER_SAVE`; a raw clock moving back loses what it moved back.
        let lost = real_on_ms - carried.boot_total_ms();
        assert!(lost <= (power_offs + restarts) * SAVE_MS + moves_back * 3_000);
    }

    // The whole path: the clock record saved to its two slots every `COUNTER_SAVE`, a
    // power-off, and the clock and counters read back from disk at the next start.
    #[test]
    fn the_counters_and_the_clock_come_back_from_the_store() {
        let dir = TestDir::new("counters");
        let store = Store::open(&dir.path).unwrap();
        store.reserve().unwrap();
        let mac = FakeMac::booted_at_round(R0, 600_000);
        let mut carried = CarriedClock::at_lock(mac);
        let mut clock = Clock::at_lock(&FakeBeacon::record_bytes(R0), &FakeBeacon, &carried).unwrap();
        let mut sequence = 1;
        store.create_clock(&clock.record(sequence, &carried.snapshot())).unwrap();
        let mut minute = 0;
        while minute < 5 {
            carried.raw_mut().pass_awake_ms(SAVE_MS);
            sequence += 1;
            store.write_clock(&clock.record(sequence, &carried.snapshot())).unwrap();
            minute += 1;
        }
        let estimate_before = clock.estimate(&carried);
        assert_eq!(estimate_before, R0 + 100);

        // Switched off for an hour, then started.
        carried.raw_mut().power_cycle(3_600_000);
        carried.raw_mut().pass_awake_ms(15_000);
        let mac = carried.raw_mut().clone();
        let record = store.load_clock().unwrap();
        assert_eq!(record.sequence, 6);
        let carried = CarriedClock::resume(mac, &CounterState::from_record(&record));
        assert_eq!(carried.boot_seen(), BootSeen::NewBoot);
        let mut clock = Clock::restore(&record, &FakeBeacon).unwrap();
        // The estimate carries on from where it was, plus the 15 seconds of this boot,
        // and lags the real round by the hour switched off.
        assert_eq!(clock.estimate(&carried), R0 + 105);
        let true_round = carried_true_round(&carried);
        assert_eq!(true_round, R0 + 100 + 1_200 + 5);
        // The next save follows the one on disk.
        store.write_clock(&clock.record(7, &carried.snapshot())).unwrap();
        assert_eq!(store.load_clock().unwrap().boot_total_ms, 315_000);
        // A save that would move a total back is refused by the store.
        let mut back = clock.record(8, &carried.snapshot());
        back.boot_total_ms = 1;
        assert!(store.write_clock(&back).is_err());
    }

    fn carried_true_round(carried: &CarriedClock<FakeMac>) -> u64 {
        use crate::constants::{BEACON_GENESIS_UNIX_SECONDS, BEACON_PERIOD_SECONDS};
        (carried.raw.true_unix_ms / 1_000 - BEACON_GENESIS_UNIX_SECONDS) / BEACON_PERIOD_SECONDS + 1
    }
}
