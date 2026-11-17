// SPDX-License-Identifier: Apache-2.0
//! The keeper: the one root part of SafeSight Mac.
//!
//! Step 0 holds only the version record. Later steps add the sealed admin secret,
//! the time lock, the request journal and the fault ladder, each behind tests that
//! run unprivileged on CI against a scratch store.

#![forbid(unsafe_code)]

pub mod constants;

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
