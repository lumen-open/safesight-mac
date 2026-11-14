<!-- SPDX-License-Identifier: Apache-2.0 -->
# Step 1 status: the cover-only app

14 November 2026. Built and tested on a developer Mac (Apple M1 Max, macOS 26.3, Swift 6.3.3) through tests and the lab harness only. **The app has not been run live on any Mac.** Running it needs the Screen Recording permission, which only the owner can grant, on a test Mac.

Step 1 is the practice state of the watcher shipped alone (register SD-223 (f)). It has no lock: no keeper, no root part, no plain shield, no installer, no updater, no login item. It can be paused or quit at any time, and it protects nothing against its own owner.

## What works

These parts are built, and each is exercised by tests or the harness:

- **The detector, vendored.** The kestrel lab build (v3-detector, commit 49ecdd9) is in `Sources/Preprocess`, `Sources/RegionFinder` and `Sources/DetectorCore`, under Apache-2.0.
  - Its tests pass here: 12 rule tests, and the preprocessing spec's 18 of 18 vectors bit-exact.
  - It uses the lab build's current Balanced rule (agreement plus a tie-breaker) and its committed cut-off table (`models/thresholds.json`, `agreement+referee/1`).
  - Added for step 1: the Either rule, the caller's budget, the pass of each entry and a separate `find`. Under Balanced it behaves exactly as the lab build.
  - No weights are in git. `tools/models/fetch_upstream.py` and `tools/models/pins.json` hold the pinned upstream hashes. At run time the models load from a local folder, and every file is checked against the hash list sealed in the build (`models/watcher-models.sha256`).
- **The capture layer** (`Sources/FernwickCapture`).
  - One ScreenCaptureKit display stream for every active display, at the source's full pixel size. It captures 8-bit BGRA in sRGB, with no cursor and no audio. The app's own windows are left out of capture.
  - The map from capture pixels to screen points is rebuilt from each frame's own metadata, and the scale is read, never assumed.
  - Only changed areas are judged, grown to the 8-pixel grid. A full pass runs every 30 s.
  - When judging is busy, frames are coalesced without losing any changed area.
- **The cover layer** (`Sources/FernwickWatcher`, `Sources/FernwickCover`).
  - **Show-first.** Changed areas are split by window, and each window gets one judge call with its own context and its share of the judging budget.
  - **Classes.** `cover` draws a plain, wordless cover over the whole picture region. `contain` draws a strong blur of at most 6 colour cells; if the blur cannot be made, a plain cover is drawn instead. `clear` draws nothing.
  - **Placement.** Covers are clipped to the window's visible part, move with their window, and cover the old place for one update after a move.
  - **Lifting.** A cover lifts only after 4 clean judgements in a row of that region (SD-230).
  - **Every display.** Each display has its own canvas: one click-through panel per display, with every change applied in one transaction. Per-window overlays are the written fallback (`FERNWICK_COVER_FORM=overlays`).
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
  - The watcher is in the practice state only while no root-owned `<rd>.fernwick.keeper.plist` (or the lab form) exists in `/Library/LaunchDaemons`. It is read with `lstat`, so a symbolic link is judged by its own owner.
  - If the check cannot be completed, the app does not claim the practice state: covering carries on and pause is turned off.
  - The menu shows "Practice: no lock" with a plain explanation.
- **The menu-bar app** (`fernwick-open`). It has no Dock icon. The menu shows:
  - the status: "Covering: on", "Needs Screen Recording" with a button that opens the setting, or why a display is covered;
  - the practice state;
  - the detector mode picker, Balanced (default) or Either, with the register's one sentence: "Balanced covers fewer harmless things and misses more. How much more has not been measured.";
  - "Strict cover mode: not in this version";
  - Pause for 15 minutes or 1 hour, enabled only in the practice state;
  - "How it works", with plain words and the honest promise word for word;
  - Quit.
- **The lab harness** (`fernwick-harness`). It feeds image files or built-in synthetic scenes through the real pipeline without capturing the screen. It prints each cover's global rectangle, overlay window frame and canvas layer frame, and can write each frame with its covers drawn on it.
- **The lab stand-in.** A synthetic magenta-and-green checker that can only force a cover. It exists only in lab builds (`FERNWICK_LAB=1`). `tools/check-no-standin.sh`, now in CI, finds no stand-in symbol or string in any release binary.
- **No networking code anywhere.** `tools/check-no-network.sh`, now in CI, fails if any source names a networking API.

