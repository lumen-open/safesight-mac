// SPDX-License-Identifier: Apache-2.0
//! The opener page's core: the keeper crate's opener core (SD-066), compiled to
//! WebAssembly and inlined into `opener/index.html`. No generated glue: a handful of
//! plain exported functions, and a few lines of JavaScript (`opener/src/core.js`).
//!
//! How the page talks to it:
//!
//! 1. `ss_input(slot, len)` makes a zeroed buffer of `len` bytes for one input (0 the
//!    copy, 1 the round, 2 the Recovery Key) and returns where it is in the module's
//!    memory; the page writes the bytes there.
//! 2. `ss_about`, `ss_inspect`, `ss_open_time`, `ss_open_key` do one step each and return
//!    0 (done) or 1 (refused). Their answer is in the output buffer (`ss_output_ptr`,
//!    `ss_output_len`): a small JSON object, or, for an opened copy, the admin secret's
//!    characters alone.
//! 3. `ss_clear` wipes every buffer, the opened time layer and the output.
//!
//! The Recovery Key's buffer is wiped as soon as `ss_open_key` has read it, whatever the
//! outcome, and the secret's as soon as the page asks (`ss_clear_output`).
//!
//! `unsafe`: none. The crate denies it; the one exception is the `no_mangle` attribute
//! on each export (Rust counts that attribute as unsafe because two exports of one name
//! would clash), which is how a WebAssembly module names its functions without generated
//! glue. There is no `unsafe` block. The page writes into a buffer through the pointer
//! `ss_input` returned, between calls, when no Rust reference to that buffer is alive.

#![deny(unsafe_code)]

use std::sync::{Mutex, MutexGuard};

use safesightmac_keeper::capsule::{OpenError, TimeLayerOpened};
use safesightmac_keeper::frame::RecordError;
use safesightmac_keeper::opener::{self, KeyError, RoundInputError};
use zeroize::{Zeroize, Zeroizing};

pub const SLOT_COPY: u32 = 0;
pub const SLOT_ROUND: u32 = 1;
pub const SLOT_KEY: u32 = 2;
const SLOTS: usize = 3;

/// The most bytes each input may hold.
const SLOT_MAX: [usize; SLOTS] = [opener::CAPSULE_INPUT_MAX, opener::ROUND_INPUT_MAX, opener::KEY_INPUT_MAX];

pub const DONE: u32 = 0;
pub const REFUSED: u32 = 1;

struct State {
    inputs: [Zeroizing<Vec<u8>>; SLOTS],
    opened: Option<TimeLayerOpened>,
    output: Zeroizing<Vec<u8>>,
}

impl State {
    fn new() -> State {
        State {
            inputs: [Zeroizing::new(Vec::new()), Zeroizing::new(Vec::new()), Zeroizing::new(Vec::new())],
            opened: None,
            output: Zeroizing::new(Vec::new()),
        }
    }

