// SPDX-License-Identifier: Apache-2.0
//! The waits, as one pure state machine (chapter 03 sections 3 to 5, 7 and 8):
//!
//! - SM-02, the exit request: Leave, the start round, the two maturity routes, Stay, the
//!   claim window, Committed (SD-039, SD-040, SD-048, SD-049, SD-050).
//! - The exit-class slot: one request at a time (SD-055). A lowering of the wait and a
//!   listed loosening follow the same table (SD-012, SD-046).
//! - SM-03, the wait change: a raise to 30 days or less at once; a raise above 30 days
//!   only after day 8, a guard day and a private yes (SD-045, SD-046, SD-047).
//! - The keyholder shortcut and the keyholder's date of power, keeper side (SD-053,
//!   SD-054; SM-04).
//! - The instant-leave window (SD-052).
//!
//! The machine has no input but messages, verified rounds and counter values. It reads
//! no file, no network and no date: every time value comes through `Clock`, and the
//! date is read only inside the `clock` module (invariant I3).
//!
//! Rules for reading this file:
//! - An act that loosens (maturing a request, a keyholder's date of power) uses verified
//!   rounds and the boot counter only.
//! - An act that cannot be undone for the owner (expiring a claim, closing the
//!   instant-leave window, expiring a raise) is refused by tighten-time and written as
//!   final only on proof: the estimate, which is verified rounds plus the boot counter
//!   (SD-041, amended by R1-lock-02).
//! - Every handler first brings the time-driven state up to date, exactly as `tick` does,
//!   then checks the message. A refused message changes nothing else.
//!
//! Not in this pass: writing the journal and the wait record to the store and replaying
//! them at start-up; the admin-task slot (SM-06); the release hold (SM-12); the private
//! check timer; "busy, try again" while another journaled operation is open (SD-226).

use crate::approval::{derive_challenge, ChallengeFields, ChallengeKind, MacLabel};
use crate::boundary::{CheckedApproval, OwnerProof, RandomSource, RoundVerifier, TimeSource};
use crate::clock::{Clock, RoundOutcome};
use crate::constants::{
    is_exit_wait_option, rounds_to_ms, wait_rounds, APPLIED_WAIT_CAP_AT_SETUP_DAYS, CLAIM_WINDOW_ROUNDS,
    INSTANT_LEAVE_CAP_ROUNDS, INSTANT_LEAVE_WINDOW_AWAKE_MS, INSTANT_RAISE_MAX_DAYS, KEYHOLDER_SHORTCUT_ROUNDS,
    LONG_WAIT_EARLIEST_ROUNDS, RAISE_CHECK_EXPIRY_ROUNDS, RAISE_GUARD_DELAY_ROUNDS,
};
use crate::records::{GuardedRaise, JournalEntry, RaiseTerms, RequestKind, RequestState};

/// A request's random 16-byte ID (chapter 03 section 3).
pub type RequestId = [u8; 16];

/// The settings whose loosening waits the applied wait (the closed list of SD-012, less
/// the exit itself and the lowering of the wait, which have their own kinds).
// OPEN: SD-012 - "removing or weakening the browser profile" is one entry here; the
// register does not split it, and does not number the list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoosenableSetting {
    BrowserProfile,
    StrictCoverModeOff,
    DetectorRuleBalanced,
}

impl LoosenableSetting {
    /// The setting's code in the keyholder challenge and on the keyholder page.
    pub fn code(self) -> u16 {
        match self {
            LoosenableSetting::BrowserProfile => 1,
            LoosenableSetting::StrictCoverModeOff => 2,
            LoosenableSetting::DetectorRuleBalanced => 3,
        }
    }
}

/// What an exit-class request does when it is Committed (chapter 03 section 5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExitClassKind {
    /// The exit steps (SM-11).
    Exit,
    /// The applied wait becomes the lower value.
    LowerWait { new_wait_days: u16 },
    /// The keeper applies that one setting.
    LoosenSetting(LoosenableSetting),
}

impl ExitClassKind {
    fn journal_kind(self) -> RequestKind {
        match self {
            ExitClassKind::Exit => RequestKind::Exit,
            ExitClassKind::LowerWait { .. } => RequestKind::LowerWait,
            ExitClassKind::LoosenSetting(_) => RequestKind::LoosenSetting,
        }
    }

    /// What the keyholder is shown, and what the challenge binds.
    fn challenge_kind(self) -> ChallengeKind {
        match self {
            ExitClassKind::Exit => ChallengeKind::Exit,
            ExitClassKind::LowerWait { new_wait_days } => ChallengeKind::LowerWait { new_wait_days },
            ExitClassKind::LoosenSetting(setting) => ChallengeKind::LoosenSetting { setting_code: setting.code() },
        }
    }
}

/// Where an open request is in SM-02.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Pending,
    Matured { matured_round: u64, claim_deadline: u64 },
}

/// What a keyholder's approval has done to a request (SD-053).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shortcut {
    /// No approval has been accepted for this request.
    NotUsed,
    /// An approval was accepted; the next round that passes SD-039 decides the target.
    AwaitingStartRound,
    /// The target is the shortcut target. A raise of the wait voids it (`apply_raise`).
    Applied,
    /// The approval is used up and changed nothing, or was withdrawn by the owner.
    Spent,
}

/// One open exit-class request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Request {
    pub id: RequestId,
    pub kind: ExitClassKind,
    pub phase: Phase,
    /// The wait in rounds: the applied wait at the request, raised if the applied wait
    /// is raised while the request is Pending.
    pub wait_rounds: u64,
    /// The boot-counter value when the request was journaled: the base of the counter route.
    pub boot_ms_at_request: u64,
    /// The first verified round received after the request that passed SD-039.
    pub start_round: Option<u64>,
    pub target_round: Option<u64>,
    pub shortcut: Shortcut,
    /// The keeper's 32 random bytes for this request's keyholder challenge (SD-306). Drawn
    /// when the request is journaled and journaled with it.
    pub nonce: [u8; 32],
}

impl Request {
    fn journal_entry(&self, state: RequestState) -> JournalEntry {
        let (matured_round, claim_deadline) = match self.phase {
            Phase::Pending => (None, None),
            Phase::Matured { matured_round, claim_deadline } => (Some(matured_round), Some(claim_deadline)),
        };
        JournalEntry {
            request_id: self.id,
            kind: self.kind.journal_kind(),
            state,
            wait_rounds: self.wait_rounds,
            boot_ms_at_request: self.boot_ms_at_request,
            start_round: self.start_round,
            target_round: self.target_round,
            matured_round,
            claim_deadline,
            approval_used: self.shortcut != Shortcut::NotUsed,
            challenge_nonce: self.nonce,
        }
    }
}

/// The one exit-class slot (SD-055).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Slot {
    Free,
    Open(Request),
    /// An exit is Committed. There is no return: the keeper only finishes forward.
    ExitCommitted(RequestId),
}

/// A keyholder's power to approve (SD-054).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Power {
    Has,
    /// Enrolled after Lock, or the shortcut switched back on: power comes one applied
    /// wait later, counted like a request.
    Waiting { wait_rounds: u64, boot_ms_at_enrolment: u64, start_round: Option<u64> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Keyholder {
    pub shortcut_on: bool,
    pub power: Power,
}

/// What Lock hands to the machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LockFacts {
    /// One of the five options, and not above `APPLIED_WAIT_CAP_AT_SETUP` (SD-045).
    pub applied_wait_days: u16,
    /// A choice above 30 days made at setup, saved as the planned wait (SD-045).
    pub planned_wait_days: Option<u16>,
    /// True only if this Lock wrote the instant-leave marker and read it back (SD-052).
    pub instant_leave_window: bool,
    /// True if a keyholder was enrolled before Lock: power from Lock (SD-054).
    pub keyholder_enrolled_before_lock: bool,
    /// The owner's label for this Mac, as the keyholder sees it (SD-196, SD-306).
    pub mac_label: MacLabel,
}

/// Why a message was refused. A refusal changes nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// The message needs the typed login password (SD-051).
    PasswordNeeded,
    /// The exit-class slot already holds a request (SD-055).
    SlotFull,
    /// An exit is Committed; nothing else is accepted.
    ExitCommitted,
    /// The wait is not one of the five options, or is not allowed here.
    NotAnOption,
    /// `raise_wait` with a wait that is not above the applied wait.
    NotARaise,
    /// `lower_wait` with a wait that is not below the applied wait.
    NotALowering,
    /// No open request has that ID.
    NoSuchRequest,
    /// The request has not matured.
    NotMatured,
    /// Only the date says a deadline has passed. Nothing final is written. The app shows
    /// the "set the date and time" card; a verified round or the boot counter settles it.
    DeadlinePassedByDateOnly,
    /// A raise above 30 days is already guarded or awaiting its answer.
    GuardedRaiseOpen,
    /// No raise is awaiting the private yes.
    NoRaiseAwaitingAnswer,
    /// There is no keyholder.
    NoKeyholder,
    /// A keyholder is already pinned; keys are never replaced in place (SD-054).
    KeyholderAlreadyPinned,
    /// "That approval does not match this request." One answer for every reason (SM-04).
    ApprovalRefused,
    /// The system random generator gave nothing. Nothing was journaled; try again.
    RandomUnavailable,
    /// The Mac's date is before the chain began, or behind the keeper's estimate (verified
    /// rounds plus the boot counter), so it cannot be trusted to say a deadline has not
    /// passed. The app shows the "set the date and time" card. Nothing is written.
    DateUntrusted,
}

/// What an accepted message did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reply {
    /// A request was journaled as Pending. The wait has not started: it has no start round.
    Pending { id: RequestId },
    /// An exit is Committed. The exit steps (SM-11) must now run.
    ExitCommitted { id: RequestId },
    /// A lowering was claimed: the applied wait is now the lower value.
    WaitLowered { id: RequestId, applied_wait_days: u16 },
    /// A loosening was claimed: the keeper must now apply that one setting.
    SettingLoosened { id: RequestId, setting: LoosenableSetting },
    /// A raise is in force.
    RaiseApplied { applied_wait_days: u16 },
    /// A raise above 30 days, asked before `LONG_WAIT_EARLIEST`: saved as the planned wait only.
    SavedAsPlanned { planned_wait_days: u16 },
    /// A raise above 30 days is guarded: the guard day runs until this round.
    RaiseGuarded { guard_end_round: u64 },
    Done,
}

/// The one fixed reply to `stay`, the same whether or not anything existed (I09-1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StayReply;

/// The keeper's wait state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WaitMachine {
    clock: Clock,
    applied_wait_days: u16,
    planned_wait_days: Option<u16>,
    guarded_raise: GuardedRaise,
    lock_round: u64,
    awake_ms_at_lock: u64,
    instant_leave_granted: bool,
    instant_leave_closed: bool,
    slot: Slot,
    keyholder: Option<Keyholder>,
    mac_label: MacLabel,
    /// Set by every raise that takes effect: the wait the next capsule must be sealed for.
    /// Cleared only when the rotation reports that the old admin secret is retired.
    reseal_owed: Option<u16>,
    journal: Vec<JournalEntry>,
}

impl WaitMachine {
    /// The machine at the commit point of Lock. The Lock round is the clock's verified
    /// round at that moment.
    pub fn at_lock(facts: LockFacts, clock: Clock, time: &dyn TimeSource) -> Result<WaitMachine, Refusal> {
        if !is_exit_wait_option(facts.applied_wait_days) || facts.applied_wait_days > APPLIED_WAIT_CAP_AT_SETUP_DAYS {
            return Err(Refusal::NotAnOption);
        }
        if let Some(planned) = facts.planned_wait_days {
            if !is_exit_wait_option(planned) || planned <= APPLIED_WAIT_CAP_AT_SETUP_DAYS {
                return Err(Refusal::NotAnOption);
            }
        }
        let mut clock = clock;
        let awake_ms_at_lock = clock.awake_now_ms(time);
        let lock_round = clock.high_water_round();
        let keyholder = if facts.keyholder_enrolled_before_lock {
            Some(Keyholder { shortcut_on: true, power: Power::Has })
        } else {
            None
        };
        Ok(WaitMachine {
            clock,
            applied_wait_days: facts.applied_wait_days,
            planned_wait_days: facts.planned_wait_days,
            guarded_raise: GuardedRaise::None,
            lock_round,
            awake_ms_at_lock,
            instant_leave_granted: facts.instant_leave_window,
            instant_leave_closed: false,
            slot: Slot::Free,
            keyholder,
            mac_label: facts.mac_label,
            reseal_owed: None,
            journal: Vec::new(),
        })
    }

    // ----- What the keeper knows (the answers of `status` and `status_private`) -----

    pub fn applied_wait_days(&self) -> u16 {
        self.applied_wait_days
    }

    pub fn planned_wait_days(&self) -> Option<u16> {
        self.planned_wait_days
    }

    pub fn guarded_raise(&self) -> GuardedRaise {
        self.guarded_raise
    }

    pub fn slot(&self) -> Slot {
        self.slot
    }

    pub fn keyholder(&self) -> Option<Keyholder> {
        self.keyholder
    }

    pub fn lock_round(&self) -> u64 {
        self.lock_round
    }

    /// The wait a raise has put in force and that no capsule yet carries (SD-057, SD-058).
    /// While this is set, the newest capsule still opens one old wait after its
    /// generation's end, so the raise does not hold yet: the rotation must seal a new
    /// capsule for this wait at once, on a fresh round, and retire the old admin secret
    /// (steps 2 to 6 of SD-061). `old_secret_retired` clears it.
    // OPEN: SD-058 / SM-05 - the rotation is not written. SD-058 starts a new generation
    // on a raise "when a fresh round is at hand"; the register does not say what the app
    // shows until then. The more protective reading is recorded here: a raise is in force
    // for every request at once, and holds against the Recovery Key route only once the
    // old secret is retired. Until the rotation exists, nothing clears this.
    pub fn reseal_owed(&self) -> Option<u16> {
        self.reseal_owed
    }

    /// The rotation reports that a capsule for `sealed_for_wait_days` was saved and read
    /// back and that the old admin secret is retired (SD-061 step 6). Clears the owed
    /// re-seal only if that wait is at least the one owed.
    pub fn old_secret_retired(&mut self, sealed_for_wait_days: u16) {
        if let Some(owed) = self.reseal_owed {
            if sealed_for_wait_days >= owed {
                self.reseal_owed = None;
            }
        }
    }

    /// True once the instant-leave window is closed for good, or if there never was one.
    pub fn instant_leave_closed(&self) -> bool {
        !self.instant_leave_granted || self.instant_leave_closed
    }

    /// "Clock refusing rounds" of `status`.
    pub fn clock_refuses_rounds(&self) -> bool {
        self.clock.clock_refuses_rounds()
    }

    pub fn high_water_round(&self) -> u64 {
        self.clock.high_water_round()
    }

    /// The keeper's estimate of the present round.
    pub fn estimate(&mut self, time: &dyn TimeSource) -> u64 {
        self.clock.estimate(time)
    }

    /// The journal entries appended so far and not yet taken, oldest first.
    pub fn journal(&self) -> &[JournalEntry] {
        &self.journal
    }

    /// Hands the appended journal entries to the caller, which writes them to the store.
    pub fn take_journal(&mut self) -> Vec<JournalEntry> {
        let taken = self.journal.clone();
        self.journal.clear();
        taken
    }

    // ----- Time -----

    /// The time-driven rules, run at every start, every `COUNTER_SAVE` and every verified
    /// round: maturity on the counter route, the final closing of deadlines on proof, the
    /// end of the guard day, a keyholder's date of power.
    pub fn tick(&mut self, time: &dyn TimeSource) {
        self.advance(time);
    }

    /// `round`: the app hands over one round record. The keeper verifies it, and a round
    /// that passes may set a start round and may mature a request (SD-038, SD-039).
    pub fn offer_round(
        &mut self,
        round_record: &[u8],
        verifier: &dyn RoundVerifier,
        time: &dyn TimeSource,
    ) -> RoundOutcome {
        let outcome = self.clock.offer_round(round_record, verifier, time);
        if let RoundOutcome::Accepted(accepted) = outcome {
            if accepted.may_start {
                self.apply_start_round(accepted.round);
            }
            self.advance(time);
        }
        outcome
    }

    fn advance(&mut self, time: &dyn TimeSource) {
        let estimate = self.clock.estimate(time);
        let boot_now = self.clock.boot_now_ms(time);
        let awake_now = self.clock.awake_now_ms(time);
        let high_water = self.clock.high_water_round();
        self.advance_instant_leave(estimate, awake_now);
        self.advance_keyholder(high_water, boot_now);
        self.advance_guarded_raise(estimate);
        self.advance_request(estimate, high_water, boot_now);
    }

    fn instant_leave_cap_round(&self) -> u64 {
        self.lock_round.saturating_add(INSTANT_LEAVE_CAP_ROUNDS)
    }

    fn long_wait_earliest_round(&self) -> u64 {
        self.lock_round.saturating_add(LONG_WAIT_EARLIEST_ROUNDS)
    }

    /// The window closes for good on proof only: the awake counter shows the window's
    /// awake-hours, or the estimate has reached the cap (SD-052; R1-lock-02).
    // OPEN: SD-052 / register 8a (wait record) - no field records that the window is
    // closed for good. The two proofs above cannot move back, so they need none. A marker
    // that failed to read back once is remembered only in memory.
    fn advance_instant_leave(&mut self, estimate: u64, awake_now: u64) {
        if !self.instant_leave_granted || self.instant_leave_closed {
            return;
        }
        let awake_used = awake_now.saturating_sub(self.awake_ms_at_lock);
        if awake_used >= INSTANT_LEAVE_WINDOW_AWAKE_MS || estimate >= self.instant_leave_cap_round() {
            self.instant_leave_closed = true;
        }
    }

