<!-- SPDX-License-Identifier: Apache-2.0 -->
# Step 2 status: the keeper, first pass

17 November 2026. Branch `step2-keeper`. Only `keeper/` and this file changed.

**Nothing in this pass has been compiled or run.** No Rust toolchain is installed on the Mac the code was written on, and none was installed. The code is written to be compiled and tested by CI (`cargo build --release`, `cargo test` in `keeper/`). Until CI has run it, every statement below about what the code does is a statement about what it was written to do.

**Nothing in this pass touches a Mac.** It has no launch item, no account, no password handling, no Secure Enclave or keychain call, no file access and no network. The lock is not built. Step 1's cover-only app is unchanged and still protects nothing against its own owner.

## What exists

This pass is the pure, testable core that chapter 03 section 16 puts first in the order of work: the records (piece 1), part of the clock (piece 2) and the waits (piece 3). The crate is still `safesightmac-keeper`, with no dependencies beyond the Rust standard library.

| File | What it holds | Tests |
|---|---|---|
| `keeper/src/constants.rs` | Every wait and timer of register 5a that the lock uses, and the sizes of 5b it needs. Each constant names its register name and decision | 8 |
| `keeper/src/frame.rs` | The common record frame of SD-022: magic, type, version, length, fields, checksum. A strict reader and writer, and CRC-32 | 7 |
| `keeper/src/records.rs` | Six fixed layouts with encode and decode: round record, request journal entry, wait record, clock record, instant-leave marker, capsule (the container only, no cryptography) | 23 |
| `keeper/src/boundary.rs` | Traits for every edge of the real system: the clocks, the beacon signature check, the random source, the typed-password proof, the approval check, the marker file | 0 |
| `keeper/src/clock.rs` | Round checking, the high-water round, the estimate, the start-round rule, tighten-time. The only module that reads the date | 12 |
| `keeper/src/waits.rs` | One state machine: the exit request, the slot, the wait change, the keyholder shortcut and date of power, the instant-leave window | 59 |
| `keeper/src/fakes.rs` | A fake clock, a fake beacon and a fake random source. Compiled only for tests, so none can reach a release build | 0 |
| `keeper/src/lib.rs` | The module list, and `#![forbid(unsafe_code)]` | 1 |

`keeper/src/main.rs` and `keeper/Cargo.toml` are unchanged.

## Register IDs each module implements