    fn answer(&mut self, status: u32, text: String) -> u32 {
        self.output = Zeroizing::new(text.into_bytes());
        status
    }
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

fn state() -> MutexGuard<'static, Option<State>> {
    match STATE.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn with_state<R>(f: impl FnOnce(&mut State) -> R) -> R {
    let mut guard = state();
    if guard.is_none() {
        *guard = Some(State::new());
    }
    match guard.as_mut() {
        Some(s) => f(s),
        None => unreachable_state(),
    }
}

fn unreachable_state() -> ! {
    // The state was set just above; a trap is the only honest answer if it were not.
    std::process::abort()
}

// ----- The safe interface (what the exports call, and what the native tests use) -----

/// A zeroed buffer of `len` bytes for `slot`, replacing what was there. None if the slot
/// is unknown or `len` is more than that input can be.
pub fn input_buffer(slot: u32, len: u32) -> Option<*mut u8> {
    let slot = slot as usize;
    if slot >= SLOTS || len as usize > SLOT_MAX[slot] {
        return None;
    }
    with_state(|s| {
        s.inputs[slot] = Zeroizing::new(vec![0u8; len as usize]);
        if slot == SLOT_COPY as usize {
            s.opened = None;
        }
        Some(s.inputs[slot].as_mut_ptr())
    })
}

/// Puts `bytes` into `slot`, as the page does through `input_buffer`. For tests.
pub fn set_input(slot: u32, bytes: &[u8]) -> bool {
    if input_buffer(slot, bytes.len() as u32).is_none() {
        return false;
    }
    with_state(|s| {
        s.inputs[slot as usize].copy_from_slice(bytes);
        true
    })
}

/// A copy of the output buffer. For tests.
pub fn output() -> Vec<u8> {
    with_state(|s| s.output.to_vec())
}

fn json_text(text: &str) -> String {
    // Only fixed ASCII words and addresses reach here; anything else is escaped anyway.
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 || (c as u32) > 0x7E => out.push_str(&format!("\\u{:04x}", c as u32 & 0xFFFF)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn urls(target_round: u64) -> String {
    let list: Vec<String> = opener::MIRRORS.iter().map(|m| json_text(&opener::round_url(m, target_round))).collect();
    format!("[{}]", list.join(","))
}

/// What the page needs to know about this core, as JSON.
pub fn about() -> u32 {
    let mirrors: Vec<String> = opener::MIRRORS.iter().map(|m| json_text(m)).collect();
    let text = format!(
        "{{\"version\":{},\"chain\":{},\"mirrors\":[{}],\"account\":{},\"claim_days\":{},\"secret_length\":{},\"key_opening\":{}}}",
        json_text(opener::VERSION),
        json_text(&opener::chain_hash_hex()),
        mirrors.join(","),
        json_text(opener::ADMIN_ACCOUNT_NAME),
        opener::CLAIM_DAYS,
        safesightmac_keeper::capsule::ADMIN_SECRET_LEN,
        json_text(opener::KEY_OPENING)
    );
    with_state(|s| s.answer(DONE, text))
}

fn copy_error(e: OpenError) -> &'static str {
    match e {
        OpenError::Capsule(RecordError::UpdateNeeded) => "newer_version",
        OpenError::Capsule(RecordError::TooShort)
        | OpenError::Capsule(RecordError::BadMagic)
        | OpenError::Capsule(RecordError::WrongType)
        | OpenError::Capsule(RecordError::WrongLength) => "not_a_copy",
        OpenError::OtherChain => "other_chain",
        _ => "damaged",
    }
}

fn info_json(info: &opener::CapsuleInfo) -> String {
    format!(
        "\"generation\":{},\"target_round\":{},\"target_time\":{},\"urls\":{}",
        info.generation,
        info.target_round,
        info.target_unix_seconds,
        urls(info.target_round)
    )
}

/// Step 1: reads the copy in slot 0.
pub fn inspect() -> u32 {
    with_state(|s| {
        s.opened = None;
        match opener::inspect(&s.inputs[SLOT_COPY as usize]) {
            Ok(info) => {
                let text = format!("{{{}}}", info_json(&info));
                s.answer(DONE, text)
            }
            Err(e) => s.answer(REFUSED, format!("{{\"error\":{}}}", json_text(copy_error(e)))),
        }
    })
}

/// Steps 2 to 5: reads the round in slot 1, checks it and opens the time layer of the
/// copy in slot 0. The round's buffer is wiped afterwards.
pub fn open_time() -> u32 {
    with_state(|s| {
        s.opened = None;
        let info = match opener::inspect(&s.inputs[SLOT_COPY as usize]) {
            Ok(i) => i,
            Err(e) => return s.answer(REFUSED, format!("{{\"error\":{}}}", json_text(copy_error(e)))),
        };
        let base = info_json(&info);
        let read = opener::read_round(&s.inputs[SLOT_ROUND as usize], info.target_round);
        s.inputs[SLOT_ROUND as usize] = Zeroizing::new(Vec::new());
        let round = match read {
            Ok(r) => r,
            Err(RoundInputError::Inconsistent) => {
                return s.answer(REFUSED, format!("{{\"error\":\"inconsistent\",{}}}", base));
            }
            Err(_) => return s.answer(REFUSED, format!("{{\"error\":\"not_a_round\",{}}}", base)),
        };
        let given = format!(
            "\"round\":{},\"round_time\":{},\"named\":{}",
            round.round,
            opener::round_unix_seconds(round.round).unwrap_or(0),
            round.round_named
        );
        match opener::open_time(&s.inputs[SLOT_COPY as usize], &round) {
            Ok(opened) => {
                s.opened = Some(opened);
                s.answer(DONE, format!("{{{},{}}}", base, given))
            }
            Err(e) => {
                let code = match e {
                    OpenError::NotYet { .. } => "not_yet",
                    OpenError::WrongRound => "wrong_round",
                    OpenError::BadRoundSignature => "bad_signature",
                    OpenError::OtherChain => "other_round_chain",
                    OpenError::Round(_) => "not_a_round",
                    other => copy_error(other),
                };
                s.answer(REFUSED, format!("{{\"error\":{},{},{}}}", json_text(code), base, given))
            }
        }
    })
}

/// Steps 6 and 7: reads the Recovery Key in slot 2 and opens the `age` layer. On success
/// the output is the admin secret's characters alone. The key's buffer is wiped whatever
/// happens.
pub fn open_key() -> u32 {
    with_state(|s| {
        let read = opener::read_recovery_key(&s.inputs[SLOT_KEY as usize]);
        s.inputs[SLOT_KEY as usize] = Zeroizing::new(Vec::new());
        let identity = match read {
            Ok(i) => i,
            Err(e) => {
                let code = match e {
                    KeyError::Empty => "empty",
                    KeyError::PublicHalf => "public_half",
                    KeyError::NotAKey => "not_a_key",
                    KeyError::Typo => "typo",
                };
                return s.answer(REFUSED, format!("{{\"error\":{}}}", json_text(code)));
            }
        };
        let result = match &s.opened {
            Some(opened) => Some(opener::open_with_key(opened, &identity)),
            None => None,
        };
        drop(identity);
        match result {
            None => s.answer(REFUSED, String::from("{\"error\":\"not_ready\"}")),
            Some(Ok(secret)) => {
                let mut out = Zeroizing::new(Vec::with_capacity(secret.reveal().len()));
                out.extend_from_slice(secret.reveal());
                s.output = out;
                DONE
            }
            Some(Err(OpenError::NotForThisKey)) => s.answer(REFUSED, String::from("{\"error\":\"not_for_this_key\"}")),
            Some(Err(_)) => s.answer(REFUSED, String::from("{\"error\":\"damaged\"}")),
        }
    })
}

/// Wipes the output buffer.
pub fn clear_output() {
    with_state(|s| {
        s.output.zeroize();
        s.output = Zeroizing::new(Vec::new());
    })
}

/// Wipes everything.
pub fn clear() {
    with_state(|s| {
        for slot in s.inputs.iter_mut() {
            slot.zeroize();
        }
        s.opened = None;
        s.output.zeroize();
        *s = State::new();
    })
}

// ----- The exports -----
//
// Each `allow(unsafe_code)` below covers the `no_mangle` attribute of one export, and
// nothing else: the functions' bodies are safe code.

#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn ss_input(slot: u32, len: u32) -> *mut u8 {
    match input_buffer(slot, len) {
        Some(p) => p,
        None => std::ptr::null_mut(),
    }
}

#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn ss_output_ptr() -> *const u8 {
    with_state(|s| s.output.as_ptr())
}

