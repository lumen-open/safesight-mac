// SPDX-License-Identifier: Apache-2.0
//! The lock's fixed-layout records (register 8a; SD-022; chapter 03 section 16).
//!
//! Each record has one layout, one length and one valid byte string per value. `encode`
//! and `decode` run the same field checks, so nothing `encode` writes is refused by
//! `decode`, and nothing `decode` accepts could not have been written by `encode`.
//!
//! The fields are those of register 8a, with the detail chapter 03 gives. Where a layout
//! needs something the register does not list, it is marked OPEN and listed in
//! `docs/STEP-2-STATUS.md`. Records whose sizes the register leaves "not specified" are
//! not laid out here at all: sealed admin secret, keyholder pin, enrolment record, request
//! code, approval code, exit journal, removal list. Release records belong to chapter 08.
//!
//! Integers are unsigned and little-endian. Counter values are in milliseconds.

use crate::constants::{
    is_exit_wait_option, BEACON_CHAIN_HASH, CAPSULE_SIZE, CLAIM_WINDOW_ROUNDS, EXIT_WAIT_MAX_ROUNDS,
    INSTANT_RAISE_MAX_DAYS, LONG_WAIT_EARLIEST_ROUNDS, PRIVATE_CHECK_EARLIEST_AWAKE_HOUR,
    PRIVATE_CHECK_LATEST_AWAKE_HOUR, RAISE_CHECK_EXPIRY_ROUNDS,
};
use crate::frame::{Reader, RecordError, Writer, FRAME_OVERHEAD};

// OPEN: SD-022 / N1 - the numbered list of record types is not specified (chapter 02
// proposes `keeper/spec/records.toml`). Working rule: a record's number is its row in the
// table of register 8a, counted from 1.
pub const TYPE_CAPSULE: u16 = 2;
pub const TYPE_REQUEST_JOURNAL_ENTRY: u16 = 3;
pub const TYPE_WAIT_RECORD: u16 = 4;
pub const TYPE_CLOCK_RECORD: u16 = 5;
pub const TYPE_ROUND_RECORD: u16 = 6;
pub const TYPE_INSTANT_LEAVE_MARKER: u16 = 19;

/// The first format version of every record here.
pub const VERSION_1: u16 = 1;

// ---------------------------------------------------------------------------------------
// Round record
// ---------------------------------------------------------------------------------------

/// One beacon round, as the app hands it to the keeper (register 8a; SD-038).
/// Fields: chain hash (32), round number (8), signature (48).
///
/// Decoding checks the layout only. Whether the chain is the pinned one, whether the
/// round is below the high-water round and whether the signature verifies are the
/// keeper's own checks, in `clock`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RoundRecord {
    pub chain_hash: [u8; 32],
    pub round: u64,
    pub signature: [u8; 48],
}

impl RoundRecord {
    pub const LEN: usize = FRAME_OVERHEAD + 32 + 8 + 48;

    fn validate(&self) -> Result<(), RecordError> {
        // The chain's first round is round 1.
        if self.round == 0 {
            return Err(RecordError::InvalidField);
        }
        Ok(())
    }

    pub fn encode(&self) -> Result<Vec<u8>, RecordError> {
        self.validate()?;
        let mut w = Writer::begin(TYPE_ROUND_RECORD, VERSION_1, Self::LEN);
        w.put_bytes(&self.chain_hash);
        w.put_u64(self.round);
        w.put_bytes(&self.signature);
        w.finish()
    }

    pub fn decode(bytes: &[u8]) -> Result<RoundRecord, RecordError> {
        let mut r = Reader::open(bytes, TYPE_ROUND_RECORD, VERSION_1, Self::LEN)?;
        let mut chain_hash = [0u8; 32];
        chain_hash.copy_from_slice(r.take(32)?);
        let round = r.read_u64()?;
        let mut signature = [0u8; 48];
        signature.copy_from_slice(r.take(48)?);
        r.close()?;
        let record = RoundRecord { chain_hash, round, signature };
        record.validate()?;
        Ok(record)
    }
}

// ---------------------------------------------------------------------------------------
// Request journal entry
// ---------------------------------------------------------------------------------------

/// What a journaled request asks for (register 8a).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestKind {
    Exit,
    LowerWait,
    LoosenSetting,
    AdminBatch,
}

impl RequestKind {
    fn code(self) -> u8 {
        match self {
            RequestKind::Exit => 1,
            RequestKind::LowerWait => 2,
            RequestKind::LoosenSetting => 3,
            RequestKind::AdminBatch => 4,
        }
    }

    fn from_code(code: u8) -> Result<RequestKind, RecordError> {
        match code {
            1 => Ok(RequestKind::Exit),
            2 => Ok(RequestKind::LowerWait),
            3 => Ok(RequestKind::LoosenSetting),
            4 => Ok(RequestKind::AdminBatch),
            _ => Err(RecordError::InvalidField),
        }
    }
}

/// The journaled states of a request (register 8a, amended by I03-13). Discarded and
/// Expired are closing states, so that a restart knows the slot is free.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestState {
    Pending,
    Matured,
    Committed,
    Discarded,
    Expired,
}

impl RequestState {
    fn code(self) -> u8 {
        match self {
            RequestState::Pending => 1,
            RequestState::Matured => 2,
            RequestState::Committed => 3,
            RequestState::Discarded => 4,
            RequestState::Expired => 5,
        }
    }

    fn from_code(code: u8) -> Result<RequestState, RecordError> {
        match code {
            1 => Ok(RequestState::Pending),
            2 => Ok(RequestState::Matured),
            3 => Ok(RequestState::Committed),
            4 => Ok(RequestState::Discarded),
            5 => Ok(RequestState::Expired),
            _ => Err(RecordError::InvalidField),
        }
    }
}

/// One entry of the append-only request journal (register 8a; chapter 03 section 3).
/// Each change of state appends a new entry for the same request ID. Holds no secret.
///
/// Fields, in order: request ID (16); kind (1); state (1); wait in rounds at request (8);
/// boot-counter value at request, in milliseconds (8); start round or none (9); target
/// round or none (9); matured round or none (9); claim deadline or none (9); approval
/// used (1).
// OPEN: register 8a (request journal entry) - the entry has no field for the wait a
// lowering asks for, for the setting a loosening names, or for whether an accepted
// approval is still waiting for its new start round. A journal of these entries alone
// cannot be replayed for those cases. No field is added here; replay is not written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JournalEntry {
    pub request_id: [u8; 16],
    pub kind: RequestKind,
    pub state: RequestState,
    pub wait_rounds: u64,
    pub boot_ms_at_request: u64,
    pub start_round: Option<u64>,
    pub target_round: Option<u64>,
    pub matured_round: Option<u64>,
    pub claim_deadline: Option<u64>,
    pub approval_used: bool,
}

impl JournalEntry {
    pub const LEN: usize = FRAME_OVERHEAD + 16 + 1 + 1 + 8 + 8 + 9 + 9 + 9 + 9 + 1;

