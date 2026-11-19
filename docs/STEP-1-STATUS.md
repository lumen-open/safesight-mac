<!-- SPDX-License-Identifier: Apache-2.0 -->
# Step 1 status: the cover-only app

14 November 2026. Built and tested on a developer Mac (Apple M1 Max, macOS 26.3, Swift 6.3.3) through tests and the lab harness only. **The app has not been run live on any Mac.** Running it needs the Screen Recording permission, which only the owner can grant, on a test Mac.

Step 1 is the practice state of the watcher shipped alone (register SD-223 (f)). It has no lock: no keeper, no root part, no plain shield, no installer, no updater, no login item. It can be paused or quit at any time, and it protects nothing against its own owner.

## What works

These parts are built, and each is exercised by tests or the harness:

- **The detector, vendored.** The kestrel lab build (v3-detector, commit 49ecdd9) is in `Sources/Preprocess`, `Sources/RegionFinder` and `Sources/DetectorCore`, under Apache-2.0.
  - Its tests pass here: 12 rule tests, and the preprocessing spec's 18 of 18 vectors bit-exact.
  - It uses the lab build's current Balanced rule (agreement plus a tie-breaker) and its committed cut-off table (`models/thresholds.json`, `agreement+referee/1`).
  - Added for step 1: the Either rule, the caller's budget, the pass of each entry and a separate `find`.
  - Changed from the lab build, as SD-125 and C06-3 require: a flagged picture under 32 detail pixels is covered, not blurred; a dispute the tie-breaker could not answer is covered, not blurred; a window turns hot only after a both-family hit. Under Balanced it therefore no longer behaves exactly as the lab build.
  - No weights are in git. `tools/models/fetch_upstream.py` and `tools/models/pins.json` hold the pinned upstream hashes. At run time the models load from a local folder, and every file is checked against the hash list sealed in the build (`models/watcher-models.sha256`).
- **The capture layer** (`Sources/SafeSightMacCapture`).
  - One ScreenCaptureKit display stream for every active display, at the source's full pixel size. It captures 8-bit BGRA in sRGB, with no cursor and no audio. The app's own windows are left out of capture.
  - The map from capture pixels to screen points is rebuilt from each frame's own metadata, and the scale is read, never assumed.
  - Only changed areas are judged, grown to the 8-pixel grid. A full pass runs every 30 s.
  - When judging is busy, frames are coalesced without losing any changed area.
- **The cover layer** (`Sources/SafeSightMacWatcher`, `Sources/SafeSightMacCover`).
  - **Show-first.** Changed areas are split by window, and each window gets one judge call with its own context and its share of the judging budget.
  - **Classes.** `cover` draws a plain, wordless cover over the whole picture region. `contain` draws a strong blur of at most 6 colour cells; if the blur cannot be made, a plain cover is drawn instead. `clear` draws nothing.
  - **Placement.** Covers are clipped to the window's visible part, move with their window, and cover the old place for one update after a move.
  - **Lifting.** A cover lifts only after 4 clean judgements in a row of that region (SD-230).
  - **Every display.** Each display has its own canvas: one click-through panel per display, with every change applied in one transaction. Per-window overlays are the written fallback (`SAFESIGHTMAC_COVER_FORM=overlays`).
  - **Faults lead to more covering.** A display is covered whole when:
    - it has not been judged yet;
    - a frame is blank, suspended or stopped;
    - metadata is missing or inconsistent;
    - a stream stops;
    - the models fail their check;
    - judging stalls for more than 5 s;
    - it is past `DISPLAYS_MAX` (2);
    - the display set changes, or the Mac sleeps or switches session.

    A repair card above the covers says why, in plain words, and offers Try again, Pause (in the practice state only) and Quit. Nothing ever locks the screen, logs anyone out or reports anywhere.
  - **Slowness covers more.** Unjudged entries stay blurred or covered and are judged again. A window still unjudged after 0.5 s is covered whole.
- **The practice state** (SD-223).
  - The watcher is in the practice state only while no root-owned `<rd>.safesightmac.keeper.plist` (or the lab form) exists in `/Library/LaunchDaemons`. It is read with `lstat`, so a symbolic link is judged by its own owner.
  - If the check cannot be completed, the app does not claim the practice state: covering carries on and pause is turned off.
  - The menu shows "Practice: no lock" with a plain explanation.