#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn ss_output_len() -> u32 {
    with_state(|s| s.output.len() as u32)
}

#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn ss_about() -> u32 {
    about()
}

#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn ss_inspect() -> u32 {
    inspect()
}

#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn ss_open_time() -> u32 {
    open_time()
}

#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn ss_open_key() -> u32 {
    open_key()
}

#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn ss_clear_output() {
    clear_output()
}

#[allow(unsafe_code)]
#[no_mangle]
pub extern "C" fn ss_clear() {
    clear()
}

#[cfg(test)]
mod tests {
    //! The same steps the page takes, on the native build, with the stored vectors. The
    //! page's own test (`opener/tests/page.test.mjs`) runs them again on the built
    //! WebAssembly inside the built page.
    use super::*;
    use safesightmac_keeper::capsule::RecoveryIdentity;
    use std::sync::Mutex as TestLock;

    const VECTORS: &str = include_str!("../../vectors/v1.txt");

    // The core has one state, so the tests take turns.
    static TURN: TestLock<()> = TestLock::new(());

    fn turn() -> std::sync::MutexGuard<'static, ()> {
        match TURN.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(),
        }
    }

    fn vector(name: &str) -> String {
        for line in VECTORS.lines() {
            if let Some(rest) = line.strip_prefix(name) {
                if let Some(value) = rest.strip_prefix(' ') {
                    return value.to_string();
                }
            }
        }
        panic!("no {}", name);
    }

    fn base64(text: &str) -> Vec<u8> {
        let alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = Vec::new();
        let (mut acc, mut bits) = (0u32, 0);
        for c in text.bytes().take_while(|c| *c != b'=') {
            acc = (acc << 6) | alphabet.iter().position(|x| *x == c).unwrap() as u32;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                out.push((acc >> bits) as u8);
            }
        }
        out
    }

    fn key_text(name: &str) -> String {
        let hex = vector(name);
        let mut scalar = [0u8; 32];
        for i in 0..32 {
            scalar[i] = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).unwrap();
        }
        opener::recovery_key_text(&RecoveryIdentity::from_bytes(scalar)).to_string()
    }

    fn out_text() -> String {
        String::from_utf8(output()).unwrap()
    }

    #[test]
    fn about_names_the_version_the_mirrors_and_the_account() {
        let _t = turn();
        assert_eq!(about(), DONE);
        let text = out_text();
        assert!(text.starts_with("{\"version\":\"0.0.1\""), "{}", text);
        assert!(text.contains("\"mirrors\":[\"https://api.drand.sh\",\"https://drand.cloudflare.com\"]"));
        assert!(text.contains("\"account\":\"SafeSight Mac administrator\""));
        assert!(text.contains("\"claim_days\":7"));
        assert!(text.contains("\"secret_length\":40"));
    }

    #[test]
    fn the_page_steps_open_the_stored_copy() {
        let _t = turn();
        clear();
        assert!(set_input(SLOT_COPY, &base64(&vector("base64"))));
        assert_eq!(inspect(), DONE);
        assert_eq!(
            out_text(),
            "{\"generation\":3,\"target_round\":1000,\"target_time\":1692806364,\"urls\":[\
             \"https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/public/1000\",\
             \"https://drand.cloudflare.com/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/public/1000\"]}"
        );

        // The key before the time layer is open: refused, and the key's buffer wiped.
        assert!(set_input(SLOT_KEY, key_text("key").as_bytes()));
        assert_eq!(open_key(), REFUSED);
        assert_eq!(out_text(), "{\"error\":\"not_ready\"}");

        assert!(set_input(SLOT_ROUND, vector("round 1").as_bytes()));
        assert_eq!(open_time(), REFUSED);
        let text = out_text();
        assert!(text.starts_with("{\"error\":\"not_yet\",\"generation\":3"), "{}", text);
        assert!(text.ends_with("\"round\":1,\"round_time\":1692803367,\"named\":true}"), "{}", text);

        assert!(set_input(SLOT_ROUND, vector("round 1001").as_bytes()));
        assert_eq!(open_time(), REFUSED);
        assert!(out_text().starts_with("{\"error\":\"wrong_round\""));

        assert!(set_input(SLOT_ROUND, b"Requested future beacon"));
        assert_eq!(open_time(), REFUSED);
        assert!(out_text().starts_with("{\"error\":\"not_a_round\""));

        assert!(set_input(SLOT_ROUND, vector("round 1000").as_bytes()));
        assert_eq!(open_time(), DONE);
        assert!(out_text().ends_with("\"round\":1000,\"round_time\":1692806364,\"named\":true}"));

        assert!(set_input(SLOT_KEY, key_text("other-key").as_bytes()));
        assert_eq!(open_key(), REFUSED);
        assert_eq!(out_text(), "{\"error\":\"not_for_this_key\"}");

        let mut typo = key_text("key").into_bytes();
        typo[50] = if typo[50] == b'Q' { b'P' } else { b'Q' };
        assert!(set_input(SLOT_KEY, &typo));
        assert_eq!(open_key(), REFUSED);
        assert_eq!(out_text(), "{\"error\":\"typo\"}");

        assert!(set_input(SLOT_KEY, key_text("key").as_bytes()));
        assert_eq!(open_key(), DONE);
        assert_eq!(out_text(), vector("secret"));
        clear_output();
        assert!(output().is_empty());

        clear();
        assert_eq!(open_key(), REFUSED);
        assert_eq!(out_text(), "{\"error\":\"empty\"}");
    }

    #[test]
    fn a_new_copy_closes_the_last_opened_time_layer() {
        let _t = turn();
        clear();
        assert!(set_input(SLOT_COPY, &base64(&vector("base64"))));
        assert!(set_input(SLOT_ROUND, vector("round 1000").as_bytes()));
        assert_eq!(open_time(), DONE);
        assert!(input_buffer(SLOT_COPY, 10).is_some());
        assert!(set_input(SLOT_KEY, key_text("key").as_bytes()));
        assert_eq!(open_key(), REFUSED);
        assert_eq!(out_text(), "{\"error\":\"not_ready\"}");
    }

    #[test]
    fn inputs_are_bounded_and_bad_copies_named() {
        let _t = turn();
        clear();
        assert!(input_buffer(3, 1).is_none());
        assert!(input_buffer(SLOT_COPY, opener::CAPSULE_INPUT_MAX as u32 + 1).is_none());
        assert!(input_buffer(SLOT_ROUND, opener::ROUND_INPUT_MAX as u32 + 1).is_none());
        assert!(input_buffer(SLOT_KEY, opener::KEY_INPUT_MAX as u32 + 1).is_none());
        assert!(input_buffer(SLOT_KEY, 0).is_some());

        assert!(set_input(SLOT_COPY, b"{\"round\":1000}"));
        assert_eq!(inspect(), REFUSED);
        assert_eq!(out_text(), "{\"error\":\"not_a_copy\"}");

        let mut damaged = base64(&vector("base64"));
        damaged[700] ^= 1;
        assert!(set_input(SLOT_COPY, &damaged));
        assert_eq!(inspect(), REFUSED);
        assert_eq!(out_text(), "{\"error\":\"damaged\"}");

        let mut newer = base64(&vector("base64"));
        newer[6] = 2;
        assert!(set_input(SLOT_COPY, &newer));
        assert_eq!(inspect(), REFUSED);
        assert_eq!(out_text(), "{\"error\":\"newer_version\"}");
    }

    #[test]
    fn json_text_escapes_what_it_must() {
        assert_eq!(json_text("plain"), "\"plain\"");
        assert_eq!(json_text("a\"b\\c\n"), "\"a\\\"b\\\\c\\u000a\"");
    }
}