    fn validate(&self) -> Result<(), RecordError> {
        if self.wait_rounds == 0 || self.wait_rounds > EXIT_WAIT_MAX_ROUNDS {
            return Err(RecordError::InvalidField);
        }
        // A start round and a target come together. The target is after the start and
        // never beyond the start plus the wait.
        match (self.start_round, self.target_round) {
            (None, None) => {}
            (Some(start), Some(target)) => {
                if start == 0 {
                    return Err(RecordError::InvalidField);
                }
                let latest = match start.checked_add(self.wait_rounds) {
                    Some(v) => v,
                    None => return Err(RecordError::InvalidField),
                };
                if target <= start || target > latest {
                    return Err(RecordError::InvalidField);
                }
            }
            _ => return Err(RecordError::InvalidField),
        }
        // A matured round and a claim deadline come together, one claim window apart.
        match (self.matured_round, self.claim_deadline) {
            (None, None) => {
                if self.state == RequestState::Matured || self.state == RequestState::Expired {
                    return Err(RecordError::InvalidField);
                }
            }
            (Some(matured), Some(deadline)) => {
                if self.state == RequestState::Pending {
                    return Err(RecordError::InvalidField);
                }
                if matured.checked_add(CLAIM_WINDOW_ROUNDS) != Some(deadline) {
                    return Err(RecordError::InvalidField);
                }
            }
            _ => return Err(RecordError::InvalidField),
        }
        Ok(())
    }

    pub fn encode(&self) -> Result<Vec<u8>, RecordError> {
        self.validate()?;
        let mut w = Writer::begin(TYPE_REQUEST_JOURNAL_ENTRY, VERSION_1, Self::LEN);
        w.put_bytes(&self.request_id);
        w.put_u8(self.kind.code());
        w.put_u8(self.state.code());
        w.put_u64(self.wait_rounds);
        w.put_u64(self.boot_ms_at_request);
        w.put_opt_u64(self.start_round);
        w.put_opt_u64(self.target_round);
        w.put_opt_u64(self.matured_round);
        w.put_opt_u64(self.claim_deadline);
        w.put_flag(self.approval_used);
        w.finish()
    }

    pub fn decode(bytes: &[u8]) -> Result<JournalEntry, RecordError> {
        let mut r = Reader::open(bytes, TYPE_REQUEST_JOURNAL_ENTRY, VERSION_1, Self::LEN)?;
        let mut request_id = [0u8; 16];
        request_id.copy_from_slice(r.take(16)?);
        let kind = RequestKind::from_code(r.read_u8()?)?;
        let state = RequestState::from_code(r.read_u8()?)?;
        let wait_rounds = r.read_u64()?;
        let boot_ms_at_request = r.read_u64()?;
        let start_round = r.read_opt_u64()?;
        let target_round = r.read_opt_u64()?;
        let matured_round = r.read_opt_u64()?;
        let claim_deadline = r.read_opt_u64()?;
        let approval_used = r.read_flag()?;
        r.close()?;
        let entry = JournalEntry {
            request_id,
            kind,
            state,
            wait_rounds,
            boot_ms_at_request,
            start_round,
            target_round,
            matured_round,
            claim_deadline,
            approval_used,
        };
        entry.validate()?;
        Ok(entry)
    }
}

// ---------------------------------------------------------------------------------------
// Wait record
// ---------------------------------------------------------------------------------------

/// The terms of a guarded raise above 30 days (SD-046; chapter 03 section 4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RaiseTerms {
    /// The wait asked for, in days.
    pub wait_days: u16,
    /// The round at which `RAISE_GUARD_DELAY` is over.
    pub guard_end_round: u64,
    /// The round at which `RAISE_CHECK_EXPIRY` has passed.
    pub check_expiry_round: u64,
}

/// The guarded raise state of SM-03: none, guarded, awaiting the private yes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuardedRaise {
    None,
    Guarded(RaiseTerms),
    AwaitingPrivateYes(RaiseTerms),
}

/// The release hold of SD-064, written when it starts and never started twice for one
/// generation (R1-lock-03).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Hold {
    pub generation: u64,
    /// By tighten-time.
    pub start_round: u64,
}

/// The wait record (register 8a, amended by I03-9, I03-3, R1-lock-03; chapter 03
/// section 4). Two copies; the valid copy with the higher sequence number wins.
///
/// Fields, in order: sequence number (8); applied wait in days (2); planned wait in days,
/// zero for none (2); guarded raise state (1), the wait asked for (2), the round the guard
/// ends (8), the round the check expires (8), all zero when there is no guarded raise;
/// Lock round (8); `LONG_WAIT_EARLIEST` round (8); awake-counter value at Lock, in
/// milliseconds (8); drawn awake-hour of the private check (1); round of the last owner
/// session or none (9); hold: present (1), generation (8), start round (8).
// OPEN: SD-028 / chapter 02 section 13 - "the higher sequence number wins" needs a
// sequence number in every two-copy record. Register 8a does not list it as a field.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WaitRecord {
    pub sequence: u64,
    pub applied_wait_days: u16,
    pub planned_wait_days: Option<u16>,
    pub guarded_raise: GuardedRaise,
    pub lock_round: u64,
    pub long_wait_earliest_round: u64,
    pub awake_ms_at_lock: u64,
    pub private_check_awake_hour: u8,
    pub last_owner_session_round: Option<u64>,
    pub hold: Option<Hold>,
}

impl WaitRecord {
    pub const LEN: usize = FRAME_OVERHEAD + 8 + 2 + 2 + 1 + 2 + 8 + 8 + 8 + 8 + 8 + 1 + 9 + 17;

    fn validate_terms(&self, terms: &RaiseTerms) -> Result<(), RecordError> {
        // Only a raise above 30 days is ever guarded, and it is a raise.
        if !is_exit_wait_option(terms.wait_days)
            || terms.wait_days <= INSTANT_RAISE_MAX_DAYS
            || terms.wait_days <= self.applied_wait_days
        {
            return Err(RecordError::InvalidField);
        }
        if terms.guard_end_round == 0 {
            return Err(RecordError::InvalidField);
        }
        if terms.guard_end_round.checked_add(RAISE_CHECK_EXPIRY_ROUNDS) != Some(terms.check_expiry_round) {
            return Err(RecordError::InvalidField);
        }
        Ok(())
    }