- **The menu-bar app** (`safesight-mac`). It has no Dock icon. The menu shows:
  - the status: "Covering: on", "Needs Screen Recording" with a button that opens the setting, or why a display is covered;
  - the practice state;
  - the detector mode picker, Balanced (default) or Either, with the register's one sentence: "Balanced covers fewer harmless things and misses more. How much more has not been measured.";
  - "Strict cover mode: not in this version";
  - Pause for 15 minutes or 1 hour, enabled only in the practice state;
  - "How it works", with plain words and the honest promise word for word;
  - Quit.
- **The lab harness** (`safesightmac-harness`). It feeds image files or built-in synthetic scenes through the real pipeline without capturing the screen. It prints each cover's global rectangle, overlay window frame and canvas layer frame, and can write each frame with its covers drawn on it.
- **The lab stand-in.** A synthetic magenta-and-green checker that can only force a cover. It exists only in lab builds (`SAFESIGHTMAC_LAB=1`). `tools/check-no-standin.sh`, now in CI, finds no stand-in symbol or string in any release binary.
- **No networking code anywhere.** `tools/check-no-network.sh`, now in CI, fails if any source names a networking API.

## What is tested, and how

Commands, all run before the final commit:

```
swift build -c release                                     # passes, no warnings in new code
swift test                                                 # 83 test functions: 18 XCTest + 65 Swift Testing, all pass
SAFESIGHTMAC_LAB=1 swift test --scratch-path .build-lab        # 85: adds the 2 stand-in tests, all pass
tools/check-spdx.sh && tools/check-signoff.sh && tools/check-no-network.sh && tools/check-no-standin.sh
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness demo --origin 1440,0 --primary-height 900 --out OUT
swift run -c release safesightmac-harness demo --models ../v3-detector/models/converted
```

| Area | Tests (target) | How |
|---|---|---|
| Detector rules, as built | 12 `RuleTests` (DetectorCoreTests) | Fake marker models; the lab build's own tests, with four changed for SD-125: a tiny agreed flag covers and makes nothing hot; an unanswered dispute covers; a tie-breaker-confirmed hit makes nothing hot; a grid of low-level tiles makes nothing hot |
| Detector additions | 5 `ContractTests` | Either covers one family's flag without making the window hot, and Balanced with no tie-breaker covers it as a dispute; a rule change empties the cache; a budget of 0 gives only `overload`, never `clear`; every entry names its pass; `find` matches the finder |
| Preprocessing | 1 `VectorTests` | 18 of 18 spec vectors bit-exact |
| Region-to-screen mapping across scales | `MappingTests` | 1x, 2x, 3x, a rotated portrait display, displays left of and above the primary (negative origins), and a letterboxed frame. Round trip within 1 detail pixel and never smaller. Retina halving, the Cocoa flip, the canvas layer space, outward snapping, refusing unusable metadata |
| Changed areas, window split, mailbox | `DirtyRegionTests`, `WindowSplitTests`, `MailboxTests` | Grid growth and merging, clipping; the front-most window gets the change; desktop areas go to the display surface; visible-area subtraction; a window across two displays; no changed area lost when frames are coalesced |
| A flagged region produces a cover window frame | `CoverLayerTests` | The real detector (fake marker models) and the real pipeline on a 2x display to the right of the primary. The flagged picture is covered, and the overlay window frame (Cocoa) and canvas layer frame are checked. Also: a clean screen draws nothing; the lift after 4 clean judgements; a reflag resets the count; containment (a faint small picture in a hot window) is a blur; a dispute nobody could settle is a plain cover, as under Either; overload never shows a picture sharp; covers follow a moving window and cover its old place once; covers are clipped by windows in front; the app's own windows are never judged |
| Fault to cover | `FaultToCoverTests` | Blank, suspended or stopped frames; missing metadata; a map that does not match the pixels; a stopped stream; a failed detector; judging behind; too many displays. Each covers the whole display, and the next judged frame lowers it |
| Practice-state signal | `PracticeSignalTests`, `PracticeMenuTests` | A fake folder: no keeper file means practice; a root-owned keeper file (release, lab, any case) ends it; a non-root file is not a keeper; similar names do not count; an unreadable folder or owner means not practice. The real `lstat` probe on a temporary folder, including a symbolic link. Pause is allowed only in practice. The menu says "no lock" |
| Model check | `ModelCheckTests` | Changed, missing and unlisted files and a malformed list are refused. The sealed list and table match the committed files. Locally only: the lab build's converted models match the sealed list |
| Wording | `AppTextTests` (SafeSightMacCoreTests) | The promise matches the README word for word; no forbidden claim; the mode sentence carries no figure; strict cover mode says "not in this version" |
| Status line | `StatusTests` | "Needs Screen Recording", "Covering: on", a whole-display cover, pause and detector failure |
| Stand-in (lab builds) | `StandInTests` | The stand-in through the real detector with null models is covered and placed on a 2x display at a negative origin; null models alone cover nothing |

