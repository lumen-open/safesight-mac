// SPDX-License-Identifier: Apache-2.0
//! The edges of the pure core.
//!
//! Everything that decides lives in the pure modules and runs on CI. Everything that
//! touches the real system (clocks, the beacon signature check, the password dialog, the
//! random generator, the keyholder's signature, files) is behind one of the traits here.
//! The fakes are in the test-only module `fakes`. The one real implementation so far is
//! the round check, `beacon::QuicknetVerifier`; the others belong to the hands layer and
//! are not written yet.

/// The Mac's clocks, as the keeper reads them itself (SD-037). Never taken from a message.
pub trait TimeSource {
    /// The boot counter's carried total, in milliseconds: monotonic time that includes
    /// sleep, carried across restarts, and that does not count time powered off. It can
    /// only run slow.
    fn boot_total_ms(&self) -> u64;

    /// The awake counter's carried total, in milliseconds: monotonic time that excludes
    /// sleep. Used for the instant-leave window and the private check timer only.
    fn awake_total_ms(&self) -> u64;

    /// The Mac's date and time, in Unix seconds. It can refuse a start round and it can
    /// tighten. It never matures a request and never shortens anything (SD-039, SD-041).
    /// Only the `clock` module reads it (chapter 03 section 3, invariant I3).
    fn wall_clock_unix_seconds(&self) -> u64;
}

/// The check of a beacon round's signature against the chain public key pinned in the
/// lock core (SD-038, SD-043). The real one is `beacon::QuicknetVerifier`.
pub trait RoundVerifier {
    fn verify_round(&self, round: u64, signature: &[u8; 48]) -> bool;
}

/// The system random generator, for request IDs (chapter 03 section 3: random, 16 bytes).
pub trait RandomSource {
    fn request_id(&mut self) -> [u8; 16];
}

/// Whether the typed login password has proven the owner for this one message (SD-051).
/// The password itself never reaches the pure core.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OwnerProof {
    TypedPasswordVerified,
    Missing,
}

/// The typed-password check of SD-051: the system dialog, or its PIVOT.
pub trait OwnerCheck {
    fn check_owner(&mut self) -> OwnerProof;
}

/// What the approval check of chapter 03 section 8 found, apart from the request rules.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CheckedApproval {
    /// The request the approval code names.
    pub request_id: [u8; 16],
    /// True only if every cryptographic and fixed-prefix check passed against the pinned
    /// key, the pinned origin and this request's challenge (steps 3 to 6).
    pub valid: bool,
}

/// The fixed-offset checks and the ES256 signature check of an approval code (SD-196).
/// None means the code's layout was refused.
pub trait ApprovalVerifier {
    fn check_approval(&self, approval_code: &[u8]) -> Option<CheckedApproval>;
}

/// The instant-leave marker file outside the keeper store (SD-052).
pub trait MarkerFile {
    /// True only if the marker written at this Lock reads back valid now.
    fn reads_back_valid_for_lock(&self, lock_round: u64) -> bool;
}