## What is tested, and how

Commands, all run before the final commit:

```
swift build -c release                                     # passes, no warnings in new code
swift test                                                 # 82 test functions: 18 XCTest + 64 Swift Testing, all pass
FERNWICK_LAB=1 swift test --scratch-path .build-lab        # 84: adds the 2 stand-in tests, all pass
tools/check-spdx.sh && tools/check-signoff.sh && tools/check-no-network.sh && tools/check-no-standin.sh
FERNWICK_LAB=1 swift run -c release --scratch-path .build-lab fernwick-harness demo --origin 1440,0 --primary-height 900 --out OUT
swift run -c release fernwick-harness demo --models ../v3-detector/models/converted
```

| Area | Tests (target) | How |
|---|---|---|
| Detector rules, as built | 12 `RuleTests` (DetectorCoreTests) | Fake marker models; the lab build's own tests, unchanged |
| Detector additions | 5 `ContractTests` | Either covers one family's flag; a rule change empties the cache; a budget of 0 gives only `overload`, never `clear`; every entry names its pass; `find` matches the finder |
| Preprocessing | 1 `VectorTests` | 18 of 18 spec vectors bit-exact |
| Region-to-screen mapping across scales | `MappingTests` | 1x, 2x, 3x, a rotated portrait display, displays left of and above the primary (negative origins), and a letterboxed frame. Round trip within 1 detail pixel and never smaller. Retina halving, the Cocoa flip, the canvas layer space, outward snapping, refusing unusable metadata |
| Changed areas, window split, mailbox | `DirtyRegionTests`, `WindowSplitTests`, `MailboxTests` | Grid growth and merging, clipping; the front-most window gets the change; desktop areas go to the display surface; visible-area subtraction; a window across two displays; no changed area lost when frames are coalesced |
| A flagged region produces a cover window frame | `CoverLayerTests` | The real detector (fake marker models) and the real pipeline on a 2x display to the right of the primary. The flagged picture is covered, and the overlay window frame (Cocoa) and canvas layer frame are checked. Also: a clean screen draws nothing; the lift after 4 clean judgements; a reflag resets the count; containment is a blur (a plain cover under Either); overload never shows a picture sharp; covers follow a moving window and cover its old place once; covers are clipped by windows in front; the app's own windows are never judged |
| Fault to cover | `FaultToCoverTests` | Blank, suspended or stopped frames; missing metadata; a map that does not match the pixels; a stopped stream; a failed detector; judging behind; too many displays. Each covers the whole display, and the next judged frame lowers it |
| Practice-state signal | `PracticeSignalTests`, `PracticeMenuTests` | A fake folder: no keeper file means practice; a root-owned keeper file (release, lab, any case) ends it; a non-root file is not a keeper; similar names do not count; an unreadable folder or owner means not practice. The real `lstat` probe on a temporary folder, including a symbolic link. Pause is allowed only in practice. The menu says "no lock" |
| Model check | `ModelCheckTests` | Changed, missing and unlisted files and a malformed list are refused. The sealed list and table match the committed files. Locally only: the lab build's converted models match the sealed list |
| Wording | `AppTextTests` (FernwickCoreTests) | The promise matches the README word for word; no forbidden claim; the mode sentence carries no figure; strict cover mode says "not in this version" |
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
- **False covers through this pipeline on real screens.** The lab build measured its own pipeline; this repository has not re-run that measurement.
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
4. **Decide a detector discrepancy, with the second reader.** This build follows the lab build's latest commit, as instructed. Register SD-125 and correction C06-3 ask for four changes that are not made:
   - a flagged picture under 32 detail pixels should get `cover` (here it gets `contain`, a blur);
   - a dispute the tie-breaker could not answer should get `cover` (here `contain`);
   - a window should turn hot only after a both-family hit (here a tie-breaker-confirmed hit or a grid of low-level tiles also does);
   - the Either rule, which is now restored.

   The first three trade false covers against misses, and the lab measurements were made without them.
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
