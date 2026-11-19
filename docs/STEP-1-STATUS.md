<!-- SPDX-License-Identifier: Apache-2.0 -->
# Step 1 status: the cover-only app

14 November 2026, updated 18 November (speed work, ST-040 re-run) and 19 November (the way out). Built and tested on a developer Mac (Apple M1 Max, macOS 26.3, Swift 6.3.3) through tests and the lab harness only. **The app has not been run live on any Mac.** Running it needs the Screen Recording permission, which only the owner can grant, on a test Mac.

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
  - **Classes.** `cover` draws a plain, wordless cover over the whole picture region (a whole-window or whole-display cover carries the way-out line; see "Way out"). `contain` draws a strong blur of at most 6 colour cells; if the blur cannot be made, a plain cover is drawn instead. `clear` draws nothing.
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

    A repair card above the covers says why, in plain words, repeats the way-out shortcuts and offers Try again, Pause (in the practice state only) and Quit. Nothing ever locks the screen, logs anyone out or reports anywhere.
  - **Slowness covers more.** Unjudged entries stay blurred or covered and are judged again. When judging a window's new pictures would take longer than `COVER_GOAL` (0.1 s), they are blurred first and shown when cleared. A window still unjudged after 0.5 s is covered whole.
  - **Covers follow scrolling.** When content moves by a translation, its covers move with it at once, before the moved area is judged again; a cover moves only onto exactly the pixels it covered.
  - **Exact-match caches.** A picture already judged is not judged again when the same pixels come back (reload, scrolling back, a moved window); the finder's proposals are reused the same way. Clean verdicts are reused only on a full SHA-256 match of every byte, and only when they were clearly clean: every model scored the picture below half its cover cut-off (the margin rule, 19 November). A borderline-clean picture is judged again, with fresh jitter, each time it comes back.
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
- **The lab harness** (`safesightmac-harness`). It feeds image files or built-in synthetic scenes through the real pipeline without capturing the screen. It prints each cover's global rectangle, overlay window frame and canvas layer frame, and can write each frame with its covers drawn on it (the cover layer's own layers, rendered offscreen, in light or dark).
- **The lab stand-in.** A synthetic magenta-and-green checker that can only force a cover. It exists only in lab builds (`SAFESIGHTMAC_LAB=1`). `tools/check-no-standin.sh`, now in CI, finds no stand-in symbol or string in any release binary.
- **No networking code anywhere.** `tools/check-no-network.sh`, now in CI, fails if any source names a networking API.

## Way out (19 November 2026)

The owner's requirement: if pages get covered up, the user must be able to leave the page. Covers already let every click and key through to the app underneath (click-through, never key). But a big cover could hide the controls for leaving, and nothing said what to do. Now:

- **Whole-window covers leave the control band** (`WayOut.controlBand`). The top 92 points of an ordinary window stay in sight: title bar, tab strip and toolbar. That is a working value for ST-032; Safari, Chrome and Firefox keep their tabs and back button within about 80 points. Short windows keep at most a third of their height. Full-screen windows, the Dock, menus and the desktop picture keep no band.
  - Only the "cover the whole window" step leaves the band. Pictures in the band are still judged, and their covers and blurs are still drawn. A flagged slice that caused the whole-window cover is covered too, band included.
- **Whole-display covers leave the menu bar**, only while the window list shows one on that display (`WayOut.menuBarHeight`). A hidden menu bar (full-screen apps) stays covered, since that strip would show unjudged content. The Dock stays covered.
- **One plain line** sits on whole-window and whole-display covers: "Press ⌘W to close this tab, or ⌘[ to go back." (`AppText.wayOutLine`, checked by the words test).
  - It uses the system font on a small pill-shaped card, with the shortcuts drawn as rounded key caps.
  - It sits in the middle of a window's cover, or below the repair card on a display's cover.
  - A cover with too little room shows nothing, and a narrow one gets a smaller line. Picture covers stay wordless.
  - It is an image on a layer, so it cannot take a click.
