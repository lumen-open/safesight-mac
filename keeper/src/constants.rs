// SPDX-License-Identifier: Apache-2.0
//! The numbers the register fixes for the lock, in one place.
//!
//! Every constant carries the register name it implements (register section 5a or 5b) and
//! the decision it comes from. A chapter, and the code, use the name and never the number.
//! Nothing here is read from a file, an environment variable or a launch argument (SD-024).
//!
//! Units are in the names. Time inside the keeper is counted in beacon rounds (SD-037);
//! the two carried counters are counted in milliseconds.

// ----- The beacon (SD-042, SD-043) -----

/// `BEACON_PERIOD`: seconds per round of the public time beacon. A published fact of the
/// drand quicknet chain; re-checked at build time by a later pass (SD-043).
pub const BEACON_PERIOD_SECONDS: u64 = 3;

/// Milliseconds per round. Follows from `BEACON_PERIOD`.
pub const MS_PER_ROUND: u64 = BEACON_PERIOD_SECONDS * 1_000;

/// `ROUNDS_PER_DAY`: one day in rounds (SD-042). Follows from `BEACON_PERIOD`.
pub const ROUNDS_PER_DAY: u64 = 28_800;

/// One hour in rounds. Follows from `BEACON_PERIOD`.
pub const ROUNDS_PER_HOUR: u64 = 1_200;

/// One minute in rounds. Follows from `BEACON_PERIOD`.
pub const ROUNDS_PER_MINUTE: u64 = 20;

/// The pinned chain hash of the drand quicknet chain (SD-043; chapter 03 section 2).
/// A change of chain is a lock-core change. Lab builds pin a lab chain instead (SD-175);
/// the lab flavour is not written yet.
pub const BEACON_CHAIN_HASH: [u8; 32] = [
    0x52, 0xdb, 0x9b, 0xa7, 0x0e, 0x0c, 0xc0, 0xf6, 0xea, 0xf7, 0x80, 0x3d, 0xd0, 0x74, 0x47, 0xa1,
    0xf5, 0x47, 0x77, 0x35, 0xfd, 0x3f, 0x66, 0x17, 0x92, 0xba, 0x94, 0x60, 0x0c, 0x84, 0xe9, 0x71,
];

/// The chain's genesis time in Unix seconds (SD-043; chapter 03 section 2). Used only to
/// work out the round implied by the Mac's wall clock, which can refuse or tighten and
/// nothing else (SD-039 rule (b), SD-041).
pub const BEACON_GENESIS_UNIX_SECONDS: u64 = 1_692_803_367;

// ----- The exit wait (SD-042, SD-044, SD-045, SD-046) -----

/// `SIX_MONTHS_DAYS`: the day count of "6 months" (SD-042). A proposal; SQ-01 may change it.
pub const SIX_MONTHS_DAYS: u16 = 182;

/// `EXIT_WAIT_MAX`: the cap on the exit wait, in days (SD-044).
pub const EXIT_WAIT_MAX_DAYS: u16 = 365;

/// The shortest exit wait, in days. The register gives it no name of its own; it is the
/// first entry of `EXIT_WAIT_OPTIONS` (SD-044).
pub const EXIT_WAIT_MIN_DAYS: u16 = 7;

/// `EXIT_WAIT_OPTIONS`: the five waits an owner can choose, in days (SD-044).
pub const EXIT_WAIT_OPTIONS_DAYS: [u16; 5] = [EXIT_WAIT_MIN_DAYS, 30, 90, SIX_MONTHS_DAYS, EXIT_WAIT_MAX_DAYS];

/// `EXIT_WAIT_MAX` in rounds.
pub const EXIT_WAIT_MAX_ROUNDS: u64 = (EXIT_WAIT_MAX_DAYS as u64) * ROUNDS_PER_DAY;

/// `APPLIED_WAIT_CAP_AT_SETUP`: a choice above this at setup locks at this value and the
/// choice is saved as the planned wait (SD-045).
pub const APPLIED_WAIT_CAP_AT_SETUP_DAYS: u16 = 30;

/// The largest wait a raise applies at once (SD-046: "a raise to 30 days or less takes
/// effect at once"). The register states the number and gives it no name of its own.
pub const INSTANT_RAISE_MAX_DAYS: u16 = 30;

/// `LONG_WAIT_EARLIEST`: no wait above 30 days can be started before this many calendar
/// days after Lock, judged by tighten-time (SD-045).
pub const LONG_WAIT_EARLIEST_DAYS: u64 = 7;
/// `LONG_WAIT_EARLIEST` in rounds.
pub const LONG_WAIT_EARLIEST_ROUNDS: u64 = LONG_WAIT_EARLIEST_DAYS * ROUNDS_PER_DAY;