| Module | Register IDs |
|---|---|
| `constants` | Section 5a: `EXIT_WAIT_OPTIONS`, `EXIT_WAIT_MAX`, `SIX_MONTHS_DAYS`, `APPLIED_WAIT_CAP_AT_SETUP`, `LONG_WAIT_EARLIEST`, `RAISE_GUARD_DELAY`, `RAISE_CHECK_EXPIRY`, `ADMIN_TASK_WAIT`, `KEYHOLDER_SHORTCUT`, `INSTANT_LEAVE_WINDOW`, `INSTANT_LEAVE_CAP`, `INSTANT_LEAVE_REPEAT`, `PRIVATE_CHECK_TIME`, `CLAIM_WINDOW`, `ROTATION_INTERVAL`, `CAPSULE_FRESH_MAX`, `ANCHOR_CLOCK_TOLERANCE`, `CAPSULE_OPEN_WARNING`, `SAVE_BANNER`, `RECOVERY_KEY_REMINDER`, `BEACON_PERIOD`, `ROUNDS_PER_DAY`, `BEACON_READ`, `COUNTER_SAVE`. Section 5b: `ADMIN_SECRET_LENGTH`, `READ_BACK_CHARS`, `KEYHOLDERS`, `RECORD_COPIES`, `CAPSULE_SIZE`, `BEACON_MIRRORS`. Decisions SD-042, SD-043 (the pinned chain hash and genesis time), SD-044, SD-045, SD-058 |
| `frame` | SD-022; register 8a (the frame); register 6e (an unknown version is "update needed"); chapter 02 table 8b and its decoding rules |
| `records` | Register 8a rows: round record, request journal entry (I03-13), wait record (I03-9, I03-3, R1-lock-03), clock record (I03-1), instant-leave marker (I09-2), capsule. SD-038, SD-056, SD-057 (the capsule holds nothing else: padding must be zero), the two-slot rule of SD-022 for the clock record |
| `clock` | SD-037 (high-water round, estimate, the estimate never moves back), SD-038 (the keeper's check of a round, in order), SD-039 (start-round rules (a) and (b)), SD-041 (tighten-time), SD-043 (the pinned chain). Invariants I1 and I3 of chapter 03 section 3 |
| `waits` | SM-02 in full; SM-03 in full; the keeper side of SM-04. SD-039, SD-040, SD-041 with R1-lock-02, SD-045, SD-046 with I03-7, SD-047, SD-048, SD-049 with I09-1 (S-19 default: Stay needs no password), SD-050, SD-052, SD-053 with I03-6, SD-054, SD-055 (the exit-class slot). R1-lock-19 (a Matured entry keeps its first deadline). Invariants I2 and I4 |
| `boundary` | SD-051 (the password never reaches the core), SD-038, SD-196, SD-052 as trait edges only |

Every row of SM-02 and SM-03 has at least one test, and so has every refusal the machine can give. Tests named after the register's own pass marks: no early maturity under any mix of sleep, power-off, date changes and rounds (ST-004); the counter route with no beacon (ST-065); no path to a wait above 30 days without the day-8 gate, the guard day and the private yes (ST-005); a refused message changes nothing (ST-003, for this message set).

## OPEN items

Where the register is silent, ambiguous or contradicts a chapter, the code does not invent security-relevant behaviour. It builds the more protective reading and marks the spot `// OPEN: <register id>`. Each needs a ruling or a register edit.

### Record formats

| # | Register ID | What is open | What the code does |
|---|---|---|---|
| 1 | SD-022; chapter 02 point N1 | The magic value, the frame's field widths, the byte order and the checksum algorithm are not fixed | Chapter 02's proposal (table 8b): 4-byte magic, 2-byte type, 2-byte version, 4-byte length, little-endian. Magic "SSMK". CRC-32, 4 bytes |
| 2 | SD-022; chapter 02 `records.toml` | The numbered list of record types does not exist | A record's number is its row in the table of register 8a |
| 3 | Register 8a, request journal entry | The entry has no field for the wait a lowering asks for, the setting a loosening names, or whether an accepted approval still awaits its new start round. Chapter 03 section 8 also stores a 32-byte challenge "with the request" that 8a does not list | No field is added. **The journal cannot be replayed for those cases, so replay at start-up is not written** |
| 4 | SD-028; register 8a, wait record and clock record | "The higher sequence number wins" needs a sequence number that 8a does not list as a field | A sequence number is the first field of both records |
| 5 | SD-037; register 8a, clock record | The unit of the carried counters is not specified | Milliseconds |
| 6 | Register 8a, clock record | Chapter 03 section 2 lists "last reading of each clock in this boot"; 8a does not | Both readings are laid out |
| 7 | Register 8a, instant-leave marker | The form of "wall-clock date of Lock" is not specified | Unix seconds. Display only; it decides nothing |

Items 3, 4 and 6 matter for the "no field outside the published tables" check of chapter 10 (layer 3), which is due in step 2 and is not written yet: as 8a stands, that check would fail on the sequence numbers and the last readings.

### State machine

| # | Register ID | What is open | What the code does (the more protective reading) |
|---|---|---|---|
| 8 | SD-053 (I03-5) | The ruling counts the shortcut's 24 hours on either route. The journal entry has no field for the boot-counter value at the shortcut's start round | The shortcut matures on the public route only. The request's own counter route runs untouched |
| 9 | SD-053; SM-02 | SM-02 accepts an approval for "Pending, counting". Chapter 03 section 8 also handles "no target yet" | An approval for a request with no start round is refused |
| 10 | SD-053 | What `keyholder_drop` or "shortcut off" does to a shortcut target already set on a Pending request | The target goes back to the start round plus the wait; the approval stays used. A Matured request is unchanged |
| 11 | SD-054; SD-195 | Enrolling while a keyholder is pinned | Refused; the owner drops the old keyholder first |
| 12 | SD-046 | A second raise above 30 days while one is guarded or awaiting its answer | Refused; `clear_planned_wait` discards the first |
| 13 | SD-046 | Whether the planned wait survives an expired raise | Cleared, as for "No" |
| 14 | SD-052; SM-02 | Leave inside the instant-leave window while the slot holds another request | Refused as "slot full"; Stay frees the slot |
| 15 | SD-052; register 8a, wait record | No field records that the window is closed for good | The two proofs (awake counter, estimate) cannot move back and need none. A marker that failed to read back once is remembered in memory only |
| 16 | SD-012 | The closed list of loosenings is not numbered, and "removing or weakening the browser profile" is not split | Three settings: browser profile, strict cover mode off, detector rule to Balanced |

### One observation, not a change

SD-039 lets a round be a start round if it is not below the estimate and not more than `ANCHOR_CLOCK_TOLERANCE` behind the date. After time powered off the estimate lags, so a round up to 10 minutes older than the request can be its start round. That is the rule as written, and the code builds it as written. It means invariant I2 ("never matures while real elapsed time is less than its wait") holds to within `ANCHOR_CLOCK_TOLERANCE`, not exactly. SD-039 is already marked NEEDS OUTSIDE REVIEW.

## Not laid out in this pass

| Record | Why |
|---|---|
| Sealed admin secret | The key reference's size waits for ST-010 |
| Keyholder pin | The credential ID's slot size is not specified; the fields for the counter route to power are in chapter 03 and not in 8a |
| Enrolment record, request code, approval code | Slot sizes not specified; chapter 09 owns the enrolment record |
| Exit journal, removal list | Sizes "not specified" (C02-18) |
| Version record and the release records | Chapter 08 |

## Not written in this pass

- Any real implementation of a `boundary` trait: the BLS check of a round, the system clocks, the typed-password dialog, the ES256 approval check, the random generator, the marker file.
- The store: two-copy and two-slot writes, the reserved files of SD-225, the journal on disk, and replay at start-up (blocked by OPEN item 3).
- Carrying the two counters across restarts and detecting a new boot. `TimeSource` hands the core the carried totals.
- The admin-task slot (SM-06), rotation and capsules (SM-05), the release hold (SM-12), the exit steps (SM-11), the private check timer, "busy, try again" (SD-226).
- The XPC message handlers of register 6c. The machine's methods carry the same names and rules, but nothing decodes a message yet.
- The lab flavour (a lab chain with a short period, SD-175).
- `keeper/spec/records.toml`, generated decoders, and the layer 3 schema check.

## What was not compiled or tested

All of it. In detail:

- `cargo build` and `cargo test` have never been run on this code. The 110 test functions have never executed.
- The code was read twice for compile errors and each test was traced by hand, once by its author and once by a second, independent reader. That second read found one failing assertion in a clock test, which is fixed. It found no compile error. A read is not a compiler.
- Two test vectors (round record, request journal entry) were produced by a separate Python encoder using `zlib.crc32`, so the layouts are pinned by bytes from a second implementation. No other record has an outside vector yet.
- The existing CI checks (`check-spdx.sh`, `check-licences.sh`, `check-signoff.sh`) were not run here beyond checking by hand that every new file starts with its SPDX line, that there is no dependency, and that every commit is signed off.
- Nothing has run on a virtual Mac or a test Mac. Gate G2 needs the keeper's CI and virtual-Mac tests green, the second-reader record (ST-063) and the keeper's size budget (SQ-08). None of these is done.

## The next pass

1. Run CI on this branch and fix whatever the compiler and the tests find.
2. Get rulings on the OPEN items, first of all item 3 (the journal entry's missing fields), then write the journal's replay with the model test of chapter 03 section 3 (invariant I5).
3. The clock record's carry across restarts, and the two-slot and two-copy store against a scratch folder.
4. The remaining records once their sizes are fixed, `keeper/spec/records.toml` with vectors, and the layer 3 schema check.
5. The message handlers of register 6c over the machine, with the hostile-order tests (every message at every state).
6. The verifying crates from the fixed list (SD-021), each with a second reader, behind `RoundVerifier` and `ApprovalVerifier`.