    /// A waiting keyholder gains power on the public route or the counter route,
    /// whichever is first (SD-054). A loosening: verified rounds and the boot counter only.
    fn advance_keyholder(&mut self, high_water: u64, boot_now: u64) {
        if let Some(ref mut keyholder) = self.keyholder {
            let mut gained = false;
            if let Power::Waiting { wait_rounds, boot_ms_at_enrolment, start_round } = keyholder.power {
                let public = match start_round {
                    Some(start) => high_water >= start.saturating_add(wait_rounds),
                    None => false,
                };
                let counter = boot_now.saturating_sub(boot_ms_at_enrolment) >= rounds_to_ms(wait_rounds);
                gained = public || counter;
            }
            if gained {
                keyholder.power = Power::Has;
            }
        }
    }

    /// The guard day ends, and an unanswered raise expires, on the estimate (SD-046,
    /// amended by I03-7; SD-041).
    // OPEN: SD-046 - whether the planned wait survives an expired raise is not specified.
    // It is cleared here, as it is for "No": the expired question leaves nothing behind.
    fn advance_guarded_raise(&mut self, estimate: u64) {
        let current = self.guarded_raise;
        match current {
            GuardedRaise::None => {}
            GuardedRaise::Guarded(terms) => {
                if estimate >= terms.guard_end_round {
                    self.guarded_raise = GuardedRaise::AwaitingPrivateYes(terms);
                }
            }
            GuardedRaise::AwaitingPrivateYes(terms) => {
                if estimate >= terms.check_expiry_round {
                    self.guarded_raise = GuardedRaise::None;
                    self.planned_wait_days = None;
                }
            }
        }
    }

    /// The maturity check and the final expiry of a claim (chapter 03 section 3).
    fn advance_request(&mut self, estimate: u64, high_water: u64, boot_now: u64) {
        let mut entry: Option<JournalEntry> = None;
        let mut free = false;
        if let Slot::Open(ref mut request) = self.slot {
            let phase = request.phase;
            match phase {
                Phase::Pending => {
                    // Public route: a verified round at or above the target.
                    let public = match request.target_round {
                        Some(target) => high_water >= target,
                        None => false,
                    };
                    // Counter route: the boot counter shows the full wait since the request.
                    let counted = boot_now.saturating_sub(request.boot_ms_at_request);
                    let counter = counted >= rounds_to_ms(request.wait_rounds);
                    if public || counter {
                        request.phase = Phase::Matured {
                            matured_round: estimate,
                            claim_deadline: estimate.saturating_add(CLAIM_WINDOW_ROUNDS),
                        };
                        entry = Some(request.journal_entry(RequestState::Matured));
                    }
                }
                Phase::Matured { claim_deadline, .. } => {
                    // Expired is final, so it is written only on proof (SD-050).
                    if estimate >= claim_deadline {
                        entry = Some(request.journal_entry(RequestState::Expired));
                        free = true;
                    }
                }
            }
        }
        if free {
            self.slot = Slot::Free;
        }
        if let Some(e) = entry {
            self.journal.push(e);
        }
    }

    /// A verified round that passed SD-039, received now: it is the start round of
    /// whatever is waiting for one.
    fn apply_start_round(&mut self, round: u64) {
        if let Some(ref mut keyholder) = self.keyholder {
            if let Power::Waiting { ref mut start_round, .. } = keyholder.power {
                if start_round.is_none() {
                    *start_round = Some(round);
                }
            }
        }
        let mut entry: Option<JournalEntry> = None;
        if let Slot::Open(ref mut request) = self.slot {
            if request.phase == Phase::Pending {
                if request.start_round.is_none() {
                    request.start_round = Some(round);
                    request.target_round = Some(round.saturating_add(request.wait_rounds));
                    entry = Some(request.journal_entry(RequestState::Pending));
                } else if request.shortcut == Shortcut::AwaitingStartRound {
                    // SD-053: the target moves to KEYHOLDER_SHORTCUT after this round, if
                    // that is earlier than the present target. Never later.
                    // OPEN: SD-053 (I03-5) - the ruling counts the shortcut's 24 hours on
                    // either route. The journal entry of register 8a has no field for the
                    // boot-counter value at the shortcut's start round, so only the public
                    // route is built. The request's own counter route runs untouched.
                    let candidate = round.saturating_add(KEYHOLDER_SHORTCUT_ROUNDS);
                    let earlier = match request.target_round {
                        Some(target) => candidate < target,
                        None => false,
                    };
                    if earlier {
                        request.target_round = Some(candidate);
                        request.shortcut = Shortcut::Applied;
                    } else {
                        request.shortcut = Shortcut::Spent;
                    }
                    entry = Some(request.journal_entry(RequestState::Pending));
                }
            }
        }
        if let Some(e) = entry {
            self.journal.push(e);
        }
    }

    // ----- Small checks shared by the handlers -----

    fn require_owner(&self, proof: OwnerProof) -> Result<(), Refusal> {
        match proof {
            OwnerProof::TypedPasswordVerified => Ok(()),
            OwnerProof::Missing => Err(Refusal::PasswordNeeded),
        }
    }

    fn require_not_committed(&self) -> Result<(), Refusal> {
        match self.slot {
            Slot::ExitCommitted(_) => Err(Refusal::ExitCommitted),
            Slot::Free => Ok(()),
            Slot::Open(_) => Ok(()),
        }
    }

    fn require_slot_free(&self) -> Result<(), Refusal> {
        match self.slot {
            Slot::Free => Ok(()),
            Slot::Open(_) => Err(Refusal::SlotFull),
            Slot::ExitCommitted(_) => Err(Refusal::ExitCommitted),
        }
    }

    /// A new request's random ID and challenge nonce. Drawn before anything changes, so a
    /// random generator that fails changes nothing.
    fn draw_request(random: &mut dyn RandomSource) -> Result<(RequestId, [u8; 32]), Refusal> {
        let id = match random.request_id() {
            Ok(id) => id,
            Err(_) => return Err(Refusal::RandomUnavailable),
        };
        let mut nonce = [0u8; 32];
        if random.fill(&mut nonce).is_err() {
            return Err(Refusal::RandomUnavailable);
        }
        Ok((id, nonce))
    }

    fn new_request(&mut self, drawn: (RequestId, [u8; 32]), kind: ExitClassKind, time: &dyn TimeSource) -> Request {
        Request {
            id: drawn.0,
            kind,
            phase: Phase::Pending,
            wait_rounds: wait_rounds(self.applied_wait_days),
            boot_ms_at_request: self.clock.boot_now_ms(time),
            start_round: None,
            target_round: None,
            shortcut: Shortcut::NotUsed,
            nonce: drawn.1,
        }
    }

    fn open_request(
        &mut self,
        kind: ExitClassKind,
        random: &mut dyn RandomSource,
        time: &dyn TimeSource,
    ) -> Result<Reply, Refusal> {
        let drawn = WaitMachine::draw_request(random)?;
        let request = self.new_request(drawn, kind, time);
        self.journal.push(request.journal_entry(RequestState::Pending));
        self.slot = Slot::Open(request);
        Ok(Reply::Pending { id: request.id })
    }

    // ----- SM-02: the exit request -----

    /// `leave`, with the typed password. Inside the instant-leave window it commits at
    /// once; otherwise it journals a Pending request with no start round, if the slot is
    /// free. `marker_reads_back_valid` is the marker file's state now (SD-052).
    // OPEN: SD-052 / SM-02 - Leave inside the window while the slot holds another request
    // is not specified. SM-02's instant row starts from "None", so it is refused as
    // "slot full" here; Stay frees the slot.
    pub fn leave(
        &mut self,
        proof: OwnerProof,
        marker_reads_back_valid: bool,
        random: &mut dyn RandomSource,
        time: &dyn TimeSource,
    ) -> Result<Reply, Refusal> {
        self.advance(time);
        self.require_owner(proof)?;
        self.require_slot_free()?;
        if self.instant_leave_granted && !self.instant_leave_closed {
            if !marker_reads_back_valid {
                // A marker that cannot be read means no window, for good.
                self.instant_leave_closed = true;
            } else {
                // Tighten-time can only say the cap has not passed if the date can be
                // trusted: a date before the chain began, or behind the keeper's estimate,
                // would let a lagging estimate stand for the present (after time powered
                // off). Refuse, and write nothing; a right date, or the window's own proofs
                // (`advance`), settle it. The ordinary Leave is never touched.
                if self.clock.date_untrusted(time) {
                    return Err(Refusal::DateUntrusted);
                }
                let tighten = self.clock.tighten_round(time);
                if tighten >= self.instant_leave_cap_round() {
                    // `advance` closes the window on proof. Here only the date says the
                    // cap has passed: refuse, and write nothing final (R1-lock-02).
                    return Err(Refusal::DeadlinePassedByDateOnly);
                }
                let drawn = WaitMachine::draw_request(random)?;
                let request = self.new_request(drawn, ExitClassKind::Exit, time);
                self.journal.push(request.journal_entry(RequestState::Committed));
                self.slot = Slot::ExitCommitted(request.id);
                return Ok(Reply::ExitCommitted { id: request.id });
            }
        }
        self.open_request(ExitClassKind::Exit, random, time)
    }

    /// `stay`: no password, no request ID, one fixed reply. Discards whatever exit-class
    /// entry exists. It only tightens. After Committed there is no return.
    pub fn stay(&mut self, time: &dyn TimeSource) -> StayReply {
        self.advance(time);
        let mut entry: Option<JournalEntry> = None;
        if let Slot::Open(ref request) = self.slot {
            entry = Some(request.journal_entry(RequestState::Discarded));
        }
        if let Some(e) = entry {
            self.journal.push(e);
            self.slot = Slot::Free;
        }
        StayReply
    }

    /// `claim`, with the typed password and the request ID. Accepted only if the entry is
    /// Matured and the claim deadline has not passed by tighten-time. A request is never
    /// claimed by itself.
    pub fn claim(&mut self, proof: OwnerProof, id: RequestId, time: &dyn TimeSource) -> Result<Reply, Refusal> {
        self.advance(time);
        self.require_owner(proof)?;
        let request = match self.slot {
            Slot::Open(request) => request,
            Slot::ExitCommitted(_) => return Err(Refusal::ExitCommitted),
            Slot::Free => return Err(Refusal::NoSuchRequest),
        };
        if request.id != id {
            return Err(Refusal::NoSuchRequest);
        }
        let claim_deadline = match request.phase {
            Phase::Matured { claim_deadline, .. } => claim_deadline,
            Phase::Pending => return Err(Refusal::NotMatured),
        };
        let tighten = self.clock.tighten_round(time);
        if tighten >= claim_deadline {
            // `advance` writes Expired on proof. Here only the date says the window has
            // passed: refuse, and write nothing final (SD-050, R1-lock-02).
            return Err(Refusal::DeadlinePassedByDateOnly);
        }
        // Committed is journaled before anything it allows is done.
        self.journal.push(request.journal_entry(RequestState::Committed));
        match request.kind {
            ExitClassKind::Exit => {
                self.slot = Slot::ExitCommitted(request.id);
                Ok(Reply::ExitCommitted { id: request.id })
            }
            ExitClassKind::LowerWait { new_wait_days } => {
                self.slot = Slot::Free;
                // A raise discards any open lowering (`apply_raise`), so a lowering that
                // reaches its claim waited out the wait in force now. It is checked again
                // here: a lowering never undoes a wait it did not wait out.
                let waited_out = request.wait_rounds >= wait_rounds(self.applied_wait_days);
                if waited_out && new_wait_days < self.applied_wait_days {
                    self.applied_wait_days = new_wait_days;
                }
                Ok(Reply::WaitLowered { id: request.id, applied_wait_days: self.applied_wait_days })
            }
            ExitClassKind::LoosenSetting(setting) => {
                self.slot = Slot::Free;
                Ok(Reply::SettingLoosened { id: request.id, setting })
            }
        }
    }

    /// `lower_wait`, with the typed password: an exit-class request that waits out the
    /// applied wait in force. The keeper applies the lower wait at the claim (SD-046).
    pub fn lower_wait(
        &mut self,
        proof: OwnerProof,
        new_wait_days: u16,
        random: &mut dyn RandomSource,
        time: &dyn TimeSource,
    ) -> Result<Reply, Refusal> {
        self.advance(time);
        self.require_owner(proof)?;
        self.require_slot_free()?;
        if !is_exit_wait_option(new_wait_days) {
            return Err(Refusal::NotAnOption);
        }
        if new_wait_days >= self.applied_wait_days {
            return Err(Refusal::NotALowering);
        }
        self.open_request(ExitClassKind::LowerWait { new_wait_days }, random, time)
    }

    /// `loosen_setting`, with the typed password: an exit-class request for one setting
    /// from the closed list (SD-012).
    pub fn loosen_setting(
        &mut self,
        proof: OwnerProof,
        setting: LoosenableSetting,
        random: &mut dyn RandomSource,
        time: &dyn TimeSource,
    ) -> Result<Reply, Refusal> {
        self.advance(time);
        self.require_owner(proof)?;
        self.require_slot_free()?;
        self.open_request(ExitClassKind::LoosenSetting(setting), random, time)
    }

    // ----- SM-03: the wait change -----

    /// A raise takes effect (SM-03; the founder's ruling on SD-054, 20 November 2026):
    ///
    /// - The applied wait rises, and an open Pending request waits the new wait from its
    ///   start round: its target moves later, never earlier.
    /// - A keyholder that has power loses it and waits again, as a keyholder newly
    ///   enrolled: the wait now in force, counted from this raise on the boot counter, or
    ///   from the first round after it that passes SD-039. A keyholder already waiting
    ///   waits the new wait from where its wait began. A lowering never gives power back.
    /// - A shortcut that an approval gave the open request, and that has not yet matured
    ///   it (awaiting its start round, or applied), is void: the target goes back to the
    ///   start round plus the new wait, and the approval stays used. This is the stricter
    ///   reading the ruling asked for. A request that has already matured, by either
    ///   route, is unchanged: a Matured entry is left only by a claim, Stay or expiry
    ///   (R1-lock-19), and it matured under the rules then in force.
    /// - An open lowering, Pending or Matured, is discarded: claimed after the raise, it
    ///   would undo the raise.
    /// - The raise is owed to the capsule (`reseal_owed`).
    ///
    /// None of this touches the full-wait route: a request still matures on its own
    /// public route or counter route, with or without a keyholder.
    fn apply_raise(&mut self, new_wait_days: u16, time: &dyn TimeSource) {
        let boot_now = self.clock.boot_now_ms(time);
        self.applied_wait_days = new_wait_days;
        let new_rounds = wait_rounds(new_wait_days);
        if let Some(ref mut keyholder) = self.keyholder {
            if keyholder.power == Power::Has {
                keyholder.power =
                    Power::Waiting { wait_rounds: new_rounds, boot_ms_at_enrolment: boot_now, start_round: None };
            } else if let Power::Waiting { wait_rounds: ref mut waiting_rounds, .. } = keyholder.power {
                if new_rounds > *waiting_rounds {
                    *waiting_rounds = new_rounds;
                }
            }
        }
        self.reseal_owed = match self.reseal_owed {
            Some(owed) if owed >= new_wait_days => Some(owed),
            _ => Some(new_wait_days),
        };
        let mut entry: Option<JournalEntry> = None;
        let mut free = false;
        if let Slot::Open(ref mut request) = self.slot {
            if let ExitClassKind::LowerWait { .. } = request.kind {
                entry = Some(request.journal_entry(RequestState::Discarded));
                free = true;
            } else if request.phase == Phase::Pending {
                let mut changed = false;
                if new_rounds > request.wait_rounds {
                    request.wait_rounds = new_rounds;
                    changed = true;
                }
                if request.shortcut == Shortcut::AwaitingStartRound || request.shortcut == Shortcut::Applied {
                    request.shortcut = Shortcut::Spent;
                    changed = true;
                }
                if changed {
                    if let Some(start) = request.start_round {
                        // Never earlier than before: the wait only rose, and a voided
                        // shortcut target was earlier than this one.
                        request.target_round = Some(start.saturating_add(request.wait_rounds));
                    }
                    entry = Some(request.journal_entry(RequestState::Pending));
                }
            }
        }
        if free {
            self.slot = Slot::Free;
        }
        if let Some(e) = entry {
            self.journal.push(e);
        }
    }

    /// `raise_wait`, with the typed password. To 30 days or less: applied at once. Above
    /// 30 days: before the day-8 gate, by tighten-time, saved as the planned wait only;
    /// after it, a guarded raise (SD-045, SD-046).
    // OPEN: SD-046 - a second raise above 30 days while one is guarded or awaiting its
    // answer is not specified. It is refused here; `clear_planned_wait` discards the
    // first one.
    pub fn raise_wait(&mut self, proof: OwnerProof, new_wait_days: u16, time: &dyn TimeSource) -> Result<Reply, Refusal> {
        self.advance(time);
        self.require_owner(proof)?;
        self.require_not_committed()?;
        if !is_exit_wait_option(new_wait_days) {
            return Err(Refusal::NotAnOption);
        }
        if new_wait_days <= self.applied_wait_days {
            return Err(Refusal::NotARaise);
        }
        if new_wait_days <= INSTANT_RAISE_MAX_DAYS {
            self.apply_raise(new_wait_days, time);
            return Ok(Reply::RaiseApplied { applied_wait_days: new_wait_days });
        }
        if self.guarded_raise != GuardedRaise::None {
            return Err(Refusal::GuardedRaiseOpen);
        }
        let tighten = self.clock.tighten_round(time);
        if tighten < self.long_wait_earliest_round() {
            self.planned_wait_days = Some(new_wait_days);
            return Ok(Reply::SavedAsPlanned { planned_wait_days: new_wait_days });
        }
        // The guard day is counted on verified rounds and the boot counter (I03-7).
        let estimate = self.clock.estimate(time);
        let guard_end_round = estimate.saturating_add(RAISE_GUARD_DELAY_ROUNDS);
        let terms = RaiseTerms {
            wait_days: new_wait_days,
            guard_end_round,
            check_expiry_round: guard_end_round.saturating_add(RAISE_CHECK_EXPIRY_ROUNDS),
        };
        self.guarded_raise = GuardedRaise::Guarded(terms);
        Ok(Reply::RaiseGuarded { guard_end_round })
    }