/// `RAISE_GUARD_DELAY`: the guard day before the private yes of a raise above 30 days
/// (SD-046). Counted on verified rounds and the boot counter.
pub const RAISE_GUARD_DELAY_DAYS: u64 = 1;
/// `RAISE_GUARD_DELAY` in rounds.
pub const RAISE_GUARD_DELAY_ROUNDS: u64 = RAISE_GUARD_DELAY_DAYS * ROUNDS_PER_DAY;

/// `RAISE_CHECK_EXPIRY`: days after the guard day ends in which the private yes can be
/// given (SD-046). Refused by tighten-time; closed for good only on proof (SD-041).
pub const RAISE_CHECK_EXPIRY_DAYS: u64 = 7;
/// `RAISE_CHECK_EXPIRY` in rounds.
pub const RAISE_CHECK_EXPIRY_ROUNDS: u64 = RAISE_CHECK_EXPIRY_DAYS * ROUNDS_PER_DAY;

// ----- Requests (SD-050, SD-053, SD-088) -----

/// `CLAIM_WINDOW`: days after maturing in which the owner must confirm (SD-050).
pub const CLAIM_WINDOW_DAYS: u64 = 7;
/// `CLAIM_WINDOW` in rounds.
pub const CLAIM_WINDOW_ROUNDS: u64 = CLAIM_WINDOW_DAYS * ROUNDS_PER_DAY;

/// `KEYHOLDER_SHORTCUT`: hours after a start round taken after the approval (SD-053).
pub const KEYHOLDER_SHORTCUT_HOURS: u64 = 24;
/// `KEYHOLDER_SHORTCUT` in rounds.
pub const KEYHOLDER_SHORTCUT_ROUNDS: u64 = KEYHOLDER_SHORTCUT_HOURS * ROUNDS_PER_HOUR;

/// `ADMIN_TASK_WAIT`: the fixed wait of an admin task, in days (S-03; SD-088).
pub const ADMIN_TASK_WAIT_DAYS: u64 = 7;
/// `ADMIN_TASK_WAIT` in rounds.
pub const ADMIN_TASK_WAIT_ROUNDS: u64 = ADMIN_TASK_WAIT_DAYS * ROUNDS_PER_DAY;

/// `KEYHOLDERS`: one keyholder at a time (SD-195).
pub const KEYHOLDERS_MAX: usize = 1;

// `NEW_KEYHOLDER_POWER_DELAY` (SD-054) is not a number: it is the applied wait in force
// when enrolment finished, and zero for a keyholder enrolled before Lock. See `waits`.

// ----- The instant-leave window and the private check (SD-052, SD-198) -----

/// `INSTANT_LEAVE_WINDOW`: awake-hours after Lock in which Leave commits at once (SD-052).
pub const INSTANT_LEAVE_WINDOW_AWAKE_HOURS: u64 = 72;
/// `INSTANT_LEAVE_WINDOW` in milliseconds of the awake counter.
pub const INSTANT_LEAVE_WINDOW_AWAKE_MS: u64 = INSTANT_LEAVE_WINDOW_AWAKE_HOURS * 3_600_000;

/// `INSTANT_LEAVE_CAP`: calendar days after Lock that cap the window, by tighten-time (SD-052).
pub const INSTANT_LEAVE_CAP_DAYS: u64 = 7;
/// `INSTANT_LEAVE_CAP` in rounds.
pub const INSTANT_LEAVE_CAP_ROUNDS: u64 = INSTANT_LEAVE_CAP_DAYS * ROUNDS_PER_DAY;

/// `INSTANT_LEAVE_REPEAT`: 12 months per Mac (SD-052). In days it is one year of SD-042,
/// as chapter 03 section 7 uses it.
pub const INSTANT_LEAVE_REPEAT_DAYS: u64 = 365;
/// `INSTANT_LEAVE_REPEAT` in rounds.
pub const INSTANT_LEAVE_REPEAT_ROUNDS: u64 = INSTANT_LEAVE_REPEAT_DAYS * ROUNDS_PER_DAY;

/// `PRIVATE_CHECK_TIME`, first part: the drawn awake-hour is not before this one (SD-198).
pub const PRIVATE_CHECK_EARLIEST_AWAKE_HOUR: u8 = 36;
/// `PRIVATE_CHECK_TIME`, first part: the drawn awake-hour is not after this one (SD-198).
pub const PRIVATE_CHECK_LATEST_AWAKE_HOUR: u8 = 60;
/// `PRIVATE_CHECK_TIME`, second part: or the first unlock after this calendar day (SD-198).
pub const PRIVATE_CHECK_CALENDAR_DAY: u64 = 5;

// ----- Capsules, generations, the Recovery Key (SD-056 to SD-065) -----

