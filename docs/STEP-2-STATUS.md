<!-- SPDX-License-Identifier: Apache-2.0 -->
# Step 2 status: the keeper

19 November 2026. Three passes so far. Only `keeper/`, `spec/vectors/` and this file changed.

| Pass | Branch | What it added |
|---|---|---|
| First | `step2-keeper` | The pure core: constants, records, the clock, the waits |
| Second | `keeper-core` | The real check of the time signal, the time lock and capsules, the store on disk, the counters across restarts |
| Third (this one) | `keeper-fixes` | Fixes from an independent review of the second pass, the keyholder's challenge and the real approval check. See "The third pass" |

**Compiled and tested on CI only.** No Rust toolchain is installed on the Mac the code was written on, and none was installed. Every pass is compiled and tested by CI (`cargo build --release`, `cargo test` in `keeper/`, on GitHub's macOS 15 runners, Rust 1.99.1). The results are in "What was compiled and tested".

**Nothing touches a Mac beyond one folder it is given.** No launch item, no account, no password handling, no Secure Enclave or keychain call, no network. The store writes only into a folder passed in; the tests use a fresh folder under the system's temporary folder. The lock is not built. Step 1's cover-only app is unchanged and still protects nothing against its own owner.

## What exists

| File | What it holds | Tests | Pass |
|---|---|---|---|
| `keeper/src/constants.rs` | Every wait and timer of register 5a the lock uses, the sizes of 5b it needs, and the pinned chain: hash, public key, group hash, period, genesis, beacon ID, scheme, hash tag | 10 | 1, 2 |
| `keeper/src/frame.rs` | The common record frame of SD-022: magic, type, version, length, fields, checksum. A strict reader and writer, and CRC-32 | 7 | 1 |
| `keeper/src/records.rs` | Seven fixed layouts with encode and decode: round record, request journal entry (now with the challenge nonce), journal header, wait record, clock record (with the boot identifier), instant-leave marker, capsule container | 24 | 1, 2, 3 |
| `keeper/src/boundary.rs` | Traits for every edge of the real system: the clocks (carried and raw), the round check, the random source (which can now fail), the typed-password proof, the approval check, the marker file | 0 | 1, 2, 3 |
| `keeper/src/approval.rs` | **The keyholder's challenge** (SD-306) and **the real approval check** (`Es256ApprovalVerifier`): ES256 over the passkey's assertion, the pinned RP ID hash and origin, the user-present and user-verified flags, strict client data | 9 | 3 |
| `keeper/src/beacon.rs` | **The real round check** (`QuicknetVerifier`): the BLS signature of a quicknet round against the pinned key, with hashing to G1 as RFC 9380 says | 9 | 2 |
| `keeper/src/timelock.rs` | **The time lock**: identity-based encryption of a 16-byte key to one round of the pinned chain (the published tlock scheme), and opening it with that round's signature. Every value that would open it is wiped after use | 7 | 2, 3 |
| `keeper/src/age.rs` | The `age` version 1 format as far as a capsule uses it: header, X25519 and tlock stanzas, header MAC, one-chunk payload. The reader is the opener's, compiled only for tests and the `opener` feature | 8 | 2 |
| `keeper/src/capsule.rs` | **The capsule**: `seal` (the admin secret, to the Recovery Key, then time-locked to the target round, in the record of register 8a), and the opener's `open`, compiled only for tests and the `opener` feature. The admin-secret and Recovery Key types | 14 | 2 |
| `keeper/src/store.rs` | **The store on disk**: two-copy records, the two-slot clock record, the request journal in two pairs of files with compaction, the reserved files of SD-225, and the local capsule folder with two slots. Root-owned folders only, no link followed | 25 | 2, 3 |
| `keeper/src/counters.rs` | **The counters across restarts**: carrying the boot and awake totals over the raw clocks, and detecting a new boot (`CarriedClock`, a `TimeSource`) | 8 | 2 |
| `keeper/src/clock.rs` | Round checking, the high-water round, the estimate, the start-round rule, tighten-time, the clock record out and back in (`Clock::record`, `Clock::restore`), a date wrong for certain, the bound on false rounds, and a capsule's freshness and schedule | 16 | 1, 2, 3 |
| `keeper/src/waits.rs` | One state machine: the exit request, the slot, the wait change, the keyholder shortcut and date of power, the instant-leave window, and the keyholder's challenge for the open request | 72 | 1, 3 |
| `keeper/src/fakes.rs` | Fake clocks, a fake beacon, fake and seeded random sources, a fake Mac's raw clocks, a scratch folder. Compiled only for tests | 0 | 1, 2 |
| `keeper/src/lib.rs` | The module list, and `#![forbid(unsafe_code)]` | 1 | 1 |

`keeper/src/main.rs` is unchanged. `keeper/Cargo.toml` lists the crates below and an `opener` feature that nothing in the keeper turns on. The counts of `constants` (10), `frame` (7), `age` (8), `beacon` (9), `capsule` (14) and `counters` (8) are unchanged by the third pass.

## Two limits, plainly

- **A keyholder caps the lock at about one day.** While a keyholder has power, every exit-class request can mature 24 hours after the start round that follows the approval, whatever the wait. Nothing the keeper can check proves that the keyholder is a different person from the owner: a passkey the owner keeps on a second phone, or a friend who always says yes, looks exactly the same. A raise resets that: by the founder's ruling of 20 November 2026, a keyholder with power loses it at every raise and waits the new wait again, as if newly enrolled, and a shortcut not yet matured is void. So a raise holds for one full wait of its own before the one-day exit can come back. A new keyholder, or one switched back on, also serves one applied wait first. None of this prevents the cap; it delays it. An owner who wants the full wait to hold should not enrol a keyholder.
- **The capsules depend on the drand quicknet chain.** A capsule opens only with the signature of its target round, which only that chain can publish. If the chain ever stopped, no capsule would ever open, the public route to maturity would stop with it, and only the counter route would remain: a request matures once the boot counter has counted the whole wait, which needs the Mac on or asleep, not powered off, for that long. The owner can still always leave that way.

## The third pass: fixes from review (`keeper-fixes`)

Each change came from an independent review of the second pass, was checked against the code first, and has tests that fail without it. The page side of item 9 is a separate draft pull request against `main` (branch `keyholder-binding`).

| # | What changed | Code | Tests |
|---|---|---|---|
| 1 | **A raise puts every keyholder back to waiting** (SD-365). A keyholder that has power loses it, and one still waiting starts again: either way it waits the wait now in force, counted from the raise, on the boot counter or from the first round after the raise that passes SD-039, exactly as a keyholder newly enrolled (the founder's ruling of 20 November 2026, closing OPEN item 26; for a keyholder still waiting, SD-365 as amended that day, which replaced "counted from its enrolment"). For one still waiting this is always a later date than the one it had, so it only tightens. A shortcut that an approval gave the open request and that has not yet matured it is void: the target goes back to the start round plus the new wait and the approval stays used (the stricter reading, chosen as the ruling asked). A request that has already matured, by the shortcut or otherwise, is left as it is, because a Matured entry is left only by a claim, Stay or expiry (R1-lock-19). An open request the keyholder had not approved keeps the full wait unless the keyholder regains power and approves it. A lowering never gives power back. The full-wait routes never involve the keyholder | `waits::apply_raise` | `a_raise_pushes_a_waiting_keyholders_date_of_power_out` (replaces `later_changes_of_the_wait_do_not_move_a_keyholders_date_of_power`), `a_raise_makes_a_keyholder_with_power_wait_again` (replaces `a_raise_leaves_a_keyholder_that_already_has_power_as_it_is`), `a_raise_during_an_open_request_the_keyholder_had_not_approved`, `a_raise_voids_a_shortcut_target_already_set` (replaces `a_shortcut_target_already_set_stands_when_the_wait_is_raised`), `a_raise_voids_an_approval_still_awaiting_its_start_round` (replaces `a_raise_while_an_approval_awaits_its_start_round_moves_only_the_wait_target`), `a_raise_leaves_a_request_the_shortcut_has_already_matured`, `no_mix_of_raises_and_approvals_matures_a_request_before_the_rules_allow` (40 random runs of raises, approvals, Leave, Stay, sleep, power-offs and rounds with a keyholder that had power from Lock), `a_keyholder_enrolled_under_30_days_waits_30_days_whatever_the_date` |
| 2 | **A date wrong for certain cannot vouch for a round.** A date before the chain's genesis, or more than `ANCHOR_CLOCK_TOLERANCE` behind the keeper's estimate (which is verified rounds plus the boot counter and never runs ahead of real time), fails rule (b) of SD-039: "clock refusing rounds". Instant Leave is refused while it lasts (`Refusal::DateUntrusted`), and so is a capsule (item 5). The estimate still moves only on verified rounds. A right date ends the state at the next round; the counter route never reads the date, so a date left wrong never keeps the owner in | `clock::Clock::date_untrusted`, `offer_round`; `waits::leave` | `a_date_wrong_for_certain_refuses_every_start_round_until_it_is_right`, `instant_leave_is_refused_while_the_date_is_behind_the_verified_rounds`, `an_archived_round_with_a_date_set_back_never_matures_a_request_at_once`; the random test of invariant I2 now also resets the date to before genesis (and again at every power-off, as a dead clock battery does), sets it behind the estimate, sets it ahead from the true time, and hands over old real rounds from up to 60 days back |
| 3 | **The journal never fills.** It is two pairs of reserved files. When the current pair is full, the newest entry, which holds the whole state of the newest request, is written into the other pair, in both copies, and only then that pair's header with the next epoch, copy A then copy B. The header write is the commit. Every entry stays in two copies at every step, and a stop anywhere leaves the journal as it was or as it is after | `store::Store::append_journal`, `compaction_plan`, `load_journal`, `read_pair`; `records::JournalHeader` | `compaction_keeps_the_newest_entry_and_alternates_the_pairs`; `compaction_survives_a_stop_at_every_step` (after each of the four writes and half-way through each, three compactions deep, in both directions); `a_journal_header_that_cannot_be_trusted_is_a_fault_or_is_not_a_commit`; `leave_and_stay_without_end_never_stop_an_exit` (600 entries through the real state machine into an 8-slot journal, then an exit to Committed) |
| 4 | **A raise discards an open lowering**, Pending or Matured, journaled as Discarded: claimed after the raise, it would have undone it. The claim also checks that the lowering waited out the wait now in force | `waits::apply_raise`, `claim` | `a_raise_discards_a_lowering_that_has_matured` (lower, mature, raise, claim), `a_raise_discards_a_pending_lowering_too`, `no_order_of_lower_mature_raise_and_claim_undoes_a_raise` |
| 5 | **Capsule freshness and target.** A round is fresh for a capsule (SD-059) if it was verified within `CAPSULE_FRESH_MAX` of boot-counter time, passed rule (b) when it came, and the date is not wrong for certain now. A generation's scheduled end and target are counted from tighten-time, the later of the estimate and the date, so a lagging estimate never gives a target already past and a wrong date can only move it later. Every raise that takes effect is recorded as owed to the capsule (`reseal_owed`) until the rotation reports the old secret retired; the rule is written down there and in OPEN item 33 | `clock::capsule_round_is_fresh`, `capsule_schedule`; `waits::reseal_owed`, `old_secret_retired` | `a_capsule_is_scheduled_only_on_a_fresh_round_and_from_tighten_time`, `every_raise_is_owed_to_the_capsule_until_the_old_secret_is_retired` |
| 6 | **A read error rewrites nothing.** A copy of a two-copy record that cannot be read (an I/O error, a link, something that is not a plain file) is now a fault, `StoreError::Io`. Before, it counted as damaged, so the older copy won and was written over the newer one | `store::read_found`, `load` | `a_copy_that_cannot_be_read_is_a_fault_and_rolls_nothing_back` |
| 7 | **Root-owned folders, no links.** In the real configuration the store folder, the capsule folder and every folder above them must be real folders owned by root that only their owner can write to, on an absolute path with no `..`. Every file is opened with `O_NOFOLLOW` and `O_NONBLOCK` and must be a plain file. The tests run as a normal user through `Store::open_for_tests` and `CapsuleFolder::open_for_tests`, which exist only under `cfg(test)`, so no release build can reach them | `store::folder_is_private`, `Owner`, `open_existing` | `the_real_configuration_takes_only_root_owned_folders`, `a_folder_above_that_is_a_link_or_writable_by_others_is_refused`, `a_store_file_that_is_a_link_is_never_followed` |
| 8 | **Hygiene.** `RandomSource::request_id` can fail; a request whose random ID or nonce cannot be drawn is refused (`Refusal::RandomUnavailable`) and nothing is journaled. `timelock::lock` wipes r, rQ, the pairing value and both masks (and `unlock` the pairing value and masks). A flood of false rounds costs at most `BAD_ROUND_BUDGET` pairing checks per `BAD_ROUND_WINDOW` of boot-counter time; the high-water round, false or repeated, costs none | `boundary`, `waits::draw_request`, `timelock`, `clock::offer_round` | `a_random_generator_that_fails_journals_nothing`, `lock_wipes_every_value_that_would_open_it` (a build check of the source, as the capsule's), `a_flood_of_false_rounds_costs_at_most_the_budget_of_checks`, `a_dropped_round_changes_nothing` (extended) |
| 9 | **The keyholder signs what they see** (SD-306). The challenge is SHA-256 over a tag, the format version, the kind, the request ID, the detail (a lowering's new wait, a loosening's setting), the Mac label, any item hashes and the keeper's 32 random bytes for the request. The test approval has its own tag. The nonce is drawn with the request and journaled in every entry, so the challenge and "used once" survive a restart. `WaitMachine::approval` recomputes the challenge from its own record and refuses any other. `Es256ApprovalVerifier` checks ES256 over the authenticator data and the SHA-256 of the client data under the pinned key, the pinned RP ID hash, user present and user verified, no attested or extension data, and client data that is exactly a `webauthn.get` for this challenge at the pinned origin, with `crossOrigin` absent or false, no `topOrigin`, and no second `type`, `challenge` or `origin` | `approval`, `waits::approval_challenge`, `approval`, `records::JournalEntry` | `the_challenge_matches_every_shared_vector`, `the_approval_check_agrees_with_every_shared_vector` (24 cases made by `node:crypto`), `a_good_approval_fails_for_any_other_challenge_key_origin_or_bit`, `client_data_members_are_read_strictly`, `an_approval_must_carry_this_requests_own_challenge`, and four more |

**Shared vectors.** `spec/vectors/keyholder-challenge-v1.txt` holds the challenge cases and the approval cases. It was made by `keyholder/tests/make-challenge-vectors.mjs` (on the `keyholder-binding` branch) with `node:crypto` only, a third implementation beside the keeper's and the page's, and is read byte for byte by both test suites (`.gitattributes` keeps git from changing it).

## The second pass, part by part

### 1. The real check of the time signal (`beacon`)

- `QuicknetVerifier` implements `RoundVerifier` against the pinned key only. There is no way to give it another key (SD-043).
- The check: refuse round 0; read the signature as a point of G1, checked on the curve and in the subgroup, not infinity; hash SHA-256 of the round (8 bytes, big-endian) to G1 with the scheme's tag; accept only if e(signature, g2) = e(H(message), public key).
- The published `drand` client crate fetches rounds over HTTP and the keeper has no network (SD-018), so, as chapter 02 section 11 says for that case, the check is written against the pairing crates directly.
- The pinned values are in `constants` with their register IDs (SD-043; chapter 03 section 2). The public key and group hash were read from drand's published chain information (`/info` at api.drand.sh). A test rebuilds the chain hash of chapter 03 from the key, period, genesis, group hash and beacon ID, so the two sources check each other.
- Test vectors: five real quicknet rounds (1, 1000, 1001, 12345678, 30000000), fetched once from api.drand.sh for the tests. Each verifies; each fails as another round; seven single-bit changes fail; the identity, all-zero and all-one signatures and round 0 fail; the two RFC 9380 hash-to-curve vectors of the suite match; the clock takes real rounds through the real check and drops a forged and a tampered one.

### 2. The time lock and the capsule (`timelock`, `age`, `capsule`)

- **Time lock.** The published tlock scheme for signatures on G1 (Boneh and Franklin with the Fujisaki-Okamoto transform, as drand's `EncryptCCAonG2`): the body is U (96 bytes), V (16), W (16). It opens only with the target round's signature; any other round, or any changed bit, opens nothing.
- **Capsule format (register 8a, SD-056).** Inner layer: an `age` v1 file to the Recovery Key's X25519 public half (two recipients during an overlap), whose payload is the admin secret and nothing else. Outer layer: an `age` v1 file with one `tlock` stanza (`-> tlock <round> <chain hash>`) whose payload is the inner file. The outer file is the ciphertext of the existing capsule record: generation, target round and chain hash in the clear, zero padding to `CAPSULE_SIZE`. One recipient: 595 bytes of ciphertext; two: 693; the record is 4,096.
- **`seal`** has exactly the inputs chapter 03 section 9 lists, plus the random generator for keys and nonces; the chain key is pinned. Every key is wiped when it returns. A test is the build check of SD-057: it fails if `seal`'s signature changes or if any other module builds a capsule record or names its type.
- **`open`** is the opener's core, in the opener's order (chapter 03 section 11): the record; the round, its chain and its signature; not before the target ("not yet"); the time layer; the `age` layer. It and the `age` reader are compiled only for tests and the `opener` feature, so the keeper itself never parses a capsule (chapter 03 section 9).
- **Cross-check.** An independent implementation, written for this pass on the noble libraries (noble-curves 1.9.1, the library tlock's JavaScript port uses; noble-ciphers 1.3.0; noble-hashes 1.8.0), made the vectors: the time-lock body for round 1000 with fixed inputs, and two whole capsules (one and two recipients) from the same seeded draws. The Rust output matches them byte for byte. A real round's published signature opens what the keeper seals.
- Tests use random data from a seeded source and a made-up secret. No real secret is stored or printed; `AdminSecret` and `RecoveryIdentity` print as "hidden".

### 3. The store on disk (`store`)

| Record | Files | How it is written | How it is read |
|---|---|---|---|
| Wait record (and later the pin and the sealed secret) | `wait.a`, `wait.b` | Each copy to a temporary name, full flush, rename, folder flush; A then B; read back and compared | The valid copy with the higher sequence number; the other is rewritten from it |
| Clock record | `clock.a`, `clock.b`, reserved | In place over the older or damaged slot, full flush, read back; refused unless it follows the current record | The valid slot with the higher sequence number |
| Request journal | Two pairs, `journal.a` and `journal.b`, `journal.c` and `journal.d`, reserved, a header slot and 2,048 entry slots each (third pass) | In place at the next slot of the current pair, A then B, each flushed and read back, before the step may run. When full: compaction into the other pair, header last | The pair with the higher epoch is current. An entry valid in one copy is taken and the other repaired; a torn last entry is ignored; a damaged earlier entry is a fault |
| Local capsule | `capsule.a`, `capsule.b` in their own folder, reserved, mode 0644 | In place over the slot that does not hold the newest capsule, read back and compared | The valid slot with the higher generation |

- "Full flush" is `File::sync_all`, which on macOS is `F_FULLFSYNC`, as chapter 02 section 8 asks.
- Both copies damaged is reported as a fault naming the record (`BothUnreadable`), never a default; no copy at all is reported separately (`NoCopy`), and after Lock the caller treats it the same (SD-227). Two valid copies with the same sequence number that differ are a fault too.
- `reserve` makes the reserved files at Lock at their fixed sizes, filled with real zero bytes, and refuses if any exists. Reserved files are never grown.
- A folder that is a link, or that group or others can write to, is refused. From the third pass: also one not owned by root, or below a folder that is any of these.
- **Journal replay is not written** (OPEN item 3): everything up to it is.

### 4. The counters across restarts (`counters`, `clock`)

- `CarriedClock` is the `TimeSource` the core reads, over a new boundary trait `RawClocks` (the continuous clock, the absolute clock, the boot identifier, the date). It carries both totals from the clock record and counts on from the readings saved with them.
- A new boot is detected as chapter 03 section 2 says: a lower continuous reading, cross-checked with the boot identifier, which the clock record now carries (OPEN item 24). The rule for each case is the table in `counters`; every case counts no more than the time that really passed, so a wait can only run long.
- `Clock::record` builds the clock record from the clock and the counters; `Clock::restore` takes it back at start-up and checks the high-water round's signature again, so the record proves itself.
- Tests: a restart in the same boot loses nothing; a new boot counts from its start and not the time off; disagreeing signs count the smaller amount; a raw clock moving back never moves a total back; 5,000 random steps of awake time, sleep, power-offs, restarts and clocks moving back, with a save every `COUNTER_SAVE`, never run ahead of real time and lose at most what was counted since the last save; and the whole path through the store's two slots and back after a power-off.

## Crates

All are on the fixed list of SD-021 for this pass and need a second reader (ST-063). None does any networking. Exact versions are pinned in `keeper/Cargo.toml`; see "The lock file" for the rest of the tree.

| Crate | Version | Licence | Used for |
|---|---|---|---|
| `ark-bls12-381` | 0.4.0 | MIT OR Apache-2.0 | The curve: G1, G2, the pairing, hashing to G1 |
| `ark-ec` | 0.4.2 | MIT OR Apache-2.0 | Curve groups, the pairing, RFC 9380 hashing |
| `ark-ff` | 0.4.2 | MIT OR Apache-2.0 | Fields, the scalar of the time lock |
| `ark-serialize` | 0.4.2 | MIT OR Apache-2.0 | Compressed points, the pairing value's bytes |
| `sha2` | 0.10.8 | MIT OR Apache-2.0 | SHA-256 |
| `chacha20poly1305` | 0.10.1 | Apache-2.0 OR MIT | The `age` payload and key wrap |
| `hkdf` | 0.12.4 | MIT OR Apache-2.0 | The `age` key steps |
| `hmac` | 0.12.1 | MIT OR Apache-2.0 | The `age` header MAC |
| `x25519-dalek` | 2.0.1 | BSD-3-Clause | The Recovery Key's X25519 recipient |
| `zeroize` | 1.8.1 | Apache-2.0 OR MIT | Wiping keys and the admin secret |
| `p256` | 0.13.2 | Apache-2.0 OR MIT | Third pass: ES256 verification of the keyholder's approval, with the `ecdsa` feature only |
| `libc` | 0.2.191 | MIT OR Apache-2.0 | Third pass: the `O_NOFOLLOW` and `O_NONBLOCK` flags only; already in the tree through `cpufeatures` |

**Why `p256`.** Nothing on the fixed list does ECDSA on P-256. The choices were RustCrypto's `p256`, of the same family and maintainers as `sha2`, `hmac` and `hkdf`, sharing their `digest`, `subtle`, `generic-array` and `zeroize`; or arkworks' `ark-secp256r1` (whose curve crates are already here) with ECDSA verification written by hand. A hand-written verifier would be one more thing for the second reader to prove. The crates `p256` brings are listed under "The lock file". SD-021's fixed list needs amending to include it, and it needs a second reader (ST-063) like the other ten.

The licences are those the crates declare, written here in SPDX form. The CI licence check read the declared licence of every crate in the lock file and passed: 64 dependencies, none GPL-family or unknown. The rest of the tree, as CI built it on macOS, beyond the ten above: `aead` 0.5.2, `ahash` 0.8.12, `ark-ff-asm` 0.4.2, `ark-ff-macros` 0.4.2, `ark-poly` 0.4.2, `ark-serialize-derive` 0.4.2, `ark-std` 0.4.0, `autocfg` 1.5.1, `block-buffer` 0.10.4, `cfg-if` 1.0.5, `chacha20` 0.9.1, `cipher` 0.4.4, `cpufeatures` 0.2.17, `crypto-common` 0.1.7, `curve25519-dalek` 4.1.3, `derivative` 2.2.0, `digest` 0.10.7, `either` 1.19.0, `generic-array` 0.14.7, `hashbrown` 0.13.2, `inout` 0.1.4, `itertools` 0.10.5, `libc` 0.2.191, `num-bigint` 0.4.8, `num-integer` 0.1.47, `num-traits` 0.2.19, `once_cell` 1.21.4, `opaque-debug` 0.3.1, `paste` 1.0.15, `poly1305` 0.8.0, `ppv-lite86` 0.2.21, `proc-macro2` 1.0.107, `quote` 1.0.47, `rand` 0.8.8, `rand_chacha` 0.3.1, `rand_core` 0.6.4, `rustc_version` 0.4.1, `semver` 1.0.28, `subtle` 2.6.1, `syn` 1.0.109 and 2.0.119, `typenum` 1.20.1, `unicode-ident` 1.0.27, `universal-hash` 0.5.1, `version_check` 0.9.5, `zerocopy` 0.8.63, `zeroize_derive` 1.5.0. The lock file also names seven crates that are not built on macOS or with the features used (`curve25519-dalek-derive` 0.1.1, `fiat-crypto` 0.2.9, `serde` 1.0.229, `serde_core` 1.0.229, `serde_derive` 1.0.229, `syn` 3.0.10, `zerocopy-derive` 0.8.63); the licence check covers them too. Nothing here was audited, and no crate is called audited.

Two crates the register names are not used, and the reasons are OPEN items 17 and 18: the published `tlock` crate and the published `age` crate.

### The lock file

Chapter 02 section 11 asks for a committed lock file. One cannot be made on this Mac without a Rust toolchain or a crate index. So the lock file is CI's own: the first runs of this pass had none, and `tools/check-licences.sh` made one with `cargo generate-lockfile` before the build. One run carried a test that wrote that file to the log (commit `78d938a`); the file was copied from the log, checked line by line (65 packages, 64 checksums, every dependency resolved), committed as `keeper/Cargo.lock`, and the test removed (commit `612023a`). From that commit on, the licence check reads the committed file with `--locked`. Nothing yet makes `cargo build` itself run `--locked` or offline after a checksummed vendor step, as chapter 02 asks; that needs the workflow, outside `keeper/`. Note that if the committed file and `Cargo.toml` ever disagree, `cargo metadata --locked` fails and the check, as written, reports "0 dependencies, all allowed" (see "Observations").

**Third pass.** The same way: the first run with `p256` in `Cargo.toml` resolved the tree (its licence check printed "0 dependencies", as above, since the committed file was then stale) and wrote the lock file to the log; it was copied from there, checked (78 packages, 77 checksums, only additions, no existing entry changed), committed, and the test that wrote it removed in the same commit. The thirteen crates added, all built: `p256` 0.13.2, `ecdsa` 0.16.9, `elliptic-curve` 0.13.8, `primeorder` 0.13.6, `crypto-bigint` 0.5.5, `ff` 0.13.1, `group` 0.13.0, `sec1` 0.7.3, `der` 0.7.10, `const-oid` 0.9.6, `base16ct` 0.2.0, `rfc6979` 0.4.0, `signature` 2.2.0. With the committed file the licence check read 77 dependencies, all allowed. `libc` was already in the file.

## Register IDs each module implements

| Module | Register IDs |
|---|---|
| `constants` | Section 5a: `EXIT_WAIT_OPTIONS`, `EXIT_WAIT_MAX`, `SIX_MONTHS_DAYS`, `APPLIED_WAIT_CAP_AT_SETUP`, `LONG_WAIT_EARLIEST`, `RAISE_GUARD_DELAY`, `RAISE_CHECK_EXPIRY`, `ADMIN_TASK_WAIT`, `KEYHOLDER_SHORTCUT`, `INSTANT_LEAVE_WINDOW`, `INSTANT_LEAVE_CAP`, `INSTANT_LEAVE_REPEAT`, `PRIVATE_CHECK_TIME`, `CLAIM_WINDOW`, `ROTATION_INTERVAL`, `CAPSULE_FRESH_MAX`, `ANCHOR_CLOCK_TOLERANCE`, `CAPSULE_OPEN_WARNING`, `SAVE_BANNER`, `RECOVERY_KEY_REMINDER`, `BEACON_PERIOD`, `ROUNDS_PER_DAY`, `BEACON_READ`, `COUNTER_SAVE`. Section 5b: `ADMIN_SECRET_LENGTH`, `READ_BACK_CHARS`, `KEYHOLDERS`, `RECORD_COPIES`, `CAPSULE_SIZE`, `BEACON_MIRRORS`. Decisions SD-042, SD-043 (the pinned chain: hash, key, genesis, period, scheme), SD-044, SD-045, SD-058 |
| `frame` | SD-022; register 8a (the frame); register 6e (an unknown version is "update needed"); chapter 02 table 8b and its decoding rules |
| `records` | Register 8a rows: round record, request journal entry (I03-13), wait record (I03-9, I03-3, R1-lock-03), clock record (I03-1), instant-leave marker (I09-2), capsule. SD-038, SD-056, SD-057 (the capsule holds nothing else: padding must be zero), the two-slot rule of SD-022 for the clock record |
| `beacon` | SD-038 (the keeper verifies each round itself), SD-043 (one chain, its key pinned); chapter 03 section 2 (the scheme, the signed message, step 4 of the check); chapter 02 section 11 (the round check against the pairing library) |
| `timelock` | SD-056 (time-locked with standard tlock to the target round); chapter 03 section 9 (the outer layer) |
| `age` | SD-056 (encrypted to the Recovery Key's public half with standard `age`), SD-065 (two recipients during an overlap); chapter 03 section 9 (the inner layer; the keeper never parses a capsule) |
| `capsule` | SD-035 (the admin secret leaves the Mac only inside a capsule), SD-056, SD-057 (the build check), SD-063 (only the public half reaches the keeper), SD-066 (the opener's core); chapter 03 sections 9 and 11; register 8a (capsule) |
| `store` | SD-022 (two slots, the older slot first), SD-028 (two copies; a damaged one repaired from the other), SD-225 (reserved files, written in place, never grown), SD-227 (both copies unreadable is a fault the caller acts on); register 8b (the keeper store; the capsule folder, world-readable); chapter 02 sections 8 and 13; SD-060 (the local save, read back) |
| `counters` | SD-037 (the boot and awake counters, carried across restarts, not counting time powered off); chapter 03 section 2 ("The counters", "A new boot", "The clock record") |
| `clock` | SD-037 (high-water round, estimate, the estimate never moves back), SD-038 (the keeper's check of a round, in order), SD-039 (start-round rules (a) and (b)), SD-041 (tighten-time), SD-043 (the pinned chain). Invariants I1 and I3 of chapter 03 section 3. The clock record out and back in (chapter 03 section 2) |
| `waits` | SM-02 in full; SM-03 in full; the keeper side of SM-04. SD-039, SD-040, SD-041 with R1-lock-02, SD-045, SD-046 with I03-7, SD-047, SD-048, SD-049 with I09-1 (S-19 default: Stay needs no password), SD-050, SD-052, SD-053 with I03-6, SD-054, SD-055 (the exit-class slot). R1-lock-19 (a Matured entry keeps its first deadline). Invariants I2 and I4 |
| `boundary` | SD-051 (the password never reaches the core), SD-038, SD-196, SD-052, SD-037 (the raw clocks) as trait edges only |

## OPEN items

Where the register is silent, ambiguous or contradicts a chapter, the code does not invent security-relevant behaviour. It builds the more protective reading and marks the spot `// OPEN: <register id>`. Each needs a ruling or a register edit. Items 1 to 16 are from the first pass and unchanged; items 17 to 25 are new.

### Record formats

| # | Register ID | What is open | What the code does |
|---|---|---|---|
| 1 | SD-022; chapter 02 point N1 | The magic value, the frame's field widths, the byte order and the checksum algorithm are not fixed | Chapter 02's proposal (table 8b): 4-byte magic, 2-byte type, 2-byte version, 4-byte length, little-endian. Magic "SSMK". CRC-32, 4 bytes |
| 2 | SD-022; chapter 02 `records.toml` | The numbered list of record types does not exist | A record's number is its row in the table of register 8a |
| 3 | Register 8a, request journal entry | The entry has no field for the wait a lowering asks for, the setting a loosening names, or whether an accepted approval still awaits its new start round. Chapter 03 section 8 also stores a 32-byte challenge "with the request" that 8a does not list | No field is added for the first three. **The journal cannot be replayed for those cases, so replay at start-up is not written.** The journal on disk is written up to replay. Third pass: the keeper's 32 random bytes for the challenge (SD-306) are added as the entry's last field, so the entry is now 119 bytes |
| 4 | SD-028; register 8a, wait record and clock record | "The higher sequence number wins" needs a sequence number that 8a does not list as a field | A sequence number is the first field of both records |
| 5 | SD-037; register 8a, clock record | The unit of the carried counters is not specified | Milliseconds |
| 6 | Register 8a, clock record | Chapter 03 section 2 lists "last reading of each clock in this boot"; 8a does not | Both readings are laid out |
| 7 | Register 8a, instant-leave marker | The form of "wall-clock date of Lock" is not specified | Unix seconds. Display only; it decides nothing |
| 24 | Register 8a, clock record; chapter 03 section 2 | A new boot is detected by a lower reading "cross-checked with kern.bootsessionuuid". Across a restart that needs the identifier of the boot the saved readings belong to, which 8a does not list | The boot identifier (16 bytes) is the clock record's last field. The record is 152 bytes |

Items 3, 4, 6 and 24 matter for the "no field outside the published tables" check of chapter 10 (layer 3), which is not written yet: as 8a stands, that check would fail on the sequence numbers, the last readings and the boot identifier.

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

### Crates, the capsule and the store (new in this pass)

| # | Register ID | What is open | What the code does (the more protective reading) |
|---|---|---|---|
| 17 | SD-021 | The register names the published `tlock` crate. That crate draws its own randomness inside the call, while the keeper's randomness comes through `RandomSource` (a boundary trait), and its API could not be read from this Mac | The scheme is written against the pairing crates (`timelock`, about 130 lines of code), pinned by a vector from an independent implementation and by a real round's signature. A vector made by the Go reference (drand/tlock) is still to be added, with the opener page (ST-072) |
| 18 | SD-021 | The register names the published `age` crate. It brings a localisation stack (i18n-embed, fluent) into a root daemon for two stanza types; and, as far as could be told without its sources, one crate of that stack (`self_cell`) offers GPL-2.0 as one of its licence choices, which `tools/check-licences.sh` refuses as written | The format is written from the published specification with the fixed-list crates (`age`, about 375 lines of code with the reader), pinned by vectors from the independent implementation. A vector from the reference `age` tools is still to be added (ST-072) |
| 19 | SD-035 | `ADMIN_SECRET_LENGTH` is "40 or more"; chapter 03 section 9 asks for a fixed length; the alphabet is not fixed | Exactly 40 characters, each printable ASCII other than a space. The generator is not written. The alphabet should avoid characters that are hard to type at the login window, since the Recovery Key holder types the secret there |
| 20 | SD-063 | The form in which the Recovery Key's public half reaches the keeper (the `age1...` text or its bytes, and in which record) | The 32 bytes |
| 21 | SD-225; C02-18 | The size of the reserved journal file, and what happens when it is full | 2,048 entries a copy. Third pass: two pairs of files (about 244 KB each, four files), and a full pair is compacted into the other (see item 31). The append never refuses for lack of room |
| 22 | SD-225; C02-18 | The sizes of the exit journal and of the "next" secret slot | Neither is reserved yet |
| 23 | SD-225 | The ruling reserves "one capsule" | Two capsule slots, written in place, the older first, so that a stop while saving never leaves the folder without a readable capsule. The second slot holds at most the previous generation, whose secret is retired once its rotation finishes |
| 25 | Chapter 03 section 2, "A new boot" | What to do when the lower reading and the boot identifier disagree | Count the smaller amount: another identifier with a reading not lower counts only the difference; the same identifier with a lower reading counts nothing |

### From the third pass

| # | Register ID | What is open | What the code does (the more protective reading) |
|---|---|---|---|
| 26 | SD-054 | Whether a raise should make a keyholder that already has power wait again | **Closed** by the founder's ruling of 20 November 2026 (SD-365): it does, from the raise, for the wait then in force, and a shortcut not yet matured is void; a keyholder still waiting also counts the new wait from the raise (third pass, item 1). SD-053's I03-6 ("a shortcut target already set stands") is replaced by this; the register needs the edit |
| 27 | SD-039; SD-313 | Rule (b) trusts a date that is behind real time but not behind the keeper's estimate. After time powered off the estimate lags, and such a date (set on purpose, which on macOS needs an administrator, or carried there by a power-off after being set back) lets an old real round from that moment be a start round. The random test of invariant I2 leaves this case out and says so | Nothing more than item 2 of the third pass. A further rule is possible but not built: within one boot, a later round that is far ahead of the start round plus the boot-counter time between them proves the start round was old, and the start could be moved later on that proof. Across a power-off nothing proves it. Needs the outside review SD-039 is already marked for |
| 28 | SD-059 | "Within `CAPSULE_FRESH_MAX` of boot-counter time" can span a power-off of any length, since the boot counter does not count it | The schedule is counted from tighten-time, so a right date covers it. The rotation, when written, should also require that the round was verified in the present boot (the clock record carries the boot identifier) |
| 29 | SQ-11 | The keyholder page's origin and RP ID are not chosen | `Es256ApprovalVerifier::new` takes them as parameters. Once chosen they become lock-core constants and the parameters go |
| 30 | Register 8a, request journal entry | The challenge nonce (32 bytes) is a field 8a does not list | Added as the last field (see item 3) |
| 31 | SD-225; C02-18; register 8a | The journal's compaction, its header record (type `0x0101`, outside the rows of 8a) and its four files are not in the register. Compaction keeps only the newest entry, which is all that any rule written so far needs, since every entry is a whole snapshot of its request | As built. When replay is written (item 3), compaction must keep whatever replay then needs |
| 32 | Register 5a | `BAD_ROUND_BUDGET` (16) and `BAD_ROUND_WINDOW` (one minute of boot-counter time) are not register values | Working values. They can only delay a good round to the next window; nothing that tightens waits for a round |
| 33 | SD-057; SD-058; SM-05 | Every raise must re-seal at once and retire the old admin secret, and a raise only holds against the Recovery Key route once the old secret is retired. The rotation that would do this is not written | `WaitMachine::reseal_owed` records the wait every raise in force is owed; `old_secret_retired` clears it, and nothing calls it yet. Until the rotation exists, the newest capsule still opens one old wait after its generation's end |
| 34 | SD-307 | Apple's sealed links (such as `/etc`) are not known by name | The real store path must have no link anywhere above it. In the test configuration only, a root-owned folder above with the sticky bit (as `/private/tmp`) is accepted |
| 36 | SD-054; register 8a (keyholder pin) | The keyholder's power, its waiting wait, base and start round live only in the state machine: the pin record that would carry them across a restart is not laid out, and journal replay is not written (item 3). The request side of the ruling is in the journal: a voided shortcut is journaled as a Pending entry with the full target and the approval used, which is a whole state a replay can take back (the tests check that entry and its round trip through the record format). No restart was tested, because there is no replay to test | When the pin record is laid out, it must carry the waiting state, and a pin read back without it must be taken as waiting the applied wait from the restart, never as having power |
| 35 | Chapter 03 section 8 | How strict to be with client data beyond the fixed prefix | Members after the prefix may be strings, `true`, `false` or `null`, with no whitespace and no escape in a key; numbers, whitespace or anything else are refused. A browser that wrote them would have its approvals refused, which leaves the full wait. ES256 signatures with a high S are accepted, as WebAuthn does not ask for low S |

### Observations, not changes

- **SD-039** lets a round be a start round if it is not below the estimate and not more than `ANCHOR_CLOCK_TOLERANCE` behind the date. After time powered off the estimate lags, so a round up to 10 minutes older than the request can be its start round. That is the rule as written, and the code builds it as written. Invariant I2 ("never matures while real elapsed time is less than its wait") holds to within `ANCHOR_CLOCK_TOLERANCE`, not exactly. SD-039 is already marked NEEDS OUTSIDE REVIEW.
- **SD-225 and APFS.** A reserved file written in place is meant to need no free space. Whether an in-place write on APFS needs free blocks (for example while a local snapshot still holds the old blocks) is not established here. ST-013 should measure it on the test Mac; until then SD-225's premise is unproven on APFS.
- **The capsule's generation number** is in the clear and is not bound into the ciphertext: a copy relabelled with another generation still opens, to the same secret. SD-056 asks only that it be carried in the clear; it decides nothing. The target round, in contrast, is bound: it is in the tlock stanza, which the header MAC covers, and the opener refuses a capsule whose two differ.
- **The licence check** (`tools/check-licences.sh`, outside `keeper/` and not changed): its `|| true` after `cargo metadata --locked` turns a failed call into "0 dependencies, all allowed"; and its plain search for "GPL" refuses a crate that offers GPL as only one of several choices (for example `r-efi`, which `getrandom` 0.3 pulls in). The second keeps the tree on `rand` 0.8 and `getrandom` 0.2 for now. Both are worth a look by whoever owns `tools/`.

## Not laid out yet

| Record | Why |
|---|---|
| Sealed admin secret | The key reference's size waits for ST-010 |
| Keyholder pin | The credential ID's slot size is not specified; the fields for the counter route to power are in chapter 03 and not in 8a |
| Enrolment record, request code, approval code | Slot sizes not specified; chapter 09 owns the enrolment record |
| Exit journal, removal list | Sizes "not specified" (C02-18) |
| Version record and the release records | Chapter 08 |

## Not written yet

- Real implementations of the other boundary traits: the raw clocks (`mach_continuous_time`, `mach_absolute_time`, `kern.bootsessionuuid`), the system random generator, the typed-password dialog, the marker file. They belong to the hands layer. The ES256 approval check is written (third pass); reading the approval code into `ApprovalCode` and converting its DER signature is the app's.
- The keyholder pin record (the public key, and where the Mac label is kept), and the enrolment check.
- Journal replay at start-up (blocked by OPEN item 3) and the model test of invariant I5.
- The run loop that saves the clock record every `COUNTER_SAVE` and at every verified round. The pieces exist (`CarriedClock::snapshot`, `Clock::record`, `Store::write_clock`).
- Rotation (SM-05): the fresh-round test of SD-059, `CAPSULE_TARGET`, forced retirement, the generation schedule. `seal` and the capsule folder are ready for it.
- The sealed admin secret and the Secure Enclave (SD-036, ST-010); the admin secret's generator.
- The opener as a tool and as a single-file page (SD-066); only its core exists.
- The admin-task slot (SM-06), the release hold (SM-12), the exit steps (SM-11), the private check timer, "busy, try again" (SD-226).
- The XPC message handlers of register 6c.
- The lab flavour (a lab chain with a short period, SD-175).
- `keeper/spec/records.toml`, generated decoders, the layer 3 schema check, the crypto allow-list file and the keeper's size budget (SQ-08).

## What was compiled and tested

Every run below is the `check` workflow on pull request lumen-open/safesight-mac#3, job "check": sign-off, SPDX lines, no secrets, no networking code, dependency licences, Swift build and test, no lab stand-in, then "Keeper build and test" (`cargo build --release`, `cargo test`). Every step passed in every run.

| Run | Commit | Keeper tests | Licence check |
|---|---|---|---|
| 44462645651 | `e1f8881` Check time signal signatures | 121 passed, 0 failed | 45 dependencies, all allowed |
| 44463585864 | `acc7219` Add the time lock | 149 passed, 0 failed | 64 dependencies, all allowed |
| 44464411235 | `233eb15` Save lock records safely | 166 passed, 0 failed | 64 dependencies, all allowed |
| 44465456461 | `28bbfa0` Carry the counters across restarts | 175 passed, 0 failed | 64 dependencies, all allowed |
| 44466338902 | `78d938a` Show the crate lock file in the test log | 176 passed, 0 failed (the extra test wrote the lock file) | 64 dependencies, all allowed |

The run on the commit that adds the lock file and this document is on the pull request. The build showed no compiler warning.

Third pass, on pull request lumen-open/safesight-mac#22 (against `keeper-core`), same job:

| Run | Commit | Keeper tests | Licence check |
|---|---|---|---|
| 44579234330 | `ea0ccfb` Tighten the keeper's waits, clock, journal, store and approval check | 207 passed, 1 failed (`a_dropped_round_changes_nothing`: the test's own comparison did not allow for the bad-round window restarting), plus the test that wrote the lock file. One compiler warning, in a test | 0 dependencies (stale lock file, as above) |
| 44580107866 | `9f6974b` Pin the crate versions CI resolved for p256 | 207 passed, 0 failed. No compiler warning | 77 dependencies, all allowed |
| 44608488375 | `19b28fc` Make a keyholder with power wait again after a raise | 210 passed, 0 failed. No compiler warning | 77 dependencies, all allowed |

Every other step passed in every run. The keyholder page's side (draft pull request #21, against `main`) has its own run.

- The first pass's 110 tests were run for the first time in this pass's first CI run, and all passed.
- Nothing has run on a virtual Mac or a test Mac. Gate G2 needs the keeper's CI and virtual-Mac tests green, the second-reader record (ST-063) and the keeper's size budget (SQ-08). None of these is done.
- The store's tests ran on CI's macOS runner against its real disk, with the full flush on files and folders.

## The next pass

1. Get rulings on the OPEN items, first of all item 3 (the journal entry's missing fields), lay out the keyholder pin with its waiting state (item 36), then write the journal's replay with the model test of chapter 03 section 3 (invariant I5), and make compaction keep what replay needs.
2. A second reader for the crates (now with `p256`) and for `beacon`, `timelock`, `age`, `capsule`, `approval` and the store's compaction (ST-063); vectors from the Go tlock reference and the reference `age` tools; an approval made by a real passkey on a real phone, checked by the keeper (ST-029, ST-030).
3. The run loop of the counters, and the hands layer's raw clocks and random generator, on the virtual Mac.
4. Rotation (SM-05) over `seal` and the capsule folder, with the fresh-round test.
5. The remaining records once their sizes are fixed, `keeper/spec/records.toml` with vectors, and the layer 3 schema check.
6. The message handlers of register 6c over the machine, with the hostile-order tests (every message at every state).