    /// `long_wait_answer`, with the typed password. Accepted only while a raise is
    /// awaiting the private yes. Yes applies the wait; no discards the raise and the
    /// planned wait. A yes after `RAISE_CHECK_EXPIRY`, by tighten-time, is refused.
    pub fn long_wait_answer(&mut self, proof: OwnerProof, yes: bool, time: &dyn TimeSource) -> Result<Reply, Refusal> {
        self.advance(time);
        self.require_owner(proof)?;
        self.require_not_committed()?;
        let terms = match self.guarded_raise {
            GuardedRaise::AwaitingPrivateYes(terms) => terms,
            GuardedRaise::Guarded(_) => return Err(Refusal::NoRaiseAwaitingAnswer),
            GuardedRaise::None => return Err(Refusal::NoRaiseAwaitingAnswer),
        };
        if !yes {
            self.guarded_raise = GuardedRaise::None;
            self.planned_wait_days = None;
            return Ok(Reply::Done);
        }
        let tighten = self.clock.tighten_round(time);
        if tighten >= terms.check_expiry_round {
            // `advance` expires the raise on proof. Here only the date says so.
            return Err(Refusal::DeadlinePassedByDateOnly);
        }
        self.guarded_raise = GuardedRaise::None;
        self.planned_wait_days = None;
        if terms.wait_days > self.applied_wait_days {
            self.apply_raise(terms.wait_days, time);
        }
        Ok(Reply::RaiseApplied { applied_wait_days: self.applied_wait_days })
    }

    /// `clear_planned_wait`, with the typed password: discards the planned wait and any
    /// guarded raise.
    pub fn clear_planned_wait(&mut self, proof: OwnerProof, time: &dyn TimeSource) -> Result<Reply, Refusal> {
        self.advance(time);
        self.require_owner(proof)?;
        self.require_not_committed()?;
        self.planned_wait_days = None;
        self.guarded_raise = GuardedRaise::None;
        Ok(Reply::Done)
    }

    // ----- The keyholder (SD-053, SD-054; SM-04, keeper side) -----

    fn challenge_of(&self, request: &Request) -> Option<[u8; 32]> {
        derive_challenge(&ChallengeFields {
            kind: request.kind.challenge_kind(),
            request_id: request.id,
            mac_label: &self.mac_label,
            items: &[],
            nonce: request.nonce,
        })
    }

    /// The request code's challenge for the one open request, if it can take an approval
    /// now: the request ID and the challenge the keyholder's passkey must sign (SD-306).
    /// The hands layer hands it to the approval check (`boundary::ApprovalVerifier`).
    pub fn approval_challenge(&self) -> Option<(RequestId, [u8; 32])> {
        match self.slot {
            Slot::Open(request) => {
                if request.phase != Phase::Pending || request.shortcut != Shortcut::NotUsed {
                    return None;
                }
                self.challenge_of(&request).map(|challenge| (request.id, challenge))
            }
            _ => None,
        }
    }

    fn waiting_power(&mut self, time: &dyn TimeSource) -> Power {
        Power::Waiting {
            wait_rounds: wait_rounds(self.applied_wait_days),
            boot_ms_at_enrolment: self.clock.boot_now_ms(time),
            start_round: None,
        }
    }

    /// The owner withdraws the shortcut: an approval that has not yet matured the request
    /// no longer shortens it.
    // OPEN: SD-053 - what `keyholder_drop` or "shortcut off" does to a shortcut target
    // already set on a Pending request is not specified. The more protective reading is
    // built: the target goes back to the start round plus the wait, and the approval
    // stays used. A request that has already Matured is unchanged.
    fn withdraw_shortcut(&mut self) {
        let mut entry: Option<JournalEntry> = None;
        if let Slot::Open(ref mut request) = self.slot {
            let live = request.shortcut == Shortcut::AwaitingStartRound || request.shortcut == Shortcut::Applied;
            if request.phase == Phase::Pending && live {
                if let Some(start) = request.start_round {
                    request.target_round = Some(start.saturating_add(request.wait_rounds));
                }
                request.shortcut = Shortcut::Spent;
                entry = Some(request.journal_entry(RequestState::Pending));
            }
        }
        if let Some(e) = entry {
            self.journal.push(e);
        }
    }

    /// `keyholder_enrol`, with the typed password, after Lock: the keyholder is pinned
    /// and waits one applied wait, as in force now, before it can approve. Checking the
    /// enrolment record itself is not in this pass.
    // OPEN: SD-054 / SD-195 - enrolling while a keyholder is pinned is not specified
    // beyond "one at a time" and "never replaced in place". It is refused here; the
    // owner drops the old keyholder first.
    pub fn keyholder_enrol(&mut self, proof: OwnerProof, time: &dyn TimeSource) -> Result<Reply, Refusal> {
        self.advance(time);
        self.require_owner(proof)?;
        self.require_not_committed()?;
        if self.keyholder.is_some() {
            return Err(Refusal::KeyholderAlreadyPinned);
        }
        let power = self.waiting_power(time);
        self.keyholder = Some(Keyholder { shortcut_on: true, power });
        Ok(Reply::Done)
    }

    /// `keyholder_drop`, with the typed password: erases the pin, at once.
    pub fn keyholder_drop(&mut self, proof: OwnerProof, time: &dyn TimeSource) -> Result<Reply, Refusal> {
        self.advance(time);
        self.require_owner(proof)?;
        self.require_not_committed()?;
        self.keyholder = None;
        self.withdraw_shortcut();
        Ok(Reply::Done)
    }

    /// `shortcut_switch`, with the typed password. Off: at once. On: as a new keyholder,
    /// which waits one applied wait again. Switching on what is already on changes nothing.
    pub fn shortcut_switch(&mut self, proof: OwnerProof, on: bool, time: &dyn TimeSource) -> Result<Reply, Refusal> {
        self.advance(time);
        self.require_owner(proof)?;
        self.require_not_committed()?;
        let current = match self.keyholder {
            Some(keyholder) => keyholder,
            None => return Err(Refusal::NoKeyholder),
        };
        if on {
            if !current.shortcut_on {
                let power = self.waiting_power(time);
                self.keyholder = Some(Keyholder { shortcut_on: true, power });
            }
        } else {
            self.keyholder = Some(Keyholder { shortcut_on: false, power: current.power });
            self.withdraw_shortcut();
        }
        Ok(Reply::Done)
    }