    fn validate(&self) -> Result<(), RecordError> {
        if !is_exit_wait_option(self.applied_wait_days) {
            return Err(RecordError::InvalidField);
        }
        if let Some(planned) = self.planned_wait_days {
            // A planned wait is a wait above 30 days that is not yet in force (SD-045).
            if !is_exit_wait_option(planned) || planned <= INSTANT_RAISE_MAX_DAYS {
                return Err(RecordError::InvalidField);
            }
        }
        match self.guarded_raise {
            GuardedRaise::None => {}
            GuardedRaise::Guarded(terms) => self.validate_terms(&terms)?,
            GuardedRaise::AwaitingPrivateYes(terms) => self.validate_terms(&terms)?,
        }
        if self.lock_round == 0 {
            return Err(RecordError::InvalidField);
        }
        if self.lock_round.checked_add(LONG_WAIT_EARLIEST_ROUNDS) != Some(self.long_wait_earliest_round) {
            return Err(RecordError::InvalidField);
        }
        if self.private_check_awake_hour < PRIVATE_CHECK_EARLIEST_AWAKE_HOUR
            || self.private_check_awake_hour > PRIVATE_CHECK_LATEST_AWAKE_HOUR
        {
            return Err(RecordError::InvalidField);
        }
        Ok(())
    }

    pub fn encode(&self) -> Result<Vec<u8>, RecordError> {
        self.validate()?;
        let mut w = Writer::begin(TYPE_WAIT_RECORD, VERSION_1, Self::LEN);
        w.put_u64(self.sequence);
        w.put_u16(self.applied_wait_days);
        match self.planned_wait_days {
            Some(days) => w.put_u16(days),
            None => w.put_u16(0),
        }
        match self.guarded_raise {
            GuardedRaise::None => {
                w.put_u8(0);
                w.put_u16(0);
                w.put_u64(0);
                w.put_u64(0);
            }
            GuardedRaise::Guarded(terms) => {
                w.put_u8(1);
                w.put_u16(terms.wait_days);
                w.put_u64(terms.guard_end_round);
                w.put_u64(terms.check_expiry_round);
            }
            GuardedRaise::AwaitingPrivateYes(terms) => {
                w.put_u8(2);
                w.put_u16(terms.wait_days);
                w.put_u64(terms.guard_end_round);
                w.put_u64(terms.check_expiry_round);
            }
        }
        w.put_u64(self.lock_round);
        w.put_u64(self.long_wait_earliest_round);
        w.put_u64(self.awake_ms_at_lock);
        w.put_u8(self.private_check_awake_hour);
        w.put_opt_u64(self.last_owner_session_round);
        match self.hold {
            Some(hold) => {
                w.put_flag(true);
                w.put_u64(hold.generation);
                w.put_u64(hold.start_round);
            }
            None => {
                w.put_flag(false);
                w.put_u64(0);
                w.put_u64(0);
            }
        }
        w.finish()
    }

    pub fn decode(bytes: &[u8]) -> Result<WaitRecord, RecordError> {
        let mut r = Reader::open(bytes, TYPE_WAIT_RECORD, VERSION_1, Self::LEN)?;
        let sequence = r.read_u64()?;
        let applied_wait_days = r.read_u16()?;
        let planned_raw = r.read_u16()?;
        let planned_wait_days = if planned_raw == 0 { None } else { Some(planned_raw) };
        let guarded_code = r.read_u8()?;
        let terms = RaiseTerms {
            wait_days: r.read_u16()?,
            guard_end_round: r.read_u64()?,
            check_expiry_round: r.read_u64()?,
        };
        let guarded_raise = match guarded_code {
            0 => {
                if terms.wait_days != 0 || terms.guard_end_round != 0 || terms.check_expiry_round != 0 {
                    return Err(RecordError::NonZeroPadding);
                }
                GuardedRaise::None
            }
            1 => GuardedRaise::Guarded(terms),
            2 => GuardedRaise::AwaitingPrivateYes(terms),
            _ => return Err(RecordError::InvalidField),
        };
        let lock_round = r.read_u64()?;
        let long_wait_earliest_round = r.read_u64()?;
        let awake_ms_at_lock = r.read_u64()?;
        let private_check_awake_hour = r.read_u8()?;
        let last_owner_session_round = r.read_opt_u64()?;
        let hold_present = r.read_flag()?;
        let hold_generation = r.read_u64()?;
        let hold_start_round = r.read_u64()?;
        let hold = if hold_present {
            Some(Hold { generation: hold_generation, start_round: hold_start_round })
        } else if hold_generation == 0 && hold_start_round == 0 {
            None
        } else {
            return Err(RecordError::NonZeroPadding);
        };
        r.close()?;
        let record = WaitRecord {
            sequence,
            applied_wait_days,
            planned_wait_days,
            guarded_raise,
            lock_round,
            long_wait_earliest_round,
            awake_ms_at_lock,
            private_check_awake_hour,
            last_owner_session_round,
            hold,
        };
        record.validate()?;
        Ok(record)
    }
}

// ---------------------------------------------------------------------------------------
// Clock record
// ---------------------------------------------------------------------------------------

/// The clock record (register 8a, amended by I03-1; chapter 03 section 2). Two
/// checksummed slots; a write goes to the older slot first; nothing in it moves back.
///
/// Fields, in order: sequence number (8); high-water round (8) and its signature (48);
/// boot-counter value when that round was verified (8); estimate base: a round (8) and
/// the boot-counter value when it was taken (8); boot counter carried total (8); awake
/// counter carried total (8); last reading of the boot clock (8) and of the awake clock
/// (8) in this boot. Counter values are in milliseconds.
// OPEN: SD-037 / register 8a (clock record) - the unit of the carried counters is not
// specified. Working value: milliseconds.
// OPEN: register 8a (clock record) - "last reading of each clock in this boot" is in
// chapter 03 section 2 and not in the register's field list; the sequence number is in
// chapter 02's two-slot rule and not in the list either. Both are laid out here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClockRecord {
    pub sequence: u64,
    pub high_water_round: u64,
    pub high_water_signature: [u8; 48],
    pub high_water_boot_ms: u64,
    pub estimate_base_round: u64,
    pub estimate_base_boot_ms: u64,
    pub boot_total_ms: u64,
    pub awake_total_ms: u64,
    pub last_boot_reading_ms: u64,
    pub last_awake_reading_ms: u64,
}

impl ClockRecord {
    pub const LEN: usize = FRAME_OVERHEAD + 8 + 8 + 48 + 8 + 8 + 8 + 8 + 8 + 8 + 8;

    fn validate(&self) -> Result<(), RecordError> {
        if self.high_water_round == 0 || self.estimate_base_round == 0 {
            return Err(RecordError::InvalidField);
        }
        // The estimate base is an accepted round, so it is never above the high-water
        // round, and it was taken no later than the high-water round was verified.
        if self.estimate_base_round > self.high_water_round {
            return Err(RecordError::InvalidField);
        }
        if self.estimate_base_boot_ms > self.high_water_boot_ms {
            return Err(RecordError::InvalidField);
        }
        if self.high_water_boot_ms > self.boot_total_ms {
            return Err(RecordError::InvalidField);
        }
        Ok(())
    }

    /// True if this record may be written over the older slot while `current` is the
    /// newer one: the sequence number rises by one and no monotonic field is below the
    /// same field of `current` (chapter 02, the two-slot write, rule 5).
    pub fn may_follow(&self, current: &ClockRecord) -> bool {
        current.sequence.checked_add(1) == Some(self.sequence)
            && self.high_water_round >= current.high_water_round
            && self.estimate_base_round >= current.estimate_base_round
            && self.boot_total_ms >= current.boot_total_ms
            && self.awake_total_ms >= current.awake_total_ms
    }