**Harness results** (lab build, null models, stand-in, an 800 x 500 point display at 2x, placed right of a 900-point-high primary):

1. A clean synthetic page: no covers.
2. The stand-in appears: covered (cover at x 1506.5, y 250, 253.5 x 160 points; overlay window y 490 in Cocoa points).
3. A 48-pixel stand-in appears: covered.
4. Both are removed: covered for 3 more clean frames, lifted on the 4th.
5. A blank frame: the whole display is covered.
6. The next frame: covers lowered.

With the real models (release build, read in place from `v3-detector`), the same synthetic page drew no cover. That is one page, not a measurement.

## Speed: the measured chain (lab, 18 November 2026)

The owner's goal is now about **0.1 s from a new picture appearing to its cover**, with no visible lag on busy pages (the register's `TIME_TO_COVER` of 0.5 s is too loose). The lab harness now times the chain: `SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness bench --models ../v3-detector/models/converted --pages ../v3-detector/data/finder-bench-heldout/screens --json FILE`.

- **What is timed:** from a frame handed to the cover layer to the cover plan, then the cover layer's layers built on a detached layer (no window). Stages: changed areas and window split, the picture finder, cache hashing, each model's preprocessing and inference, the rules, planning, and cover drawing. The capture callback's frame copy (BGRA to RGBA, 2880 x 1800) is timed on its own: 4.4 ms median.
- **What is not timed:** ScreenCaptureKit's capture latency and real display time. Both need ST-031 on a test Mac, with a camera or capture device.
- **Setup:** Apple M1 Max, macOS 26.3, release lab build, the three real models (Marqo, NSFWJS, the Bumble tie-breaker) checked against the sealed hash list, the sealed cut-off table, Balanced. A 1440 x 900 point display at 2x with one window filling it. The lab stand-in stands in for a flagged picture; everything else is harmless (synthetic patterns, and the lab's held-out composed pages of harmless photos). Results: `results/speed-before.json`.

Before any speed work:

| Case | Median | Worst | Notes |
|---|---|---|---|
| One new picture, 16-31 px | 58.5 ms | 77.6 ms | 16 of 16 covered |
| One new picture, 32-63 px | 46.8 ms | 53.0 ms | 16 of 16 |
| One new picture, 64-127 px | 50.7 ms | 58.1 ms | 16 of 16; Marqo is 38 of the 51 ms (4 tiles) |
| One new picture, 128 px and up | 51.4 ms | 67.4 ms | 16 of 16 |
| 32-tile grid, one stand-in tile | 460 ms | 1,070 ms | 8 of 8; the stand-in's cover also spread over 23 harmless tiles in 8 trials |
| Busy Retina page from scratch (6 pages, 260 to 430 regions), first plan | 2.83 s | 3.01 s | the stand-in is shown sharp until then; 400 judgements per call at most, the rest left for later |
| Same, until every region is judged | 18.1 s | 21.5 s | at `JUDGEMENT_BUDGET` 40/s; 8.5 s (worst 9.5 s) with no budget limit |
| Scrolling, per judged frame (8, 32, 96 px a frame) | 1.2 to 1.4 s | 1.5 s | covers do not move with the content: a covered stand-in in view was fully exposed for 1.8 s at 8 px a frame |
| Reload of a judged busy page | 270 ms | | every verdict from the cache; the finder (223 ms) runs again |
| Window moved, same content | 1.01 s | | the finder runs again and the uncovered strip is judged |
| Scrolling back to places seen before / to other places | 186 ms / 1.12 s | | at other places no slice matches the cache |

Where the time goes: Marqo (about 3.5 ms preprocessing and 7 ms inference a tile) dominates; on a full-window change the 40 slices of 512 px cost about 0.8 s, the finder 150 to 220 ms and hashing for the cache about 38 ms. On busy pages the per-call cap and the judging budget, not compute, decide how long pictures stay blurred or covered: once a window has had unjudged entries for 0.5 s it is covered whole.

## False covers through the whole pipeline: ST-040 re-run (18 November 2026)

`safesightmac-harness falsecovers` (release build, no lab hook) shows each harmless screen in one window filling a display and runs it through the cover layer: the window split, every detector rule including the three of 18 November, all three models (Marqo, NSFWJS and the Bumble tie-breaker, checked against the sealed hash list) and the sealed cut-off table, unedited. The cover layer then keeps judging what it left unjudged (budget unlimited) until every entry is judged, plus four more clean judgements, so lasting covers can be told from covers for load. A false cover is an entry the models covered. Harmless pictures only. Results: `results/false-covers-heldout.json`.

The set is the lab build's 932 held-out harmless screens: 180 composed pages of harmless photos, 602 screenshots (364 developer, 226 game, 12 console) and 150 generated pages.

| | Balanced | Either |
|---|---|---|
| Screens with a false cover | **8 of 932** (0.9%; 95% interval 0.4 to 1.7%) | **194 of 932** (20.8%; 18.3 to 23.5%) |
| False-cover entries | 13 of 108,773 judged (1.2 in 10,000; 0.7 to 2.0) | 683 of 110,044 (62 in 10,000) |
| Of which under 32 detail pixels | 13 | 493 |
| Screens with a false blur (hot window or contained small picture) | 0 | 1 (308 blurs, after one both-family false cover) |
| Both-family false covers / strikes | 0 / 0 | 1 / 0 |
| Same screens, rule against rule | fewer on 192 screens, more on 1, the same on 739 (sign test p < 10^-50) | |

- **S-21: Balanced shows fewer false covers than Either**, on the shipping table and the same pictures. By S-21's mark, Balanced stays the default.
- **`SCREEN_FALSE_COVERS`** (at most 1 harmless screen in 100): Balanced's 0.9% is under the mark, but the 95% interval reaches 1.7%, so 932 screens do not show it. Either fails it.
- **Every Balanced false cover is a tile under 32 detail pixels** that one family flagged and the tie-breaker confirmed. The rule "a flagged picture under 32 detail pixels is covered" (SD-125, C06-3 b) turns them from blurs into covers; before it they would have been blurred.
- **`FALSE_BOTH_FAMILY`** (mark: zero) was not met in the Either run: both families flagged one tile of a harmless developer screenshot once (1 in about 219,000 judged entries over both runs; the Balanced run, with fresh jitter, judged the same screen clean). It made the window hot and blurred 308 small pictures there. No strike in either run.
- The lab's method (one call of at most 400 judgements per screen) would have found 7 and 183 of these screens; judging every entry found 1 and 11 more.
- These are screens and tiles, not pictures one by one: `LASTING_FALSE_COVERS` (per ordinary picture) is not measured by this run.
- The cut-off table that ships here, `models/thresholds.json` (`agreement+referee/1`, lab report section 11), differs from the values the register lists as `COVER_CUTOFFS_*` (lab report section 6). This run used the sealed table only.
- Under Either, a one-family cover carries the reason "referee" in the detector's records although no tie-breaker is asked; a naming quirk, not a behaviour.

## What is not tested

- **The live app, end to end.** No ScreenCaptureKit stream has run, and no cover window has been drawn on a real screen. The menu, the repair card, the "How it works" window and both cover forms have not been seen.
- **Platform behaviours the capture code assumes,** each listed in chapter 05 as unproven:
  - the units of `dirtyRects` (read as frame pixels) and `contentRect` (read as frame points);
  - whether a still screen sends idle frames;
  - whether `.best` gives full backing pixels on every display type;
  - whether excluding the app keeps the content under a cover visible to capture.
- **Window levels and surfaces** (ST-032): full-screen apps, Spaces, Mission Control, menus, the Dock, notifications, click-through, VoiceOver. The canvas level is a working value (screen-saver level).
- **Displays** (ST-033, ST-034): external, mirrored, Sidecar, AirPlay, DisplayLink; plug, unplug, sleep, wake, resolution changes.
- **Time to cover on a real display** (ST-031). The flash length is unknown.
- **Speed, memory and energy** (ST-038, ST-039). Each complete frame is copied into an RGBA buffer for the detector, which costs memory and energy, unmeasured. `JUDGEMENT_BUDGET` (40 per second) and `FULL_REJUDGE` (30 s) are proposals.
- **False covers on real screens in daily use.** ST-040 re-ran through this pipeline on 932 held-out harmless screens (above); nothing has been measured on a live screen.
- **The catch rate.** Not measurable on this Mac by design.
- **The signed `.app`.** `tools/make-app.sh` assembles an unsigned bundle under `.build/`. That was checked once, and the bundle was then deleted. Nothing has been signed or notarized.

## What needs the founder

1. **A bundle identifier.** The reverse-domain prefix is not chosen (the identity file is still [P]). `tools/make-app.sh BUNDLE_ID MODELS_DIR` needs one.
2. **Sign and notarize** the app with your Developer ID, as in step 0. It is unsigned today.
3. **Try it on a test Mac, never this one.** This Mac runs your separate personal protection, which nothing here touches. Use the virtual test Mac or the helper's test Mac:
   1. build the app with the models inside;
   2. open it, choose "Open Screen Recording settings…" and grant the permission;
   3. quit and reopen it if macOS asks;
   4. check that the status reads "Covering: on".

   Then run, in a lab build, the stand-in through a real screen. Open a synthetic stand-in image in Preview, and check that:
   - it is covered;
   - the cover follows a moved window;
   - it lifts when closed;
   - the whole display is covered while a display is plugged in or the Mac wakes;
   - menus and full-screen apps stay under covers;
   - clicks pass through.

   Film the screen to count the flash (ST-031). Use synthetic patterns only.
4. **Detector discrepancy: done.** You approved building the register's rules. Register SD-125 and correction C06-3 asked for four changes to the lab build; all four are now in:
   - a flagged picture under 32 detail pixels gets `cover` (it got `contain`, a blur). It still never strikes or makes the window hot, and a video hold on it covers too;
   - a dispute the tie-breaker could not answer gets `cover` (it got `contain`). It never strikes or makes the window hot;
   - a window turns hot only after a both-family hit. The grid trigger (several low-level grid tiles) and the tie-breaker-confirmed trigger are removed, and under Either one family's hit no longer makes the window hot;
   - the Either rule, restored earlier.

   The code is in `Sources/DetectorCore/Detector.swift`, and `RuleTests`, `ContractTests` and `CoverLayerTests` pin each change. The first two cover more harmless things; the third blurs fewer. The lab false-alarm measurements were made without these rules; ST-040 has now re-run on this build (section "False covers through the whole pipeline").
5. **Model conversion.** The Core ML conversion tools, with their parity checks and broken controls, are still only in `v3-detector/convert/`. Vendoring them means vendoring Python tooling. Decide whether that belongs in this repository.

## Known limits

- **Flashes.** In show-first mode every window is shown first and judged just after, so a picture can be seen for a moment before its cover. How long is not measured; the target is under half a second. When judging is busy (busy pages, many changes), it is longer.
- **The catch rate is unmeasured.** Nobody knows how many explicit pictures this detector misses. The cut-offs are strict to keep false covers low, so Balanced may miss more, by an amount nobody has measured. No accuracy figure may be published (claims ledger).
- **False covers and blurs.** The detector covers some harmless things. The picture finder grows regions to a picture's edge, so a cover can spill over neighbouring text. Small pictures it is unsure about are blurred.
- **No lock and no shield.** This build can be paused or quit, and if it crashes or is quit, the screen is uncovered. At start, and when a display appears or wakes, the display is covered whole until its first judged frame (a few seconds when the models load).
- **Not judged:** the cursor, the brighter-than-white range of HDR displays, protected video (captured as black), sound and text, anything before login. Accessibility Zoom is not detected.
- **Load.** A busy screen judged from scratch exceeds the budget. Unjudged regions are blurred and unjudged 512-pixel slices are covered, so busy pages show lag, blur and blocks of cover until they are judged. A third display and beyond are covered whole.
- **Choices made where the register is silent or open.** Each is a working value tied to its test:
  - canvas window level: screen-saver level (ST-032);
  - cover colour: neutral grey;
  - blur: at most 6 colour cells;
  - judging stall before a whole-display cover: 5 s (ST-038);
  - `JUDGEMENT_BURST`: 400 (ST-038);
  - the repair card: shown after 2 s of a whole-display cover.

  A flagged whole pass covers the whole window only when the call spanned the window. On a call over changed parts, it covers the judged area unless a region cover in the same call explains it.

  For an unjudged slice or whole entry, this build keeps the detector's cover where C05-20 would blur only the pending regions it touches. That is more covering, not less.
- **Not built in this version:**
  - strict cover mode and judged copy;
  - "This is wrong";
  - heat and Low Power Mode inputs;
  - pointer and focus priority (hot windows do go first);
  - matching a frame to the window list taken nearest its time (the list is read when the frame is judged);
  - the crash-loop breaker;
  - the heartbeat and the plain shield, which are not part of the practice state.
- **Models are compiled by Core ML at load,** into a temporary folder. Correction C06-14 forbids a compile fallback once models ship compiled; that is build work for the release bundle.
