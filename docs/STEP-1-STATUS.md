<!-- SPDX-License-Identifier: Apache-2.0 -->
# Step 1 status: the cover-only app

14 November 2026, updated 18 November (speed work, ST-040 re-run), 19 November (the way out; every display, one rule; the Testing edition; its first live run) and 20 November (a stricter clean cache: sticky, a quarter of the cut-off, three checks). Built and tested on a developer Mac (Apple M1 Max, macOS 26.3, Swift 6.3.3) through tests and the lab harness. **It has run live once, as the Testing edition in a disposable virtual Mac, and was unusable there** (see "The first live run"); the fixes are tested off the screen and still have to be seen live. It has not run on a physical Mac. Running it needs the Screen Recording permission, which only the owner can grant.

Step 1 is the practice state of the watcher shipped alone (register SD-223 (f)). It has no lock: no keeper, no root part, no plain shield, no installer, no updater, no login item. It can be paused or quit at any time, and it protects nothing against its own owner.

## What works

These parts are built, and each is exercised by tests or the harness:

- **The detector, vendored.** The kestrel lab build (from the project's detector lab, commit 49ecdd9) is in `Sources/Preprocess`, `Sources/RegionFinder` and `Sources/DetectorCore`, under Apache-2.0.
  - Its tests pass here: 12 rule tests, and the preprocessing spec's 18 of 18 vectors bit-exact.
  - It uses the lab build's current Balanced rule (agreement plus a tie-breaker) and its committed cut-off table (`models/thresholds.json`, `agreement+referee/1`).
  - Added for step 1: the Either rule, the caller's budget, the pass of each entry and a separate `find`.
  - Changed from the lab build, as SD-125 and C06-3 require: a flagged picture under 32 detail pixels is covered, not blurred; a dispute the tie-breaker could not answer is covered, not blurred; a window turns hot only after a both-family hit. Under Balanced it therefore no longer behaves exactly as the lab build.
  - No weights are in git. `tools/models/fetch_upstream.py` and `tools/models/pins.json` hold the pinned upstream hashes. At run time the models load from a local folder, and every file is checked against the hash list sealed in the build (`models/watcher-models.sha256`).
- **The capture layer** (`Sources/SafeSightMacCapture`).
  - One ScreenCaptureKit display stream for every judged display, at the source's full pixel size. It captures 8-bit BGRA in sRGB, with no cursor and no audio. The app's own windows are left out of capture.
  - The map from capture pixels to screen points is rebuilt from each frame's own metadata, and the scale is read, never assumed.
  - Only changed areas are judged, grown to the 8-pixel grid. A full pass runs every 30 s.
  - When judging is busy, frames are coalesced without losing any changed area.
  - Only the judged displays are streamed (the first `DISPLAYS_MAX` of the OS's list): a display past the limit stays covered whole and costs no capture memory.
  - Streams start and stop on request (`StreamScheduler`, with ScreenCaptureKit as its backend). Every request carries a generation number taken on the main thread when it is asked for, and every frame carries its stream's number, so a display change after the request outranks it however late its streams start. A start stops every older stream; a request overtaken by a newer start or a stop stops what it started; two streams never run for one display (the newer is kept). Every stream that ends is reported with its number, whether stopped on purpose or by itself, so no display keeps a plan whose stream is gone. A display with no stream (ScreenCaptureKit did not list it yet, or its stream stopped) is retried after 1, 2 and 4 s, without touching the other streams. Pausing stops the old streams without waiting: anything they still send is outranked when covering starts again.
  - A frame that cannot be read goes through the same mailbox as the others, so it is acted on in order.
- **The cover layer** (`Sources/SafeSightMacWatcher`, `Sources/SafeSightMacCover`).
  - **Show-first.** Changed areas are split by window, and each window gets one judge call with its own context and its share of the judging budget.
  - **Classes.** `cover` draws a plain, wordless cover over the whole picture region (a whole-window or whole-display cover carries the way-out line; see "Way out"). `contain` draws a strong blur of at most 6 colour cells; if the blur cannot be made, a plain cover is drawn instead. `clear` draws nothing.
  - **Placement.** Covers are clipped to the window's visible part, move with their window, and cover the old place for one update after a move.
  - **Lifting.** A cover lifts only after 4 clean judgements in a row of that region (SD-230).
  - **Every display, one rule** (`Displays.swift` in the watcher and in the cover layer). Every display the OS lists (AppKit's screens and CoreGraphics' active list) gets a canvas, covered whole from the moment it is listed, before any capture stream exists for it. ScreenCaptureKit's list can add a display; it never takes one away. A cover comes down only for a plan judged on a frame from a stream started after that display's last change, made for the display's current bounds. Mirrors get no canvas, no judged place and no stream of their own: a display that repeats another (`CGDisplayMirrorsDisplay`) shows its source's composited picture, covers included, whether CoreGraphics lists it as active (software mirroring, where the window system draws the same windows into each display of the set) or only as online (hardware mirroring). The relationship counts only when the display shares its source's place in global coordinates (the same origin, or inside its bounds): one CoreGraphics says is a mirror but placed elsewhere (a stale value around un-mirroring) keeps its own canvas. Any doubt means a canvas. The judged displays are the first `DISPLAYS_MAX` of the OS's list, main display first; the rest are covered whole whatever the capture layer reports.
  - **Display changes** (SD-112). CoreGraphics' reconfiguration callback is registered at launch. On its begin call every display is covered whole on the main thread and pushed to the screen at once (before the callback returns, when macOS makes the call on the main thread, where it was registered); no plan lowers a cover until the change is done. After the change the OS's lists are read again, a canvas is made at once for each new display, and capture restarts once the change has been quiet for 0.2 s. Sleep, display sleep and a session switch hold every cover the same way, each until its own counterpart (wake, display wake, return), so a display change while the Mac goes to sleep does not end the sleep hold. The lists are also read again at every drawing and four times a second, so a change nobody announced is covered like one. A plan judged on a frame from before the change, even one that was being judged while the change happened, is refused, and its frame is never counted as judging the display. The first frame of a new stream is judged whole.
  - **Canvases.** One click-through panel per display, with every change applied in one transaction. Per-window overlays are the written fallback (`SAFESIGHTMAC_COVER_FORM=overlays`).
  - **Faults lead to more covering.** A display is covered whole when:
    - it has not been judged yet, or not since its last change;
    - the OS lists it but no stream runs for it (ScreenCaptureKit cannot see it): for as long as that lasts;
    - a frame is blank, suspended or stopped;
    - metadata is missing or inconsistent;
    - its stream stops (frames of that stream still waiting never lower the cover);
    - the models fail their check, including on displays attached later;
    - judging stalls for more than 5 s, or a frame has waited more than 5 s to be judged;
    - it is past `DISPLAYS_MAX` (2), counted from the OS's list;
    - macOS announces a display change; a display is attached, removed, moved, rotated, mirrored or changes mode; the main display changes; the Mac or its displays sleep; or the session switches.

    A repair card above the covers says why, in plain words, repeats the way-out shortcuts and offers Try again, Pause (in the practice state only) and Quit. Nothing ever locks the screen, logs anyone out or reports anywhere.
  - **Slowness covers more.** Frames are judged one at a time, every display in turn, so a display whose screen never stops changing (a video, an animation) cannot keep another display's frames waiting. Unjudged entries stay blurred or covered and are judged again. When judging a window's new pictures would take longer than `COVER_GOAL` (0.1 s), they are blurred first and shown when cleared. A window still unjudged after 0.5 s is covered whole.
  - **A model failure is never clear** (19 November). A model has failed for an entry when it throws, or when any of the entry's scores is not a number, infinite, negative or above 1 (0.001 over 1 is allowed for rounding; `Detector.usable`). One bad score among an entry's pieces is enough, since the highest of the rest could look clean. Before, a score that was not a number read as "not flagged", so the picture was shown.
    - The entry is left unjudged, as for any fault: picture regions in show-first windows are blurred, everything else is covered, it is judged again, and a window still failing after 0.5 s is covered whole. Nothing of it is cached. A picture the fastest model failed on is not tried again in the same call.
    - A tie-breaker that fails has not answered, so its dispute is covered (SD-125).
    - Each failure is counted per model: `Detector.modelFaults`, `FrameVerdict.modelFaults`, and the bench and false-cover records. Nothing trips on the count yet: this build has no run-time model self-check. SD-244's self-check pack and model ladder are not built, and SD-223 (d) leaves the fault ladder out of the practice state.
  - **Covers follow scrolling.** When content moves by a translation, its covers move with it at once, before the moved area is judged again; a cover moves only onto exactly the pixels it covered.
  - **Exact-match caches.** A picture already judged is not judged again when the same pixels come back (reload, scrolling back, a moved window); the finder's proposals are reused the same way. Clean verdicts are reused only on a full SHA-256 match of every byte, and only when they were clearly clean three times in a row (the margin rule, 19 November, made stricter on 20 November): every model scored the picture below a quarter of its cover cut-off, and, where a blur can apply (a small picture in a hot window or a covered-start context), below a quarter of its containment cut-off too. A picture judged borderline even once is never remembered as clean while the cache holds it, and is judged again, with fresh jitter, each time it comes back. This narrows the gap measured in "How far jitter moves real scores" but does not close it for certain (see "The default since 20 November 2026").
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
- **The Testing edition** (19 November), the only build offered to volunteer helpers: this app built with `SAFESIGHTMAC_TESTING=1` and assembled with `tools/make-app.sh --testing`. No keeper check; quit any time, also with ⌃⌥⌘Q; runs only inside the App Sandbox; one click removes its own data; and "Testing edition: no lock. Quit any time with ⌃⌥⌘Q." on its menu bar item, menu, covers, repair card and "How it works". `tools/check-testing-edition.sh` and `tools/check-covers-vanish.sh`, both in CI, check it. See [TESTING-EDITION.md](TESTING-EDITION.md).
- **The lab harness** (`safesightmac-harness`). It feeds image files or built-in synthetic scenes through the real pipeline without capturing the screen. It prints each cover's global rectangle, overlay window frame and canvas layer frame, and can write each frame with its covers drawn on it (the cover layer's own layers, rendered offscreen, in light or dark).
- **The lab stand-in.** A synthetic magenta-and-green checker that can only force a cover. It exists only in lab builds (`SAFESIGHTMAC_LAB=1`). `tools/check-no-standin.sh`, now in CI, finds no stand-in symbol or string in any release binary.
- **No networking code anywhere.** `tools/check-no-network.sh`, now in CI, fails if any source names a networking API.

## Way out (19 November 2026)

The owner's requirement: if pages get covered up, the user must be able to leave the page. Covers already let every click and key through to the app underneath (click-through, never key). But a big cover could hide the controls for leaving, and nothing said what to do. Now:

- **Whole-window covers leave the control band** (`WayOut.controlBand`). The top 92 points of an ordinary window stay in sight: title bar, tab strip and toolbar. That is a working value for ST-032; Safari, Chrome and Firefox keep their tabs and back button within about 80 points. Short windows keep at most a third of their height. Full-screen windows, the Dock, menus and the desktop picture keep no band.
  - Only the "cover the whole window" step leaves the band. Pictures in the band are still judged, and their covers and blurs are still drawn. A flagged slice that caused the whole-window cover is covered too, band included.
- **Whole-display covers leave the menu bar** of the main display's mirror set only (the main display, and any display it repeats or that repeats it while sharing its place), and only while the window list shows one there (`WayOut.leavesMenuBar`, `WayOut.menuBarHeight`). A hidden menu bar (full-screen apps) stays covered, since that strip would show unjudged content. Every other display's menu bar is covered with the rest of it: the macOS 26 menu bar is see-through, so on a display covered for a long time (past `DISPLAYS_MAX`, or one that cannot be captured) the strip would show unjudged content for as long as the display is attached. The Dock stays covered.
- **One plain line** sits on whole-window and whole-display covers: "Press ⌘W to close this tab, or ⌘[ to go back." (`AppText.wayOutLine`, checked by the words test).
  - It uses the system font on a small pill-shaped card, with the shortcuts drawn as rounded key caps.
  - It sits in the middle of a window's cover, or below the repair card on a display's cover.
  - A cover with too little room shows nothing, and a narrow one gets a smaller line. Picture covers stay wordless.
  - It is an image on a layer, so it cannot take a click.
- **The repair card** repeats the line. It never takes the keyboard (non-activating, key only if a view needs typing, and none does).
- **Look.** All colours and typefaces are in `CoverTheme`, light and dark. It follows the "desert" study (`DESIGN-desert.md`), the look chosen for the product: lime plaster by day, lapis night by night, malachite for the one accent, gold only as a hairline.
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

## Found in the Testing edition's safety pass (19 November 2026)

These of the safety pass's fixes ([TESTING-EDITION.md](TESTING-EDITION.md), "The safety pass") change this app too:
- **Compiled models no longer pile up, and Core ML's cache no longer grows.** Core ML compiled each model package into the temporary folder at every start and never removed the copy: about 220 MB a start (144 copies, 9.1 GB, had piled up on the developer Mac from lab runs). Its own cache, filed under the compiled model's path, then grew by about 200 MB a start too (found by the second independent review). Now `tools/make-app.sh` compiles the models into the app (`xcrun coremlcompiler`), with `compiled.sha256` tying them to the sealed hash list, and the app never compiles. The harness, lab builds and tests compile each package once, to `<Caches>/<owner>/compiled-models/<hash>/` (`CompiledModels`), and load that path every time. Measured over three harness starts: the cache went 206, 412, 618 MB before, and stays at 206 MB now.
- **The repair card sits on a display that is covered whole.** With a third display covered for good (`DISPLAYS_MAX` is 2) it sat in the middle of the main display and never went away.
- **It never starts by itself.** `disableRelaunchOnLogin()`, so "Reopen windows when logging back in" (and the restart after a macOS update) does not open it again, and none of its windows keeps saved state.
- **`tools/make-app.sh` never builds a lab app,** even when `SAFESIGHTMAC_LAB` is set in the shell.
- **Accepted: it no longer comes back through "Reopen windows when logging back in"** after a restart, a macOS update included. That is the point of the change above; a person who wants it at login adds it to Login Items. Recorded here at the review's request.
- **"How it works" shows every paragraph whole.** A line that only just fitted when measured could wrap when drawn on a Retina display, and the paragraph's last word was cut off. Paragraphs are now measured with room for that line (`HowItWorksPageTests`).

## The first live run (19 November 2026)

The Testing edition ran for the first time on 19 November, in a disposable virtual Mac (Tart, macOS 26.6.2, 1024 by 768 points at 2x, no Neural Engine: judging took 250 to 470 ms a frame against about 50 ms in the lab). On a still, harmless desktop nearly everything stayed blurred or covered for minutes, the covers flipped between a whole-display cover and blurs about 20 times a second (274 to 292 screen changes in 15 seconds with the app on, none with it off), it used about 150% of a core, two to four Testing lines were drawn stacked, the repair card's buttons were cut off, the report said "Frames with a cover or blur: 0" over a covered screen, and while the screen locked the desktop was in sight for a moment. A reproduction later the same day, with the same build, gave the same picture (274 screen changes in 15 seconds, 152% of a core, three stacked lines).

**Reproduced off the screen.** `safesightmac-harness static` (lab builds) feeds one harmless screenshot of that desktop, taken in the virtual Mac, through the real pipeline and the real models as a still screen, on a judge slowed down to the virtual Mac's speed. Nothing captures the developer Mac's screen. With the code that ran live the desktop never settled, even at the developer Mac's full speed: after 90 seconds 234 covers were still drawn, the same ten judgements a frame going to the same few pictures, and 578 entries left unjudged every frame.

**What was wrong, and what changed:**
- **The budget was spent on the same pictures for ever.** The desktop had 377 places the picture finder takes for pictures (icons, text, widgets). Pictures judged clean but close to a cut-off are never kept in the verdict cache (the margin rule), so every look at them costs the budget again. Judging went in a fixed order, front window first and the same pictures first, so with 40 judgements a second (`JUDGEMENT_BUDGET`) the menu bar's borderline pictures took everything every frame and the rest of the screen stayed unjudged, and so blurred or covered, for ever (`Detector.judge`, `DisplayPipeline.run`). Now entries never judged go first and entries judged before take turns, oldest first; windows with nothing new take turns too; and an entry too dear for one frame (a long, thin menu-bar strip's whole pass costs about 40 judgements) has the budget saved up for it, one such call at a time, in turn: a quarter of what comes in is set aside for the first in line, which no other call can spend and which stops no other call (added later: at first the calls before it in a look spent the saving, see "A still screen" below). A picture judged clear before on exactly the same pixels, and not reached again yet, is shown as judged (`Reason.judgedEarlier`) instead of being blurred again as unjudged; it never counts as a fresh judgement, it is never used for an entry a model failed on, nor for a small picture in a window that turns hot in that call, and it never applies where a blur rule applies. It would not apply where a window starts covered or in video either, but the Mac app has neither yet (every window is show-first and nothing is judged as video), so those two exclusions do nothing today. After 30 seconds such an entry is due again, which only puts it first among entries judged before: nothing looks at a still screen again once nothing is left to judge, so a picture shown clear stays shown until the screen changes. The full re-judge on the `FULL_REJUDGE` rhythm happens at any look, a look at a still screen included (while covers wait to lift, say), but no look is made once nothing is left to judge. At a still screen, a window that such a look has no time or budget for is judged at the next looks and shows what was judged before, unchanged, meanwhile, for at most `JUDGING_STALL`; it is not blurred for want of time. That holds only at a look at the last frame, with the window list exactly as at the last look, for a window seen before, not moved and not hot, with nothing in it left unjudged; anything else (a window that moved, opened or turned hot, work left over, anything new) is blurred until judged, as before. Re-judging due entries on a still screen was left out: on a slow Mac it would cost a quarter of the budget all the time.
- **A cover could only lift in one call that judged everything over it.** A cover lifts after four clean judgements of every pixel it hides (SD-230). When no single call could afford every entry over a cover, it never lifted. Clean judgements now gather over several calls: a cover's count goes up each time every entry over it has been judged clean (freshly, or from the exact-match cache) since the last count; a flag starts it again, an entry only shown as judged earlier never counts, and a judgement of an entry made before a change that touched it no longer counts. A change under a cover starts its count again (found by the independent review: new content left unjudged kept the old count): only judgements of what it hides now count. Under a cover, every new frame's pixels are compared with the last judged frame's, whatever the capture reports (its reported areas can miss a change): pixels that differ start the count again, and a change reported where the pixels are the same does not. So a cover over content that keeps changing, a playing video say, lifts once the content has been still for four clean judgements, not while it plays. With budget for everything in one call this is exactly one count per call, as before. Every cover is judged on its own, over exactly what it hides, so the entries over it stay the same from call to call; overlapping covers share what is judged; at most one count per cover per frame.
- **Covers grew.** Covers for entries left unjudged were merged into the union of what they overlapped, and every merge started the count again, so 512-point slice covers grew into a cover of the whole window that could never lift. Now such a cover goes into one that already holds all of it (count kept) or stands alone. The whole pass is judged right after the first picture, so it is seldom left unjudged (left unjudged it covers the whole call area).
- **Nothing was judged on a still screen.** A still screen sends no frames, so covers waiting to lift were never judged again. The watcher now asks for a look at the last frame itself (an idle frame, every quarter second) while something is left to judge, and stops when nothing is.
- **Blurring first on every frame.** Large-part blurs and "cover first" blurs fired on every frame, re-judges included, because a slow Mac is always slow, so early plans blurred what the final plan showed. They now apply only to what the frame shows changed; a full re-judge or a cover judged again blurs nothing first.
- **The window server's indicator counted as another app's window above the covers.** The screen-recording indicator in the menu bar and, in a virtual Mac, the pointer are the window server's own windows at the cursor's level, above every cover; any cover touching them made the final plan "covered whole" while early plans skipped the check, so the display alternated many times a second (`DisplayPipeline.swift`, `WindowList.swift`). Windows at exactly the cursor's level, at most 64 points a side, owned by a process running as the window server's own user (`_windowserver`, read from the kernel's process table and the user list, never from a name) are not counted; any other window there, an app's raised to that level included, still covers the display. Early plans now go through the same check as final ones. Inside the sandbox the lookups work (the lab log in the virtual Mac read the window server's user as 88).
- **The app judged its own effect.** On macOS 26 the menu bar item seems to be drawn by the system's menu bar, not in a window of the app's (the window list shows none of the app's own in the menu bar), so the capture sees it; it was redrawn at every cover update, and its symbol changed whenever a display was covered whole. That the covers themselves are left out of capture could not be confirmed with a frame counter, because the second live run did not get that far. It is now redrawn only when its symbol or status changes, and the cover canvas is not redrawn for an update that draws exactly the same.
- **Unjudged work was asked for again over a different area.** The finder proposes pictures within the area it is given, so a different area gave different pictures, new and unjudged. Work left over is now judged again over the same area.
- **One Testing line per display; the repair card shown whole; the lock screen** (canvases stay covered whole, below the lock screen's level, until the lock screen is seen over every display, 10 seconds at most); **the report counts what is drawn.** See [TESTING-EDITION.md](TESTING-EDITION.md).

**Tests** (`LiveRunTests`, and in `TestingLineTests`, `TestingCardTests`, `CoverCoordinatorTests`, `TestingReportTests`), each failing on the code that ran live: a still screen on a slow judge (2 ms a judgement against a 40 ms frame limit, the register's budget, a menu bar in front) settles to nothing drawn, early plans included, and stays so with nothing left to judge (83 covers for ever before); clean judgements gather over calls and a flag starts them again; the window server's indicator does not cover the display and an app's window at the same place does; early plans are checked like final ones; every entry is judged in turn and "judged earlier" is shown, never in a covered-start window; a flagged picture on a still screen stays covered. Later, `StillScreenSettlesTests` (a fake judge with the detector's order of work and costs), the first two failing on the code before the fix: the menu bar's dear whole pass is judged while the desktop still has work; desktop covers held for one dear line of text lift and the looks stop; a cover needing about 1,000 entries a round still lifts, after four whole rounds and no sooner; a flagged picture stays covered; a model failure mid-round blocks the lift; a change under a cover starts its count again. After a second review: at a still look with no time for it, a window that moved, opened or turned hot, and work left over, are blurred (the first three failed on the version before); a window left without budget is blurred after `JUDGING_STALL`; every full pass judges every window again with budget within 5 s. After the first review: a busy window elsewhere starves neither pictures left unjudged by a model failure, nor a flagged picture's checks, nor the cover saving up; a due flagged check gets budget while a cover saves up; the turns skip no cover; full re-judges at a still screen do not flicker. Each of these failed on the first version.

**Off the screen, on the real desktop's screenshot** (real models, judge slowed by 10 ms a judgement, the register's budget): see "The first live runs" in [TESTING-EDITION.md](TESTING-EDITION.md) for the numbers. **Live:** the second run in the virtual Mac is still to be done (it stopped at the Screen Recording permission, which needs the owner's password: see there).

## The third live run (20 November 2026)

The lab Testing build of `b761203` in the virtual Mac, after the owner gave it Screen Recording (the grant survived the in-place update, because the build is signed there with a signing identity of the virtual Mac's own). On a still desktop it never settled: about 18 frames a second reached the app, every one reporting the whole display as changed, each judged whole; 1,100 to 1,800 covers and blurs stayed up (the whole display hidden) for the 7 minutes measured, at 120 to 170% of a core. The frames followed the app's own drawing: every update of its covers, which are left out of capture, still brought a frame that said "everything changed" (a virtual Mac's display reports the whole frame), and the pixels were the same.

What changed is now read from the pixels: the capture compares each complete frame with the stream's previous one, block by block, and a frame in which no pixel changed is a "nothing changed" frame. A "nothing changed" frame also no longer erases what a frame waiting to be judged changed (merging them said "everything changed"). With that build the same desktop settled to nothing drawn in about 5 minutes, and then the app used 0.1 to 0.5% of a core, with a short burst of background second checks every 30 seconds or so. A real change on screen afterwards (a window's content) brought covers back over that window for a few minutes while it was judged again. The report now says "nothing drawn" while every canvas is off the screen (it said "covered whole" at the lock screen).

Found and not changed (see the run's notes): an authorization prompt (`SecurityAgent`) is drawn at level 1000, under the covers' level, so while a display is covered it is hidden until judged; ⌃⌥⌘Q was reported as not registered in that run; the repair card stays ordered in, under the lock screen, while the screen is locked; capture keeps running (and comparing frames) at the lock screen.

## What is tested, and how

Commands, all run before the final commit. `MODELS_DIR` is a folder holding the three converted Core ML model packages that match `models/watcher-models.sha256`, and `LAB` is the project's detector lab. The lab is a separate repository that isn't public yet: it converts the pinned upstream models (which `tools/models/fetch_upstream.py` downloads, checking every byte) to Core ML, and holds the harmless test screens. Until it is published, the commands that name `MODELS_DIR` or `LAB` can't be rerun from this repository alone; their results are in `results/`.

```
swift build -c release                                     # passes, no warnings in new code
swift test                                                 # 411 tests pass (80 XCTest, 331 Swift Testing)
SAFESIGHTMAC_LAB=1 swift test --scratch-path .build-lab        # 416 (83, 333)
SAFESIGHTMAC_TESTING=1 swift test --scratch-path .build-testing  # 401 (80, 321)
tools/check-spdx.sh && tools/check-signoff.sh && tools/check-no-network.sh && tools/check-no-standin.sh
tools/check-testing-edition.sh && tools/check-covers-vanish.sh
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness demo --origin 1440,0 --primary-height 900 --out OUT
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness wayout --out OUT --appearance light   # and dark
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness displays --out OUT --appearance light # and dark
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness bench --models MODELS_DIR --pages LAB/data/finder-bench-heldout/screens --json FILE
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness bench ... --cases reappear --json FILE      # the clean-cache cost
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness bench ... --cases reuse [--no-background-checks] --json FILE  # two clean checks
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness jitter --models ... --list ... --json FILE  # see "How far jitter moves real scores"
swift run -c release safesightmac-harness falsecovers --models MODELS_DIR --list LIST --root LAB --rule balanced --json FILE
swift run -c release safesightmac-harness demo --models MODELS_DIR
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
| Model failures | 7 `ModelFaultTests` (DetectorCoreTests), `ModelFaultPipelineTests` | Scores that are not a number (either sign), infinite (either sign), negative, above 1 or the largest float are failures: the picture is blurred (covered in a covered-start context), every other entry covered, nothing clear or cached, each failure counted per model, and the picture is judged again and shown once the model works. A model that throws is counted the same way. 0.001 over 1 is a flag, not a failure. One unusable score among an entry's pieces fails the entry, where the highest of the rest (0.1) would have looked clean. A tie-breaker whose score is unusable leaves the dispute unanswered, so it is covered. A picture the fastest model failed on stays unjudged in that call even though a second try would have worked. Through the cover layer: never shown sharp, the window stays covered while the model fails, and the covers lift only after `VIDEO_VOTE` clean judgements once it works again. With the check switched off, all but the throwing test fail |
| Practice-state signal | `PracticeSignalTests`, `PracticeMenuTests` | A fake folder: no keeper file means practice; a root-owned keeper file (release, lab, any case) ends it; a non-root file is not a keeper; similar names do not count; an unreadable folder or owner means not practice. The real `lstat` probe on a temporary folder, including a symbolic link. Pause is allowed only in practice. The menu says "no lock" |
| Model check | `ModelCheckTests` | Changed, missing and unlisted files and a malformed list are refused. The sealed list and table match the committed files. Locally only: the lab build's converted models match the sealed list |
| Wording | `AppTextTests` (SafeSightMacCoreTests) | The promise matches the README word for word; no forbidden claim; the mode sentence carries no figure; strict cover mode says "not in this version"; the way-out line is word for word and its key caps rejoin to it |
| The way out | `ControlBandTests`, `MenuBarTests` (SafeSightMacWatcherTests); `WayOutLineTests`, `RepairCardTests`, `ClickThroughTests` (SafeSightMacCoverTests) | A whole-window cover never covers the control band; a flagged picture, a flagged slice and an unjudged picture in the band are still covered; full-screen windows and system surfaces keep no band; only the largest piece carries the line. A whole-display cover leaves the menu bar only while it is on screen, never more than a menu bar, and always covers the Dock. The line's words on whole-window and whole-display covers, inside the cover, in both appearances; none on picture covers or without room; the compact size; contrast; covers opaque and neutral. Cover panels are click-through, never key or main, out of window cycling, with no view to click; the repair card repeats the line and never takes the keyboard |
| Status line | `StatusTests` | "Needs Screen Recording", "Covering: on", a whole-display cover, pause and detector failure |
| Every display, one rule | `DisplayListTests`, `DisplayCoverageTests`, `PipelineGenerationTests`, `FrameQueueTests`, `DisplayChangeTests` (SafeSightMacWatcherTests); `CoverCoordinatorTests`, `StreamSchedulerTests`, `CaptureLinkTests` (SafeSightMacCoverTests) | Faked OS display lists, synthetic frames, the real pipeline and detector (fake marker models), and a presenter that only records what it is asked to draw. Every display the OS lists gets a canvas, main display first; a screen missing from CoreGraphics' list, a display missing from AppKit's and one only ScreenCaptureKit lists are all covered, and the capture list never removes one; mirrors get no canvas and do not count toward the limit, whether CoreGraphics lists them as active or only online, unless their source is not listed; a mirror loop is covered, never left out; a display CoreGraphics says repeats another but placed elsewhere, or with bounds that cannot be read, keeps its canvas, its judged place and its menu bar's cover, while one inside its source's bounds (a hardware matte) is still a mirror; when the main display is a mirror, the display it repeats comes first; the limit is counted from the OS's lists, so a third display stays covered even when a plan for it arrives. At start every display is covered before any stream starts. The begin callback, called through its real C entry point, draws every display covered before it returns and pushes it to the screen; a display attached by the change gets its canvas at once, before capture restarts. A display attached while another display's frame is being judged: that judgement is refused, the frame still waiting from the old stream is not judged, and each display comes down only with its own first judged frame. A display the capture layer cannot see stays covered; a stream that delivers nothing keeps its display covered; frames of a stopped stream never lower its cover again, while a late report about an older stream, or from a start that lost the race, does not cover a display a newer stream is judging; a display removed and added back with the same identifier stays covered until judged again; a plan for old bounds is refused (rearranged, rotated, clamshell); a change nobody announced is found at the next drawing or tick; an announced change that never finishes ends after 3 s; sleep holds every cover until wake, and a display change while going to sleep does not end that hold; a display with no stream is retried three times; unreadable lists keep every display covered; a failed detector covers displays attached later; Try again keeps every cover up; a new stream's first frame is judged whole; frames of two streams never merge; a display that never stops changing cannot keep another waiting; a late frame from an older stream never replaces a newer stream's frame. A display only ScreenCaptureKit lists is a change when it alters the judged displays (it needs a stream), and not one past the limit. Sleep, display-sleep and session holds end without their notification once the OS says they are over (after 10, 2 and 2 s). Streams on request, with a fake capture backend whose gates hold a request part-way: a start streams only the displays asked for, with the request's generation, and stops and reports every older stream; requests older than the newest start are ignored; a top-up only adds missing streams; every display not listed, or not listable, is reported with the request's generation; a start overtaken while it opens a stream stops and reports it; two requests for one display keep the newer stream; a stream that stops by itself, even before it is kept, is reported once and never kept; nothing starts after a stop. Through the app's own link between the coordinator and the scheduler: a restart asked for before a display change but starting its streams after it never shows their frames, and a display the next restart cannot start is covered, never left showing an old plan; pausing and covering again never shows a plan from the old streams or an old request. Only the main display's mirror set leaves its menu bar under a whole-display cover (`MenuBarTests`) |
| Jitter measurement (lab builds) | 3 `LabJitterTests` (DetectorCoreTests) | The entries measured are the first call's entries; each is judged the asked number of times, one judgement per piece per draw, with fresh jitter; batched scores equal one-at-a-time scores; a model that fails is left out, never read as a score |
| Stand-in (lab builds) | `StandInTests` | The stand-in through the real detector with null models is covered and placed on a 2x display at a negative origin; null models alone cover nothing |
| Exact-match caches | 10 `CacheTests`, 12 `CleanCacheMarginTests` (DetectorCoreTests), `VerdictCacheInThePipelineTests` | The key is the full SHA-256 of every byte (all four channels), size, pass and bundle version; one changed byte in any channel is a new key; a picture one level different is judged again; a flagged picture drawn where a clean one was is judged afresh, with nothing from the cache, and is covered (cut-offs far below its score); a clean outcome counts towards the cache only when every model scored it strictly below half its cover cut-off for the band, and is reused only after two such judgements in a row; a borderline-clean outcome and a dispute the tie-breaker declined are judged again, and can then be covered; a small picture just under its containment cut-off is reused where no blur can apply, and judged again, then blurred, in a hot window or a covered-start context; one settled for a blur is reused in a hot window too; in a call where the window turns hot, a reused small picture not settled for a blur is blurred, and judged again in the next call; a picture of 128 pixels or more and the whole pass are held to the cover cut-off only; covered outcomes are cached, under both rules; the cache refuses an outcome not marked cacheable; a moved picture comes from the cache; the cache never holds more than its bound and keeps what is used; cached finder proposals equal the finder's, at the same place and moved; a change inside the finder's reach is a new key; a reloaded page is not judged again and stays covered |
| Two clean checks | 16 `TwoCleanChecksTests` (DetectorCoreTests), 3 in `VerdictCacheInThePipelineTests`, 3 `SecondChecksInTheLooksTests` | One clearly clean judgement is kept as seen clean once and never handed back; the same pixels are judged again, and reused only after a second; a score at the margin, a flag or a model failure (full rule or fast pass) between starts the count again, and so does a score over the margin on an entry already reused; where a blur can apply both checks must be settled for it, counted apart; a picture seen clean once is not cleared in a call where the window turns hot, nor with no budget left; entries seen clean once are held within the same bound; a fake model scoring under half the cut-off, then over it (as measured on a harmless 64-127 px entry) is judged again and covered. In the background: only pictures seen clean once are judged, within the budget, nothing else; a flag covers and a failure is reported unjudged; through the cover layer, a still page gets its second checks with nothing judged in the foreground and nothing covered, a reload after that is served from the cache, a background flag covers at once, and with background checks off the second check waits for the picture to come back. With "judged earlier": with no budget left, a picture seen clean once is shown as judged earlier, never from the cache, and still waits for its second check; it is unjudged in a covered-start window; after a model failure it is neither shown as judged earlier nor one check along; it waits behind a picture never judged; in a window that turns hot in the call it is unjudged, not shown. As part of the looks: second checks keep the looks going only until their bound, after which a look does nothing; a change under a cover starts its count again, and in that test the cover lifts after the same number of looks with background checks or without (they are not counted directly; see above for the indirect way). After more than the bound of activity, the first still looks still give second checks, and the looks then stop. With `CLEAN_CHECKS` set to 1, all but three of them fail: one pins the start-again on a reused entry, which main also lacked; the other two are the looks' bound, which use a fake judge |
| Slice grid moved with the content | 3 `SliceGridTests` | No anchor gives the lab build's grid exactly; 300 random areas and anchors: every slice inside the area, the grid reaches both edges, steps of at most 384 (overlap at least 128), at most one slice more per axis; a scrolled view judges fewer tiles |
| Covers follow scrolling | `MotionTests` | Vertical and horizontal scrolls are found; nothing moved, another page and a blank page give none; the match is exact to one byte; a cover moves with its picture in a plan handed out before judging and reaches ahead along the motion, with no smear left behind; a cover whose picture did not move with the page covers both places; nothing is handed out when nothing scrolled |
| Faster order, never less judging | 4 `FastFirstTests`, `CoverFirstTests` | With or without the fast pass: the same verdicts, judgements and tiles per model, also under a tight budget; what is left is told after the finder, and once cached holds only what was not clearly clean; a fast flag is told but the tie-breaker still decides (it can clear it); under Either it is told as a cover; pictures nearest the pointer come first and the rest are left as overload, never clear. A busy page is blurred first and shown when cleared; a picture judged in time is not blurred first; a fast flag is blurred before the full rule covers; every early plan keeps every cover already shown; no early plan while a display is covered whole; the window under the pointer is judged first, and with no pointer the order is front to back |
| Compiled models | `CompiledModelsTests` (DetectorCoreTests), `CompiledModelCheckTests` (SafeSightMacWatcherTests) | A package is compiled once, to a place named after its contents, and that place is used again; a changed package gets a new place; when another run gets there first its copy is used; a failed compile leaves nothing; old staging is swept and fresh staging kept; a key that is not a plain name is refused (Core ML's compiler is faked). The app's compiled models pass only with the stamp of the sealed list, every package's compiled model and no changed or extra file; compiled models and packages are never mixed |
| The Testing edition | `EmergencyQuitTests`, `KeyLayoutTests`, `RemovalTests`, `SandboxTests`, `SingleCopyTests`, `StallWatchdogTests`, `TestingReportTests` (SafeSightMacTestingEditionTests); `TestingLineTests`, `TestingCardTests` (SafeSightMacCoverTests); the Testing tests in `AppTextTests` and `PracticeMenuTests` | ⌃⌥⌘Q as written and registered; a hot-key event sent to the app's own event target runs the quit and no other event does; a shortcut already taken is refused and the lines then name none; Q found on US, French, Belgian, German, Dvorak and Dvorak-QWERTY ⌘ layouts. Removal clears only a container's own data, its per-Mac (ByHost) settings included, never another app's container, never following a symbolic link (the files links point to stay), and outside a container only the settings. The sandbox needs both signs. A second copy is found. The watchdog quits only with a cover up, the main thread silent for 8 s and its own check on time. The line under the way out on whole-window and whole-display covers (both appearances, both cover forms), on covers hiding half a display, never in the release edition; the card's line; the card on a covered display. The words, word for word, and no forbidden claim. The report: its lines, the note, timings bounded to the last 5000, and nothing about what was on screen |

**Harness results** (lab build, null models, stand-in, an 800 x 500 point display at 2x, placed right of a 900-point-high primary):

1. A clean synthetic page: no covers.
2. The stand-in appears: covered (cover at x 1506.5, y 250, 253.5 x 160 points; overlay window y 490 in Cocoa points).
3. A 48-pixel stand-in appears: covered.
4. Both are removed: covered for 3 more clean frames, lifted on the 4th.
5. A blank frame: the whole display is covered.
6. The next frame: covers lowered.

With the real models (release build, read in place from the detector lab), the same synthetic page drew no cover. That is one page, not a measurement.

**Display scenes** (`safesightmac-harness displays`, lab build, null models and the stand-in, synthetic desktops drawn offscreen, through the real cover coordinator and pipelines; looked at in light and dark):

1. One display, judged: its stand-in is covered.
2. macOS announces a change: it is covered whole at once, its menu bar left in sight.
3. A second display is attached: it gets its canvas, covered whole with its menu bar, before any stream exists; a plan judged before the change arrives and is refused.
4. Capture restarts after 0.2 s of quiet; the first display's first judged frame lowers its cover; the second waits for its own.
5. The second display's first judged frame lowers its cover; its stand-in is covered.
6. A third display stays covered whole (past `DISPLAYS_MAX`), even when a plan for it arrives; the repair card on the main display says why.

## Speed: the measured chain (lab, 18 November 2026)

The goal is now about **0.1 s from a new picture appearing to its cover**, with no visible lag on busy pages (the register's `TIME_TO_COVER` of 0.5 s is too loose). The lab harness now times the chain: `SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness bench --models MODELS_DIR --pages LAB/data/finder-bench-heldout/screens --json FILE`.

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
- **Cover first on busy pages** (`DisplayPipeline`, `JudgeProgress.found`). After the finder and the caches, the detector tells the cover layer which picture regions are still to judge and about how long that will take. If the frame's time so far plus that estimate passes `COVER_GOAL` (0.1 s, the goal; `TIME_TO_COVER` stays 0.5 s for the whole-window step), those regions are blurred at once, and shown when the full rule clears them. A picture that can be judged within the goal is not blurred first.
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
- **What is cached.** A clean outcome is kept only when every model's top score for the task is below 0.5 of its cover cut-off for the task's size band. With the sealed table: below 0.38 to 0.45 for Marqo and below 0.47 to 0.50 for NSFWJS.
- **Where a blur can apply** (added later on 19 November). A picture region under 128 detail pixels in a hot window, or under 64 in a covered-start context, is blurred when a model scores it above its containment cut-off. There a kept clean outcome is reused only if every score was also below 0.5 of the containment cut-off, where that is lower (`VerdictCache.actionCutoff`, `TileOutcome.settledForBlur`). With the sealed table: below 0.14, 0.23 and 0.23 for Marqo (10-31, 32-63 and 64-127 pixels), and below 0.42, 0.46 and 0.43 for NSFWJS. Otherwise the picture is judged again, with fresh jitter. In a call where the window turns hot, such a picture is blurred until it is judged again. Before, a small picture just under its containment cut-off was cached as clean and never blurred again.
  - First built as "hold every small picture to the containment cut-off, in every window". That made a reload of a busy page judge 485 entries again instead of 133, past the per-call cap of 400 judgements, with 181 entries left blurred for a later call. In this build's show-first windows a blur can apply only in a hot window, so that cost bought nothing elsewhere. It is replaced by the rule above.
- **What is judged again.** Any other clean outcome is judged again each time its pixels come back, as before the cache. That includes a dispute the tie-breaker declined; the tie-breaker is asked again too.
- **Covers.** An outcome that covers is still cached, since reusing it only covers.
- **How it is decided.** The decision is made where the scores are. Only a `cacheable` flag leaves `judgeTask`, and the cache refuses any outcome without it.
- **Nothing judges or covers less.** The rule only makes caching stricter.

Why 0.5: it was a working guess. It is now measured (next section): half is needed for every model and band, and in some it is not enough. Raising it caches more and protects less.

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
- **If the cost is too high.** Measured since (next section): raising the margin anywhere would protect less than the measurement says is needed, so it stays at half.

Found, not changed:
- **Copies in one frame.** Two entries with the same pixels in one call still share one judgement, as before, even when it was borderline. It is not reused in later frames.

### How far jitter moves real scores (19 November 2026)

Half the cut-off was a guess. How far the deliberate jitter moves each real model's score is now measured, with `safesightmac-harness jitter` (`JitterSpread.swift`, `LabJitter.swift`). It runs only in lab builds, the only place a score leaves the detector. Results: `results/jitter-spread.json`.

```
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness jitter --models MODELS_DIR \
    --list LAB/results/private/tiles-heldout.txt --root LAB --draws 20 --per-band 2000 --background 500 --json results/jitter-spread.json
```

- **Pictures.** ST-040's set, the lab's 932 held-out harmless screens. No explicit image was used.
- **Models.** Marqo and NSFWJS, the converted models checked against the sealed hash list, and the sealed cut-off table. The tie-breaker is not measured: it is asked only about disputes, and a dispute is never cached as clean.
- **Method.**
  - Every entry of each screen's first call (finder regions, the whole pass and the slices: 108,738 entries) was judged once by each model, as the product judges it.
  - 18,195 of them were then judged 20 more times each, every time with fresh jitter on every piece and the top score over the pieces, as `topScore` does. Per model and band, the sample took up to 2,000 entries whose first score reached 0.35 of the entry's lowest action cut-off, and 500 per band at random. No model failed. The run took 66 minutes.
  - The scores were taken in batches. Batching was checked on its own: on the first screen's 40 entries, 8 draws each, batched and one-at-a-time scores were identical. Every run now checks this first.
- **Spread.** Per entry: the highest minus the lowest of its scores (its range), and the largest distance of a score from its median. Per model and band, both are taken over the borderline entries: those whose highest score reached half the entry's lowest action cut-off. Only their caching can change with the margin.

| Model | Band (px) | Borderline entries | Range: median, 99th, 99.9th percentile, largest | Distance from the median, 99.9th | Gap: twice the 99.9th range | Action cut-off; half of it |
|---|---|---|---|---|---|---|
| Marqo | 10-15 | 3,549 | 0.015, 0.049, 0.077, 0.106 | 0.048 | 0.155 | containment 0.278; 0.139 |
| Marqo | 16-31 | 2,663 | 0.013, 0.058, 0.084, 0.103 | 0.051 | 0.167 | containment 0.278; 0.139 |
| Marqo | 32-63 | 1,416 | 0.090, 0.318, 0.432, 0.517 | 0.302 | 0.864 | containment 0.461; 0.231 |
| Marqo | 64-127 | 1,555 | 0.099, 0.367, 0.616, 0.654 | 0.343 | 1.231 | containment 0.452; 0.226 |
| Marqo | 128+ | 372 | 0.282, 0.650, 0.731, 0.731 | 0.583 | 1.461 | cover 0.758; 0.379 |
| NSFWJS | 10-15 | 2,340 | 0.091, 0.378, 0.469, 0.553 | 0.338 | 0.938 | containment 0.831; 0.416 |
| NSFWJS | 16-31 | 2,132 | 0.087, 0.366, 0.514, 0.578 | 0.289 | 1.028 | containment 0.831; 0.416 |
| NSFWJS | 32-63 | 2,323 | 0.118, 0.519, 0.650, 0.722 | 0.504 | 1.299 | containment 0.926; 0.463 |
| NSFWJS | 64-127 | 3,114 | 0.129, 0.521, 0.714, 0.938 | 0.457 | 1.427 | containment 0.857; 0.429 |
| NSFWJS | 128+ | 798 | 0.276, 0.660, 0.817, 0.817 | 0.598 | 1.634 | cover 0.934; 0.467 |

- **The rule.** A cached clean score must sit below the entry's action cut-off by more than twice the spread. The spread is the 99.9th percentile of the borderline range (the largest, on fewer than 1,000 entries); no random borderline entry that the sample's selection could have missed had a wider range. The margin never protects more than before, so no level goes below half the cut-off.
- **What it says: half is needed everywhere, and it is kept.** In every model and band the gap is wider than half the cut-off. So the share stays 0.5 for every model and band: the measurement changes no level and wins no speed back.
  - For Marqo under 32 pixels the gap is only just over half (0.155 and 0.167, against 0.139). Under 34 pixels the jitter is the value noise alone, with no trim. That moves Marqo little, and NSFWJS almost as much as the trims do.
  - Where no blur can apply, only the cover cut-off acts on those small pictures, and Marqo's gap (0.155 and 0.167) is well under half of it (0.447). But their spread was measured near the containment cut-off, not near the cover cut-off, so nothing is loosened. Measuring it there is the one place this data leaves room.
  - Everywhere else the gap is wider than the cut-off itself. By the rule, no clean score is safely cached there at all.
- **Half is not always enough.** In 20 draws, 63 harmless borderline entries had one score under half their action cut-off and another at or over the cut-off: Marqo 8 (32-63 px), 26 (64-127) and 19 (128 and up), and NSFWJS 10 (64-127). No other model and band had one.
  - With the cache, such a picture is cached as clean when the score it happens to get is the low one. It is then not blurred or flagged again while its pixels stay the same. Without the cache, every judgement would draw again.
  - Closing this needs a rule stricter than half where it was crossed. That protects more than before, which this change was not to do, so it is the owner's call. It would cost speed: those bands hold most of a photo page's pictures, which would then be judged again on every reload.
  - The founder chose a second look instead of a stricter share (next section, "Two clean checks").
- **Limits.** Harmless pictures only, by design. How far jitter moves an explicit picture near a cut-off is not known, and it could be more. 20 draws per entry show less than its whole spread. The entries are tiles of these screens, not every kind of picture. Crossings were counted at each entry's lowest action cut-off; for a picture under 128 pixels that is the containment cut-off, not the cover cut-off that is the only one acting on it where no blur can apply.

Speed (`--cases reappear`, real models, the same machine and pages; medians over the six busy pages, worst in brackets). "Before" is commit 4a7c278: a clean outcome kept below half the cover cut-off. "Held everywhere" is the containment rule as first built (commit b265a82): every picture region under 128 pixels held to half its containment cut-off, in every window. "After" is this build: kept below half the cover cut-off, and below half the containment cut-off too where a blur can apply. The measurement changed no level. Results: `results/speed-clean-margin-measured.json`.

| Case | Before (3 runs) | Held everywhere | After |
|---|---|---|---|
| Reload of a judged busy page | 2.28, 1.42, 1.80 s (2.84) | 2.70 s (2.81) | **1.47 s (2.44)** |
| ... entries judged again, judgements, left for a later call | 129 to 134, 200 to 210, none | 485, 400 (the call cap), 181 | **135, 212, none** |
| Window moved, same content | 2.92, 2.83, 2.93 s (3.47) | 2.96 s (3.09) | **2.81 s (3.66)** |
| ... judgements, entries left for a later call | 400, 16 to 21 | 400, 321 | **400, 15** |
| Scrolling back to places seen before | 84, 55, 54 ms (141) | 61 ms (149) | 55 ms (79) |
| Scrolling back to other places | 626, 594, 581 ms (949) | 882 ms (1,131) | 546 ms (905) |

- **The cost of "held everywhere" was a bug, now fixed.** It judged most small harmless photos again on every reload, past the call cap, and left 181 entries blurred for a later call. One bench run took 21 minutes against 6. In this build's show-first windows a small picture can be blurred only in a hot window, so that work protected nothing anywhere else. "After" does the same work as before: 135 entries judged again on a reload against 129 to 134, and 15 left after a window move against 16 to 21.
- **Times.** The machine was shared with other work throughout (load averages 9 to 43), so times vary by up to a half between runs of the same build; the judgement counts do not. Earlier runs on a quieter machine gave 1.38 to 1.47 s for a reload and 2.70 to 2.81 s for a window move (above).
- **No speed is won back from the margin itself.** The measurement says half is needed. The reload still costs about 1.4 s against 62 ms with no margin at all, and a window move about 2.8 s against 1.1 s.

### Two clean checks (20 November 2026)

Founder decision: a picture is remembered as clean only after **two separate judgements, each with fresh jitter, both come out clean under the margin**. Zero workarounds comes before speed.

What is built (`VerdictCache.CLEAN_CHECKS`, `VerdictCache.put`, `Detector.judge`, `Detector.secondChecks`, `DisplayPipeline` step 3c):
- **Seen clean once.** The first judgement clearly under the margin is kept only as "seen clean once". It is never handed back as a clean verdict, and nothing is lifted or cleared on the strength of it. It can be *shown*: when a later call's budget does not reach it, it is shown as judged earlier, as main's display rule allows (next points).
- **The second check.** The next time the same pixels would have come from the cache, they are judged again with fresh jitter, like a picture the cache has never seen. Until then the picture stays as it is on screen. It waits behind entries never judged, with the pictures judged clear earlier, the longest ago first. If the call's budget does not reach it, it is shown as judged earlier where that display rule allows, and otherwise blurred or covered as unjudged (next point). It is never shown from the cache. A second clearly clean judgement makes the entry a cached clean verdict.
- **With "judged earlier".** Main's display rule (`Reason.judgedEarlier`, `Detector.seenClear`) shows a picture judged clear before on exactly the same pixels when a call's budget does not reach it again. It is not a cached verdict: it costs no judgement, the cover layer counts it towards no cover's lift, and it keeps all its own limits. It never applies in a covered-start window, in video, where a blur rule applies, for an entry a model failed on in that call, or for a small picture in a window that turns hot in that call. It is due again after 30 s.
  - A picture seen clean once is kept in `seenClear` too. Before, only clear judgements too near a cut-off for the cache were kept there.
  - It leaves `seenClear` at the second clean check, when the cache can hand it back, or at a flag.
  - A model failure takes it out of both, so after a failure it is neither shown as judged earlier nor one check along (`Detector.swift`, `cache.put` / `seenClear.put` and the `failed` loop).
  - So, between the two checks, the same picture can be shown (judged earlier) but never reused (cached). Only the cache's `get` hands back a verdict, and only after two clean checks.
- **Starting again.** Any of these between the two checks makes the count start from nothing:
  - a judgement at or over the margin;
  - a model failure, in the full rule or in the fast pass;
  - a flag. A flag is kept as a cover, as before.
  
  This also applies to an entry already reused if it is judged again somewhere a blur can apply.
- **Where a blur can apply.** The entry is reused there only if both judgements in a row were also under half the containment cut-off (`settledForBlur`). The two counts are kept apart, so a picture can be reused in a show-first window and still be judged again in a hot one.
- **In the background, as part of the looks at a still screen.** Main's watcher asks for another look at the last frame while the pipeline has something left to judge (`needsAnotherLook`). Pictures seen clean once count as something left, and each look gives them their second check after everything else in it (`DisplayPipeline`, step 3c; `Detector.secondChecks`).
  - It uses only judgements beyond half the display's bucket, within the frame's time.
  - The looks for them end when every one has had its check, or after 30 s of still screen (`secondChecksFor`, the full re-judge rhythm). The clock starts at the first look at a still screen, and any frame with new pixels stops it, so scrolling or a video playing before does not use it up. Looks never push it back, a full re-judge on a still screen included. One not given its check by then gets it when it comes back. A still screen then rests: no look, no judgement.
  - A clean background result only adds to the picture's count, and is not itself counted towards any cover's lift. Indirectly it can be: once its second check makes the entry reusable, a cover's own next check over it gets that entry from the cache, and a cache hit counts towards the cover's round, as main counts any cache hit. So a background check can bring a cover's lift sooner by one look. It never adds a vote the cover's own checks would not have given it. A flag covers at once. A model failure blurs the picture, as any fault does, and it is judged again. A picture that comes back before its background check is judged when it comes back, as above.
- **Unchanged:**
  - the share (0.5);
  - the cut-offs;
  - the cover and lift rules (four clean results to lift a cover);
  - the bound: entries seen clean once count towards the same 65,536 entries, about 4 MB.

Cost, measured with the lab bench's new `reuse` case (`safesightmac-harness bench --cases reuse`). Real models, the six busy pages of harmless photos. Each page or view is judged in full at the detector, in one call with no cap. That way the judgements reuse costs are counted exactly, with no cover-layer budget or time limit in the way. "Before" is main at 74c0462, after "Make the cover settle on a real screen" (#25). "On reuse" and "Background" are this branch merged with it. "On reuse" gives the second check only when the picture comes back (`--no-background-checks`). "Background" also gives it while the page is still, and that work is counted apart. Medians over the six pages. Counts are exact; times are noisy (the Mac was shared with other work). Results: `results/speed-two-checks.json`, which also holds the same runs against 73b6568.

| Case | Before | On reuse | Background (and its judgements) |
|---|---|---|---|
| First showing of a busy page | 1,082 judgements, 7.0 s | 1,082, 7.0 s | 1,082, 7.0 s |
| Reload of that page | **214**, 1.4 s | **1,082** (5.1x), 6.7 s | **234**, 1.4 s (776 in the background) |
| Window moved, same content | **162**, 1.1 s | **818** (5.0x), 5.1 s | **166**, 1.1 s (560) |
| Scrolling back to places seen before (all steps) | **4**, 0.3 s | **224**, 2.9 s | **12**, 0.4 s (368) |
| Scrolling back to other places (all steps) | **234**, 3.8 s | **326**, 5.0 s | **232**, 3.8 s (550) |
| Third showing | 208 | 236 | 234 |

- **Chosen: the background check, with the check on reuse behind it.** Doing the second check only when a picture comes back made a reload judge 5.1 times as much, and a window move 5.0 times. With background checks a reuse costs about what it did before. The extra judgements move to moments when the screen is still, out of the budget's spare half. Neither way ever shows more: a picture is cleared only on a real clean judgement, and reused only after two.
- **When there is no still moment** (a video playing on the same display, say), the background check does not run, and the cost is the "on reuse" column.
- **A still screen** (`safesightmac-harness static`, the virtual Mac's desktop screenshot, real models, judging slowed by 10 ms a judgement, the register's budget, 360 s; two runs of each build):
  - **This branch merged with #25:** one run settled. It had no cover from 271 s, the looks stopped at 273 s, and nothing was judged after. The other run kept the same 8 covers from 220 s to the end.
  - **Main at 74c0462:** both runs kept 8 covers from 140 s to the end.
  - **The second checks did not slow the settling here.** They take only the bucket's spare half, and while covers were being lifted the bucket never had one: they ran only from about 240 s, in the run that settled. In the other run none ran at all.
  - **A busy page opened while second checks wait** (`--cases pending`, register budget, the next busy page opened after 20 s of the first one still, three pairs). With background checks, all of the new page was judged after 23.3, 27.5 and 27.0 s; with them off, after 23.3, 27.5 and 27.0 s too. The bucket was empty at the switch either way (the first page's own judging had used it), and the new page's first call got 10 judgements in both. The most they can take from a page opened later is bounded by construction: they never take the bucket below half, so such a page starts with at least 200 judgements instead of up to 400. At 40 a second that is at most 5 s more before it is all judged; this was not measured.
  - **The 8 covers were main's, and are fixed since.** With `STATIC_HELD` they are two whole-window covers and six covers over most of the desktop window. Each waited for one entry dearer than any look gave its call: the menu bar's whole pass (the thin strip grown to 64 pixels, 21 pieces, about 42 judgements), and on the desktop a long, thin line of text (16 pieces and three models, about 48). The budget saved up for such an entry held back only the calls after it in the same look, and a cover the look had no time for lost its saving, so calls were never given more than about 13 judgements and those entries waited until the bucket happened to fill, or for good. (The desktop covers' rounds had gathered over a thousand entries, but those include entries shared from other calls; the ones still missing were these dear entries.) Now the calls saving up are served one at a time in the order they started: a quarter of what comes in is set aside for the first in line, which no other call can spend; it is served once that reaches its cost, and its cover then goes first among the covers judged on their own. No other call is held back for it. Nothing needs less evidence.
  - **Measured** on the same screenshot, with two clean checks merged in and after the second review, three runs: no cover from 196.0, 202.1 and 210.0 s; the looks stopped at 201.0 to 214.8 s, and nothing was judged after; nothing came back in any run. (After the first review, four runs: 202.9 to 207.4 s.)
  - **A first version** held every other call that only judges again at nothing until the first in line was served. It settled too (four runs: no cover from 204.8, 208.7, 211.5 and 218.8 s), but an independent review found that judging elsewhere could then keep it waiting for ever, and with it every other check, first judgements left over included. In one of those runs something was drawn again for under a second at about 211 s on the unchanged screen, at a look that made a `FULL_REJUDGE` pass (every 30 s while looks go on). Its log shows no unjudged entry and no new cover, so it was either a window that look had no time for, blurred until its turn, or the fastest model's early flag on a picture judged again with fresh jitter (a real flag, shown at once by design); the log does not say which. The first can no longer happen at a still screen (see "the full re-judge" above); the second still covers at once, as any flag does.
- **Before the merge with #25** (against 73b6568) the counts were much the same: reload 228, 1,082 and 232; window move 168, 818 and 170.
- **The cover layer's own bench** (`--cases reappear`, run before the merge) caps each frame at one call's worth and 0.25 s, so its counts are capped, not exact. Its times per frame are close for all three builds: reload 225, 205 and 186 ms; window move 316, 344 and 321 ms. Scrolling back to places seen before is the one clear difference: 47 ms with no judgement on main, 124 ms with 6 second checks on reuse, and 58 ms with none in the background build.
- **Unchanged elsewhere** (`--cases single,busy,scroll`, main against the background build):
  - one new picture is covered first in 3.8 to 8.9 ms against 3.7 to 9.0 ms (median by band);
  - every harmless photo on a busy page is shown after 62.6 s against 63.2 s under the budget, and 90.1 s in both with no budget limit;
  - scrolling takes 214 to 251 ms a judged frame against 215 to 279 ms.
  
  Results for all three builds are in the same file.
- **The page that never finished, fixed by #25.** Before #25, judged in calls of the usual cap (400), one of the six busy pages never finished: it used all 40 calls the bench allows, 16,000 judgements, against 1,238 in one uncapped call. Re-checked with the new `capped` case (`--cases capped`):
  - on main at 74c0462, and on this branch merged with it, every page now finishes in 3 or 4 calls (1,130 to 1,600 judgements);
  - the dearest entry a call left behind cost 2 to 6 judgements.
  
  So it was never one entry dearer than a call, as first thought here. Each call spent the cap again on the same borderline pictures, which the margin rule never caches, and #25's order (entries never judged first, then those judged earlier, oldest first) ends that. The budget saved up for a dear entry was not needed on these pages. The case would run any page that still did not finish through the cover layer, where that saving applies.

How many of the 63 crossings would two checks still cache? The stored spread data (`results/jitter-spread.json`) holds only summaries per model and band, not each entry's draws, so it cannot say. The jitter tool now counts this itself (`--bands`; per model and band, `twoChecks`). It was re-run on half the screens (every second one, 466) and only the bands where crossings were found (32 px and up), so that it fitted in 30 minutes; it took 24 minutes. Results: `results/jitter-two-checks.json`.

```
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness jitter --models ../v3-detector/models/converted \
    --list ../v3-detector/results/private/tiles-heldout.txt --root ../v3-detector --draws 20 --per-band 1500 --background 500 \
    --every 2 --bands 32-63,64-127,128+ --json results/jitter-two-checks.json
```

- **Crossings found: 25** (Marqo 32-63: 3, 64-127: 14, 128+: 3; NSFWJS 64-127: 5). On half the screens that is in line with the 63 on all of them.
- **Each entry's 20 draws, in the order made, stand for 20 showings.** With one check, all 25 have a draw under half, so every one could be cached clean. With two checks, **10 of the 25** had two draws in a row under half (Marqo 2, 6 and 2; NSFWJS none), so they could still be cached clean within 20 showings. The other 15 could not.
- **On the first showings.** Summed over the 25, the chance of being cached clean on the first judgement was 4.7 with one check. On the first two judgements with two checks it is 1.5. That is about a third as many.
- **What it means.** Two checks cut the chance a borderline picture is cached clean by about three at each showing. They do not close the gap: a picture shown many times can still get two low scores in a row. Closing it would need a stricter share where crossings were found, which is still open.
- **Limits:** the same as the first measurement: harmless pictures only, 20 draws, half the screens and only the bands named.

### Closing the clean-cache gap: a measurement of margin, checks and a sticky rule (20 November 2026)

The measurement ran with the defaults of the time (share 0.5, two checks, restarting); the stricter margins it measures stay lab switches. The founder chose the strictest rule measured, sticky at a quarter of the cut-off with three checks, as the default: see the next section. Two clean checks narrowed the gap but did not close it: a borderline picture shown often enough can still get two low draws in a row and be remembered as clean for as long as it stays unchanged. This measures what it would take to close it, for margins 0.5, 0.4, 0.3, 0.25, 0.2 and 0.1 (the share of the cut-off a clean score must be under; verified: it is the share of the cut-off that acts there, the cover cut-off, or the containment cut-off where a blur can apply) by 2 and 3 clean checks, and for one alternative design.

**The alternative: sticky.** Today a borderline judgement (at or over the margin) only starts the count again, so a picture shown many times gets many chances. Under the sticky rule a borderline judgement, or a cover, marks the picture as never to be remembered clean while the cache holds it: only its first `checks` judgements can cache it. Ordinary pictures that are clearly clean from the start are cached as before. Other variants suggested (the highest draw so far under the margin, a small spread between draws) are what today's consecutive checks already do, or a lower margin.

**Switches** (lab builds only; refused in release builds, and a rule looser than the default is refused everywhere; since the default is now sticky at 0.25 with three checks, only margins of 0.25 or less, three checks or more, and sticky can be set): `safesightmac-harness bench|static ... --clean-margin M --clean-checks N [--clean-sticky]` (`Detector.labSetCleanRule`, `VerdictCache.CleanRule`). Tests: `CleanRuleTests`. The jitter tool now also scores every setting against its draws (`CleanGrid.swift`).

```
SAFESIGHTMAC_LAB=1 swift run -c release --scratch-path .build-lab safesightmac-harness jitter --models ../v3-detector/models/converted \
    --list ../v3-detector/results/private/tiles-heldout.txt --root ../v3-detector --draws 40 --per-band 1500 --background 500 \
    --every 2 --bands 32-63,64-127,128+ --json results/jitter-clean-margin.json
```

Results: `results/jitter-clean-margin.json` (protection and harmless-picture cost, `cleanGrid`) and `results/speed-clean-margin-grid.json` (benches and the still screen). Same screens, bands and sample as the fresh-four run, with 40 draws an entry instead of 20, so more crossings show up: **48** (Marqo 32-63: 4, 64-127: 27, 128+: 10; NSFWJS 64-127: 6, 128+: 1), against 27 in 20 draws. Counted per entry instead (every model under the margin in the same draw, as the product decides), 30.

| Setting | Crossings with a draw under the margin / cached in their 40 draws | Expected cached (largest chance for one) | Harmless entries not cacheable on one draw | Harmless entries never cached | Reload (judgements) | Window move | Still screen settled (s) |
|---|---|---|---|---|---|---|---|
| **until now: restart 0.5 x 2** | 48 / 22 | 14.8 (99.9%) | 30% | 25% | 238 | 172 | 195, 212 |
| restart 0.4 x 2 | 19 / 6 | 4.7 (96%) | 39% | 32% | 322 (1.4x) | 228 (1.3x) | |
| restart 0.3 x 2 | 5 / 3 | 1.2 (49%) | 49% | 39% | 428 (1.8x) | 322 (1.9x) | |
| restart 0.25 x 2 | 3 / 0 | 0.25 (16%) | 56% | 44% | 500 (2.1x) | 376 (2.2x) | |
| restart 0.2 x 2 | 0 / 0 | 0 | 64% | 50% | 590 (2.5x) | 460 (2.7x) | 261, 265 |
| restart 0.1 x 2 | 0 / 0 | 0 | 90% | 75% | 872 (3.7x) | 676 (3.9x) | |
| restart 0.5 x 3 | 48 / 10 | 6.5 (95%) | 30% | 27% | 244 (1.0x) | 180 (1.0x) | |
| restart 0.4 x 3 | 19 / 2 | 1.9 (68%) | 39% | 34% | 324 (1.4x) | 236 (1.4x) | |
| restart 0.3 x 3 | 5 / 2 | 0.20 (11%) | 49% | 41% | 434 (1.8x) | 328 (1.9x) | |
| restart 0.25 x 3 | 3 / 0 | 0.02 (1.6%) | 56% | 46% | 500 (2.1x) | 374 (2.2x) | |
| restart 0.2 x 3 | 0 / 0 | 0 | 64% | 52% | 590 (2.5x) | 462 (2.7x) | |
| restart 0.1 x 3 | 0 / 0 | 0 | 90% | 77% | 876 (3.7x) | 684 (4.0x) | |
| sticky 0.5 x 3 | 48 / 0 | 0.87 (24%) | 30% | 32% | 238 (1.0x) | 172 (1.0x) | |
| sticky 0.3 x 3 | 5 / 0 | 0.014 (0.8%) | 49% | 46% | 432 (1.8x) | 334 (1.9x) | 264, 266 |
| sticky 0.25 x 2 | 3 / 0 | 0.015 (1.0%) | 56% | 50% | 494 (2.1x) | 368 (2.1x) | |
| **sticky 0.25 x 3 (now the default)** | 3 / 0 | 0.0013 (0.1%) | 56% | 51% | 500 (2.1x) | 372 (2.2x) | 280, 270 |

How to read it:

- **Crossings, per model**, as before: a harmless sampled entry with one draw under half its action cut-off and another at or over it. "With a draw under the margin" can ever be cached under today's restart rule, given enough showings; "cached in their 40 draws" took the draws in the order made as 40 showings. "Expected cached" sums each crossing's chance, with its draws taken as independent at its observed share under the margin: within 20 showings for restart, for good for sticky (share to the power of the checks). The other sticky settings are in the JSON.
- **Cost on harmless pictures.** "Not cacheable on one draw": of all 54,727 entries of the first calls (pass 1), any model at or over the margin of its cover cut-off. "Never cached": the random background sample (1,500 entries, bands 32 px and up, 40 draws), the chance it is never cached (within 20 showings, or for good), weighted by band. Today already re-judges about a quarter to a third of entries every time (slices and whole passes included).
- **Benches** (`--cases reuse,pending,capped`, real models, the six busy pages): judgements are exact; the reload and window-move medians are in the table. First showings are 1,082 judgements in every setting. Scrolling back to the same places: 8 today, 144 at restart 0.2 x 2, 78 to 112 at the 0.25 settings, 564 at 0.1. Background second checks grow with the checks (766 today, about 1,000 to 1,500 with three). `capped`: every page finishes in 3 or 4 calls, 1,200 to 1,600 judgements, in every setting. `pending`: the new page is all judged after 22.0 to 28.0 s in every setting, except one run each of sticky 0.3 x 3 (37.3 s) and sticky 0.25 x 3 (39.3 s), against 23.3, 27.5 and 27.0 s today. Three three-check runs first showed "never judged"; they ran while another job held the Mac at a load average up to 73, and re-run at about 9 they finished in 23.3 to 27.5 s (both are kept in the JSON).
- **Still screen** (`static`, the virtual Mac's desktop, 10 ms a judgement, 360 s, two runs each, run one after another): today settled at 195 and 212 s with about 8,200 to 8,900 judgements; the three strict settings at 261 to 280 s with about 10,900 to 11,600. All eight settled and nothing came back. About a minute later, for the extra re-judging of borderline entries.

What it shows:

- **Only lowering the margin far enough closes the gap.** Every crossing's lowest draw was at 0.206 of its action cut-off or above (median 0.42), so in this sample nothing is cacheable at 0.2 or below. But 0.206 is just over the line; another sample will likely find a crossing under 0.2, so 0.2 under today's restart rule closes the gap here by a hair, and only on these draws.
- **Sticky turns "eventually" into "once".** Under restart, any crossing with any draw under the margin is cached in the end if it is shown often enough (the 99.9% at today's setting). Under sticky its chance is fixed at its first showings. At a margin of 0.25 with three checks, the three crossings left with a draw under 0.25 have chances of 0.1%, 0.01% and 0.01%, 0.13 in 100 over all 48, for about the cost of restart 0.25 (2.1x a reload, 2.2x a window move), cheaper than restart 0.2 (2.5x, 2.7x), with more room under the lowest crossing.
- **Sticky costs almost nothing extra over the same margin**: the pictures it stops caching are the ones that already went over the margin once, and most of those are judged again anyway.

**Limits.** Harmless pictures standing in for borderline explicit ones; nothing says a real explicit picture's draws spread the same way. Half the screens, bands 32 px and up only, 40 draws an entry: shares near 0 or 1 are rough (one draw in 40 is 2.5%), and "never cached" for good can only be estimated. Draws are taken as independent (they are, jitter is drawn fresh each time), but each crossing's share under the margin comes from those 40 draws. Crossings are counted against the action cut-off (containment where a blur can apply); where no blur applies only the cover cut-off counts, which is the looser case. The sticky mark lives in the bounded cache: if the cache drops it (65,536 entries, oldest first), the picture gets fresh first chances. The benches ran once per setting, the still screen twice for three settings; times are noisy, judgement counts are exact.

### The default since 20 November 2026: sticky, a quarter of the cut-off, three checks

The founder's decision, after the measurement above: the strictest rule measured that still caches. In every build:

- **Margin 0.25** (`CLEAN_CACHE_MARGIN`). A clean judgement counts only when every model's score is under a quarter of the cut-off that acts where the verdict is reused (it was half).
- **Three checks** (`CLEAN_CHECKS`). A picture is reused as clean only after three clearly clean judgements in a row, each with fresh jitter (it was two).
- **Sticky** (`CLEAN_STICKY`). A judgement at or over the margin, or a flag, marks the picture as never to be cached clean while the cache holds it. Before, it only started the count again.

The lab switches can now set only rules at least this strict.

**At a still screen.** The background checks (`DisplayPipeline`, step 3c) give a waiting picture one check a look until it has all three. They are still bounded by 30 s of still screen; a picture that doesn't get them all by then is checked when it comes back. A picture marked borderline leaves the queue at once and is never queued again. Tests: `theLooksGiveEveryCheckAndNeverQueueAPictureOnceBorderline`, `CleanRuleTests`, `TwoCleanChecksTests`.

**When the cache drops a mark.** The mark lives in the bounded verdict cache (65,536 entries, oldest first), like the counts, and goes when the cache drops the entry or is emptied (a rule change, a pause). Nothing is then left for those pixels. They are judged again as if never seen and need three fresh clearly clean judgements in a row; the first borderline one marks them again. Dropping a mark can only give a picture fresh first chances, never a clean verdict (`testADroppedMarkGivesOnlyFreshFirstChances`).

**What it costs**, with the default as shipped (no switch), against the old rule. Real models (only the sealed files, checked against the hash list), the six busy pages of harmless photos, and the virtual Mac's desktop for the still screen. Results: `results/speed-clean-default.json`.

| | Old rule (restart, 0.5, two checks) | Default now (sticky, 0.25, three checks) |
|---|---|---|
| First showing of a busy page | 1,082 judgements | 1,082 |
| Reload | 238 judgements, 1.4 s | **496 (2.1x)**, 3.0 s |
| Window moved | 172 judgements, 1.1 s | **376 (2.2x)**, 2.3 s |
| Background checks after a page is shown | 766 | 1,024 |
| Scrolling back to the same places / to other places | 8 / 236 | 112 / 324 |
| `capped`: calls and judgements per page | 3 or 4; 1,200 to 1,600 | the same |
| `pending`: new page all judged after | 23.3, 27.5, 27.0 s | 23.3, 27.5, 27.0 s |
| Still screen settled (two runs, 360 s, 10 ms a judgement) | 195, 212 s; about 8,200 to 8,900 judgements | **252, 287 s**; about 10,500 to 11,900 |

In plain words:
- It takes about 2.1 times the judging work on a reload, and about 2.2 times on a window move.
- A still screen takes about a minute longer to settle. Both runs settled and nothing came back.
- No setting closes the gap for certain, this one included. In the measurement, 3 of 48 harmless crossings still had a draw under a quarter of their cut-off. The expected number cached clean falls from 14.8 to about 0.001. A borderline picture whose first three judgements all land under a quarter is still remembered as clean for as long as it stays unchanged.

**Limits of the comparison.** The old-rule figures were measured earlier the same day, before this branch was merged with main at df457a6 (#28, #30, #31). A same-code re-run of main was started; its `capped` case had not finished after almost four hours of wall time, during which the Mac appears to have slept, and it was stopped, so it gave no figures. Judgement counts are exact. Times are noisy: other work kept the load average at about 23 to 27 during the runs.

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

- **The live app, end to end.** It has run once, in a virtual Mac, and was unusable there ("The first live run"); the fixes have not been seen live yet. Nothing has run on a physical Mac.
- **Platform behaviours the capture code assumes,** each listed in chapter 05 as unproven:
  - the units of `dirtyRects` (read as frame pixels) and `contentRect` (read as frame points);
  - whether a still screen sends idle frames (the watcher no longer depends on it: it asks for a look itself);
  - whether `.best` gives full backing pixels on every display type;
  - whether excluding the app keeps the content under a cover visible to capture.
- **The lock screen over a whole-display cover. Test this first on the virtual Mac.** With a display covered whole, lock the screen, log out to the login window, trigger an authorization prompt (an administrator password request) and open the Accessibility Keyboard: each must stay visible and usable above the cover. The canvas sits at level 1990, below loginwindow's windows, which were read at levels 2001 and 2004 on a locked Mac, and every cover is taken off the screen while the OS says the screen is locked or another session has the console. Raising the canvas above the lock screen is not allowed until this test passes.
- **Window levels and surfaces** (ST-032): full-screen apps, Spaces, Mission Control, menus, the Dock, notifications, click-through, VoiceOver. The canvas level is a working value: 1990, above the screen saver (1000) and the assistive-technology levels (up to 1500), below the lock screen, with the app's own windows and its menu at 1991. Another app's window at or above the canvas, over a cover, covers that display whole, and the repair card says why. **An app that raises its own window above 1990 is itself not covered** (only everything else is); the planned answer is to close such an app (blueprint SD-304). **Must check on a test Mac** which ordinary system windows sit that high or could trigger the whole-display cover, so none leaves a display covered whole for good: Live Captions, the Accessibility Keyboard, VoiceOver's caption panel, Zoom's window, picture-in-picture video, the screenshot toolbar (⇧⌘5), Notification Centre, Spotlight and the Force Quit window. Also check that the app's own menu really opens above a whole-display cover (its windows are lifted while it is open), and that ScreenCaptureKit always lists the app while its canvas is up (no stream starts otherwise).
- **Displays** (ST-033, ST-034): external, mirrored, Sidecar, AirPlay, DisplayLink; plug, unplug, sleep, wake, lid, rotation and resolution changes. The display rule is tested with faked display lists and frames only. Not yet seen on hardware:
  - whether macOS makes the reconfiguration callback's begin call before it applies each kind of change, and on the main thread;
  - how many frames a new display shows before its canvas exists (SL-023);
  - whether ScreenCaptureKit lists and streams DisplayLink, Sidecar, AirPlay and app-made virtual displays (one it cannot see stays covered whole, which makes that display unusable);
  - **must check on a real mirrored set-up** (built-in display mirrored to an external display, and AirPlay mirroring to a TV): which of CoreGraphics' active and online lists, AppKit's screens and ScreenCaptureKit's list hold the mirror; that it gets no canvas of its own; that it shows its source's covers; and that a whole-display cover still leaves the main display's menu bar in sight while mirrored;
  - a stream that stops delivering frames without an error, and ScreenCaptureKit handing one display's picture to another display's stream (Apple feedback FB17797423). Neither is detected: the per-display canary of red-team fix FIX-13 is the planned check;
  - a display captured by an app (`CGDisplayCapture`): that app draws at the shielding window level, above the canvas level, so its pictures would show over the covers (ST-032).
- **Time to cover on a real display** (ST-031). The flash length is unknown.
- **Speed, memory and energy** (ST-038, ST-039). Each complete frame is copied into an RGBA buffer for the detector, which costs memory and energy, unmeasured. `JUDGEMENT_BUDGET` (40 per second) and `FULL_REJUDGE` (30 s) are proposals.
- **False covers on real screens in daily use.** ST-040 re-ran through this pipeline on 932 held-out harmless screens (above); nothing has been measured on a live screen.
- **The catch rate.** Not measured. By design, no explicit pictures are used anywhere in this work.
- **Jitter on explicit pictures.** How far jitter moves a score was measured on harmless screens only, by design. An explicit picture near a cut-off may move more.
- **The signed `.app`.** `tools/make-app.sh` assembles an unsigned bundle under `.build/`. That was checked once, and the bundle was then deleted. Nothing has been signed or notarized. The Testing edition's bundle is signed ad hoc (sandboxed, not notarized); `tools/check-testing-edition.sh` assembles one without models in a temporary folder, checks it and deletes it.

## What needs the maintainers

1. **A bundle identifier.** The reverse-domain prefix is not chosen (the identity file is still [P]). `tools/make-app.sh BUNDLE_ID MODELS_DIR` needs one.
2. **Sign and notarize** the app with the project's Developer ID, as in step 0. It is unsigned today.
3. **Try it on a test Mac,** never a Mac anyone relies on. Use a virtual test Mac or a helper's test Mac:
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
5. **Model conversion.** The Core ML conversion tools, with their parity checks and broken controls, are still only in the detector lab, which isn't public yet. Vendoring them means vendoring Python tooling. Decide whether that belongs in this repository.

## Known limits

- **Flashes.** In show-first mode every window is shown first and judged just after, so a picture can be seen for a moment before its cover. How long on a real display is not measured (ST-031). In the lab, from the frame to the cover layer, one new picture is covered within about 50 ms (worst 66 ms) and a busy page's new pictures are blurred after about 0.25 s; a picture scrolling into view can show for up to the time one judged frame takes (0.6 to 0.9 s on a Retina window). The goal is about 0.1 s.
- **The catch rate is unmeasured.** Nobody knows how many explicit pictures this detector misses. The cut-offs are strict to keep false covers low, so Balanced may miss more, by an amount nobody has measured. No accuracy figure may be published (claims ledger).
- **False covers and blurs.** The detector covers some harmless things. The picture finder grows regions to a picture's edge, so a cover can spill over neighbouring text. Small pictures it is unsure about are blurred.
- **No lock and no shield.** This build can be paused or quit, and if it crashes or is quit, the screen is uncovered. At start, and when a display appears or wakes, the display is covered whole until its first judged frame (a few seconds when the models load).
- **Display changes cover every display.** Plugging or unplugging a display, mirroring, a new resolution, and sleep and wake (of the Mac, or of its displays alone) cover every display whole until each has a judged frame from a restarted stream: 0.2 s of quiet, then one full judgement per display. Not measured on hardware. A new display can show what macOS puts on it for a moment before its canvas exists (SL-023): a canvas can only be made for a display that exists. A monitor usually takes a moment to show a picture after it is plugged in; whether the canvas is always there first is what ST-034 measures.
- **Not judged:** the cursor, the brighter-than-white range of HDR displays, protected video (captured as black), sound and text, anything before login. Accessibility Zoom is not detected.
- **Other screens.** Media sent from the Mac straight to a TV, and a window capture sent to another device, never pass through the cover. See "Other displays and other screens" below.
- **Load.** A busy screen judged from scratch exceeds the budget. Its new pictures are blurred first; unjudged 512-pixel slices are covered; after 0.5 s of unjudged entries the window is covered whole. A busy Retina page stays blurred or covered for 13 to 21 s at `JUDGEMENT_BUDGET` (6 to 8 s with no budget limit). A third display and beyond are covered whole.
- **Choices made where the register is silent or open.** Each is a working value tied to its test:
  - canvas window level: 1990, below the lock screen (ST-032);
  - time per judged frame: 0.25 s (`JUDGE_CALL_WALL`); a change left unjudged 0.5 s is covered; the pictures of new frames are blurred before judging after 3 slow frames in a row; a large change is blurred whole only until its pictures are found (ST-038);
  - a closed window's cover: kept where it stood until judged clean 4 times, or 2 times after 1 s (`WINDOW_GONE`);
  - the reported changed areas are checked against the pixels once a second, by comparing the frame with the frame of the last check outside every area reported since. That keeps one more full frame per display in memory (about 59 MB on a 5K display). When more than 256 areas are reported between checks they are merged, grown to the 8-pixel grid, so a change in that margin is not caught by the check;
  - cover colour: one calm neutral per appearance, in the theme type `CoverTheme` (the desert study);
  - the control band a whole-window cover leaves: 92 points (`WayOut.controlBand`, ST-032);
  - the room a cover needs around the way-out line: 24 points;
  - blur: at most 6 colour cells;
  - judging stall before a whole-display cover: 5 s, also for a frame left waiting (ST-038);
  - display changes: capture restarts after 0.2 s of quiet; an announced change with no "after" call ends after 3 s; a display with no stream is retried after 1, 2 and 4 s; the OS's display lists are read again at every drawing and four times a second; a sleep, display-sleep or session hold whose wake or return notification never came ends once the displays are awake and the session is on the console, after 10 s (sleep) or 2 s of awake time (ST-034);
  - `JUDGEMENT_BURST`: 400 (ST-038);
  - the repair card: shown after 2 s of a whole-display cover.

  A flagged whole pass covers the whole window only when the call spanned the window. On a call over changed parts, it covers the judged area.

  **Known cost: covers are never trimmed by windows in front.** A window in front may be see-through, so a cover is always drawn whole, over any window in front of its own. A whole-window cover on a window behind therefore also hides the part of the front window that overlaps it, until it lifts.

  For an unjudged slice or whole entry, this build keeps the detector's cover where C05-20 would blur only the pending regions it touches. That is more covering, not less.
- **Not built in this version:**
  - strict cover mode and judged copy;
  - "This is wrong";
  - heat and Low Power Mode inputs;
  - keyboard-focus priority (the pointer's window and the pictures nearest the pointer go first since 18 November; the front-most window comes before windows behind it);
  - matching a frame to the window list taken nearest its time (the list is read when the frame is taken for judging);
  - the crash-loop breaker;
  - the heartbeat and the plain shield, which are not part of the practice state.
- **Models ship compiled** in an app made by `tools/make-app.sh` (correction C06-14). Outside an app (the harness, lab builds, tests) each package is still compiled once at first load, to a fixed place. An app made by `make-app.sh` holds only compiled models, so it never compiles, and `tools/check-testing-edition.sh` refuses a Testing app that holds packages.

## Other displays and other screens (written down, not built)

The display rule covers every display the Mac draws on: built-in, wired, DisplayLink, AirPlay or Sidecar used as a display, mirrors, and displays apps create. Whatever reaches those displays was composited by the Mac, so it passes through capture, judging and the canvas. Some routes put pictures on another screen without the Mac drawing them, or copy the Mac's screen without its covers. Each is listed here with its planned fix. None of these fixes is built.

| Route | Where the pictures go | Covered by the cover? | What closes it |
|---|---|---|---|
| AirPlay or Cast of a media stream from a browser (Safari, Chrome, Edge) | A TV or streaming box, which plays the stream itself | **No.** The Mac never draws those frames | The browser layer |
| AirPlay from QuickTime Player or the Apple TV app | The same | **No** | No switch known; a setting or a published limit |
| An app capturing one window, or the screen without SafeSight Mac's windows (OBS, QuickTime recording, window sharing in Zoom, Discord, Teams or Meet, screen-sharing tools) | The far side of a call or stream, or a recording | **No**, for the copy: window capture leaves overlays out | The Screen Recording permission |
| AirPlay to this Mac, iPhone Mirroring, a virtual machine or remote desktop in a window | This Mac | **Yes**, like any window | Already covered |
| A phone, a tablet's own apps (Universal Control included), a TV's own apps, another computer, a phone casting to a TV | Another screen | **No** | Outside SafeSight Mac's reach (SL-025) |

**Media streams sent to a TV.** Not to be confused with AirPlay used as a display, extended or mirrored, which the display rule covers: there the Mac draws every pixel, covers included.
- Chrome and Edge (the optional browser profile): `EnableMediaRouter` set to false turns off Cast, its toolbar button, and Cast started by a page through the Remote Playback API. Neither browser has its own AirPlay; Firefox has neither.
- Every browser the extension runs in: the extension sets `disableRemotePlayback` on every video and audio element, including ones added later, and sets it again if a page clears it. In Safari it also adds `x-webkit-airplay="deny"` and refuses the playback-target picker. Safari takes no policy (the owner switches the extension on, and Safari is never forced), so with the extension off, Safari's AirPlay button still works: a published limit.
- QuickTime Player and the Apple TV app: no per-app switch is known. Candidates: an AirPlay allow-list in a device-management profile where the Mac is enrolled (the Hardcore lock), or a published limit.
- Protected streams are already black to capture on the Mac (SL-024), and the protected-streaming research is about the Mac's own screen. Sent to a TV, they play there, outside every check.

**Apps that capture a window.** ScreenCaptureKit can capture one window, or a display minus chosen windows, so the copy can leave the covers out and send unjudged frames to another device. On this Mac, any preview the capturing app draws is judged and covered like any other window; the far side is another screen. The covers keep the default sharing type, so an app capturing a whole display without excluding them receives the covers (ST-037 records this per app).
- The gate is the Screen Recording permission: no app captures without it. In this build (the practice state) nothing limits who holds it.
- Planned: at Lock, record which apps hold Screen Recording; a new grant is a loosening that waits, unless the admin-tasks design finds a safe fast path for it. That design is not written yet. It has to keep window sharing in a meeting easy, since that is ordinary work, without letting a capture app become a way around the cover.

**Plainly:** the cover reaches every display the Mac draws and every window on them, AirPlay and iPhone Mirroring into this Mac included. A browser sending media to a TV needs the browser layer. QuickTime Player and the TV app sending media to a TV, and window capture sent to another device, need settings and the lock's permission rules, none built. A phone, a TV's own apps and other computers are other screens, outside SafeSight Mac's reach.