    pub fn encode(&self) -> Result<Vec<u8>, RecordError> {
        self.validate()?;
        let mut w = Writer::begin(TYPE_CLOCK_RECORD, VERSION_1, Self::LEN);
        w.put_u64(self.sequence);
        w.put_u64(self.high_water_round);
        w.put_bytes(&self.high_water_signature);
        w.put_u64(self.high_water_boot_ms);
        w.put_u64(self.estimate_base_round);
        w.put_u64(self.estimate_base_boot_ms);
        w.put_u64(self.boot_total_ms);
        w.put_u64(self.awake_total_ms);
        w.put_u64(self.last_boot_reading_ms);
        w.put_u64(self.last_awake_reading_ms);
        w.finish()
    }

    pub fn decode(bytes: &[u8]) -> Result<ClockRecord, RecordError> {
        let mut r = Reader::open(bytes, TYPE_CLOCK_RECORD, VERSION_1, Self::LEN)?;
        let sequence = r.read_u64()?;
        let high_water_round = r.read_u64()?;
        let mut high_water_signature = [0u8; 48];
        high_water_signature.copy_from_slice(r.take(48)?);
        let high_water_boot_ms = r.read_u64()?;
        let estimate_base_round = r.read_u64()?;
        let estimate_base_boot_ms = r.read_u64()?;
        let boot_total_ms = r.read_u64()?;
        let awake_total_ms = r.read_u64()?;
        let last_boot_reading_ms = r.read_u64()?;
        let last_awake_reading_ms = r.read_u64()?;
        r.close()?;
        let record = ClockRecord {
            sequence,
            high_water_round,
            high_water_signature,
            high_water_boot_ms,
            estimate_base_round,
            estimate_base_boot_ms,
            boot_total_ms,
            awake_total_ms,
            last_boot_reading_ms,
            last_awake_reading_ms,
        };
        record.validate()?;
        Ok(record)
    }
}

/// Which of the two slots of a two-slot record is current: the valid one with the higher
/// sequence number (chapter 02, the two-slot write, rules 1 and 2). With no valid slot
/// there is no record, and nothing is guessed (SD-227: none adopted for the clock record).
pub fn newer_clock_slot(
    slot_a: Result<ClockRecord, RecordError>,
    slot_b: Result<ClockRecord, RecordError>,
) -> Option<ClockRecord> {
    match (slot_a, slot_b) {
        (Ok(a), Ok(b)) => {
            if b.sequence > a.sequence {
                Some(b)
            } else {
                Some(a)
            }
        }
        (Ok(a), Err(_)) => Some(a),
        (Err(_), Ok(b)) => Some(b),
        (Err(_), Err(_)) => None,
    }
}

// ---------------------------------------------------------------------------------------
// Instant-leave marker
// ---------------------------------------------------------------------------------------

/// The instant-leave marker (register 8a, amended by I09-2; SD-052). A root-owned,
/// world-readable file outside the keeper store, left in place by the exit steps.
///
/// Fields, in order: Lock round (8); wall-clock date of Lock (8).
// OPEN: register 8a (instant-leave marker) - the form of "wall-clock date of Lock" is not
// specified. Working value: Unix seconds. It is for display in Prepare only and decides
// nothing; the marker's age is judged on the Lock round (chapter 03 section 7).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InstantLeaveMarker {
    pub lock_round: u64,
    pub lock_date_unix_seconds: u64,
}

impl InstantLeaveMarker {
    pub const LEN: usize = FRAME_OVERHEAD + 8 + 8;

    fn validate(&self) -> Result<(), RecordError> {
        if self.lock_round == 0 {
            return Err(RecordError::InvalidField);
        }
        Ok(())
    }

    pub fn encode(&self) -> Result<Vec<u8>, RecordError> {
        self.validate()?;
        let mut w = Writer::begin(TYPE_INSTANT_LEAVE_MARKER, VERSION_1, Self::LEN);
        w.put_u64(self.lock_round);
        w.put_u64(self.lock_date_unix_seconds);
        w.finish()
    }

    pub fn decode(bytes: &[u8]) -> Result<InstantLeaveMarker, RecordError> {
        let mut r = Reader::open(bytes, TYPE_INSTANT_LEAVE_MARKER, VERSION_1, Self::LEN)?;
        let lock_round = r.read_u64()?;
        let lock_date_unix_seconds = r.read_u64()?;
        r.close()?;
        let marker = InstantLeaveMarker { lock_round, lock_date_unix_seconds };
        marker.validate()?;
        Ok(marker)
    }
}

// ---------------------------------------------------------------------------------------
// Capsule (the container only)
// ---------------------------------------------------------------------------------------

/// The capsule record (register 8a; SD-056; chapter 03 section 9), as a container. This
/// pass writes no cryptography: the ciphertext is opaque bytes made elsewhere.
///
/// Fields, in order: generation number (8); target round (8); chain hash (32); ciphertext
/// length (2); ciphertext; zero padding to `CAPSULE_SIZE`. The format version is the
/// frame's. It holds nothing else, ever (SD-057).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Capsule {
    pub generation: u64,
    pub target_round: u64,
    pub chain_hash: [u8; 32],
    pub ciphertext: Vec<u8>,
}

impl Capsule {
    pub const LEN: usize = CAPSULE_SIZE;
    /// The most ciphertext a capsule can carry.
    pub const CIPHERTEXT_MAX: usize = CAPSULE_SIZE - FRAME_OVERHEAD - 8 - 8 - 32 - 2;

    fn validate(&self) -> Result<(), RecordError> {
        if self.target_round == 0 {
            return Err(RecordError::InvalidField);
        }
        if self.ciphertext.is_empty() || self.ciphertext.len() > Self::CIPHERTEXT_MAX {
            return Err(RecordError::InvalidField);
        }
        Ok(())
    }

    /// True if the capsule names the pinned chain (SD-043).
    pub fn is_on_pinned_chain(&self) -> bool {
        self.chain_hash == BEACON_CHAIN_HASH
    }

    pub fn encode(&self) -> Result<Vec<u8>, RecordError> {
        self.validate()?;
        let mut w = Writer::begin(TYPE_CAPSULE, VERSION_1, Self::LEN);
        w.put_u64(self.generation);
        w.put_u64(self.target_round);
        w.put_bytes(&self.chain_hash);
        w.put_u16(self.ciphertext.len() as u16);
        w.put_bytes(&self.ciphertext);
        w.put_zeros(Self::CIPHERTEXT_MAX - self.ciphertext.len());
        w.finish()
    }

