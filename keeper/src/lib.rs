// SPDX-License-Identifier: Apache-2.0
//! The keeper: the one root part of SafeSight Mac.
//!
//! Step 2: the core. The constants the register fixes, the fixed-layout records, the
//! clock and the wait state machine, the real check of a beacon round, the time lock and
//! the capsule, the store on disk in a folder it is given and the carried counters, with
//! every other edge of the real system behind a trait in `boundary`. Nothing here touches
//! the Mac beyond that folder: no launch item, no account, no password, no Secure Enclave,
//! no network.
//! `docs/STEP-2-STATUS.md` says what exists, what is open and what comes next.

#![forbid(unsafe_code)]

pub mod age;
pub mod approval;
pub mod beacon;
pub mod boundary;
pub mod capsule;
pub mod clock;
pub mod constants;
pub mod counters;
pub mod frame;
pub mod records;
pub mod store;
pub mod timelock;
pub mod waits;

#[cfg(test)]
mod fakes;

/// The keeper's own version. Any change to the keeper's bytes is a lock-core change.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// One line for logs.
pub fn summary() -> String {
    format!("safesightmac-keeper {VERSION}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_semantic() {
        let parts: Vec<&str> = VERSION.split('.').collect();
        assert_eq!(parts.len(), 3);
        assert!(parts.iter().all(|p| p.parse::<u32>().is_ok()));
    }

    // For CI runs only until the lock file is committed: writes the lock file CI resolved
    // into the log, past the test harness's capture. Removed by the commit that adds it.
    #[test]
    fn show_the_lock_file_in_the_log() {
        use std::io::Write;
        let mut out = std::io::stderr();
        let _ = out.write_all(b"=====BEGIN KEEPER CARGO.LOCK=====\n");
        let _ = out.write_all(include_str!("../Cargo.lock").as_bytes());
        let _ = out.write_all(b"=====END KEEPER CARGO.LOCK=====\n");
    }
}