    /// `approval`: no password. `approval` carries what the cryptographic checks found.
    /// Accepted only if a keyholder is pinned, the shortcut is on, the keyholder has
    /// power, the checks passed, and the ID names the one open request, Pending and
    /// counting, with no approval used yet. An approval can only shorten: the keyholder
    /// can never block, cancel or delay anything.
    // OPEN: SD-053 / SM-02 - SM-02 accepts an approval for a request that is "Pending,
    // counting". Chapter 03 section 8 also sets a shortcut target when there is "no
    // target yet". The register's row is built: an approval for a request with no start
    // round is refused.
    pub fn approval(&mut self, approval: CheckedApproval, time: &dyn TimeSource) -> Result<Reply, Refusal> {
        self.advance(time);
        let has_power = match self.keyholder {
            Some(keyholder) => keyholder.shortcut_on && keyholder.power == Power::Has,
            None => false,
        };
        if !has_power || !approval.valid {
            return Err(Refusal::ApprovalRefused);
        }
        // The challenge the check was made against must be this request's, recomputed here
        // from the keeper's own record: its ID, its kind and detail, the Mac label and its
        // nonce (SD-306). A test approval, or one for any other request, never matches.
        let expected = match self.slot {
            Slot::Open(request) => self.challenge_of(&request),
            _ => None,
        };
        if expected != Some(approval.challenge) {
            return Err(Refusal::ApprovalRefused);
        }
        let mut entry: Option<JournalEntry> = None;
        if let Slot::Open(ref mut request) = self.slot {
            if request.id == approval.request_id
                && request.phase == Phase::Pending
                && request.start_round.is_some()
                && request.shortcut == Shortcut::NotUsed
            {
                request.shortcut = Shortcut::AwaitingStartRound;
                entry = Some(request.journal_entry(RequestState::Pending));
            }
        }
        match entry {
            Some(e) => {
                self.journal.push(e);
                Ok(Reply::Done)
            }
            None => Err(Refusal::ApprovalRefused),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::DropReason;
    use crate::constants::{BEACON_GENESIS_UNIX_SECONDS, BEACON_PERIOD_SECONDS, MS_PER_ROUND, ROUNDS_PER_DAY};
    use crate::fakes::{BrokenRandom, FakeBeacon, FakeRandom, FakeTime};

    const LOCK_ROUND: u64 = 1_000_000;
    const DAY: u64 = ROUNDS_PER_DAY;
    const DAY_MS: u64 = 86_400_000;
    const BOOT_AT_LOCK: u64 = 5_000_000;
    const OWNER: OwnerProof = OwnerProof::TypedPasswordVerified;
    const NOBODY: OwnerProof = OwnerProof::Missing;

    struct World {
        time: FakeTime,
        random: FakeRandom,
        m: WaitMachine,
    }

    fn label() -> MacLabel {
        MacLabel::new("Test Mac").unwrap()
    }

    /// The date and time, in milliseconds, at which the beacon publishes `round`.
    fn unix_ms_of_round(round: u64) -> u64 {
        (BEACON_GENESIS_UNIX_SECONDS + BEACON_PERIOD_SECONDS * (round - 1)) * 1_000
    }

    fn world_with(applied: u16, planned: Option<u16>, window: bool, keyholder: bool) -> World {
        let time = FakeTime::at_round(LOCK_ROUND);
        let clock = Clock::at_lock(&FakeBeacon::record_bytes(LOCK_ROUND), &FakeBeacon, &time).unwrap();
        let facts = LockFacts {
            applied_wait_days: applied,
            planned_wait_days: planned,
            instant_leave_window: window,
            keyholder_enrolled_before_lock: keyholder,
            mac_label: label(),
        };
        let m = WaitMachine::at_lock(facts, clock, &time).unwrap();
        World { time, random: FakeRandom::new(), m }
    }

    fn world(applied: u16) -> World {
        world_with(applied, None, false, false)
    }

    impl World {
        fn tick(&mut self) {
            self.m.tick(&self.time);
        }

        fn awake_rounds(&mut self, rounds: u64) {
            self.time.pass_awake_ms(rounds * MS_PER_ROUND);
        }

        fn off_rounds(&mut self, rounds: u64) {
            self.time.pass_powered_off_ms(rounds * MS_PER_ROUND);
        }

        fn deliver(&mut self, round: u64) -> RoundOutcome {
            self.m.offer_round(&FakeBeacon::record_bytes(round), &FakeBeacon, &self.time)
        }

        /// The app hands over the newest real round. Returns its number.
        fn deliver_latest(&mut self) -> u64 {
            let round = self.time.true_round();
            match self.deliver(round) {
                RoundOutcome::Accepted(_) => round,
                RoundOutcome::Dropped(reason) => panic!("the newest round was dropped: {:?}", reason),
            }
        }

        fn leave(&mut self) -> Result<Reply, Refusal> {
            self.m.leave(OWNER, true, &mut self.random, &self.time)
        }

        fn pending_id(&mut self) -> RequestId {
            match self.leave() {
                Ok(Reply::Pending { id }) => id,
                other => panic!("leave did not journal a Pending request: {:?}", other),
            }
        }

        fn lower_to(&mut self, days: u16) -> Result<Reply, Refusal> {
            self.m.lower_wait(OWNER, days, &mut self.random, &self.time)
        }

        fn request(&self) -> Request {
            match self.m.slot() {
                Slot::Open(request) => request,
                other => panic!("no open request: {:?}", other),
            }
        }

        fn is_pending(&self) -> bool {
            self.request().phase == Phase::Pending
        }

        fn is_matured(&self) -> bool {
            match self.request().phase {
                Phase::Matured { .. } => true,
                Phase::Pending => false,
            }
        }

        fn claim(&mut self, id: RequestId) -> Result<Reply, Refusal> {
            self.m.claim(OWNER, id, &self.time)
        }

        /// What the keyholder's page would have had the passkey sign for request `id`:
        /// computed from the open request when it is that one, made up otherwise.
        fn challenge_for(&self, id: RequestId) -> [u8; 32] {
            match self.m.slot() {
                Slot::Open(r) if r.id == id => derive_challenge(&ChallengeFields {
                    kind: r.kind.challenge_kind(),
                    request_id: id,
                    mac_label: &label(),
                    items: &[],
                    nonce: r.nonce,
                })
                .unwrap(),
                _ => [0x5E; 32],
            }
        }

        fn approve(&mut self, id: RequestId) -> Result<Reply, Refusal> {
            let challenge = self.challenge_for(id);
            self.m.approval(CheckedApproval { request_id: id, challenge, valid: true }, &self.time)
        }

        fn raise_to(&mut self, days: u16) -> Result<Reply, Refusal> {
            self.m.raise_wait(OWNER, days, &self.time)
        }

        /// The open request matures on the counter route: the Mac sleeps through the wait.
        fn sleep_through_the_wait(&mut self) {
            let wait_ms = rounds_to_ms(self.request().wait_rounds);
            self.time.pass_asleep_ms(wait_ms);
            self.tick();
            assert!(self.is_matured());
        }

        fn last_state(&self) -> RequestState {
            let journal = self.m.journal();
            journal[journal.len() - 1].state
        }
    }

    /// A refused message leaves the machine exactly as a tick at that moment leaves it.
    fn refused(w: &mut World, expected: Refusal, act: &dyn Fn(&mut World) -> Result<Reply, Refusal>) {
        w.tick();
        let before = w.m.clone();
        assert_eq!(act(&mut *w), Err(expected));
        assert_eq!(w.m, before);
    }

    // ----- Lock -----

    #[test]
    fn lock_takes_only_a_wait_the_setup_rules_allow() {
        let time = FakeTime::at_round(LOCK_ROUND);
        let clock = Clock::at_lock(&FakeBeacon::record_bytes(LOCK_ROUND), &FakeBeacon, &time).unwrap();
        let good = LockFacts {
            applied_wait_days: 30,
            planned_wait_days: Some(365),
            instant_leave_window: true,
            keyholder_enrolled_before_lock: false,
            mac_label: label(),
        };
        let m = WaitMachine::at_lock(good, clock.clone(), &time).unwrap();
        assert_eq!(m.applied_wait_days(), 30);
        assert_eq!(m.planned_wait_days(), Some(365));
        assert_eq!(m.lock_round(), LOCK_ROUND);
        assert_eq!(m.slot(), Slot::Free);
        assert_eq!(m.keyholder(), None);
        assert_eq!(m.guarded_raise(), GuardedRaise::None);
        assert!(!m.instant_leave_closed());
        assert!(m.journal().is_empty());

        // A wait above 30 days never locks as the applied wait (SD-045).
        let mut above = good;
        above.applied_wait_days = 90;
        assert_eq!(WaitMachine::at_lock(above, clock.clone(), &time), Err(Refusal::NotAnOption));
        let mut off_list = good;
        off_list.applied_wait_days = 14;
        assert_eq!(WaitMachine::at_lock(off_list, clock.clone(), &time), Err(Refusal::NotAnOption));
        let mut short_planned = good;
        short_planned.planned_wait_days = Some(30);
        assert_eq!(WaitMachine::at_lock(short_planned, clock.clone(), &time), Err(Refusal::NotAnOption));
        let mut odd_planned = good;
        odd_planned.planned_wait_days = Some(100);
        assert_eq!(WaitMachine::at_lock(odd_planned, clock.clone(), &time), Err(Refusal::NotAnOption));

        let with_keyholder = world_with(7, None, false, true);
        assert_eq!(with_keyholder.m.keyholder(), Some(Keyholder { shortcut_on: true, power: Power::Has }));
        assert!(world(7).m.instant_leave_closed());
    }

    // ----- The typed password -----

    #[test]
    fn every_message_that_needs_the_password_is_refused_without_it() {
        let mut w = world_with(30, None, true, true);
        w.awake_rounds(10);
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| {
            w.m.leave(NOBODY, true, &mut w.random, &w.time)
        });
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| {
            w.m.lower_wait(NOBODY, 7, &mut w.random, &w.time)
        });
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| {
            w.m.loosen_setting(NOBODY, LoosenableSetting::StrictCoverModeOff, &mut w.random, &w.time)
        });
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| w.m.raise_wait(NOBODY, 90, &w.time));
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| w.m.long_wait_answer(NOBODY, true, &w.time));
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| w.m.long_wait_answer(NOBODY, false, &w.time));
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| w.m.clear_planned_wait(NOBODY, &w.time));
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| w.m.keyholder_enrol(NOBODY, &w.time));
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| w.m.keyholder_drop(NOBODY, &w.time));
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| w.m.shortcut_switch(NOBODY, false, &w.time));
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| w.m.shortcut_switch(NOBODY, true, &w.time));

        // The claim, too, on a request that is ready to be claimed.
        let mut w = world(7);
        let id = w.pending_id();
        w.sleep_through_the_wait();
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| w.m.claim(NOBODY, id, &w.time));
        assert!(w.is_matured());
    }

    // ----- SM-02: Leave and the slot -----

    #[test]
    fn leave_journals_a_pending_request_with_no_start_round() {
        let mut w = world(7);
        w.awake_rounds(10);
        let id = w.pending_id();
        let request = w.request();
        assert_eq!(request.id, id);
        assert_eq!(request.kind, ExitClassKind::Exit);
        assert_eq!(request.phase, Phase::Pending);
        assert_eq!(request.wait_rounds, 7 * DAY);
        assert_eq!(request.boot_ms_at_request, BOOT_AT_LOCK + 30_000);
        assert_eq!(request.start_round, None);
        assert_eq!(request.target_round, None);
        assert_eq!(request.shortcut, Shortcut::NotUsed);
        assert_eq!(w.m.journal().len(), 1);
        assert_eq!(w.m.journal()[0].request_id, id);
        assert_eq!(w.m.journal()[0].state, RequestState::Pending);
        assert_eq!(w.m.journal()[0].kind, RequestKind::Exit);
        assert_eq!(w.m.journal()[0].start_round, None);
    }

    #[test]
    fn one_request_at_a_time() {
        let mut w = world(30);
        w.pending_id();
        refused(&mut w, Refusal::SlotFull, &|w: &mut World| w.leave());
        refused(&mut w, Refusal::SlotFull, &|w: &mut World| w.lower_to(7));
        refused(&mut w, Refusal::SlotFull, &|w: &mut World| {
            w.m.loosen_setting(OWNER, LoosenableSetting::DetectorRuleBalanced, &mut w.random, &w.time)
        });
        // The slot is as full when the request has matured.
        w.sleep_through_the_wait();
        refused(&mut w, Refusal::SlotFull, &|w: &mut World| w.leave());
        refused(&mut w, Refusal::SlotFull, &|w: &mut World| w.lower_to(7));

        // And as full when it holds a lowering.
        let mut w = world(30);
        assert!(w.lower_to(7).is_ok());
        refused(&mut w, Refusal::SlotFull, &|w: &mut World| w.leave());
        refused(&mut w, Refusal::SlotFull, &|w: &mut World| w.lower_to(7));
    }

    // ----- SM-02: the start round (SD-039) -----

    #[test]
    fn a_request_starts_on_the_first_fresh_round_after_it() {
        let mut w = world(7);
        w.awake_rounds(10);
        let id = w.pending_id();
        let start = w.deliver_latest();
        assert_eq!(start, LOCK_ROUND + 10);
        let request = w.request();
        assert_eq!(request.id, id);
        assert_eq!(request.phase, Phase::Pending);
        assert_eq!(request.start_round, Some(start));
        assert_eq!(request.target_round, Some(start + 7 * DAY));
        assert_eq!(w.m.journal().len(), 2);
        assert_eq!(w.m.journal()[1].state, RequestState::Pending);
        assert_eq!(w.m.journal()[1].start_round, Some(start));

        // Later rounds never move the start round or the target.
        w.awake_rounds(500);
        w.deliver_latest();
        w.off_rounds(1_000);
        w.deliver_latest();
        assert_eq!(w.request().start_round, Some(start));
        assert_eq!(w.request().target_round, Some(start + 7 * DAY));
        assert_eq!(w.m.journal().len(), 2);
    }

    #[test]
    fn a_round_from_before_the_request_is_not_its_start_round() {
        let mut w = world(7);
        w.awake_rounds(100);
        w.pending_id();
        // Older than the keeper's estimate, though above the high-water round: rule (a).
        match w.deliver(LOCK_ROUND + 40) {
            RoundOutcome::Accepted(a) => assert!(!a.may_start),
            RoundOutcome::Dropped(reason) => panic!("dropped: {:?}", reason),
        }
        assert_eq!(w.request().start_round, None);
        // Below the high-water round: dropped, with no effect.
        assert_eq!(w.deliver(LOCK_ROUND + 39), RoundOutcome::Dropped(DropReason::BelowHighWater));
        assert_eq!(w.deliver(LOCK_ROUND), RoundOutcome::Dropped(DropReason::BelowHighWater));
        assert_eq!(w.request().start_round, None);
        // A malformed record: dropped.
        match w.m.offer_round(&[0u8; 104], &FakeBeacon, &w.time) {
            RoundOutcome::Dropped(DropReason::Malformed(_)) => {}
            other => panic!("accepted: {:?}", other),
        }
        assert_eq!(w.request().start_round, None);
        // The newest round: the start.
        let start = w.deliver_latest();
        assert_eq!(start, LOCK_ROUND + 100);
        assert_eq!(w.request().start_round, Some(start));
    }

    #[test]
    fn a_wrong_date_can_refuse_a_start_round_and_the_counter_route_still_runs() {
        let mut w = world(7);
        w.awake_rounds(10);
        w.pending_id();
        w.time.wall_unix_ms += DAY_MS;
        w.deliver_latest();
        assert_eq!(w.request().start_round, None);
        assert!(w.m.clock_refuses_rounds());
        // The date is put right: the next round is the start round.
        w.time.wall_unix_ms = w.time.true_unix_ms;
        w.awake_rounds(1);
        let start = w.deliver_latest();
        assert_eq!(w.request().start_round, Some(start));
        assert!(!w.m.clock_refuses_rounds());

        // With the date left wrong, the request still matures on the counter route.
        let mut w = world(7);
        w.pending_id();
        w.time.wall_unix_ms += DAY_MS;
        w.awake_rounds(7 * DAY - 1);
        w.deliver_latest();
        assert_eq!(w.request().start_round, None);
        assert!(w.is_pending());
        w.awake_rounds(1);
        w.tick();
        assert!(w.is_matured());
    }

    // ----- SM-02: the two maturity routes (SD-040) -----

    #[test]
    fn the_public_route_matures_on_a_round_at_the_target_and_not_before() {
        let mut w = world(7);
        w.awake_rounds(10);
        w.pending_id();
        let start = w.deliver_latest();
        let target = start + 7 * DAY;
        // The Mac is off, so the counter route counts nothing.
        w.off_rounds(7 * DAY - 1);
        assert_eq!(w.deliver_latest(), target - 1);
        assert!(w.is_pending());
        w.off_rounds(1);
        assert_eq!(w.deliver_latest(), target);
        assert_eq!(
            w.request().phase,
            Phase::Matured { matured_round: target, claim_deadline: target + CLAIM_WINDOW_ROUNDS }
        );
        assert_eq!(w.last_state(), RequestState::Matured);
        // Protection stays on: nothing is committed by maturing.
        assert_eq!(w.m.slot(), Slot::Open(w.request()));
    }

    #[test]
    fn the_counter_route_matures_on_the_full_wait_of_boot_counter_time_and_not_before() {
        let mut w = world(7);
        w.awake_rounds(10);
        w.pending_id();
        // No round ever arrives. Sleep counts on the boot counter.
        w.time.pass_asleep_ms(7 * DAY_MS - 1);
        w.tick();
        assert!(w.is_pending());
        assert_eq!(w.request().start_round, None);
        w.time.pass_awake_ms(1);
        w.tick();
        let matured_at = LOCK_ROUND + 10 + 7 * DAY;
        assert_eq!(
            w.request().phase,
            Phase::Matured { matured_round: matured_at, claim_deadline: matured_at + CLAIM_WINDOW_ROUNDS }
        );
    }

    #[test]
    fn time_powered_off_and_a_changed_date_never_mature_a_request() {
        let mut w = world(7);
        w.pending_id();
        // A year powered off, with no round delivered: the counter route counted nothing.
        w.off_rounds(365 * DAY);
        w.tick();
        assert!(w.is_pending());
        // A date set far ahead.
        w.time.wall_unix_ms += 400 * DAY_MS;
        w.tick();
        assert!(w.is_pending());
        // A date set far back.
        w.time.wall_unix_ms = 0;
        w.tick();
        assert!(w.is_pending());
        assert_eq!(w.m.journal().len(), 1);

        // With a start round, a wrong date still matures nothing.
        let mut w = world(7);
        w.awake_rounds(10);
        w.pending_id();
        w.deliver_latest();
        w.time.wall_unix_ms += 400 * DAY_MS;
        w.tick();
        assert!(w.is_pending());
    }

    #[test]
    fn the_two_routes_take_no_credit_from_each_other() {
        let mut w = world(7);
        w.awake_rounds(10);
        w.pending_id();
        let start = w.deliver_latest();
        // Six days off and one day awake: neither route is complete while no round comes.
        w.off_rounds(6 * DAY);
        w.awake_rounds(DAY - 10);
        w.tick();
        assert!(w.is_pending());
        // Offline for the whole wait in real time: still nothing without a round.
        w.off_rounds(30 * DAY);
        w.tick();
        assert!(w.is_pending());
        // The next round is past the target: the public route.
        let latest = w.deliver_latest();
        assert!(latest >= start + 7 * DAY);
        assert!(w.is_matured());
    }

    // Invariant I2: a request never matures while real elapsed time since it was
    // journaled is less than its wait (to within `ANCHOR_CLOCK_TOLERANCE`, as SD-039 is
    // written: see the status document), whatever mix of awake, asleep, off and rounds; of
    // a date set ahead, set right, reset to before the chain began (and reset again at
    // every power-off, as a clock with a dead battery does), or set back behind the
    // keeper's estimate; and of old real rounds handed over again.
    //
    // Not in the mix: a date that is behind now and yet not behind the keeper's estimate.
    // That happens when a date set back is then carried past the estimate by time powered
    // off, or set there directly. Rule (b) then passes an old round, and nothing the
    // keeper holds tells it from a fresh one after time powered off. So a date set back
    // here is put right at the next power-off. Changing the date needs an administrator
    // on macOS; the status document lists the case as open.
    #[test]
    fn no_mix_of_sleep_power_and_rounds_matures_a_request_early() {
        let waits: [u16; 2] = [7, 30];
        let tolerance_ms = rounds_to_ms(crate::constants::ANCHOR_CLOCK_TOLERANCE_ROUNDS);
        for wait in waits.iter() {
            let mut seed: u64 = 0x0DDB_A11 + (*wait as u64);
            let mut run = 0;
            while run < 40 {
                let mut w = world(*wait);
                w.awake_rounds(3);
                w.pending_id();
                let journaled_at_ms = w.time.true_unix_ms;
                let wait_ms = rounds_to_ms(wait_rounds(*wait));
                // 0: the date as the steps left it; 1: reset to before the chain began;
                // 2: set back behind the estimate.
                let mut date_mode = 0;
                let mut step = 0;
                while step < 400 && w.m.slot() != Slot::Free {
                    seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
                    let choice = (seed >> 33) % 10;
                    let amount = (seed >> 40) % (DAY_MS / 2);
                    if choice == 0 {
                        w.time.pass_awake_ms(amount);
                    } else if choice == 1 {
                        w.time.pass_asleep_ms(amount);
                    } else if choice == 2 || choice == 6 {
                        // Powered off, for hours or for days at a time.
                        let off = if choice == 2 { amount } else { amount * 40 };
                        w.time.pass_powered_off_ms(off);
                        if date_mode == 1 {
                            w.time.wall_unix_ms = amount % 1_000_000;
                        } else if date_mode == 2 {
                            w.time.wall_unix_ms = w.time.true_unix_ms;
                            date_mode = 0;
                        }
                    } else if choice == 3 {
                        w.deliver_latest();
                    } else if choice == 4 {
                        w.time.wall_unix_ms = w.time.true_unix_ms + amount * 100;
                        date_mode = 0;
                    } else if choice == 5 {
                        w.time.wall_unix_ms = w.time.true_unix_ms;
                        date_mode = 0;
                    } else if choice == 7 {
                        if amount % 2 == 0 {
                            w.time.wall_unix_ms = (amount % (BEACON_GENESIS_UNIX_SECONDS * 1_000)) / 2;
                            date_mode = 1;
                        } else {
                            let behind = 205 + (amount / 1_000) % (60 * DAY);
                            let estimate = w.m.estimate(&w.time);
                            let round = if estimate > behind + 1 { estimate - behind } else { 1 };
                            w.time.wall_unix_ms = unix_ms_of_round(round);
                            date_mode = 2;
                        }
                    } else {
                        // An old real round, from up to 60 days back, handed over again.
                        let back = (amount / 1_000) % (60 * DAY);
                        let old = w.time.true_round().saturating_sub(back);
                        if old >= 1 {
                            let _ = w.deliver(old);
                        }
                    }
                    w.tick();
                    if w.m.slot() != Slot::Free && w.is_matured() {
                        let real_elapsed = w.time.true_unix_ms - journaled_at_ms;
                        assert!(real_elapsed + tolerance_ms >= wait_ms, "matured early: run {} step {}", run, step);
                    }
                    step += 1;
                }
                run += 1;
            }
        }
    }

    // ----- SM-02: Stay (SD-049) -----

    #[test]
    fn stay_throws_the_request_away_at_every_state_and_always_answers_the_same() {
        let mut w = world(7);
        w.awake_rounds(10);

        // Nothing to discard: the same reply, and nothing changes.
        w.tick();
        let before = w.m.clone();
        assert_eq!(w.m.stay(&w.time), StayReply);
        assert_eq!(w.m, before);

        // Pending, no start round.
        let first = w.pending_id();
        assert_eq!(w.m.stay(&w.time), StayReply);
        assert_eq!(w.m.slot(), Slot::Free);
        assert_eq!(w.last_state(), RequestState::Discarded);
        assert_eq!(w.m.journal()[w.m.journal().len() - 1].request_id, first);

        // Pending, counting.
        w.awake_rounds(10);
        let second = w.pending_id();
        w.deliver_latest();
        assert!(w.request().start_round.is_some());
        assert_eq!(w.m.stay(&w.time), StayReply);
        assert_eq!(w.m.slot(), Slot::Free);
        assert_eq!(w.last_state(), RequestState::Discarded);

        // Matured.
        let third = w.pending_id();
        w.sleep_through_the_wait();
        assert_eq!(w.m.stay(&w.time), StayReply);
        assert_eq!(w.m.slot(), Slot::Free);
        assert_eq!(w.last_state(), RequestState::Discarded);

        // A late claim for a discarded request is refused.
        refused(&mut w, Refusal::NoSuchRequest, &|w: &mut World| w.claim(third));

        // The next request starts from zero: a new ID, no start round, a new counter base.
        let fourth = w.pending_id();
        assert!(first != second && second != third && third != fourth);
        let request = w.request();
        assert_eq!(request.start_round, None);
        assert_eq!(request.target_round, None);
        assert_eq!(request.phase, Phase::Pending);
        assert_eq!(request.boot_ms_at_request, w.time.boot_ms);
        w.time.pass_asleep_ms(7 * DAY_MS - 1);
        w.tick();
        assert!(w.is_pending());
    }

    // ----- SM-02: the claim window (SD-050) -----

    #[test]
    fn a_claim_needs_a_matured_request_and_its_id() {
        let mut w = world(7);
        w.awake_rounds(10);
        refused(&mut w, Refusal::NoSuchRequest, &|w: &mut World| w.claim([9; 16]));
        let id = w.pending_id();
        refused(&mut w, Refusal::NotMatured, &|w: &mut World| w.claim(id));
        w.deliver_latest();
        refused(&mut w, Refusal::NotMatured, &|w: &mut World| w.claim(id));
        w.sleep_through_the_wait();
        refused(&mut w, Refusal::NoSuchRequest, &|w: &mut World| w.claim([9; 16]));
        assert_eq!(w.claim(id), Ok(Reply::ExitCommitted { id }));
        assert_eq!(w.m.slot(), Slot::ExitCommitted(id));
        assert_eq!(w.last_state(), RequestState::Committed);
    }

    #[test]
    fn a_matured_request_is_never_claimed_by_itself_and_expires_unclaimed() {
        let mut w = world(7);
        let id = w.pending_id();
        w.sleep_through_the_wait();
        let matured = w.request();
        // One round short of the claim window: still Matured, with its first deadline.
        w.awake_rounds(CLAIM_WINDOW_ROUNDS - 1);
        w.tick();
        w.deliver_latest();
        assert_eq!(w.m.slot(), Slot::Open(matured));
        // The window passes on the boot counter: Expired, and nothing is kept.
        w.awake_rounds(1);
        w.tick();
        assert_eq!(w.m.slot(), Slot::Free);
        assert_eq!(w.last_state(), RequestState::Expired);
        refused(&mut w, Refusal::NoSuchRequest, &|w: &mut World| w.claim(id));
        // Protection continues: the applied wait is what it was, and a new request
        // starts from zero.
        assert_eq!(w.m.applied_wait_days(), 7);
        let next = w.pending_id();
        assert!(next != id);
        assert_eq!(w.request().start_round, None);
        assert!(w.is_pending());
    }

    #[test]
    fn the_claim_window_also_closes_on_a_verified_round() {
        let mut w = world(7);
        w.pending_id();
        w.sleep_through_the_wait();
        // Powered off past the window. Nothing is final until a round proves it.
        w.off_rounds(CLAIM_WINDOW_ROUNDS + 5);
        w.tick();
        assert!(w.is_matured());
        w.deliver_latest();
        assert_eq!(w.m.slot(), Slot::Free);
        assert_eq!(w.last_state(), RequestState::Expired);
    }

    #[test]
    fn a_date_that_runs_ahead_refuses_a_claim_and_destroys_nothing() {
        let mut w = world(7);
        let id = w.pending_id();
        w.sleep_through_the_wait();
        w.time.wall_unix_ms += 8 * DAY_MS;
        refused(&mut w, Refusal::DeadlinePassedByDateOnly, &|w: &mut World| w.claim(id));
        assert!(w.is_matured());
        // The date is put right: the claim works again.
        w.time.wall_unix_ms = w.time.true_unix_ms;
        assert_eq!(w.claim(id), Ok(Reply::ExitCommitted { id }));
    }

    #[test]
    fn a_claim_is_accepted_up_to_the_last_round_of_the_window() {
        let mut w = world(7);
        let id = w.pending_id();
        w.sleep_through_the_wait();
        w.awake_rounds(CLAIM_WINDOW_ROUNDS - 1);
        assert_eq!(w.claim(id), Ok(Reply::ExitCommitted { id }));
    }

    #[test]
    fn after_an_exit_is_committed_there_is_no_return() {
        let mut w = world_with(7, None, false, true);
        let id = w.pending_id();
        w.sleep_through_the_wait();
        assert_eq!(w.claim(id), Ok(Reply::ExitCommitted { id }));

        // Stay answers as always and changes nothing.
        let before = w.m.clone();
        assert_eq!(w.m.stay(&w.time), StayReply);
        assert_eq!(w.m, before);
        // Time and rounds change nothing about the request.
        w.awake_rounds(30 * DAY);
        w.tick();
        w.deliver_latest();
        assert_eq!(w.m.slot(), Slot::ExitCommitted(id));

        refused(&mut w, Refusal::ExitCommitted, &|w: &mut World| w.leave());
        refused(&mut w, Refusal::ExitCommitted, &|w: &mut World| w.claim(id));
        refused(&mut w, Refusal::ExitCommitted, &|w: &mut World| w.lower_to(7));
        refused(&mut w, Refusal::ExitCommitted, &|w: &mut World| {
            w.m.loosen_setting(OWNER, LoosenableSetting::BrowserProfile, &mut w.random, &w.time)
        });
        refused(&mut w, Refusal::ExitCommitted, &|w: &mut World| w.raise_to(30));
        refused(&mut w, Refusal::ExitCommitted, &|w: &mut World| w.m.long_wait_answer(OWNER, true, &w.time));
        refused(&mut w, Refusal::ExitCommitted, &|w: &mut World| w.m.clear_planned_wait(OWNER, &w.time));
        refused(&mut w, Refusal::ExitCommitted, &|w: &mut World| w.m.keyholder_enrol(OWNER, &w.time));
        refused(&mut w, Refusal::ExitCommitted, &|w: &mut World| w.m.keyholder_drop(OWNER, &w.time));
        refused(&mut w, Refusal::ExitCommitted, &|w: &mut World| w.m.shortcut_switch(OWNER, false, &w.time));
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));
    }

    // ----- SM-02: a raise while a request is open -----

    #[test]
    fn a_raise_moves_a_pending_target_later_and_never_earlier() {
        // Pending, counting.
        let mut w = world(7);
        w.awake_rounds(10);
        w.pending_id();
        let start = w.deliver_latest();
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        let request = w.request();
        assert_eq!(request.wait_rounds, 30 * DAY);
        assert_eq!(request.start_round, Some(start));
        assert_eq!(request.target_round, Some(start + 30 * DAY));
        // The counter route's span is the new wait, too.
        w.time.pass_asleep_ms(30 * DAY_MS - 30_000 - 1);
        w.tick();
        assert!(w.is_pending());
        w.time.pass_asleep_ms(30_000 + 1);
        w.tick();
        assert!(w.is_matured());

        // Pending, no start round: the wait in rounds rises, and the start round that
        // comes later uses it.
        let mut w = world(7);
        w.awake_rounds(10);
        w.pending_id();
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        assert_eq!(w.request().wait_rounds, 30 * DAY);
        assert_eq!(w.request().target_round, None);
        w.awake_rounds(5);
        let start = w.deliver_latest();
        assert_eq!(w.request().target_round, Some(start + 30 * DAY));
    }

    #[test]
    fn a_raise_leaves_a_matured_request_as_it_matured() {
        let mut w = world(7);
        let id = w.pending_id();
        w.sleep_through_the_wait();
        let matured = w.request();
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        assert_eq!(w.m.slot(), Slot::Open(matured));
        assert_eq!(w.claim(id), Ok(Reply::ExitCommitted { id }));
    }

    // ----- The keyholder shortcut (SD-053) -----

    #[test]
    fn an_approval_moves_the_target_to_24_hours_after_a_new_start_round() {
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        let id = w.pending_id();
        let start = w.deliver_latest();
        w.awake_rounds(100);
        assert_eq!(w.approve(id), Ok(Reply::Done));
        // Accepted, and nothing has moved yet: the shortcut needs its own start round.
        let request = w.request();
        assert_eq!(request.shortcut, Shortcut::AwaitingStartRound);
        assert_eq!(request.target_round, Some(start + 7 * DAY));
        assert_eq!(w.m.journal()[w.m.journal().len() - 1].approval_used, true);

        w.awake_rounds(5);
        let shortcut_start = w.deliver_latest();
        assert_eq!(shortcut_start, start + 105);
        let request = w.request();
        assert_eq!(request.shortcut, Shortcut::Applied);
        assert_eq!(request.start_round, Some(start));
        assert_eq!(request.target_round, Some(shortcut_start + KEYHOLDER_SHORTCUT_ROUNDS));

        // It matures on a round at the shortcut target, and not one round before.
        w.off_rounds(KEYHOLDER_SHORTCUT_ROUNDS - 1);
        w.deliver_latest();
        assert!(w.is_pending());
        w.off_rounds(1);
        let matured_at = w.deliver_latest();
        assert_eq!(
            w.request().phase,
            Phase::Matured { matured_round: matured_at, claim_deadline: matured_at + CLAIM_WINDOW_ROUNDS }
        );
        // The claim window still applies, and so does the typed password.
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| w.m.claim(NOBODY, id, &w.time));
        assert_eq!(w.claim(id), Ok(Reply::ExitCommitted { id }));
    }

    #[test]
    fn a_shortcut_does_not_mature_on_the_boot_counter_alone() {
        // OPEN SD-053 (I03-5): only the public route is built for the shortcut.
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        let id = w.pending_id();
        w.deliver_latest();
        assert_eq!(w.approve(id), Ok(Reply::Done));
        w.awake_rounds(1);
        w.deliver_latest();
        assert_eq!(w.request().shortcut, Shortcut::Applied);
        // Two days asleep with no round: not matured.
        w.time.pass_asleep_ms(2 * DAY_MS);
        w.tick();
        assert!(w.is_pending());
        // The request's own counter route runs untouched: the full wait from the request.
        w.time.pass_asleep_ms(5 * DAY_MS);
        w.tick();
        assert!(w.is_matured());
    }

    #[test]
    fn an_approval_that_would_not_be_earlier_changes_nothing_and_is_used_up() {
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        let id = w.pending_id();
        let start = w.deliver_latest();
        let target = start + 7 * DAY;
        // Less than 24 hours of the wait are left.
        w.off_rounds(7 * DAY - 100);
        w.deliver_latest();
        assert_eq!(w.approve(id), Ok(Reply::Done));
        w.awake_rounds(1);
        w.deliver_latest();
        let request = w.request();
        assert_eq!(request.shortcut, Shortcut::Spent);
        assert_eq!(request.target_round, Some(target));
        // A second approval for the same request changes nothing.
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));
        // A raise afterwards moves the target later, and no later round brings the
        // spent shortcut back.
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        w.awake_rounds(1);
        w.deliver_latest();
        assert_eq!(w.request().target_round, Some(start + 30 * DAY));
        assert_eq!(w.request().shortcut, Shortcut::Spent);
    }

    // The founder's ruling on SD-054 (20 Nov 2026), the stricter reading: a raise voids a
    // shortcut that has not yet matured the request. The approval stays used, and the
    // request waits the new wait from its start round.
    #[test]
    fn a_raise_voids_a_shortcut_target_already_set() {
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        let id = w.pending_id();
        let start = w.deliver_latest();
        assert_eq!(w.approve(id), Ok(Reply::Done));
        w.awake_rounds(1);
        let shortcut_start = w.deliver_latest();
        assert_eq!(w.request().target_round, Some(shortcut_start + KEYHOLDER_SHORTCUT_ROUNDS));
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        let request = w.request();
        assert_eq!(request.target_round, Some(start + 30 * DAY));
        assert_eq!(request.wait_rounds, 30 * DAY);
        assert_eq!(request.start_round, Some(start));
        assert_eq!(request.shortcut, Shortcut::Spent);
        // What a replay would read: the last entry holds the voided state whole (the full
        // target, the approval used), and the record format takes it back unchanged.
        let last = w.m.journal()[w.m.journal().len() - 1];
        assert_eq!(last.state, RequestState::Pending);
        assert_eq!(last.target_round, Some(start + 30 * DAY));
        assert!(last.approval_used);
        assert_eq!(JournalEntry::decode(&last.encode().unwrap()), Ok(last));
        // A day later, nothing has matured; nor a day before the full wait.
        w.off_rounds(KEYHOLDER_SHORTCUT_ROUNDS);
        w.deliver_latest();
        assert!(w.is_pending());
        w.off_rounds(30 * DAY - KEYHOLDER_SHORTCUT_ROUNDS - 2);
        assert_eq!(w.deliver_latest(), start + 30 * DAY - 1);
        assert!(w.is_pending());
        // The keyholder is waiting again, and the used approval cannot be given twice.
        assert!(!has_power(&w));
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));
        // The full wait still matures it, with no keyholder involved.
        w.off_rounds(1);
        w.deliver_latest();
        assert!(w.is_matured());
        assert_eq!(w.claim(id), Ok(Reply::ExitCommitted { id }));
    }

    #[test]
    fn a_raise_voids_an_approval_still_awaiting_its_start_round() {
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        let id = w.pending_id();
        let start = w.deliver_latest();
        assert_eq!(w.approve(id), Ok(Reply::Done));
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        assert_eq!(w.request().target_round, Some(start + 30 * DAY));
        assert_eq!(w.request().shortcut, Shortcut::Spent);
        // The next round sets no shortcut target.
        w.awake_rounds(1);
        w.deliver_latest();
        assert_eq!(w.request().target_round, Some(start + 30 * DAY));
        assert_eq!(w.request().shortcut, Shortcut::Spent);
        let last = w.m.journal()[w.m.journal().len() - 1];
        assert!(last.approval_used);
        assert_eq!(last.target_round, Some(start + 30 * DAY));
    }

    // A request the shortcut has already matured is left as it matured: Matured is left
    // only by a claim, Stay or expiry (R1-lock-19). The raise still resets the keyholder.
    #[test]
    fn a_raise_leaves_a_request_the_shortcut_has_already_matured() {
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        let id = w.pending_id();
        w.deliver_latest();
        assert_eq!(w.approve(id), Ok(Reply::Done));
        w.awake_rounds(1);
        w.deliver_latest();
        w.off_rounds(KEYHOLDER_SHORTCUT_ROUNDS);
        w.deliver_latest();
        let matured = w.request();
        assert!(w.is_matured());
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        assert_eq!(w.m.slot(), Slot::Open(matured));
        assert!(!has_power(&w));
        assert_eq!(w.claim(id), Ok(Reply::ExitCommitted { id }));
    }

    #[test]
    fn every_approval_that_does_not_fit_is_refused_and_records_nothing() {
        // No keyholder at all.
        let mut w = world(7);
        w.awake_rounds(10);
        let id = w.pending_id();
        w.deliver_latest();
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));

        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        // No open request.
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve([1; 16]));
        let id = w.pending_id();
        // A request with no start round (SM-02: "Pending, counting" only).
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));
        w.deliver_latest();
        // Another request's ID.
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve([0x77; 16]));
        // A signature, origin or challenge that did not check out.
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| {
            let challenge = w.challenge_for(id);
            w.m.approval(CheckedApproval { request_id: id, challenge, valid: false }, &w.time)
        });
        // A matured request.
        w.sleep_through_the_wait();
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));
        // A discarded request.
        assert_eq!(w.m.stay(&w.time), StayReply);
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));
    }

    // The keyholder can never block, cancel or delay: whatever the moment of a valid
    // approval, the target afterwards is never later than it was.
    #[test]
    fn an_approval_never_moves_a_target_later() {
        let offsets: [u64; 6] = [0, 1, 1_000, 100_000, 172_799, 201_000];
        for offset in offsets.iter() {
            let mut w = world_with(7, None, false, true);
            w.awake_rounds(10);
            let id = w.pending_id();
            let start = w.deliver_latest();
            w.off_rounds(*offset);
            w.deliver_latest();
            let before = w.request().target_round;
            assert_eq!(before, Some(start + 7 * DAY));
            assert_eq!(w.approve(id), Ok(Reply::Done));
            assert_eq!(w.request().target_round, before);
            w.awake_rounds(1);
            let shortcut_start = w.deliver_latest();
            let shortcut_target = shortcut_start + KEYHOLDER_SHORTCUT_ROUNDS;
            let after = w.request().target_round;
            if shortcut_target < start + 7 * DAY {
                assert_eq!(after, Some(shortcut_target));
            } else {
                assert_eq!(after, before);
            }
            assert!(after <= before);
            assert!(w.is_pending());
            // And the request can still be thrown away by the owner alone.
            assert_eq!(w.m.stay(&w.time), StayReply);
            assert_eq!(w.m.slot(), Slot::Free);
        }
    }

    // ----- The keyholder's date of power (SD-054) -----

    #[test]
    fn a_keyholder_enrolled_after_lock_waits_a_full_wait_on_the_public_route() {
        let mut w = world(7);
        w.awake_rounds(10);
        assert_eq!(w.m.keyholder_enrol(OWNER, &w.time), Ok(Reply::Done));
        assert_eq!(
            w.m.keyholder(),
            Some(Keyholder {
                shortcut_on: true,
                power: Power::Waiting {
                    wait_rounds: 7 * DAY,
                    boot_ms_at_enrolment: BOOT_AT_LOCK + 30_000,
                    start_round: None,
                },
            })
        );
        w.awake_rounds(1);
        let start = w.deliver_latest();
        match w.m.keyholder() {
            Some(Keyholder { power: Power::Waiting { start_round, .. }, .. }) => assert_eq!(start_round, Some(start)),
            other => panic!("not waiting: {:?}", other),
        }
        w.off_rounds(7 * DAY - 1);
        w.deliver_latest();
        assert!(w.m.keyholder().unwrap().power != Power::Has);
        w.off_rounds(1);
        w.deliver_latest();
        assert_eq!(w.m.keyholder().unwrap().power, Power::Has);

        // From now on it can approve.
        let id = w.pending_id();
        w.awake_rounds(1);
        w.deliver_latest();
        assert_eq!(w.approve(id), Ok(Reply::Done));
    }

    #[test]
    fn a_waiting_keyholder_cannot_approve_and_gains_power_on_the_counter_route_too() {
        let mut w = world(7);
        w.awake_rounds(10);
        assert_eq!(w.m.keyholder_enrol(OWNER, &w.time), Ok(Reply::Done));
        let id = w.pending_id();
        w.deliver_latest();
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));
        assert_eq!(w.m.stay(&w.time), StayReply);

        w.time.pass_asleep_ms(7 * DAY_MS - 1);
        w.tick();
        assert!(w.m.keyholder().unwrap().power != Power::Has);
        w.time.pass_asleep_ms(1);
        w.tick();
        assert_eq!(w.m.keyholder().unwrap().power, Power::Has);
    }

    fn has_power(w: &World) -> bool {
        w.m.keyholder().unwrap().power == Power::Has
    }

    // A keyholder still waiting for power waits whatever wait a later raise puts in force,
    // counted from its enrolment, as an open request's wait is pushed out. Without this, a
    // key enrolled under 7 days and a raise to a long wait would leave every exit at about
    // a day from day 7 on.
    #[test]
    fn a_raise_pushes_a_waiting_keyholders_date_of_power_out() {
        // The counter route: enrolled under 7 days, raised to 30 at once.
        let mut w = world(7);
        assert_eq!(w.m.keyholder_enrol(OWNER, &w.time), Ok(Reply::Done));
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        match w.m.keyholder().unwrap().power {
            Power::Waiting { wait_rounds, .. } => assert_eq!(wait_rounds, 30 * DAY),
            other => panic!("not waiting: {:?}", other),
        }
        w.time.pass_asleep_ms(7 * DAY_MS);
        w.tick();
        assert!(!has_power(&w));
        w.time.pass_asleep_ms(23 * DAY_MS - 1);
        w.tick();
        assert!(!has_power(&w));
        w.time.pass_asleep_ms(1);
        w.tick();
        assert!(has_power(&w));

        // The public route: the keyholder's start round stays, and its date moves out.
        let mut w = world(7);
        w.awake_rounds(10);
        assert_eq!(w.m.keyholder_enrol(OWNER, &w.time), Ok(Reply::Done));
        w.awake_rounds(1);
        let start = w.deliver_latest();
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        w.off_rounds(7 * DAY);
        w.deliver_latest();
        assert!(!has_power(&w));
        w.off_rounds(23 * DAY - 1);
        assert_eq!(w.deliver_latest(), start + 30 * DAY - 1);
        assert!(!has_power(&w));
        w.off_rounds(1);
        w.deliver_latest();
        assert!(has_power(&w));

        // Enrolled under 7 days, raised to 30, then to 365 through the guard and the
        // private yes: no power, and so no one-day exit, before 365 days from enrolment.
        let mut w = world(7);
        assert_eq!(w.m.keyholder_enrol(OWNER, &w.time), Ok(Reply::Done));
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        w.awake_rounds(7 * DAY);
        match w.raise_to(365) {
            Ok(Reply::RaiseGuarded { .. }) => {}
            other => panic!("not guarded: {:?}", other),
        }
        w.awake_rounds(DAY);
        assert_eq!(w.m.long_wait_answer(OWNER, true, &w.time), Ok(Reply::RaiseApplied { applied_wait_days: 365 }));
        w.time.pass_asleep_ms(30 * DAY_MS);
        w.tick();
        assert!(!has_power(&w));
        let id = w.pending_id();
        w.awake_rounds(1);
        w.deliver_latest();
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));
        assert_eq!(w.m.stay(&w.time), StayReply);
        w.time.pass_asleep_ms(365 * DAY_MS - 38 * DAY_MS - 3 * 1_000 - 1);
        w.tick();
        assert!(!has_power(&w));
        w.time.pass_asleep_ms(1);
        w.tick();
        assert!(has_power(&w));

        // A lowering, once claimed, never shortens a waiting keyholder's wait.
        let mut w = world(30);
        let id = match w.lower_to(7) {
            Ok(Reply::Pending { id }) => id,
            other => panic!("not pending: {:?}", other),
        };
        w.sleep_through_the_wait();
        assert_eq!(w.m.keyholder_enrol(OWNER, &w.time), Ok(Reply::Done));
        assert_eq!(w.claim(id), Ok(Reply::WaitLowered { id, applied_wait_days: 7 }));
        w.time.pass_asleep_ms(7 * DAY_MS);
        w.tick();
        assert!(!has_power(&w));
        w.time.pass_asleep_ms(23 * DAY_MS);
        w.tick();
        assert!(has_power(&w));
    }

    // The founder's ruling on SD-054 (20 Nov 2026): a raise makes a keyholder that has
    // power wait again, the wait now in force, counted from the raise, as a keyholder
    // newly enrolled.
    #[test]
    fn a_raise_makes_a_keyholder_with_power_wait_again() {
        // The counter route.
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        assert!(has_power(&w));
        let boot_at_raise = w.time.boot_ms;
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        assert_eq!(
            w.m.keyholder(),
            Some(Keyholder {
                shortcut_on: true,
                power: Power::Waiting { wait_rounds: 30 * DAY, boot_ms_at_enrolment: boot_at_raise, start_round: None },
            })
        );
        let id = w.pending_id();
        w.awake_rounds(1);
        w.deliver_latest();
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));
        assert_eq!(w.m.stay(&w.time), StayReply);
        w.time.pass_asleep_ms(30 * DAY_MS - 3_000 - 1);
        w.tick();
        assert!(!has_power(&w));
        w.time.pass_asleep_ms(1);
        w.tick();
        assert!(has_power(&w));
        let id = w.pending_id();
        w.awake_rounds(1);
        w.deliver_latest();
        assert_eq!(w.approve(id), Ok(Reply::Done));

        // The public route: from the first round after the raise that passes SD-039.
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        w.awake_rounds(1);
        let start = w.deliver_latest();
        w.off_rounds(30 * DAY - 1);
        w.deliver_latest();
        assert!(!has_power(&w));
        w.off_rounds(1);
        assert_eq!(w.deliver_latest(), start + 30 * DAY);
        assert!(has_power(&w));

        // A second raise while it waits pushes it out again, from where its wait began.
        let mut w = world_with(7, None, false, true);
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        w.awake_rounds(7 * DAY);
        assert!(w.raise_to(90).is_ok());
        w.awake_rounds(DAY);
        assert_eq!(w.m.long_wait_answer(OWNER, true, &w.time), Ok(Reply::RaiseApplied { applied_wait_days: 90 }));
        w.time.pass_asleep_ms(82 * DAY_MS - 1);
        w.tick();
        assert!(!has_power(&w));
        w.time.pass_asleep_ms(1);
        w.tick();
        assert!(has_power(&w));

        // A raise while the shortcut is off resets the power too; switching it back on
        // starts a new wait, never an earlier one.
        let mut w = world_with(7, None, false, true);
        assert_eq!(w.m.shortcut_switch(OWNER, false, &w.time), Ok(Reply::Done));
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        assert!(!has_power(&w));
        assert_eq!(w.m.shortcut_switch(OWNER, true, &w.time), Ok(Reply::Done));
        assert!(!has_power(&w));

        // A lowering never gives the power back early: claimed, it leaves the wait as it is.
        let mut w = world_with(30, None, false, true);
        let lowering = match w.lower_to(7) {
            Ok(Reply::Pending { id }) => id,
            other => panic!("not pending: {:?}", other),
        };
        w.sleep_through_the_wait();
        assert!(w.raise_to(90).is_ok());
        assert!(w.is_matured());
        // The guarded raise is not in force yet; the lowering is claimed first, then the
        // yes resets the keyholder; the claim had changed nothing about the keyholder.
        assert_eq!(w.claim(lowering), Ok(Reply::WaitLowered { id: lowering, applied_wait_days: 7 }));
        assert!(has_power(&w));
        w.awake_rounds(DAY);
        assert!(w.m.long_wait_answer(OWNER, true, &w.time).is_ok());
        let waiting = w.m.keyholder().unwrap().power;
        let lowering = match w.lower_to(7) {
            Ok(Reply::Pending { id }) => id,
            other => panic!("not pending: {:?}", other),
        };
        w.sleep_through_the_wait();
        assert_eq!(w.claim(lowering), Ok(Reply::WaitLowered { id: lowering, applied_wait_days: 7 }));
        match (waiting, w.m.keyholder().unwrap().power) {
            (Power::Waiting { wait_rounds: before, .. }, Power::Has) => assert_eq!(before, 90 * DAY),
            (before, after) => assert_eq!(before, after),
        }
    }

    // An exit request open when the wait is raised keeps the full wait unless and until
    // the keyholder has power again and approves; the full wait never needs the keyholder.
    #[test]
    fn a_raise_during_an_open_request_the_keyholder_had_not_approved() {
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        let id = w.pending_id();
        let start = w.deliver_latest();
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        assert_eq!(w.request().target_round, Some(start + 30 * DAY));
        assert_eq!(w.request().shortcut, Shortcut::NotUsed);
        w.awake_rounds(1);
        w.deliver_latest();
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));
        w.off_rounds(30 * DAY - 2);
        w.deliver_latest();
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));
        assert!(w.is_pending());
        w.off_rounds(1);
        w.deliver_latest();
        assert!(w.is_matured());
        assert!(!has_power(&w));
        assert_eq!(w.claim(id), Ok(Reply::ExitCommitted { id }));

        // A request opened after the raise: once the keyholder has its power back, an
        // approval shortens that request as before.
        let mut w = world_with(7, None, false, true);
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        w.awake_rounds(5 * DAY);
        let id = w.pending_id();
        let start = w.deliver_latest();
        w.time.pass_asleep_ms(25 * DAY_MS);
        w.tick();
        assert!(has_power(&w));
        assert_eq!(w.approve(id), Ok(Reply::Done));
        w.awake_rounds(1);
        let shortcut_start = w.deliver_latest();
        assert_eq!(w.request().target_round, Some(shortcut_start + KEYHOLDER_SHORTCUT_ROUNDS));
        assert!(shortcut_start + KEYHOLDER_SHORTCUT_ROUNDS < start + 30 * DAY);
    }

    // Raises, approvals, Leave and Stay, sleep, power-offs and rounds in a random mix, with
    // a keyholder that had power from Lock. Whenever a request matures, it has waited its
    // full wait (as raised), or 24 hours since an approval no raise has voided; whenever an
    // approval is taken after a raise that reset the keyholder, the wait then in force has
    // passed since that reset. Each to within `ANCHOR_CLOCK_TOLERANCE`, as SD-039 is.
    #[test]
    fn no_mix_of_raises_and_approvals_matures_a_request_before_the_rules_allow() {
        let tolerance_ms = rounds_to_ms(crate::constants::ANCHOR_CLOCK_TOLERANCE_ROUNDS);
        let shortcut_ms = rounds_to_ms(KEYHOLDER_SHORTCUT_ROUNDS);
        let mut seed: u64 = 0x5EED_0026;
        let mut matured_by_shortcut = 0;
        let mut approvals_after_reset = 0;
        let mut run = 0;
        while run < 40 {
            let mut w = world_with(7, None, false, true);
            let mut journaled_at: Option<u64> = None;
            let mut approved_at: Option<u64> = None;
            let mut reset_at: Option<u64> = None;
            let mut step = 0;
            while step < 600 {
                seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
                let choice = (seed >> 33) % 10;
                let amount = (seed >> 40) % (DAY_MS / 2);
                let now = w.time.true_unix_ms;
                let mut raised = false;
                let had_power = has_power(&w);
                if choice == 0 {
                    w.time.pass_awake_ms(amount);
                } else if choice == 1 {
                    w.time.pass_asleep_ms(amount * 4);
                } else if choice == 2 {
                    w.time.pass_powered_off_ms(amount * 20);
                } else if choice == 3 || choice == 4 {
                    w.deliver_latest();
                } else if choice == 5 {
                    if w.m.slot() == Slot::Free {
                        if let Ok(Reply::Pending { .. }) = w.leave() {
                            journaled_at = Some(now);
                            approved_at = None;
                        }
                    }
                } else if choice == 6 {
                    if amount % 4 == 0 {
                        assert_eq!(w.m.stay(&w.time), StayReply);
                        journaled_at = None;
                        approved_at = None;
                    }
                } else if choice == 7 {
                    if let Slot::Open(request) = w.m.slot() {
                        if w.approve(request.id).is_ok() {
                            if let Some(reset) = reset_at {
                                let wait_ms = rounds_to_ms(wait_rounds(w.m.applied_wait_days()));
                                assert!(now - reset + tolerance_ms >= wait_ms, "approved early: run {} step {}", run, step);
                                approvals_after_reset += 1;
                            }
                            approved_at = Some(now);
                        }
                    }
                } else if choice == 8 {
                    // The private yes to a guarded raise, whenever one awaits it.
                    if let Ok(Reply::RaiseApplied { .. }) = w.m.long_wait_answer(OWNER, true, &w.time) {
                        raised = true;
                    }
                } else if amount % 3 == 0 {
                    let next = match w.m.applied_wait_days() {
                        7 => 30,
                        30 => 90,
                        90 => 182,
                        182 => 365,
                        _ => 0,
                    };
                    if next > 0 {
                        if let Ok(Reply::RaiseApplied { .. }) = w.raise_to(next) {
                            raised = true;
                        }
                    }
                }
                if raised {
                    if had_power {
                        reset_at = Some(now);
                    }
                    if let Slot::Open(request) = w.m.slot() {
                        if request.phase == Phase::Pending {
                            approved_at = None;
                        }
                    }
                }
                w.tick();
                if let Slot::Open(request) = w.m.slot() {
                    if let Phase::Matured { .. } = request.phase {
                        let now = w.time.true_unix_ms;
                        let full = match journaled_at {
                            Some(at) => now - at + tolerance_ms >= rounds_to_ms(request.wait_rounds),
                            None => false,
                        };
                        let short = match approved_at {
                            Some(at) => now - at + tolerance_ms >= shortcut_ms,
                            None => false,
                        };
                        assert!(full || short, "matured early: run {} step {}", run, step);
                        if !full {
                            matured_by_shortcut += 1;
                        }
                        assert_eq!(w.m.stay(&w.time), StayReply);
                        journaled_at = None;
                        approved_at = None;
                    }
                }
                step += 1;
            }
            run += 1;
        }
        // The mix did reach the cases it is about.
        assert!(matured_by_shortcut > 0);
        assert!(approvals_after_reset > 0);
    }

    #[test]
    fn a_keyholder_enrolled_under_30_days_waits_30_days_whatever_the_date() {
        let mut w = world(30);
        assert_eq!(w.m.keyholder_enrol(OWNER, &w.time), Ok(Reply::Done));
        w.time.wall_unix_ms += 400 * DAY_MS;
        w.time.pass_asleep_ms(30 * DAY_MS - 1);
        w.tick();
        assert!(w.m.keyholder().unwrap().power != Power::Has);
        w.time.pass_asleep_ms(1);
        w.tick();
        assert_eq!(w.m.keyholder().unwrap().power, Power::Has);
    }

    #[test]
    fn the_shortcut_goes_off_at_once_and_comes_back_on_as_a_new_keyholder() {
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        let id = w.pending_id();
        w.deliver_latest();
        assert_eq!(w.m.shortcut_switch(OWNER, false, &w.time), Ok(Reply::Done));
        assert_eq!(w.m.keyholder(), Some(Keyholder { shortcut_on: false, power: Power::Has }));
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));

        // On again: a full wait, as a new keyholder.
        assert_eq!(w.m.shortcut_switch(OWNER, true, &w.time), Ok(Reply::Done));
        let waiting = w.m.keyholder().unwrap();
        assert!(waiting.shortcut_on);
        assert!(waiting.power != Power::Has);
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.approve(id));
        // Switching on what is already on changes nothing: it neither grants power nor
        // starts the wait again.
        w.time.pass_asleep_ms(DAY_MS);
        w.tick();
        let before = w.m.clone();
        assert_eq!(w.m.shortcut_switch(OWNER, true, &w.time), Ok(Reply::Done));
        assert_eq!(w.m, before);
        assert_eq!(w.m.stay(&w.time), StayReply);
        w.time.pass_asleep_ms(6 * DAY_MS);
        w.tick();
        assert_eq!(w.m.keyholder().unwrap().power, Power::Has);
    }

    #[test]
    fn keyholders_are_pinned_one_at_a_time_and_dropped_at_once() {
        let mut w = world_with(7, None, false, true);
        refused(&mut w, Refusal::KeyholderAlreadyPinned, &|w: &mut World| w.m.keyholder_enrol(OWNER, &w.time));
        assert_eq!(w.m.keyholder_drop(OWNER, &w.time), Ok(Reply::Done));
        assert_eq!(w.m.keyholder(), None);
        assert_eq!(w.m.keyholder_drop(OWNER, &w.time), Ok(Reply::Done));
        refused(&mut w, Refusal::NoKeyholder, &|w: &mut World| w.m.shortcut_switch(OWNER, true, &w.time));
        refused(&mut w, Refusal::NoKeyholder, &|w: &mut World| w.m.shortcut_switch(OWNER, false, &w.time));
        // A new enrolment is a new keyholder: a full wait again.
        assert_eq!(w.m.keyholder_enrol(OWNER, &w.time), Ok(Reply::Done));
        assert!(w.m.keyholder().unwrap().power != Power::Has);
    }

    #[test]
    fn withdrawing_the_shortcut_puts_a_pending_target_back_on_the_full_wait() {
        // OPEN SD-053: the more protective reading.
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        let id = w.pending_id();
        let start = w.deliver_latest();
        assert_eq!(w.approve(id), Ok(Reply::Done));
        w.awake_rounds(1);
        w.deliver_latest();
        assert_eq!(w.request().shortcut, Shortcut::Applied);
        assert_eq!(w.m.shortcut_switch(OWNER, false, &w.time), Ok(Reply::Done));
        assert_eq!(w.request().target_round, Some(start + 7 * DAY));
        assert_eq!(w.request().shortcut, Shortcut::Spent);

        // The same for a drop while the approval still awaits its start round.
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        let id = w.pending_id();
        let start = w.deliver_latest();
        assert_eq!(w.approve(id), Ok(Reply::Done));
        assert_eq!(w.m.keyholder_drop(OWNER, &w.time), Ok(Reply::Done));
        w.awake_rounds(1);
        w.deliver_latest();
        assert_eq!(w.request().target_round, Some(start + 7 * DAY));
        assert_eq!(w.request().shortcut, Shortcut::Spent);
    }

    // ----- The instant-leave window (SD-052) -----

    #[test]
    fn leave_inside_the_instant_leave_window_commits_at_once() {
        let mut w = world_with(7, None, true, false);
        w.awake_rounds(10);
        assert!(!w.m.instant_leave_closed());
        let id = match w.leave() {
            Ok(Reply::ExitCommitted { id }) => id,
            other => panic!("not committed: {:?}", other),
        };
        assert_eq!(w.m.slot(), Slot::ExitCommitted(id));
        assert_eq!(w.m.journal().len(), 1);
        assert_eq!(w.m.journal()[0].state, RequestState::Committed);
        assert_eq!(w.m.journal()[0].request_id, id);
    }

    #[test]
    fn the_window_is_72_awake_hours_and_sleep_does_not_use_it_up() {
        // One millisecond short of 72 awake-hours: still open.
        let mut w = world_with(7, None, true, false);
        w.time.pass_awake_ms(INSTANT_LEAVE_WINDOW_AWAKE_MS - 1);
        match w.leave() {
            Ok(Reply::ExitCommitted { .. }) => {}
            other => panic!("not committed: {:?}", other),
        }
        // At 72 awake-hours: closed for good; Leave journals an ordinary request.
        let mut w = world_with(7, None, true, false);
        w.time.pass_awake_ms(INSTANT_LEAVE_WINDOW_AWAKE_MS);
        w.pending_id();
        assert!(w.m.instant_leave_closed());
        // Six days asleep use none of the awake-hours.
        let mut w = world_with(7, None, true, false);
        w.time.pass_asleep_ms(6 * DAY_MS);
        match w.leave() {
            Ok(Reply::ExitCommitted { .. }) => {}
            other => panic!("not committed: {:?}", other),
        }
    }

    #[test]
    fn the_window_is_capped_at_seven_days_and_never_reopens() {
        // Asleep for seven days: the boot counter proves the cap has passed.
        let mut w = world_with(7, None, true, false);
        w.time.pass_asleep_ms(7 * DAY_MS);
        w.pending_id();
        assert!(w.m.instant_leave_closed());
        assert_eq!(w.m.stay(&w.time), StayReply);
        // A date set back does not reopen it.
        w.time.wall_unix_ms = 0;
        w.pending_id();
        assert!(w.m.instant_leave_closed());
    }

    #[test]
    fn only_the_date_saying_the_cap_has_passed_refuses_and_closes_nothing() {
        // The date runs ahead.
        let mut w = world_with(7, None, true, false);
        w.awake_rounds(10);
        w.time.wall_unix_ms += 8 * DAY_MS;
        refused(&mut w, Refusal::DeadlinePassedByDateOnly, &|w: &mut World| w.leave());
        assert!(!w.m.instant_leave_closed());
        assert_eq!(w.m.slot(), Slot::Free);
        w.time.wall_unix_ms = w.time.true_unix_ms;
        match w.leave() {
            Ok(Reply::ExitCommitted { .. }) => {}
            other => panic!("not committed: {:?}", other),
        }

        // Really powered off for eight days: refused until a round proves it, then the
        // window is closed for good and Leave is an ordinary request.
        let mut w = world_with(7, None, true, false);
        w.off_rounds(8 * DAY);
        refused(&mut w, Refusal::DeadlinePassedByDateOnly, &|w: &mut World| w.leave());
        w.deliver_latest();
        assert!(w.m.instant_leave_closed());
        w.pending_id();
    }

    #[test]
    fn no_readable_marker_means_no_window() {
        let mut w = world_with(7, None, true, false);
        match w.m.leave(OWNER, false, &mut w.random, &w.time) {
            Ok(Reply::Pending { .. }) => {}
            other => panic!("not pending: {:?}", other),
        }
        assert!(w.m.instant_leave_closed());
        assert_eq!(w.m.stay(&w.time), StayReply);
        // It stays closed when the marker reads back again.
        w.pending_id();

        // A Lock that granted no window has none.
        let mut w = world(7);
        w.pending_id();
    }

    #[test]
    fn instant_leave_needs_a_free_slot_and_the_password() {
        let mut w = world_with(30, None, true, false);
        refused(&mut w, Refusal::PasswordNeeded, &|w: &mut World| {
            w.m.leave(NOBODY, true, &mut w.random, &w.time)
        });
        assert!(w.lower_to(7).is_ok());
        refused(&mut w, Refusal::SlotFull, &|w: &mut World| w.leave());
        assert_eq!(w.m.stay(&w.time), StayReply);
        match w.leave() {
            Ok(Reply::ExitCommitted { .. }) => {}
            other => panic!("not committed: {:?}", other),
        }
    }

    // ----- SM-03: the wait change -----

    #[test]
    fn a_raise_to_30_days_or_less_applies_at_once() {
        let mut w = world(7);
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        assert_eq!(w.m.applied_wait_days(), 30);
        assert_eq!(w.m.guarded_raise(), GuardedRaise::None);
        assert_eq!(w.m.planned_wait_days(), None);
        // In force at once for every new request, online or not (SD-047).
        w.pending_id();
        assert_eq!(w.request().wait_rounds, 30 * DAY);
    }

    #[test]
    fn a_raise_must_be_an_option_and_must_be_a_raise() {
        let mut w = world(30);
        refused(&mut w, Refusal::NotAnOption, &|w: &mut World| w.raise_to(31));
        refused(&mut w, Refusal::NotAnOption, &|w: &mut World| w.raise_to(0));
        refused(&mut w, Refusal::NotAnOption, &|w: &mut World| w.raise_to(366));
        refused(&mut w, Refusal::NotAnOption, &|w: &mut World| w.raise_to(1_000));
        refused(&mut w, Refusal::NotARaise, &|w: &mut World| w.raise_to(30));
        refused(&mut w, Refusal::NotARaise, &|w: &mut World| w.raise_to(7));
    }

    #[test]
    fn a_raise_above_30_days_before_day_8_is_saved_as_the_planned_wait_only() {
        let mut w = world(30);
        assert_eq!(w.raise_to(90), Ok(Reply::SavedAsPlanned { planned_wait_days: 90 }));
        assert_eq!(w.m.applied_wait_days(), 30);
        assert_eq!(w.m.planned_wait_days(), Some(90));
        assert_eq!(w.m.guarded_raise(), GuardedRaise::None);
        // One round before the day-8 gate: still planned only.
        w.awake_rounds(7 * DAY - 1);
        assert_eq!(w.raise_to(365), Ok(Reply::SavedAsPlanned { planned_wait_days: 365 }));
        assert_eq!(w.m.planned_wait_days(), Some(365));
        assert_eq!(w.m.applied_wait_days(), 30);
        // The planned wait can be cleared, with the password.
        assert_eq!(w.m.clear_planned_wait(OWNER, &w.time), Ok(Reply::Done));
        assert_eq!(w.m.planned_wait_days(), None);
    }

    fn guarded_world() -> (World, RaiseTerms) {
        let mut w = world_with(30, Some(90), false, false);
        w.awake_rounds(7 * DAY);
        let guard_end = LOCK_ROUND + 8 * DAY;
        assert_eq!(w.raise_to(90), Ok(Reply::RaiseGuarded { guard_end_round: guard_end }));
        let terms = RaiseTerms { wait_days: 90, guard_end_round: guard_end, check_expiry_round: guard_end + 7 * DAY };
        assert_eq!(w.m.guarded_raise(), GuardedRaise::Guarded(terms));
        (w, terms)
    }

    fn awaiting_world() -> (World, RaiseTerms) {
        let (mut w, terms) = guarded_world();
        w.awake_rounds(DAY);
        w.tick();
        assert_eq!(w.m.guarded_raise(), GuardedRaise::AwaitingPrivateYes(terms));
        (w, terms)
    }

    #[test]
    fn a_raise_above_30_days_from_day_8_is_guarded_for_a_day_then_awaits_the_private_yes() {
        let (mut w, terms) = guarded_world();
        // Guarded: nothing is applied, and no answer is taken yet.
        assert_eq!(w.m.applied_wait_days(), 30);
        assert_eq!(w.m.planned_wait_days(), Some(90));
        refused(&mut w, Refusal::NoRaiseAwaitingAnswer, &|w: &mut World| w.m.long_wait_answer(OWNER, true, &w.time));
        refused(&mut w, Refusal::NoRaiseAwaitingAnswer, &|w: &mut World| w.m.long_wait_answer(OWNER, false, &w.time));
        w.awake_rounds(DAY - 1);
        w.tick();
        assert_eq!(w.m.guarded_raise(), GuardedRaise::Guarded(terms));
        // A date set ahead does not end the guard day.
        w.time.wall_unix_ms += 3 * DAY_MS;
        w.tick();
        assert_eq!(w.m.guarded_raise(), GuardedRaise::Guarded(terms));
        w.time.wall_unix_ms = w.time.true_unix_ms;
        // The delay is over.
        w.awake_rounds(1);
        w.tick();
        assert_eq!(w.m.guarded_raise(), GuardedRaise::AwaitingPrivateYes(terms));
        assert_eq!(w.m.applied_wait_days(), 30);
    }

    #[test]
    fn the_private_yes_applies_the_longer_wait() {
        let (mut w, _terms) = awaiting_world();
        assert_eq!(w.m.long_wait_answer(OWNER, true, &w.time), Ok(Reply::RaiseApplied { applied_wait_days: 90 }));
        assert_eq!(w.m.applied_wait_days(), 90);
        assert_eq!(w.m.planned_wait_days(), None);
        assert_eq!(w.m.guarded_raise(), GuardedRaise::None);
        // The answer is used: a second one has nothing to answer.
        refused(&mut w, Refusal::NoRaiseAwaitingAnswer, &|w: &mut World| w.m.long_wait_answer(OWNER, true, &w.time));
        // From there a further raise is guarded again, at once (day 8 has passed).
        match w.raise_to(365) {
            Ok(Reply::RaiseGuarded { .. }) => {}
            other => panic!("not guarded: {:?}", other),
        }
        assert_eq!(w.m.applied_wait_days(), 90);
    }

    #[test]
    fn a_no_keeps_the_wait_and_leaves_nothing_behind() {
        let (mut w, _terms) = awaiting_world();
        assert_eq!(w.m.long_wait_answer(OWNER, false, &w.time), Ok(Reply::Done));
        assert_eq!(w.m.applied_wait_days(), 30);
        assert_eq!(w.m.planned_wait_days(), None);
        assert_eq!(w.m.guarded_raise(), GuardedRaise::None);
        assert!(w.m.journal().is_empty());
    }

    #[test]
    fn no_answer_within_the_expiry_keeps_the_wait() {
        let (mut w, terms) = awaiting_world();
        w.awake_rounds(7 * DAY - 1);
        w.tick();
        assert_eq!(w.m.guarded_raise(), GuardedRaise::AwaitingPrivateYes(terms));
        w.awake_rounds(1);
        w.tick();
        assert_eq!(w.m.guarded_raise(), GuardedRaise::None);
        assert_eq!(w.m.planned_wait_days(), None);
        assert_eq!(w.m.applied_wait_days(), 30);
        refused(&mut w, Refusal::NoRaiseAwaitingAnswer, &|w: &mut World| w.m.long_wait_answer(OWNER, true, &w.time));
    }

    #[test]
    fn a_date_that_runs_ahead_refuses_the_yes_and_expires_nothing() {
        let (mut w, terms) = awaiting_world();
        w.time.wall_unix_ms += 8 * DAY_MS;
        refused(&mut w, Refusal::DeadlinePassedByDateOnly, &|w: &mut World| {
            w.m.long_wait_answer(OWNER, true, &w.time)
        });
        assert_eq!(w.m.guarded_raise(), GuardedRaise::AwaitingPrivateYes(terms));
        w.time.wall_unix_ms = w.time.true_unix_ms;
        assert_eq!(w.m.long_wait_answer(OWNER, true, &w.time), Ok(Reply::RaiseApplied { applied_wait_days: 90 }));
    }

    #[test]
    fn one_guarded_raise_at_a_time_and_it_can_be_cleared() {
        let (mut w, terms) = guarded_world();
        refused(&mut w, Refusal::GuardedRaiseOpen, &|w: &mut World| w.raise_to(365));
        refused(&mut w, Refusal::GuardedRaiseOpen, &|w: &mut World| w.raise_to(90));
        assert_eq!(w.m.guarded_raise(), GuardedRaise::Guarded(terms));
        assert_eq!(w.m.clear_planned_wait(OWNER, &w.time), Ok(Reply::Done));
        assert_eq!(w.m.guarded_raise(), GuardedRaise::None);
        assert_eq!(w.m.planned_wait_days(), None);
        assert_eq!(w.m.applied_wait_days(), 30);

        let (mut w, _terms) = awaiting_world();
        refused(&mut w, Refusal::GuardedRaiseOpen, &|w: &mut World| w.raise_to(365));
        assert_eq!(w.m.clear_planned_wait(OWNER, &w.time), Ok(Reply::Done));
        refused(&mut w, Refusal::NoRaiseAwaitingAnswer, &|w: &mut World| w.m.long_wait_answer(OWNER, true, &w.time));
    }

    #[test]
    fn a_raise_to_30_days_still_applies_at_once_beside_a_guarded_raise() {
        let mut w = world(7);
        w.awake_rounds(7 * DAY);
        match w.raise_to(90) {
            Ok(Reply::RaiseGuarded { .. }) => {}
            other => panic!("not guarded: {:?}", other),
        }
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        assert_eq!(w.m.applied_wait_days(), 30);
        w.awake_rounds(DAY);
        assert_eq!(w.m.long_wait_answer(OWNER, true, &w.time), Ok(Reply::RaiseApplied { applied_wait_days: 90 }));
    }

    #[test]
    fn the_day_8_gate_opens_by_tighten_time() {
        // SD-045: the gate is judged by tighten-time, so a Mac that was powered off for
        // the week (the estimate lags, the date does not) finds it open.
        let mut w = world(30);
        w.off_rounds(7 * DAY);
        assert_eq!(w.raise_to(90), Ok(Reply::RaiseGuarded { guard_end_round: LOCK_ROUND + DAY }));
        // The guard day itself still runs on verified rounds and the boot counter.
        w.off_rounds(30 * DAY);
        w.tick();
        match w.m.guarded_raise() {
            GuardedRaise::Guarded(_) => {}
            other => panic!("the guard day ended on the date alone: {:?}", other),
        }
        assert_eq!(w.m.applied_wait_days(), 30);
    }

    // ST-005: no path applies a wait above 30 days before the day-8 gate or without the
    // private yes.
    #[test]
    fn no_path_applies_a_wait_above_30_days_without_the_gate_the_guard_and_the_yes() {
        let long_waits: [u16; 3] = [90, 182, 365];
        for long in long_waits.iter() {
            let mut w = world(30);
            // Before day 8, asked again and again.
            let mut tries = 0;
            while tries < 5 {
                assert_eq!(w.raise_to(*long), Ok(Reply::SavedAsPlanned { planned_wait_days: *long }));
                assert!(w.m.long_wait_answer(OWNER, true, &w.time).is_err());
                w.awake_rounds(DAY);
                w.tick();
                assert_eq!(w.m.applied_wait_days(), 30);
                tries += 1;
            }
            // After day 8: guarded, and a yes during the guard day is refused.
            w.awake_rounds(2 * DAY);
            match w.raise_to(*long) {
                Ok(Reply::RaiseGuarded { .. }) => {}
                other => panic!("not guarded: {:?}", other),
            }
            assert!(w.m.long_wait_answer(OWNER, true, &w.time).is_err());
            assert_eq!(w.m.applied_wait_days(), 30);
            // After the guard day, time alone applies nothing.
            w.awake_rounds(DAY);
            w.tick();
            w.deliver_latest();
            assert_eq!(w.m.applied_wait_days(), 30);
            // A yes without the password applies nothing.
            assert_eq!(w.m.long_wait_answer(NOBODY, true, &w.time), Err(Refusal::PasswordNeeded));
            assert_eq!(w.m.applied_wait_days(), 30);
            // The private yes, with the password.
            assert_eq!(
                w.m.long_wait_answer(OWNER, true, &w.time),
                Ok(Reply::RaiseApplied { applied_wait_days: *long })
            );
            assert_eq!(w.m.applied_wait_days(), *long);
        }
    }

    #[test]
    fn a_guarded_raise_that_is_applied_retargets_an_open_request() {
        let mut w = world(30);
        w.awake_rounds(7 * DAY);
        w.pending_id();
        let start = w.deliver_latest();
        match w.raise_to(90) {
            Ok(Reply::RaiseGuarded { .. }) => {}
            other => panic!("not guarded: {:?}", other),
        }
        assert_eq!(w.request().target_round, Some(start + 30 * DAY));
        w.awake_rounds(DAY);
        assert_eq!(w.m.long_wait_answer(OWNER, true, &w.time), Ok(Reply::RaiseApplied { applied_wait_days: 90 }));
        assert_eq!(w.request().target_round, Some(start + 90 * DAY));
        assert_eq!(w.request().wait_rounds, 90 * DAY);
    }

    // ----- Lowering the wait and loosening a setting (SD-046, SD-012) -----

    #[test]
    fn a_lowering_waits_out_the_wait_in_force_and_is_applied_at_the_claim() {
        let mut w = world(30);
        w.awake_rounds(10);
        let id = match w.lower_to(7) {
            Ok(Reply::Pending { id }) => id,
            other => panic!("not pending: {:?}", other),
        };
        let request = w.request();
        assert_eq!(request.kind, ExitClassKind::LowerWait { new_wait_days: 7 });
        assert_eq!(request.wait_rounds, 30 * DAY);
        assert_eq!(w.m.journal()[0].kind, RequestKind::LowerWait);
        assert_eq!(w.m.applied_wait_days(), 30);

        // It waits the 30 days in force, not the 7 it asks for.
        w.time.pass_asleep_ms(30 * DAY_MS - 1);
        w.tick();
        assert!(w.is_pending());
        assert_eq!(w.m.applied_wait_days(), 30);
        w.time.pass_asleep_ms(1);
        w.tick();
        assert!(w.is_matured());
        // Matured is not applied: the claim applies it.
        assert_eq!(w.m.applied_wait_days(), 30);
        assert_eq!(w.claim(id), Ok(Reply::WaitLowered { id, applied_wait_days: 7 }));
        assert_eq!(w.m.applied_wait_days(), 7);
        assert_eq!(w.m.slot(), Slot::Free);
        assert_eq!(w.last_state(), RequestState::Committed);

        // The next request waits the lower wait.
        w.pending_id();
        assert_eq!(w.request().wait_rounds, 7 * DAY);
    }

    #[test]
    fn a_lowering_must_be_an_option_below_the_applied_wait_and_stay_cancels_it() {
        let mut w = world(30);
        refused(&mut w, Refusal::NotAnOption, &|w: &mut World| w.lower_to(14));
        refused(&mut w, Refusal::NotAnOption, &|w: &mut World| w.lower_to(0));
        refused(&mut w, Refusal::NotALowering, &|w: &mut World| w.lower_to(30));
        refused(&mut w, Refusal::NotALowering, &|w: &mut World| w.lower_to(90));
        let mut seven = world(7);
        refused(&mut seven, Refusal::NotALowering, &|w: &mut World| w.lower_to(7));

        assert!(w.lower_to(7).is_ok());
        w.sleep_through_the_wait();
        assert_eq!(w.m.stay(&w.time), StayReply);
        assert_eq!(w.m.slot(), Slot::Free);
        assert_eq!(w.m.applied_wait_days(), 30);
    }

    #[test]
    fn an_unclaimed_lowering_expires_and_lowers_nothing() {
        let mut w = world(30);
        assert!(w.lower_to(7).is_ok());
        w.sleep_through_the_wait();
        w.awake_rounds(CLAIM_WINDOW_ROUNDS);
        w.tick();
        assert_eq!(w.m.slot(), Slot::Free);
        assert_eq!(w.last_state(), RequestState::Expired);
        assert_eq!(w.m.applied_wait_days(), 30);
    }

    #[test]
    fn a_loosening_follows_the_same_table() {
        let settings = [
            LoosenableSetting::BrowserProfile,
            LoosenableSetting::StrictCoverModeOff,
            LoosenableSetting::DetectorRuleBalanced,
        ];
        for setting in settings.iter() {
            let mut w = world(7);
            w.awake_rounds(10);
            let id = match w.m.loosen_setting(OWNER, *setting, &mut w.random, &w.time) {
                Ok(Reply::Pending { id }) => id,
                other => panic!("not pending: {:?}", other),
            };
            assert_eq!(w.request().kind, ExitClassKind::LoosenSetting(*setting));
            assert_eq!(w.m.journal()[0].kind, RequestKind::LoosenSetting);
            refused(&mut w, Refusal::NotMatured, &|w: &mut World| w.claim(id));
            let start = w.deliver_latest();
            assert_eq!(w.request().target_round, Some(start + 7 * DAY));
            w.off_rounds(7 * DAY);
            w.deliver_latest();
            assert!(w.is_matured());
            assert_eq!(w.claim(id), Ok(Reply::SettingLoosened { id, setting: *setting }));
            assert_eq!(w.m.slot(), Slot::Free);
        }
    }

    // A raise discards an open lowering: claimed after the raise, it would undo it.
    #[test]
    fn a_raise_discards_a_lowering_that_has_matured() {
        let mut w = world(30);
        let id = match w.lower_to(7) {
            Ok(Reply::Pending { id }) => id,
            other => panic!("not pending: {:?}", other),
        };
        w.sleep_through_the_wait();
        // Day 30: the day-8 gate is open. Raise to 90, through the guard and the yes.
        match w.raise_to(90) {
            Ok(Reply::RaiseGuarded { .. }) => {}
            other => panic!("not guarded: {:?}", other),
        }
        // Not in force yet: the lowering still stands while the raise is only guarded.
        assert!(w.is_matured());
        w.awake_rounds(DAY);
        assert_eq!(w.m.long_wait_answer(OWNER, true, &w.time), Ok(Reply::RaiseApplied { applied_wait_days: 90 }));
        assert_eq!(w.m.slot(), Slot::Free);
        assert_eq!(w.last_state(), RequestState::Discarded);
        assert_eq!(w.m.journal()[w.m.journal().len() - 1].request_id, id);
        refused(&mut w, Refusal::NoSuchRequest, &|w: &mut World| w.claim(id));
        assert_eq!(w.m.applied_wait_days(), 90);
        // A new lowering waits the 90 days now in force.
        assert!(w.lower_to(7).is_ok());
        assert_eq!(w.request().wait_rounds, 90 * DAY);
    }

    #[test]
    fn a_raise_discards_a_pending_lowering_too() {
        let mut w = world(30);
        w.awake_rounds(7 * DAY);
        let id = match w.lower_to(7) {
            Ok(Reply::Pending { id }) => id,
            other => panic!("not pending: {:?}", other),
        };
        w.deliver_latest();
        match w.raise_to(182) {
            Ok(Reply::RaiseGuarded { .. }) => {}
            other => panic!("not guarded: {:?}", other),
        }
        w.awake_rounds(DAY);
        assert_eq!(w.m.long_wait_answer(OWNER, true, &w.time), Ok(Reply::RaiseApplied { applied_wait_days: 182 }));
        assert_eq!(w.m.slot(), Slot::Free);
        // Waiting out the old lowering's wait, or the new one, gives nothing to claim.
        w.time.pass_asleep_ms(182 * DAY_MS);
        w.tick();
        refused(&mut w, Refusal::NoSuchRequest, &|w: &mut World| w.claim(id));
        assert_eq!(w.m.applied_wait_days(), 182);
    }

    // Lower, mature, raise, claim, in every order the slot allows: the applied wait after
    // the claim is never below the highest wait in force since the lowering matured.
    #[test]
    fn no_order_of_lower_mature_raise_and_claim_undoes_a_raise() {
        let mut w = world(30);
        let id = match w.lower_to(7) {
            Ok(Reply::Pending { id }) => id,
            other => panic!("not pending: {:?}", other),
        };
        w.sleep_through_the_wait();
        // Claimed before any raise: the lowering applies, as it waited out 30 days.
        assert_eq!(w.claim(id), Ok(Reply::WaitLowered { id, applied_wait_days: 7 }));
        // Raised again at once, then lowered again.
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        let second = match w.lower_to(7) {
            Ok(Reply::Pending { id }) => id,
            other => panic!("not pending: {:?}", other),
        };
        w.sleep_through_the_wait();
        // The guarded raise is answered after the lowering is claimed: the claim lowers to
        // 7, and the yes then raises to 90. The raise stands.
        match w.raise_to(90) {
            Ok(Reply::RaiseGuarded { .. }) => {}
            other => panic!("not guarded: {:?}", other),
        }
        assert_eq!(w.claim(second), Ok(Reply::WaitLowered { id: second, applied_wait_days: 7 }));
        w.awake_rounds(DAY);
        assert_eq!(w.m.long_wait_answer(OWNER, true, &w.time), Ok(Reply::RaiseApplied { applied_wait_days: 90 }));
        assert_eq!(w.m.applied_wait_days(), 90);
    }

    #[test]
    fn every_raise_is_owed_to_the_capsule_until_the_old_secret_is_retired() {
        let mut w = world(7);
        assert_eq!(w.m.reseal_owed(), None);
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        assert_eq!(w.m.reseal_owed(), Some(30));
        // A capsule sealed for a shorter wait does not settle it.
        w.m.old_secret_retired(7);
        assert_eq!(w.m.reseal_owed(), Some(30));
        w.m.old_secret_retired(30);
        assert_eq!(w.m.reseal_owed(), None);
        // A guarded raise is owed only once it is in force, and the higher one is kept.
        w.awake_rounds(7 * DAY);
        assert!(w.raise_to(90).is_ok());
        assert_eq!(w.m.reseal_owed(), None);
        w.awake_rounds(DAY);
        assert!(w.m.long_wait_answer(OWNER, true, &w.time).is_ok());
        assert_eq!(w.m.reseal_owed(), Some(90));
        w.m.old_secret_retired(90);
        assert_eq!(w.m.reseal_owed(), None);
        // A lowering owes nothing (SD-058).
        let mut w = world(30);
        let id = match w.lower_to(7) {
            Ok(Reply::Pending { id }) => id,
            other => panic!("not pending: {:?}", other),
        };
        w.sleep_through_the_wait();
        assert!(w.claim(id).is_ok());
        assert_eq!(w.m.reseal_owed(), None);
    }

    // ----- The date behind the verified rounds (SD-039, SD-052) -----

    #[test]
    fn instant_leave_is_refused_while_the_date_is_behind_the_verified_rounds() {
        // Really powered off past the cap, then the date reset to before the chain began:
        // the estimate lags, and only the date could say the cap has passed.
        let mut w = world_with(7, None, true, false);
        w.off_rounds(8 * DAY);
        w.time.wall_unix_ms = 0;
        refused(&mut w, Refusal::DateUntrusted, &|w: &mut World| w.leave());
        // A date set back to before the Lock round: the same.
        w.time.wall_unix_ms = unix_ms_of_round(LOCK_ROUND - 1_000);
        refused(&mut w, Refusal::DateUntrusted, &|w: &mut World| w.leave());
        assert!(!w.m.instant_leave_closed());
        // The date put right: the cap has passed by the date; a round proves it.
        w.time.wall_unix_ms = w.time.true_unix_ms;
        refused(&mut w, Refusal::DeadlinePassedByDateOnly, &|w: &mut World| w.leave());
        w.deliver_latest();
        assert!(w.m.instant_leave_closed());
        w.pending_id();

        // Inside the window, a wrong date refuses and closes nothing; the right date
        // gives the instant exit back.
        let mut w = world_with(7, None, true, false);
        w.awake_rounds(10);
        w.time.wall_unix_ms = 1_000;
        refused(&mut w, Refusal::DateUntrusted, &|w: &mut World| w.leave());
        w.time.wall_unix_ms = w.time.true_unix_ms;
        match w.leave() {
            Ok(Reply::ExitCommitted { .. }) => {}
            other => panic!("not committed: {:?}", other),
        }

        // And with the date left wrong for good, the owner still leaves: the window
        // closes on its own proofs and Leave becomes an ordinary request, which matures
        // on the counter route.
        let mut w = world_with(7, None, true, false);
        w.time.wall_unix_ms = 0;
        w.awake_rounds(3 * DAY);
        let id = w.pending_id();
        assert!(w.m.instant_leave_closed());
        w.sleep_through_the_wait();
        assert_eq!(w.claim(id), Ok(Reply::ExitCommitted { id }));
    }

    // An archived real round cannot become a start round while the date is behind the
    // keeper's own verified rounds, so the newest round cannot then mature the request
    // at once.
    #[test]
    fn an_archived_round_with_a_date_set_back_never_matures_a_request_at_once() {
        let backs: [u64; 3] = [0, 1, 2];
        for back in backs.iter() {
            let mut w = world(7);
            // Powered off for 30 days: the estimate is still at the Lock round.
            w.off_rounds(30 * DAY);
            w.time.wall_unix_ms = match *back {
                0 => 0,
                1 => unix_ms_of_round(LOCK_ROUND - 300),
                _ => (BEACON_GENESIS_UNIX_SECONDS - 1) * 1_000,
            };
            let id = w.pending_id();
            // An old real round, just above the estimate.
            match w.deliver(LOCK_ROUND + 5) {
                RoundOutcome::Accepted(a) => assert!(!a.may_start),
                RoundOutcome::Dropped(reason) => panic!("dropped: {:?}", reason),
            }
            assert_eq!(w.request().start_round, None);
            assert!(w.m.clock_refuses_rounds());
            // Today's round: not a start round either, and nothing matures.
            w.deliver_latest();
            assert!(w.is_pending());
            assert_eq!(w.request().start_round, None);
            // The date put right: the next round is the start, and the full wait follows.
            w.time.wall_unix_ms = w.time.true_unix_ms;
            w.awake_rounds(1);
            let start = w.deliver_latest();
            assert!(!w.m.clock_refuses_rounds());
            assert_eq!(w.request().target_round, Some(start + 7 * DAY));
            w.off_rounds(7 * DAY - 1);
            w.deliver_latest();
            assert!(w.is_pending());
            w.off_rounds(1);
            w.deliver_latest();
            assert!(w.is_matured());
            assert_eq!(w.claim(id), Ok(Reply::ExitCommitted { id }));
        }
    }

    // ----- The random generator -----

    #[test]
    fn a_random_generator_that_fails_journals_nothing() {
        let mut w = world_with(30, None, true, false);
        w.awake_rounds(10);
        refused(&mut w, Refusal::RandomUnavailable, &|w: &mut World| {
            w.m.leave(OWNER, true, &mut BrokenRandom, &w.time)
        });
        let mut w = world(30);
        refused(&mut w, Refusal::RandomUnavailable, &|w: &mut World| {
            w.m.leave(OWNER, true, &mut BrokenRandom, &w.time)
        });
        refused(&mut w, Refusal::RandomUnavailable, &|w: &mut World| {
            w.m.lower_wait(OWNER, 7, &mut BrokenRandom, &w.time)
        });
        refused(&mut w, Refusal::RandomUnavailable, &|w: &mut World| {
            w.m.loosen_setting(OWNER, LoosenableSetting::BrowserProfile, &mut BrokenRandom, &w.time)
        });
        assert!(w.m.journal().is_empty());
        // It works again once the generator does.
        w.pending_id();
    }

    // ----- The keyholder's challenge (SD-306) -----

    #[test]
    fn an_approval_must_carry_this_requests_own_challenge() {
        let mut w = world_with(30, None, false, true);
        w.awake_rounds(10);
        let id = w.pending_id();
        w.deliver_latest();
        let request = w.request();
        let (named, challenge) = w.m.approval_challenge().unwrap();
        assert_eq!(named, id);
        assert_eq!(challenge, w.challenge_for(id));
        // Every journal entry of the request carries its nonce, so the challenge can be
        // rebuilt after a restart.
        for entry in w.m.journal().iter() {
            assert_eq!(entry.challenge_nonce, request.nonce);
        }
        let other_label = MacLabel::new("Other Mac").unwrap();
        let none: [[u8; 32]; 0] = [];
        let wrong = [
            // The test approval of enrolment, for the same request.
            derive_challenge(&ChallengeFields { kind: ChallengeKind::Test, request_id: id, mac_label: &label(), items: &none[..], nonce: request.nonce }).unwrap(),
            // Another kind: a lowering, shown to the keyholder as such.
            derive_challenge(&ChallengeFields { kind: ChallengeKind::LowerWait { new_wait_days: 7 }, request_id: id, mac_label: &label(), items: &none[..], nonce: request.nonce }).unwrap(),
            // Another Mac's label.
            derive_challenge(&ChallengeFields { kind: ChallengeKind::Exit, request_id: id, mac_label: &other_label, items: &none[..], nonce: request.nonce }).unwrap(),
            // Another nonce.
            derive_challenge(&ChallengeFields { kind: ChallengeKind::Exit, request_id: id, mac_label: &label(), items: &none[..], nonce: [0; 32] }).unwrap(),
        ];
        for challenge in wrong.iter() {
            let checked = CheckedApproval { request_id: id, challenge: *challenge, valid: true };
            refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.m.approval(checked, &w.time));
        }
        // The right one is accepted once, and never again.
        assert_eq!(w.approve(id), Ok(Reply::Done));
        assert_eq!(w.m.approval_challenge(), None);
        let checked = CheckedApproval { request_id: id, challenge, valid: true };
        refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.m.approval(checked, &w.time));

        // A lowering's challenge names the lowering and its new wait.
        let mut w = world_with(30, None, false, true);
        w.awake_rounds(10);
        assert!(w.lower_to(7).is_ok());
        let lowering = w.request();
        let (_, challenge) = w.m.approval_challenge().unwrap();
        assert_eq!(
            Some(challenge),
            derive_challenge(&ChallengeFields { kind: ChallengeKind::LowerWait { new_wait_days: 7 }, request_id: lowering.id, mac_label: &label(), items: &none[..], nonce: lowering.nonce })
        );

        // An approval kept from an earlier request is refused for the next one.
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        let first = w.pending_id();
        w.deliver_latest();
        let (_, old_challenge) = w.m.approval_challenge().unwrap();
        assert_eq!(w.m.stay(&w.time), StayReply);
        let second = w.pending_id();
        w.awake_rounds(1);
        w.deliver_latest();
        assert!(first != second);
        for named in [first, second].iter() {
            let checked = CheckedApproval { request_id: *named, challenge: old_challenge, valid: true };
            refused(&mut w, Refusal::ApprovalRefused, &|w: &mut World| w.m.approval(checked, &w.time));
        }
        assert_eq!(w.approve(second), Ok(Reply::Done));
    }

    // ----- The journal -----

    #[test]
    fn every_change_of_a_request_appends_an_entry_that_the_record_format_accepts() {
        let mut w = world_with(7, None, false, true);
        w.awake_rounds(10);
        let id = w.pending_id();
        w.deliver_latest();
        assert_eq!(w.approve(id), Ok(Reply::Done));
        w.awake_rounds(1);
        w.deliver_latest();
        // The raise voids the shortcut: the request waits out the 30 days.
        assert_eq!(w.raise_to(30), Ok(Reply::RaiseApplied { applied_wait_days: 30 }));
        w.off_rounds(30 * DAY);
        w.deliver_latest();
        assert_eq!(w.claim(id), Ok(Reply::ExitCommitted { id }));

        let expected = [
            (RequestState::Pending, false),
            (RequestState::Pending, false),
            (RequestState::Pending, true),
            (RequestState::Pending, true),
            (RequestState::Pending, true),
            (RequestState::Matured, true),
            (RequestState::Committed, true),
        ];
        let journal = w.m.journal().to_vec();
        assert_eq!(journal.len(), expected.len());
        let mut i = 0;
        while i < journal.len() {
            assert_eq!(journal[i].request_id, id);
            assert_eq!(journal[i].kind, RequestKind::Exit);
            assert_eq!(journal[i].state, expected[i].0);
            assert_eq!(journal[i].approval_used, expected[i].1);
            let bytes = journal[i].encode().unwrap();
            assert_eq!(JournalEntry::decode(&bytes), Ok(journal[i]));
            i += 1;
        }

        // The caller takes the entries to write them; the machine keeps none.
        let taken = w.m.take_journal();
        assert_eq!(taken, journal);
        assert!(w.m.journal().is_empty());
    }

    #[test]
    fn closing_and_instant_entries_are_accepted_by_the_record_format_too() {
        // Discarded while Pending, Expired, and an instant Committed.
        let mut w = world(7);
        w.pending_id();
        assert_eq!(w.m.stay(&w.time), StayReply);
        w.pending_id();
        w.sleep_through_the_wait();
        w.awake_rounds(CLAIM_WINDOW_ROUNDS);
        w.tick();
        assert!(w.lower_to(7).is_err());
        let mut instant = world_with(30, None, true, false);
        assert!(instant.leave().is_ok());
        let mut all = w.m.take_journal();
        all.extend(instant.m.take_journal());
        assert_eq!(all.len(), 6);
        for entry in all.iter() {
            let bytes = entry.encode().unwrap();
            assert_eq!(JournalEntry::decode(&bytes), Ok(*entry));
        }
        assert_eq!(all[1].state, RequestState::Discarded);
        assert_eq!(all[4].state, RequestState::Expired);
        assert_eq!(all[5].state, RequestState::Committed);
    }
}
