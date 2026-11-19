// SPDX-License-Identifier: Apache-2.0
//! The keeper: the one root part of SafeSight Mac.
//!
//! Step 2: the core. The constants the register fixes, the fixed-layout records, the
//! clock and the wait state machine, the real check of a beacon round, the time lock and
//! the capsule, the store on disk in a folder it is given and the carried counters, with
//! every other edge of the real system behind a trait in `boundary`. Nothing here touches
//! the Mac beyond that folder: no launch item, no account, no password, no Secure Enclave,
//! no network.
//!
//! The opener's core (`opener`, and the opening half of `capsule` and `age`) is compiled
//! only with the `opener` feature, which the keeper never turns on: the keeper seals and
//! never opens (chapter 03 section 9). The command-line opener is the binary
//! `safesightmac-opener`; the page is built from the same core in `opener/wasm`.
//! `docs/STEP-2-STATUS.md` says what exists, what is open and what comes next.

#![forbid(unsafe_code)]

pub mod age;
pub mod beacon;
pub mod boundary;
pub mod capsule;
pub mod clock;
pub mod constants;
pub mod counters;
pub mod frame;
#[cfg(any(test, feature = "opener"))]
pub mod opener;
pub mod records;
// The store uses Unix file calls; the opener also builds for WebAssembly and Windows,
// where no store exists.
#[cfg(unix)]
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
}