/// `ROTATION_INTERVAL`: the smaller of half the applied wait and this many days (SD-058).
pub const ROTATION_INTERVAL_CAP_DAYS: u64 = 30;

/// `CAPSULE_FRESH_MAX`: hours of boot-counter time since a round was verified, inside which
/// a capsule may be sealed on it (SD-059). A proposal (ST-006).
pub const CAPSULE_FRESH_MAX_HOURS: u64 = 24;

/// `CAPSULE_OPEN_WARNING`: days before a capsule's target at which the app warns (SD-064).
pub const CAPSULE_OPEN_WARNING_DAYS: u64 = 7;

/// `SAVE_BANNER`: hours without an outside capsule copy before the banner (SD-060).
pub const SAVE_BANNER_HOURS: u64 = 24;

/// `RECOVERY_KEY_REMINDER`: days between offers of the key check (SD-065).
pub const RECOVERY_KEY_REMINDER_DAYS: u64 = 90;

// `RECOVERY_KEY_OVERLAP` (SD-065) and `CAPSULE_TARGET` (SD-057) are not numbers: one
// applied wait, and the generation's scheduled end plus the applied wait.

/// `CAPSULE_SIZE`: the fixed size of a capsule record, in bytes (SD-056). A proposal.
pub const CAPSULE_SIZE: usize = 4_096;

/// `ADMIN_SECRET_LENGTH`: the admin secret has at least this many random characters (SD-035).
pub const ADMIN_SECRET_LENGTH_MIN: usize = 40;

/// `READ_BACK_CHARS`: characters of the Recovery Key typed back before Lock (SD-063).
pub const READ_BACK_CHARS: usize = 4;

/// `RECORD_COPIES`: copies of each critical record in the keeper store (SD-028).
pub const RECORD_COPIES: usize = 2;

// ----- The clock (SD-037, SD-038, SD-039) -----

/// `ANCHOR_CLOCK_TOLERANCE`: a round more than this far behind the round implied by the
/// wall clock is refused as a start round (SD-039 rule (b)). A proposal (ST-004).
pub const ANCHOR_CLOCK_TOLERANCE_MINUTES: u64 = 10;
/// `ANCHOR_CLOCK_TOLERANCE` in rounds.
pub const ANCHOR_CLOCK_TOLERANCE_ROUNDS: u64 = ANCHOR_CLOCK_TOLERANCE_MINUTES * ROUNDS_PER_MINUTE;

/// `BEACON_READ`: the app offers a round about this often while online (SD-038). A proposal.
/// The keeper itself never fetches anything.
pub const BEACON_READ_MINUTES: u64 = 10;

/// `COUNTER_SAVE`: the counters are saved this often, in seconds (SD-037). A proposal.
pub const COUNTER_SAVE_SECONDS: u64 = 60;

/// `BEACON_MIRRORS`: at least this many mirrors, run by different operators (SD-038).
pub const BEACON_MIRRORS_MIN: usize = 2;

// ----- Small helpers that only apply the numbers above -----

/// True if `days` is one of `EXIT_WAIT_OPTIONS` (SD-044).
pub fn is_exit_wait_option(days: u16) -> bool {
    let mut i = 0;
    while i < EXIT_WAIT_OPTIONS_DAYS.len() {
        if EXIT_WAIT_OPTIONS_DAYS[i] == days {
            return true;
        }
        i += 1;
    }
    false
}

/// A wait of `days` days, in rounds (SD-042).
pub fn wait_rounds(days: u16) -> u64 {
    (days as u64) * ROUNDS_PER_DAY
}

/// A span of rounds as milliseconds of a carried counter. Saturates, which can only make
/// a wait longer.
pub fn rounds_to_ms(rounds: u64) -> u64 {
    rounds.saturating_mul(MS_PER_ROUND)
}