    pub fn decode(bytes: &[u8]) -> Result<Capsule, RecordError> {
        let mut r = Reader::open(bytes, TYPE_CAPSULE, VERSION_1, Self::LEN)?;
        let generation = r.read_u64()?;
        let target_round = r.read_u64()?;
        let mut chain_hash = [0u8; 32];
        chain_hash.copy_from_slice(r.take(32)?);
        let ciphertext_len = r.read_u16()? as usize;
        if ciphertext_len == 0 || ciphertext_len > Self::CIPHERTEXT_MAX {
            return Err(RecordError::InvalidField);
        }
        let ciphertext = r.take(ciphertext_len)?.to_vec();
        r.read_zeros(Self::CIPHERTEXT_MAX - ciphertext_len)?;
        r.close()?;
        let capsule = Capsule { generation, target_round, chain_hash, ciphertext };
        capsule.validate()?;
        Ok(capsule)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::constants::ROUNDS_PER_DAY;
    use crate::frame::{reseal, HEADER_LEN};

    fn unhex(text: &str) -> Vec<u8> {
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

    /// The frame-level strictness every record shares: one length, one magic, one type,
    /// one version, a checksum that matters, and no single damaged byte accepted.
    fn assert_strict(good: &[u8], decode_error: &dyn Fn(&[u8]) -> Option<RecordError>) {
        assert_eq!(decode_error(good), None);
        assert_eq!(decode_error(&[]), Some(RecordError::TooShort));
        assert_eq!(decode_error(&good[..good.len() - 1]), Some(RecordError::WrongLength));

        let mut longer = good.to_vec();
        longer.push(0);
        assert_eq!(decode_error(&longer), Some(RecordError::WrongLength));

        let mut magic = good.to_vec();
        magic[0] ^= 0x01;
        reseal(&mut magic);
        assert_eq!(decode_error(&magic), Some(RecordError::BadMagic));

        let mut other_type = good.to_vec();
        other_type[4] ^= 0x40;
        reseal(&mut other_type);
        assert_eq!(decode_error(&other_type), Some(RecordError::WrongType));

        let mut version_two = good.to_vec();
        version_two[6] = 2;
        reseal(&mut version_two);
        assert_eq!(decode_error(&version_two), Some(RecordError::UpdateNeeded));

        let mut version_zero = good.to_vec();
        version_zero[6] = 0;
        reseal(&mut version_zero);
        assert_eq!(decode_error(&version_zero), Some(RecordError::UpdateNeeded));

        let mut length_field = good.to_vec();
        length_field[8] ^= 0x01;
        reseal(&mut length_field);
        assert_eq!(decode_error(&length_field), Some(RecordError::WrongLength));

        let mut i = 0;
        while i < good.len() {
            let mut damaged = good.to_vec();
            damaged[i] ^= 0xFF;
            assert!(decode_error(&damaged).is_some(), "a damaged byte {} was accepted", i);
            i += 1;
        }
    }

    // ----- Round record -----

    fn sample_round() -> RoundRecord {
        let mut signature = [0u8; 48];
        let mut i = 0;
        while i < 48 {
            signature[i] = i as u8;
            i += 1;
        }
        RoundRecord { chain_hash: BEACON_CHAIN_HASH, round: 1_000_000, signature }
    }

    #[test]
    fn round_record_round_trips() {
        let record = sample_round();
        let bytes = record.encode().unwrap();
        assert_eq!(bytes.len(), RoundRecord::LEN);
        assert_eq!(RoundRecord::LEN, 104);
        assert_eq!(RoundRecord::decode(&bytes), Ok(record));
    }

    // The same record encoded by an independent encoder (a short Python script using
    // zlib.crc32), so the layout is pinned by bytes and not only by a round trip.
    #[test]
    fn round_record_matches_its_vector() {
        let vector = unhex(ROUND_RECORD_VECTOR);
        assert_eq!(sample_round().encode().unwrap(), vector);
        assert_eq!(RoundRecord::decode(&vector), Ok(sample_round()));
    }

    #[test]
    fn round_record_is_strict() {
        let bytes = sample_round().encode().unwrap();
        assert_strict(&bytes, &|b: &[u8]| RoundRecord::decode(b).err());
    }

    #[test]
    fn round_record_refuses_round_zero() {
        let mut record = sample_round();
        record.round = 0;
        assert_eq!(record.encode(), Err(RecordError::InvalidField));
        let mut bytes = sample_round().encode().unwrap();
        let mut i = HEADER_LEN + 32;
        while i < HEADER_LEN + 40 {
            bytes[i] = 0;
            i += 1;
        }
        reseal(&mut bytes);
        assert_eq!(RoundRecord::decode(&bytes), Err(RecordError::InvalidField));
    }

    // ----- Request journal entry -----

    fn sample_entry() -> JournalEntry {
        JournalEntry {
            request_id: [0xA5; 16],
            kind: RequestKind::Exit,
            state: RequestState::Matured,
            wait_rounds: 201_600,
            boot_ms_at_request: 123_456_789,
            start_round: Some(1_000_010),
            target_round: Some(1_201_610),
            matured_round: Some(1_201_610),
            claim_deadline: Some(1_403_210),
            approval_used: false,
        }
    }

    fn pending_entry() -> JournalEntry {
        JournalEntry {
            request_id: [7; 16],
            kind: RequestKind::LowerWait,
            state: RequestState::Pending,
            wait_rounds: 864_000,
            boot_ms_at_request: 0,
            start_round: None,
            target_round: None,
            matured_round: None,
            claim_deadline: None,
            approval_used: false,
        }
    }

    #[test]
    fn journal_entry_round_trips_for_every_kind_and_state() {
        assert_eq!(JournalEntry::LEN, 87);
        let kinds = [
            RequestKind::Exit,
            RequestKind::LowerWait,
            RequestKind::LoosenSetting,
            RequestKind::AdminBatch,
        ];
        let states = [
            RequestState::Pending,
            RequestState::Matured,
            RequestState::Committed,
            RequestState::Discarded,
            RequestState::Expired,
        ];
        let mut count = 0;
        for kind in kinds.iter() {
            for state in states.iter() {
                let mut entry = if *state == RequestState::Pending { pending_entry() } else { sample_entry() };
                entry.kind = *kind;
                entry.state = *state;
                let bytes = entry.encode().unwrap();
                assert_eq!(bytes.len(), JournalEntry::LEN);
                assert_eq!(JournalEntry::decode(&bytes), Ok(entry));
                count += 1;
            }
        }
        assert_eq!(count, 20);

        // Closing and committed entries with no matured round (Stay while Pending; an
        // instant leave), and one with a shortcut target and a used approval.
        let mut discarded = pending_entry();
        discarded.state = RequestState::Discarded;
        assert_eq!(JournalEntry::decode(&discarded.encode().unwrap()), Ok(discarded));
        let mut committed = pending_entry();
        committed.state = RequestState::Committed;
        assert_eq!(JournalEntry::decode(&committed.encode().unwrap()), Ok(committed));
        let mut shortcut = sample_entry();
        shortcut.state = RequestState::Pending;
        shortcut.matured_round = None;
        shortcut.claim_deadline = None;
        shortcut.target_round = Some(1_000_010 + 28_800);
        shortcut.approval_used = true;
        assert_eq!(JournalEntry::decode(&shortcut.encode().unwrap()), Ok(shortcut));
    }

    #[test]
    fn journal_entry_matches_its_vector() {
        let vector = unhex(JOURNAL_ENTRY_VECTOR);
        assert_eq!(sample_entry().encode().unwrap(), vector);
        assert_eq!(JournalEntry::decode(&vector), Ok(sample_entry()));
    }

    #[test]
    fn journal_entry_is_strict() {
        let bytes = sample_entry().encode().unwrap();
        assert_strict(&bytes, &|b: &[u8]| JournalEntry::decode(b).err());
        let bytes = pending_entry().encode().unwrap();
        assert_strict(&bytes, &|b: &[u8]| JournalEntry::decode(b).err());
    }

    fn entry_refused(entry: JournalEntry) {
        assert_eq!(entry.encode(), Err(RecordError::InvalidField));
    }

    #[test]
    fn journal_entry_refuses_values_outside_their_ranges() {
        let mut e = sample_entry();
        e.wait_rounds = 0;
        entry_refused(e);
        let mut e = sample_entry();
        e.wait_rounds = EXIT_WAIT_MAX_ROUNDS + 1;
        entry_refused(e);
        // A start round without a target, and a target without a start round.
        let mut e = sample_entry();
        e.target_round = None;
        entry_refused(e);
        let mut e = sample_entry();
        e.start_round = None;
        entry_refused(e);
        // A target at or before the start, and one beyond the start plus the wait.
        let mut e = sample_entry();
        e.target_round = e.start_round;
        entry_refused(e);
        let mut e = sample_entry();
        e.target_round = Some(1_201_611);
        entry_refused(e);
        let mut e = sample_entry();
        e.start_round = Some(0);
        e.target_round = Some(5);
        entry_refused(e);
        // Matured round and claim deadline come together, one claim window apart.
        let mut e = sample_entry();
        e.claim_deadline = None;
        entry_refused(e);
        let mut e = sample_entry();
        e.matured_round = None;
        entry_refused(e);
        let mut e = sample_entry();
        e.claim_deadline = Some(1_403_211);
        entry_refused(e);
        // A Pending entry is not matured; a Matured or Expired entry is.
        let mut e = sample_entry();
        e.state = RequestState::Pending;
        entry_refused(e);
        let mut e = pending_entry();
        e.state = RequestState::Matured;
        entry_refused(e);
        let mut e = pending_entry();
        e.state = RequestState::Expired;
        entry_refused(e);
    }

    #[test]
    fn journal_entry_refuses_unknown_codes_flags_and_padding() {
        let good = pending_entry().encode().unwrap();
        // Offsets: kind 28, state 29, start flag 46, start value 47..55, approval 82.
        let mut b = good.clone();
        b[28] = 0;
        reseal(&mut b);
        assert_eq!(JournalEntry::decode(&b), Err(RecordError::InvalidField));
        let mut b = good.clone();
        b[28] = 5;
        reseal(&mut b);
        assert_eq!(JournalEntry::decode(&b), Err(RecordError::InvalidField));
        let mut b = good.clone();
        b[29] = 0;
        reseal(&mut b);
        assert_eq!(JournalEntry::decode(&b), Err(RecordError::InvalidField));
        let mut b = good.clone();
        b[29] = 6;
        reseal(&mut b);
        assert_eq!(JournalEntry::decode(&b), Err(RecordError::InvalidField));
        let mut b = good.clone();
        b[46] = 2;
        reseal(&mut b);
        assert_eq!(JournalEntry::decode(&b), Err(RecordError::InvalidField));
        let mut b = good.clone();
        b[47] = 9;
        reseal(&mut b);
        assert_eq!(JournalEntry::decode(&b), Err(RecordError::NonZeroPadding));
        let mut b = good.clone();
        b[82] = 2;
        reseal(&mut b);
        assert_eq!(JournalEntry::decode(&b), Err(RecordError::InvalidField));
    }

    // ----- Wait record -----

    fn sample_wait() -> WaitRecord {
        WaitRecord {
            sequence: 3,
            applied_wait_days: 30,
            planned_wait_days: Some(90),
            guarded_raise: GuardedRaise::None,
            lock_round: 1_000_000,
            long_wait_earliest_round: 1_000_000 + 7 * ROUNDS_PER_DAY,
            awake_ms_at_lock: 4_000_000,
            private_check_awake_hour: 41,
            last_owner_session_round: Some(1_000_500),
            hold: None,
        }
    }

    fn sample_terms() -> RaiseTerms {
        RaiseTerms {
            wait_days: 90,
            guard_end_round: 1_300_000,
            check_expiry_round: 1_300_000 + 7 * ROUNDS_PER_DAY,
        }
    }

    #[test]
    fn wait_record_round_trips_in_every_shape() {
        assert_eq!(WaitRecord::LEN, 98);
        let plain = sample_wait();
        assert_eq!(WaitRecord::decode(&plain.encode().unwrap()), Ok(plain));

        let mut guarded = sample_wait();
        guarded.guarded_raise = GuardedRaise::Guarded(sample_terms());
        assert_eq!(WaitRecord::decode(&guarded.encode().unwrap()), Ok(guarded));

        let mut awaiting = sample_wait();
        awaiting.guarded_raise = GuardedRaise::AwaitingPrivateYes(sample_terms());
        assert_eq!(WaitRecord::decode(&awaiting.encode().unwrap()), Ok(awaiting));

        let mut bare = sample_wait();
        bare.planned_wait_days = None;
        bare.last_owner_session_round = None;
        assert_eq!(WaitRecord::decode(&bare.encode().unwrap()), Ok(bare));

        let mut held = sample_wait();
        held.hold = Some(Hold { generation: 12, start_round: 2_000_000 });
        assert_eq!(WaitRecord::decode(&held.encode().unwrap()), Ok(held));

        for days in [7u16, 30, 90, 182, 365].iter() {
            let mut each = sample_wait();
            each.planned_wait_days = None;
            each.applied_wait_days = *days;
            assert_eq!(WaitRecord::decode(&each.encode().unwrap()), Ok(each));
        }
    }

    #[test]
    fn wait_record_is_strict() {
        let bytes = sample_wait().encode().unwrap();
        assert_strict(&bytes, &|b: &[u8]| WaitRecord::decode(b).err());
        let mut guarded = sample_wait();
        guarded.guarded_raise = GuardedRaise::Guarded(sample_terms());
        guarded.hold = Some(Hold { generation: 1, start_round: 9 });
        let bytes = guarded.encode().unwrap();
        assert_strict(&bytes, &|b: &[u8]| WaitRecord::decode(b).err());
    }

    fn wait_refused(record: WaitRecord) {
        assert_eq!(record.encode(), Err(RecordError::InvalidField));
    }

    #[test]
    fn wait_record_refuses_values_outside_their_ranges() {
        // A wait that is not one of the five options.
        let mut r = sample_wait();
        r.applied_wait_days = 14;
        wait_refused(r);
        let mut r = sample_wait();
        r.applied_wait_days = 0;
        wait_refused(r);
        let mut r = sample_wait();
        r.applied_wait_days = 366;
        wait_refused(r);
        // A planned wait that is not an option, or not above 30 days.
        let mut r = sample_wait();
        r.planned_wait_days = Some(60);
        wait_refused(r);
        let mut r = sample_wait();
        r.planned_wait_days = Some(30);
        wait_refused(r);
        // A guarded raise that is not above 30 days, not a raise, or with deadlines that
        // are not one expiry period apart.
        let mut r = sample_wait();
        let mut terms = sample_terms();
        terms.wait_days = 30;
        r.guarded_raise = GuardedRaise::Guarded(terms);
        wait_refused(r);
        let mut r = sample_wait();
        r.applied_wait_days = 90;
        r.guarded_raise = GuardedRaise::AwaitingPrivateYes(sample_terms());
        wait_refused(r);
        let mut r = sample_wait();
        let mut terms = sample_terms();
        terms.check_expiry_round += 1;
        r.guarded_raise = GuardedRaise::Guarded(terms);
        wait_refused(r);
        let mut r = sample_wait();
        let mut terms = sample_terms();
        terms.guard_end_round = 0;
        terms.check_expiry_round = 7 * ROUNDS_PER_DAY;
        r.guarded_raise = GuardedRaise::Guarded(terms);
        wait_refused(r);
        // The Lock round and the day-8 round.
        let mut r = sample_wait();
        r.lock_round = 0;
        r.long_wait_earliest_round = 7 * ROUNDS_PER_DAY;
        wait_refused(r);
        let mut r = sample_wait();
        r.long_wait_earliest_round -= 1;
        wait_refused(r);
        // The drawn awake-hour of the private check: 36 to 60.
        let mut r = sample_wait();
        r.private_check_awake_hour = 35;
        wait_refused(r);
        let mut r = sample_wait();
        r.private_check_awake_hour = 61;
        wait_refused(r);
        let mut r = sample_wait();
        r.private_check_awake_hour = 36;
        assert!(r.encode().is_ok());
        let mut r = sample_wait();
        r.private_check_awake_hour = 60;
        assert!(r.encode().is_ok());
    }

    #[test]
    fn wait_record_refuses_unknown_codes_flags_and_padding() {
        let mut bare = sample_wait();
        bare.last_owner_session_round = None;
        let good = bare.encode().unwrap();
        // Offsets: guarded state 24, the wait asked for 25..27, guard end 27..35, owner
        // session flag 68 and value 69..77, hold flag 77, generation 78..86.
        let mut b = good.clone();
        b[24] = 3;
        reseal(&mut b);
        assert_eq!(WaitRecord::decode(&b), Err(RecordError::InvalidField));
        let mut b = good.clone();
        b[25] = 90;
        reseal(&mut b);
        assert_eq!(WaitRecord::decode(&b), Err(RecordError::NonZeroPadding));
        let mut b = good.clone();
        b[27] = 1;
        reseal(&mut b);
        assert_eq!(WaitRecord::decode(&b), Err(RecordError::NonZeroPadding));
        let mut b = good.clone();
        b[68] = 2;
        reseal(&mut b);
        assert_eq!(WaitRecord::decode(&b), Err(RecordError::InvalidField));
        let mut b = good.clone();
        b[69] = 1;
        reseal(&mut b);
        assert_eq!(WaitRecord::decode(&b), Err(RecordError::NonZeroPadding));
        let mut b = good.clone();
        b[77] = 2;
        reseal(&mut b);
        assert_eq!(WaitRecord::decode(&b), Err(RecordError::InvalidField));
        let mut b = good.clone();
        b[78] = 1;
        reseal(&mut b);
        assert_eq!(WaitRecord::decode(&b), Err(RecordError::NonZeroPadding));
    }

    // ----- Clock record -----

    fn sample_clock() -> ClockRecord {
        ClockRecord {
            sequence: 10,
            high_water_round: 1_000_500,
            high_water_signature: [0x33; 48],
            high_water_boot_ms: 9_000_000,
            estimate_base_round: 1_000_400,
            estimate_base_boot_ms: 8_000_000,
            boot_total_ms: 9_500_000,
            awake_total_ms: 6_000_000,
            last_boot_reading_ms: 77_000,
            last_awake_reading_ms: 55_000,
        }
    }

    #[test]
    fn clock_record_round_trips() {
        assert_eq!(ClockRecord::LEN, 136);
        let record = sample_clock();
        let bytes = record.encode().unwrap();
        assert_eq!(bytes.len(), ClockRecord::LEN);
        assert_eq!(ClockRecord::decode(&bytes), Ok(record));
    }

    #[test]
    fn clock_record_is_strict() {
        let bytes = sample_clock().encode().unwrap();
        assert_strict(&bytes, &|b: &[u8]| ClockRecord::decode(b).err());
    }

    #[test]
    fn clock_record_refuses_fields_that_disagree() {
        let mut r = sample_clock();
        r.high_water_round = 0;
        r.estimate_base_round = 0;
        assert_eq!(r.encode(), Err(RecordError::InvalidField));
        let mut r = sample_clock();
        r.estimate_base_round = r.high_water_round + 1;
        assert_eq!(r.encode(), Err(RecordError::InvalidField));
        let mut r = sample_clock();
        r.estimate_base_boot_ms = r.high_water_boot_ms + 1;
        assert_eq!(r.encode(), Err(RecordError::InvalidField));
        let mut r = sample_clock();
        r.high_water_boot_ms = r.boot_total_ms + 1;
        assert_eq!(r.encode(), Err(RecordError::InvalidField));
    }

    #[test]
    fn a_clock_record_never_follows_one_it_would_move_back() {
        let current = sample_clock();
        let mut next = sample_clock();
        next.sequence = 11;
        next.boot_total_ms += 60_000;
        next.awake_total_ms += 60_000;
        assert!(next.may_follow(&current));

        let mut same_sequence = next;
        same_sequence.sequence = 10;
        assert!(!same_sequence.may_follow(&current));
        let mut skipped = next;
        skipped.sequence = 12;
        assert!(!skipped.may_follow(&current));
        let mut lower_round = next;
        lower_round.high_water_round -= 1;
        assert!(!lower_round.may_follow(&current));
        let mut lower_base = next;
        lower_base.estimate_base_round -= 1;
        assert!(!lower_base.may_follow(&current));
        let mut lower_boot = next;
        lower_boot.boot_total_ms = current.boot_total_ms - 1;
        assert!(!lower_boot.may_follow(&current));
        let mut lower_awake = next;
        lower_awake.awake_total_ms = current.awake_total_ms - 1;
        assert!(!lower_awake.may_follow(&current));

        let mut last = sample_clock();
        last.sequence = u64::MAX;
        assert!(!next.may_follow(&last));
    }

    #[test]
    fn the_newer_valid_clock_slot_is_current() {
        let older = sample_clock();
        let mut newer = sample_clock();
        newer.sequence = 11;
        let torn: Result<ClockRecord, RecordError> = Err(RecordError::BadChecksum);
        assert_eq!(newer_clock_slot(Ok(older), Ok(newer)), Some(newer));
        assert_eq!(newer_clock_slot(Ok(newer), Ok(older)), Some(newer));
        assert_eq!(newer_clock_slot(Ok(older), torn), Some(older));
        assert_eq!(newer_clock_slot(torn, Ok(older)), Some(older));
        assert_eq!(newer_clock_slot(torn, torn), None);
    }

    // ----- Instant-leave marker -----

    #[test]
    fn marker_round_trips_and_is_strict() {
        assert_eq!(InstantLeaveMarker::LEN, 32);
        let marker = InstantLeaveMarker { lock_round: 1_000_000, lock_date_unix_seconds: 1_795_000_000 };
        let bytes = marker.encode().unwrap();
        assert_eq!(InstantLeaveMarker::decode(&bytes), Ok(marker));
        assert_strict(&bytes, &|b: &[u8]| InstantLeaveMarker::decode(b).err());
        let zero = InstantLeaveMarker { lock_round: 0, lock_date_unix_seconds: 1 };
        assert_eq!(zero.encode(), Err(RecordError::InvalidField));
    }

    // ----- Capsule -----

    fn sample_capsule() -> Capsule {
        let mut ciphertext: Vec<u8> = Vec::new();
        let mut i = 0;
        while i < 300 {
            ciphertext.push((i % 251) as u8 + 1);
            i += 1;
        }
        Capsule { generation: 4, target_round: 9_000_000, chain_hash: BEACON_CHAIN_HASH, ciphertext }
    }

    #[test]
    fn capsule_round_trips_at_its_fixed_size() {
        assert_eq!(Capsule::LEN, 4_096);
        assert_eq!(Capsule::CIPHERTEXT_MAX, 4_030);
        let capsule = sample_capsule();
        let bytes = capsule.encode().unwrap();
        assert_eq!(bytes.len(), CAPSULE_SIZE);
        assert_eq!(Capsule::decode(&bytes), Ok(capsule.clone()));
        assert!(capsule.is_on_pinned_chain());

        let mut full = sample_capsule();
        full.ciphertext = vec![0xEE; Capsule::CIPHERTEXT_MAX];
        let bytes = full.encode().unwrap();
        assert_eq!(bytes.len(), CAPSULE_SIZE);
        assert_eq!(Capsule::decode(&bytes), Ok(full));

        let mut one = sample_capsule();
        one.ciphertext = vec![1];
        one.chain_hash = [0; 32];
        assert_eq!(Capsule::decode(&one.encode().unwrap()), Ok(one.clone()));
        assert!(!one.is_on_pinned_chain());
    }

    #[test]
    fn capsule_is_strict() {
        let bytes = sample_capsule().encode().unwrap();
        assert_strict(&bytes, &|b: &[u8]| Capsule::decode(b).err());
    }

    #[test]
    fn capsule_refuses_bad_lengths_and_padding() {
        let mut empty = sample_capsule();
        empty.ciphertext = Vec::new();
        assert_eq!(empty.encode(), Err(RecordError::InvalidField));
        let mut too_long = sample_capsule();
        too_long.ciphertext = vec![1; Capsule::CIPHERTEXT_MAX + 1];
        assert_eq!(too_long.encode(), Err(RecordError::InvalidField));
        let mut no_target = sample_capsule();
        no_target.target_round = 0;
        assert_eq!(no_target.encode(), Err(RecordError::InvalidField));

        let good = sample_capsule().encode().unwrap();
        // Offsets: ciphertext length 60..62, ciphertext from 62.
        let mut zero_len = good.clone();
        zero_len[60] = 0;
        zero_len[61] = 0;
        reseal(&mut zero_len);
        assert_eq!(Capsule::decode(&zero_len), Err(RecordError::InvalidField));
        let mut huge_len = good.clone();
        huge_len[60] = 0xFF;
        huge_len[61] = 0xFF;
        reseal(&mut huge_len);
        assert_eq!(Capsule::decode(&huge_len), Err(RecordError::InvalidField));
        // A byte after the ciphertext that is not zero: something else in the capsule.
        let mut padded = good.clone();
        padded[62 + 300] = 1;
        reseal(&mut padded);
        assert_eq!(Capsule::decode(&padded), Err(RecordError::NonZeroPadding));
        let mut last = good.clone();
        last[CAPSULE_SIZE - 5] = 1;
        reseal(&mut last);
        assert_eq!(Capsule::decode(&last), Err(RecordError::NonZeroPadding));
    }

    // ----- No two record types share a number or can be read as each other -----

    #[test]
    fn a_record_is_never_read_as_another_type() {
        let types = [
            TYPE_CAPSULE,
            TYPE_REQUEST_JOURNAL_ENTRY,
            TYPE_WAIT_RECORD,
            TYPE_CLOCK_RECORD,
            TYPE_ROUND_RECORD,
            TYPE_INSTANT_LEAVE_MARKER,
        ];
        let mut i = 0;
        while i < types.len() {
            let mut j = i + 1;
            while j < types.len() {
                assert!(types[i] != types[j]);
                j += 1;
            }
            i += 1;
        }
        let round = sample_round().encode().unwrap();
        let entry = sample_entry().encode().unwrap();
        let wait = sample_wait().encode().unwrap();
        let clock = sample_clock().encode().unwrap();
        assert_eq!(JournalEntry::decode(&round), Err(RecordError::WrongType));
        assert_eq!(WaitRecord::decode(&round), Err(RecordError::WrongType));
        assert_eq!(ClockRecord::decode(&round), Err(RecordError::WrongType));
        assert_eq!(InstantLeaveMarker::decode(&round), Err(RecordError::WrongType));
        assert_eq!(Capsule::decode(&round), Err(RecordError::WrongType));
        assert_eq!(RoundRecord::decode(&entry), Err(RecordError::WrongType));
        assert_eq!(RoundRecord::decode(&wait), Err(RecordError::WrongType));
        assert_eq!(RoundRecord::decode(&clock), Err(RecordError::WrongType));
        assert_eq!(WaitRecord::decode(&clock), Err(RecordError::WrongType));
        assert_eq!(ClockRecord::decode(&wait), Err(RecordError::WrongType));
    }

    const ROUND_RECORD_VECTOR: &str = "53534d4b060001006800000052db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e97140420f0000000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f2e346e26";
    const JOURNAL_ENTRY_VECTOR: &str = "53534d4b0300010057000000a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a50102801303000000000015cd5b0700000000014a420f000000000001ca5512000000000001ca55120000000000014a6915000000000000a20ca3e7";
}
