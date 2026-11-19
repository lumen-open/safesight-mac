// SPDX-License-Identifier: Apache-2.0
//! The keeper: the one root part of SafeSight Mac.
//!
//! Step 2: the core. The constants the register fixes, the fixed-layout records, the
//! clock and the wait state machine, the real check of a beacon round, with every other
//! edge of the real system behind a trait in `boundary`. Nothing here touches the Mac: no
//! launch item, no account, no password, no Secure Enclave, no network.
//! `docs/STEP-2-STATUS.md` says what exists, what is open and what comes next.

#![forbid(unsafe_code)]

pub mod beacon;
pub mod boundary;
pub mod clock;
pub mod constants;
pub mod frame;
pub mod records;
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
}