- **The repair card** repeats the line. It never takes the keyboard (non-activating, key only if a view needs typing, and none does).
- **Look.** All colours and typefaces are in `CoverTheme`, light and dark. It follows the "desert" study (`DESIGN-desert.md` on the website branch), which the owner approved: lime plaster by day, lapis night by night, malachite for the one accent, gold only as a hairline.
  - Covers are a calm, opaque, flat neutral with no ornament: limestone `#e5e7e1`, or lapis-black `#121828` in dark mode. A system material would show what is under them.
  - The way-out line keeps the system font. Its key caps are plain neutral caps with near-black or near-white letters, on a pill in the card colour with a hairline edge.
  - The repair card and the "How it works" window use the theme's colours. Headings are in the system serif (New York) and the rest is in the system sans. Controls stay native, and Try again is malachite.
  - The arch appears only on the card's mark and on the panel holding the promise. One gold hairline sits inside the card's edge and one inside the promise panel.
  - Tested contrast: words and quieter words at least 7:1, key letters at least 7:1, the words on Try again at least 4.5:1.

Seen only in the lab, never on a real screen: `safesightmac-harness wayout` draws synthetic desktops with the cover layer's own layers and the card's own views, offscreen, and the "How it works" window from its own views. ST-032 still needs to check:
- the band on real apps;
- that macOS 26 lists the menu bar as assumed (if not, it stays covered);
- that menus opened from the menu bar fall under a whole-display cover (their shortcuts still work).

Found, not changed: a window is judged over the bounding box of its visible area, which can include a window in front of it. A flagged front window can therefore get the window behind it covered whole too (often the desktop picture). That covers more, never less.

## What is tested, and how

Commands, all run before the final commit:

```
swift build -c release                                     # passes, no warnings in new code
swift test                                                 # 152 test functions: 43 XCTest + 109 Swift Testing, all pass
SAFESIGHTMAC_LAB=1 swift test --scratch-path .build-lab        # 154: adds the 2 stand-in tests, all pass
tools/check-spdx.sh && tools/check-signoff.sh && tools/check-no-network.sh && tools/check-no-standin.sh
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness demo --origin 1440,0 --primary-height 900 --out OUT
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness wayout --out OUT --appearance light   # and dark
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness bench --models ../v3-detector/models/converted --pages ../v3-detector/data/finder-bench-heldout/screens --json FILE
swift run -c release safesightmac-harness falsecovers --models ../v3-detector/models/converted --list LIST --root ../v3-detector --rule balanced --json FILE
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
| Wording | `AppTextTests` (SafeSightMacCoreTests) | The promise matches the README word for word; no forbidden claim; the mode sentence carries no figure; strict cover mode says "not in this version"; the way-out line is word for word and its key caps rejoin to it |
| The way out | `ControlBandTests`, `MenuBarTests` (SafeSightMacWatcherTests); `WayOutLineTests`, `RepairCardTests`, `ClickThroughTests` (SafeSightMacCoverTests) | A whole-window cover never covers the control band; a flagged picture, a flagged slice and an unjudged picture in the band are still covered; full-screen windows and system surfaces keep no band; only the largest piece carries the line. A whole-display cover leaves the menu bar only while it is on screen, never more than a menu bar, and always covers the Dock. The line's words on whole-window and whole-display covers, inside the cover, in both appearances; none on picture covers or without room; the compact size; contrast; covers opaque and neutral. Cover panels are click-through, never key or main, out of window cycling, with no view to click; the repair card repeats the line and never takes the keyboard |
| Status line | `StatusTests` | "Needs Screen Recording", "Covering: on", a whole-display cover, pause and detector failure |
| Stand-in (lab builds) | `StandInTests` | The stand-in through the real detector with null models is covered and placed on a 2x display at a negative origin; null models alone cover nothing |
| Exact-match caches | 10 `CacheTests`, 8 `CleanCacheMarginTests` (DetectorCoreTests), `VerdictCacheInThePipelineTests` | The key is the full SHA-256 of every byte (all four channels), size, pass and bundle version; one changed byte in any channel is a new key; a picture one level different is judged again; a flagged picture drawn where a clean one was is judged afresh, with nothing from the cache, and is covered (cut-offs far below its score); a clean outcome is cached only when every model scored it strictly below half its cover cut-off for the band, and a score that is not a number never counts as below; a borderline-clean outcome and a dispute the tie-breaker declined are judged again, and can then be covered; covered outcomes are cached, under both rules; the cache refuses an outcome not marked cacheable; a moved picture comes from the cache; the cache never holds more than its bound and keeps what is used; cached finder proposals equal the finder's, at the same place and moved; a change inside the finder's reach is a new key; a reloaded page is not judged again and stays covered |
| Slice grid moved with the content | 3 `SliceGridTests` | No anchor gives the lab build's grid exactly; 300 random areas and anchors: every slice inside the area, the grid reaches both edges, steps of at most 384 (overlap at least 128), at most one slice more per axis; a scrolled view judges fewer tiles |
| Covers follow scrolling | `MotionTests` | Vertical and horizontal scrolls are found; nothing moved, another page and a blank page give none; the match is exact to one byte; a cover moves with its picture in a plan handed out before judging and reaches ahead along the motion, with no smear left behind; a cover whose picture did not move with the page covers both places; nothing is handed out when nothing scrolled |
| Faster order, never less judging | 4 `FastFirstTests`, `CoverFirstTests` | With or without the fast pass: the same verdicts, judgements and tiles per model, also under a tight budget; what is left is told after the finder, and once cached holds only what was not clearly clean; a fast flag is told but the tie-breaker still decides (it can clear it); under Either it is told as a cover; pictures nearest the pointer come first and the rest are left as overload, never clear. A busy page is blurred first and shown when cleared; a picture judged in time is not blurred first; a fast flag is blurred before the full rule covers; every early plan keeps every cover already shown; no early plan while a display is covered whole; the window under the pointer is judged first, and with no pointer the order is front to back |

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

### What the speed work changed (18 November 2026)

The hard rule for all of it: nothing judges or covers less. No model is skipped, no cut-off is raised, the cut-off table is unchanged, and only the full rule lifts a cover (after `VIDEO_VOTE` clean judgements, as before). Speed comes only from caching exact matches, moving covers, covering earlier and ordering.

- **Exact-match caches** (`VerdictCache.swift`, `FinderCache.swift`). The verdict cache's key is now the full 256-bit SHA-256 (it was cut to 128 bits) over fixed-width fields and every byte of the tile's pixels, all four channels, with its size, pass and bundle version. Preprocessing is a fixed function of exactly those bytes, so an exact match is an exact match of the preprocessed input. No approximate hash is used anywhere; a near copy is judged again. Memory is bounded: at most 65,536 entries, about 4 MB, in two generations close to least-recently-used (O(1); the lab build's eviction shifted a 50,000-entry array on every insert). New: the picture finder's proposals are reused when every pixel the finder can read (the area and up to `max(68, short side / 2 + 4)` pixels around it) is byte for byte the same, moved to the area's new place; at most 32 results.
- **Covers follow scrolling** (`Motion.swift`, `DisplayPipeline.followMotion`). Each changed part is checked for a vertical, else horizontal, translation from row hashes (the last frame's are kept, so each frame is hashed once; about 6 ms for a 2880 x 1800 window). A cover moves with its picture in a plan handed out at once, before the moved area is judged again, and only when the pixels at its new place equal the pixels it covered, byte for byte; otherwise its new place is covered as well as its old one. For this update each moved cover also reaches ahead along the motion as far as the content will go before the next plan (its speed times the recent longest judging run, at least 0.25 s). The slice grid now moves with the content (`SliceAnchor`): same slice size and overlap, at most one slice more per axis, so slices over content already judged come from the cache. Covers no longer smear into long streaks while a page scrolls.
- **Cover first on busy pages** (`DisplayPipeline`, `JudgeProgress.found`). After the finder and the caches, the detector tells the cover layer which picture regions are still to judge and about how long that will take. If the frame's time so far plus that estimate passes `COVER_GOAL` (0.1 s, the owner's goal; `TIME_TO_COVER` stays 0.5 s for the whole-window step), those regions are blurred at once, and shown when the full rule clears them. A picture that can be judged within the goal is not blurred first.
- **Order** (`Detector.judge`, `DisplayPipeline`). Hot windows first, as before; then the window under the pointer and those nearest it; within a window, pictures nearest the pointer first (otherwise smallest first, as before). Within one call the fastest model (by measured cost; NSFWJS here) now runs first over every picture region the call will judge, and a flag is shown at once as a blur (a cover under Either, where that flag alone covers) before the other model and the tie-breaker decide. The same entries are chosen within the same budget as before; tests check that the verdicts, the judgements and the tiles each model judges are the same with and without the fast pass.
- **Plans handed out early** reach the screen through `process(..., provisional:)`; the app draws them on the main thread as they come. Every early plan holds every cover the last plan held, plus every cover decided so far in the frame, and none is handed out while a display is covered whole.

### Measured after the speed work

Same bench, same machine, models, pages and settings. Results: `results/speed-after.json` (all four changes), `results/speed-after-caches.json` (the caches alone) and `results/speed-after-scrolling.json` (caches and scrolling). "First cover" is the first plan with a cover or blur over the picture, counting the cover layer update; "full rule" is the final plan.

| Case | Before | After | Which change |
|---|---|---|---|
| One new picture, first cover (16-31 / 32-63 / 64-127 / 128+ px), median, worst | 58.5, 77.6 / 46.8, 53.0 / 50.7, 58.1 / 51.4, 67.4 ms | **2.6, 9.3 / 6.2, 8.3 / 6.0, 8.4 / 7.9, 10.2 ms** (64 of 64 covered) | fastest model first (see the caveat below) |
| One new picture, full rule's cover | 47 to 59 ms, worst 78 ms | 45 to 54 ms, worst 66 ms | unchanged, as it must be |
| 32-tile grid, first cover | 460 ms, worst 1,070 ms | **5.8 ms, worst 6.6 ms**; full rule 415 ms, worst 967 ms | fastest model first |
| Busy Retina page, stand-in first covered | 2.83 s, worst 3.01 s | **0.25 s, worst 0.33 s** | cover first |
| Busy page, harmless photos shown sharp before their first blur | 2.8 s, worst 3.0 s | 0.2 s, worst 0.3 s | cover first |
| Busy page, every harmless photo shown | 19.0 s (9.3 s with no budget limit) | 17.4 s (7.4 s) | caches |
| Scrolling, each judged frame (8 / 32 / 96 px a frame) | 1.33 / 1.18 / 1.50 s | 0.87 / 0.64 / 0.89 s | slice grid moved with the content |
| Scrolling, a covered picture in view: time exposed (most of it exposed) | 1.82 / 0.45 / 0.15 s (all of it) | **0.03 / 0.04 / 0.05 s** (12% / 47% / all, at the very start of the scroll) | covers follow scrolling |
| Scrolling, a picture scrolling into view: covered after it shows | 2.26 / 0.56 / 0.19 s | 1.65 / 0.61 / 0.08 s (0.15 s at 32 px with no budget limit) | not solved: it waits for the next judged frame |
| Reload of a judged busy page | 270 ms | **59 ms** | finder cache |
| Scrolling back to places seen before / to other places | 186 ms / 1.12 s | **50 ms / 519 ms** | finder cache / slice grid |
| Window moved, same content | 1.01 s | 1.07 s | none: the finder's reach takes in the new surroundings, and the uncovered strip is new |

- **The caveat on "first cover".** The early blur comes when the fastest model (NSFWJS) has run on the picture and flagged it. In the lab the stand-in's check, made right after NSFWJS has run, stands in for that flag. A real explicit picture gets that early blur only if NSFWJS flags it at its strict cut-offs (0.93 to 0.996); otherwise it is covered by the full rule, at 45 to 54 ms median and 66 ms worst in this bench. Both are under the 0.1 s goal here, before capture latency and display time, which only ST-031 can add.
- **The cost of covering first.** On the six busy pages, 580 picture regions a page (median; worst 947) were blurred first. Before, every photo on those pages was shown sharp, unjudged, for 2.8 s, then blurred or covered for load until judged; now they are blurred from 0.2 s. The time until every harmless photo is shown is unchanged by covering first: the judging budget and the whole-window step decide it.
- **Ordering.** The pointer did not help on these pages: photos near it were shown after 17.7 s with or without it, because once a window has had unjudged entries for 0.5 s it is covered whole. Judging the pictures nearest the pointer first left more entries for later in the first call (375 against 338, median), as nearer pictures were larger. Early fast flags on the busy pages, the stand-in's included: at most 1 a page without the pointer, up to 5 with it (median 0 and 1); the bench does not record whether any of them was a harmless photo, which would be blurred briefly until the full rule cleared it.
- **While scrolling**, up to 35% of the display was under covers or blurs at the worst moment (median 2.5 to 3.5%), from blurring new pictures first and from covers reaching ahead.

Still not measured: ScreenCaptureKit's capture latency and real display time (ST-031, test Mac, camera or capture device); energy and heat (ST-038, the Air); memory over a day with these caches (ST-039; the bounds are about 4 MB for verdicts and 32 finder results); how often a real flagged picture is flagged by the fastest model alone; scrolling inside part of a window, horizontal scrolling and zooming on real apps.

Where the time still goes, and what is left (none of it built): on a full-window change the finder (about 185 ms) and exact-match hashing (about 40 ms) come before any blur, so a busy page cannot be blurred within 0.1 s; pictures scrolling into view wait for the next judged frame; `JUDGEMENT_BUDGET` (40 a second) against about 1,100 judgements for a busy Retina page from scratch, and the whole-window step at 0.5 s of unjudged entries, decide how long busy pages stay blurred or covered. Each is for ST-038 or a later design decision.

### The clean-cache margin (19 November 2026)

Found: `testAFlaggedPictureNeverInheritsACleanVerdict` failed about 1 run in 20 to 40, here and on CI. In the failing runs the flagged picture was judged afresh, and jitter put the fake models' scores just under the test's cut-off. The cache's rule held; the test was checking jitter luck. But it showed a real gap. A borderline picture that jitter once pushed under a cut-off was cached as clean, and it stayed clean for as long as its pixels did not change. Before the cache, each judgement drew fresh jitter.

The margin rule (`VerdictCache.CLEAN_CACHE_MARGIN`, `Detector.judgeTask`):
- **What is cached.** A clean outcome is cached only when every model's top score for the task is below 0.5 of its cover cut-off for the task's size band. With the sealed table, that is below 0.38 to 0.45 for Marqo and below 0.47 to 0.50 for NSFWJS.
- **What is judged again.** Any other clean outcome is judged again each time its pixels come back, as before the cache. That includes a dispute the tie-breaker declined; the tie-breaker is asked again too.
- **Covers.** An outcome that covers is still cached, since reusing it only covers.
- **How it is decided.** The decision is made where the scores are. Only a `cacheable` flag leaves `judgeTask`, and the cache refuses any outcome without it.
- **Nothing judges or covers less.** The rule only makes caching stricter.

Why 0.5: it is a wide working margin, not a measured bound. How far jitter moves a real model's score has not been measured on this build. Raising it caches more and protects less.

Cost (`--cases reappear`, real models, same machine and pages, runs before and after alternated; medians, worst in brackets):

| Case | Before | After | Entries judged again |
|---|---|---|---|
| Reload of a judged busy page | 62, 61 ms (65) | **1.38, 1.47 s (2.32 s)** | 133 to 137 of about 635 entries (21%), 206 to 216 judgements; none before |
| Scrolling back to places seen before | 62, 50 ms (63) | 49, 49 ms (101) | none, before or after |
| Scrolling back to other places | 899, 535 ms (1,344) | 510, 541 ms (913) | the same 22 judgements before and after |
| Window moved, same content | 1.22, 1.06 s (2.66 s) | **2.81, 2.70 s (3.20 s)** | 400 judgements, the per-call cap, with 13 to 17 entries left for the next call; 58 before |

Results: `results/speed-clean-margin.json` (two runs each; the first "before" run was slower throughout, as the machine was busier).

- **Where the cost comes from.** On the six busy pages of harmless photos, about one entry in five scored at least half a cut-off on some model, so it is judged again every time it comes back.
- **Why scrolling back shows no cost.** The bench's scrolling page is synthetic texture, which the models score low. On real photo pages, scrolling back would cost about what a reload costs.
- **What is shown meanwhile.** Once judging them would pass `COVER_GOAL`, picture regions that are to be judged again are blurred as soon as the caches have been read. They are shown when cleared, which on a reloaded busy page takes about 1.4 s. Entries past the call cap stay blurred or covered.
- **The budget.** This bench has no budget limit. Under `JUDGEMENT_BUDGET` the extra judgements come out of the same 40 a second.
- **If the cost is too high** (nothing built): raise the margin, which caches more and protects less, or first measure how far jitter moves real scores and set the margin from that.

Found, not changed:
- **Containment cut-off.** The rule guards the cover cut-off only. A small picture (under 64 detail pixels, or under 128 in a hot window) whose score sat just under the containment `clean` cut-off is still cached as clean, so it is not blurred again. This matters most for Marqo at 16-31 pixels, where `clean` (0.28) is below the margin (0.45).
- **Copies in one frame.** Two entries with the same pixels in one call still share one judgement, as before, even when it was borderline. It is not reused in later frames.

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

- **The live app, end to end.** No ScreenCaptureKit stream has run, and no cover window has been drawn on a real screen. The menu, the repair card, the "How it works" window and both cover forms have not been seen on a screen (the harness draws covers, way-out lines and the repair card offscreen only).
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

- **Flashes.** In show-first mode every window is shown first and judged just after, so a picture can be seen for a moment before its cover. How long on a real display is not measured (ST-031). In the lab, from the frame to the cover layer, one new picture is covered within about 50 ms (worst 66 ms) and a busy page's new pictures are blurred after about 0.25 s; a picture scrolling into view can show for up to the time one judged frame takes (0.6 to 0.9 s on a Retina window). The owner's goal is about 0.1 s.
- **The catch rate is unmeasured.** Nobody knows how many explicit pictures this detector misses. The cut-offs are strict to keep false covers low, so Balanced may miss more, by an amount nobody has measured. No accuracy figure may be published (claims ledger).
- **False covers and blurs.** The detector covers some harmless things. The picture finder grows regions to a picture's edge, so a cover can spill over neighbouring text. Small pictures it is unsure about are blurred.
- **No lock and no shield.** This build can be paused or quit, and if it crashes or is quit, the screen is uncovered. At start, and when a display appears or wakes, the display is covered whole until its first judged frame (a few seconds when the models load).
- **Not judged:** the cursor, the brighter-than-white range of HDR displays, protected video (captured as black), sound and text, anything before login. Accessibility Zoom is not detected.
- **Load.** A busy screen judged from scratch exceeds the budget. Its new pictures are blurred first; unjudged 512-pixel slices are covered; after 0.5 s of unjudged entries the window is covered whole. A busy Retina page stays blurred or covered for 13 to 21 s at `JUDGEMENT_BUDGET` (6 to 8 s with no budget limit). A third display and beyond are covered whole.
- **Choices made where the register is silent or open.** Each is a working value tied to its test:
  - canvas window level: screen-saver level (ST-032);
  - cover colour: one calm neutral per appearance, in the theme type `CoverTheme` (the desert study);
  - the control band a whole-window cover leaves: 92 points (`WayOut.controlBand`, ST-032);
  - the room a cover needs around the way-out line: 24 points;
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
  - keyboard-focus priority (the pointer's window and the pictures nearest the pointer go first since 18 November; the front-most window comes before windows behind it);
  - matching a frame to the window list taken nearest its time (the list is read when the frame is judged);
  - the crash-loop breaker;
  - the heartbeat and the plain shield, which are not part of the practice state.
- **Models are compiled by Core ML at load,** into a temporary folder. Correction C06-14 forbids a compile fallback once models ship compiled; that is build work for the release bundle.