/// `ROTATION_INTERVAL` for an applied wait, in rounds: the smaller of half the applied
/// wait and 30 days (SD-058).
pub fn rotation_interval_rounds(applied_wait_days: u16) -> u64 {
    let half = wait_rounds(applied_wait_days) / 2;
    let cap = ROTATION_INTERVAL_CAP_DAYS * ROUNDS_PER_DAY;
    if half < cap {
        half
    } else {
        cap
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_day_of_rounds_follows_from_the_beacon_period() {
        assert_eq!(ROUNDS_PER_DAY * BEACON_PERIOD_SECONDS, 86_400);
        assert_eq!(ROUNDS_PER_HOUR * 24, ROUNDS_PER_DAY);
        assert_eq!(ROUNDS_PER_MINUTE * 60, ROUNDS_PER_HOUR);
        assert_eq!(MS_PER_ROUND, 3_000);
    }

    #[test]
    fn the_wait_options_are_the_register_five() {
        assert_eq!(EXIT_WAIT_OPTIONS_DAYS, [7, 30, 90, 182, 365]);
        assert_eq!(EXIT_WAIT_OPTIONS_DAYS[0], EXIT_WAIT_MIN_DAYS);
        assert_eq!(EXIT_WAIT_OPTIONS_DAYS[4], EXIT_WAIT_MAX_DAYS);
        let mut i = 1;
        while i < EXIT_WAIT_OPTIONS_DAYS.len() {
            assert!(EXIT_WAIT_OPTIONS_DAYS[i - 1] < EXIT_WAIT_OPTIONS_DAYS[i]);
            i += 1;
        }
    }

    #[test]
    fn only_the_five_options_are_options() {
        let mut days: u16 = 0;
        let mut found = 0;
        while days <= 400 {
            if is_exit_wait_option(days) {
                found += 1;
                assert!(days >= EXIT_WAIT_MIN_DAYS && days <= EXIT_WAIT_MAX_DAYS);
            }
            days += 1;
        }
        assert_eq!(found, 5);
        assert!(!is_exit_wait_option(0));
        assert!(!is_exit_wait_option(6));
        assert!(!is_exit_wait_option(8));
        assert!(!is_exit_wait_option(180));
        assert!(!is_exit_wait_option(366));
    }

    // Chapter 03 section 3, "Waits in rounds".
    #[test]
    fn waits_in_rounds_match_the_chapter_table() {
        assert_eq!(KEYHOLDER_SHORTCUT_ROUNDS, 28_800);
        assert_eq!(wait_rounds(7), 201_600);
        assert_eq!(ADMIN_TASK_WAIT_ROUNDS, 201_600);
        assert_eq!(CLAIM_WINDOW_ROUNDS, 201_600);
        assert_eq!(wait_rounds(30), 864_000);
        assert_eq!(wait_rounds(90), 2_592_000);
        assert_eq!(wait_rounds(SIX_MONTHS_DAYS), 5_241_600);
        assert_eq!(wait_rounds(365), 10_512_000);
        assert_eq!(EXIT_WAIT_MAX_ROUNDS, 10_512_000);
    }

    #[test]
    fn timers_in_rounds() {
        assert_eq!(LONG_WAIT_EARLIEST_ROUNDS, 201_600);
        assert_eq!(RAISE_GUARD_DELAY_ROUNDS, 28_800);
        assert_eq!(RAISE_CHECK_EXPIRY_ROUNDS, 201_600);
        assert_eq!(INSTANT_LEAVE_CAP_ROUNDS, 201_600);
        assert_eq!(INSTANT_LEAVE_REPEAT_ROUNDS, 10_512_000);
        assert_eq!(INSTANT_LEAVE_WINDOW_AWAKE_MS, 259_200_000);
        assert_eq!(ANCHOR_CLOCK_TOLERANCE_ROUNDS, 200);
        assert_eq!(rounds_to_ms(28_800), 86_400_000);
        assert_eq!(rounds_to_ms(u64::MAX), u64::MAX);
    }

    // Register 5a: 3.5, 15, 30, 30, 30 days for the five waits.
    #[test]
    fn rotation_interval_is_half_the_wait_capped_at_thirty_days() {
        assert_eq!(rotation_interval_rounds(7), 100_800);
        assert_eq!(rotation_interval_rounds(30), 15 * ROUNDS_PER_DAY);
        assert_eq!(rotation_interval_rounds(90), 30 * ROUNDS_PER_DAY);
        assert_eq!(rotation_interval_rounds(182), 30 * ROUNDS_PER_DAY);
        assert_eq!(rotation_interval_rounds(365), 30 * ROUNDS_PER_DAY);
    }

    #[test]
    fn the_pinned_chain_hash_is_the_published_one() {
        let mut text = String::new();
        for byte in BEACON_CHAIN_HASH.iter() {
            text.push_str(&format!("{:02x}", byte));
        }
        assert_eq!(text, "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971");
    }

    #[test]
    fn small_fixed_numbers() {
        assert_eq!(CAPSULE_SIZE, 4_096);
        assert_eq!(READ_BACK_CHARS, 4);
        assert_eq!(RECORD_COPIES, 2);
        assert_eq!(KEYHOLDERS_MAX, 1);
        assert!(ADMIN_SECRET_LENGTH_MIN >= 40);
        assert!(BEACON_MIRRORS_MIN >= 2);
        assert_eq!(PRIVATE_CHECK_EARLIEST_AWAKE_HOUR, 36);
        assert_eq!(PRIVATE_CHECK_LATEST_AWAKE_HOUR, 60);
        assert_eq!(PRIVATE_CHECK_CALENDAR_DAY, 5);
        assert_eq!(INSTANT_RAISE_MAX_DAYS, APPLIED_WAIT_CAP_AT_SETUP_DAYS);
    }
}
