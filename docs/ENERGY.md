<!-- SPDX-License-Identifier: Apache-2.0 -->
# Energy

SafeSight Mac runs all day on your own Mac, often on a laptop's battery. It should cost you next to nothing when the screen is still, a fair share while you browse or play a video, and never more just because something went wrong. This page says what it does in each state, what we have measured and how, what we have not measured yet, and how anyone can measure it on a real Mac.

One rule comes before any saving: **saving energy never shows anything sooner.** On battery, in Low Power Mode or when the Mac is hot, the only trade allowed is to keep a cover up a little longer and judge later. A cover needs the same evidence to lift in every mode (four clean judgements in a row of everything it hides), no cut-off or count changes, new pictures are judged at the full budget, and a fault covers more.

## What it does, state by state

Figures are from the lab harness on the reference Mac (below), unless marked as measured in a virtual Mac.

| State | What runs | What wakes it | Judgements | CPU |
|---|---|---|---|---|
| **Still screen, settled** (nothing covered, nothing left to judge) | Nothing is judged. The quarter-second check reads the display lists and the session state. | The check, 4 times a second. A capture frame when the screen changes; one whose pixels are all the same as before judges nothing. | 0 | the check: 0.12 CPU-ms a tick, 0.03 CPU-s a minute (0.05% of a core). In a virtual Mac, the whole app: 0.1 to 0.5% |
| **Still screen, settling** (covers waiting to lift) | A look at the last frame while covers wait for their four clean judgements; a full re-judge every 30 s while looks go on | The check, plus a look every tick while new pictures or background clean checks are left; once nothing but covers waits, a look a second (every 2 s in Low Power Mode or when hot) | the budget: 40 a second, plus one first burst of 400 | 14.9 CPU-s a simulated minute (a quarter of a core) for about 4 minutes on the harness's desktop: 64 CPU-s in all, 101 on main |
| **Scrolling and browsing** | Each new frame's changed parts: the picture finder, the caches, the models on new pictures, covers moved with the content | Capture frames at the display's own rate while things move; one frame judged at a time, the newest | up to the budget, in bursts of up to 400 | a busy page shown for the first time: 65 CPU-s until it rests (70 on main); shown again: 0.1 CPU-s |
| **A full-screen video** | The video's area, judged frame after frame, as fast as judging allows | Capture frames at the display's rate | about 1,900 a minute in the harness's case | 84% of a core: about 240 frames judged a minute at 214 CPU-ms each (main: 92%, 160 frames at 341 CPU-ms) |
| **Display asleep, Mac asleep, screen locked** (the screensaver too, once the lock screen is up) **or another account on the screen** | Nothing is captured or judged. Every display is held covered, or, at the lock screen, the covers are taken off. | The check only, which also ends the hold | 0 | the check's cost |
| **On battery** | The same as on power: the settings that cost least in total are already the ones used on power | as on power | as on power | as on power |
| **Low Power Mode, or the Mac is hot** | As on power, but a look every 2 s once nothing but covers waits | Fewer looks at the end of settling | the same budget | about the same as on power (21 CPU-s a minute, 3.1 minutes, measured before the looks were made cheaper and before the third clean check; not measured again) |

A few notes:

- **The quarter-second check** is the one timer that runs at a settled screen. It backs up macOS's own notices: a display change nobody announced, the lock screen, judging that has stalled, frames left waiting too long. It keeps the same rate in every mode, because it is part of how the cover fails safe.
- **Capture frames.** ScreenCaptureKit sends a frame when the screen changes. Each frame with new pixels is copied once into the memory of the part that reads the screen, on the capture queue, and compared with the last frame to find what really changed. Frames that come while another is judged wait in a mailbox of one per display, which keeps only the newest pixels and adds up what changed, so nothing is dropped unjudged.
- **Coming back** (wake, unlock, back from another account): every display stays covered whole until a frame from a stream started after you came back has been judged.
- **Lid closed:** with no other display, the Mac sleeps (the row above). With an external display, the built-in display is simply gone, and the rest goes on as usual.
- **Memory.** In the harness, the process uses about 660 MB with the three models loaded and about 850 to 960 MB at its peak, with a busy Retina page, its caches and the harness's own pictures (the same before and after the looks were made cheaper). The app in a virtual Mac used 230 to 315 MB. Models stay loaded while the screen is still, so a new picture never waits for them. Nothing cheap stood out to save there: most of it is the models.

## What changed for energy

| What | Where | Before | After |
|---|---|---|---|
| Capture while asleep, locked or switched away | `CoverCoordinator.willChange` and `tick` (`pauseForHold`), `StreamScheduler.pause` | streams kept running for nothing: about 26 frames a second captured and compared at the lock screen in the virtual Mac, 10 to 54% of a core | streams stopped; started again after the wake, every display covered whole until a frame of the new streams is judged |
| Settling on a still screen | `LookPace`, `WatcherController.askForLooks`, `DisplayPipeline.hasLeftOverWork` | a look every quarter second, each with what a quarter second of budget brings | every tick while new pictures or background clean checks are left (so a check that flags covers as soon as on main); then a look a second, each with a second's budget. 78.3 to 68.6 CPU-s to settle the harness's desktop, 160 s to 156 s: a small saving, within what a shared Mac can blur |
| Low Power Mode and heat | `EnergyMode`, `PowerState` | the same as on power | a look every 2 s once nothing but covers waits: 65.7 CPU-s and 186 s to settle |
| Looks while capture is paused | `LookPace` | asked for during a hold, waking the judging queue for nothing | none while any hold is on |
| The capture callback's frame copy, every frame with new pixels | `RGBAImage.fromBGRA` | 4.2 CPU-ms a 2880 x 1800 frame (12.3 at 5120 x 2880): 25% of a core at 60 frames a second | **1.35 CPU-ms** (4.1 at 5120 x 2880), byte for byte the same: 8% of a core at 60 frames a second |
| A slow first load (Core ML building its cache, 12.3 s in the virtual Mac, past the 10 s `WARM_UP_LIMIT`) | `WatcherController.loadDetector`, `Register.WARM_UP_SLOW_LIMIT` | a detector failure: covered whole until someone pressed Try again | covered whole with the repair card at 10 s, as before; if the warm-up then ends well within 120 s, covering starts by itself. Nothing is judged or shown before the models are ready |
| The picture finder, every judge call that misses the finder cache | `RegionFinder.markCells`, `grow`, `mergeOverlapping` | each pixel's colour worked out four times; a side stopped at a plain line read again in full at every round of growing; the merge started over from the top after every merge | each pixel worked out once; a stopped side reads only the new ends of its line; the merge goes on from where it was. The same proposals: the same regions in the same order, and the same grids (`FinderEquivalenceTests`, against the vendored finder). A 2880 x 1800 busy page: 133 to 68 ms; a 1280 x 720 video frame: 86 to 35 ms |
| The finder cache at a still screen | `FinderCache.defaultCapacity` | 32 results: a look at the harness's desktop makes a few dozen calls on the same pixels, so it found its own results in 3% of them | 512: 86% of the calls while settling |
| Hashing for the caches at a still screen | `FrameKeys` | every look hashed every entry of the same last frame again (full SHA-256) | each key worked out once per frame, for the very same pixel storage only (kept alive while its keys are, so it can be neither freed nor changed in place): 19 s to 1.3 s of hashing while the desktop settles. Any changed pixel is a new frame, hashed in full |
| Preprocessing, once per model for every judgement | `Preprocessor.run` | the opaque test and divide on every byte of an opaque capture; one sum at a time | opaque pixels copied as they are (the same value); four rows summed side by side; whole rows at once in the second pass. Byte for byte the same tensors (`FastPreprocessTests`, against the vendored code, and the spec's vectors) |

The energy mode follows macOS's own notices (power source, Low Power Mode, thermal state); nothing polls for it. The Testing edition follows Low Power Mode and heat only: it links no IOKit, which the power source needs.

**What we tried and dropped,** measured the same way (`results/energy-tried-*.json`):

- **A duty cycle for settling** (looks may take at most a quarter of the judging time): the desktop took 842 s to settle instead of 160 s, and 419 CPU-s instead of 78. Most of a look's CPU time is its fixed cost (the window split, finding pictures, hashing every picture for the cache), not its judgements, so stretching the looks out multiplied that cost.
- **A smaller share of the budget on battery** (half, a look every 2 s): 617 s and 67.5 CPU-s to settle, more in total than at full power, because the checks that come round every 30 s kept coming for longer.
- **A quarter of the budget in Low Power Mode** (a look every 4 s): it had not settled after 20 minutes. Slower settling is safe (covers stay up), but it was not gentler.
- **Slowing the background clean checks too** (a look a second for everything but new pictures): 42.5 CPU-s to settle. Dropped after review: a picture shown clear that its next jittered check would flag was covered up to 0.75 s later than on main (1.75 s in Low Power Mode). Those checks now keep the tick's pace, and the saving is much smaller.

So no mode lowers the judging budget. Saving comes from fewer, larger looks.

**The burst about every 30 s at a settled screen is kept.** A frame whose pixels are all the same as before judges nothing at a settled screen (main does this since pull request 31, and `EnergyBudgetTests` holds it). What is most likely left is the full re-judge (`FULL_REJUDGE`): the first frame with a real change (the menu bar clock, say) more than 30 s after the last full pass judges the whole display again, not only the change. That is a protection: a picture shown as clean gets another look with fresh jitter. Most of it comes from the caches; the cost is the picture finder and hashing over the display, a short burst, and its average stays well under the 1% target below.

**Settling stays the main cost.** It is the price of the rule that a cover lifts only after four clean judgements of everything it hides: on a busy desktop that is thousands of judgements, about a quarter of them clean checks that make later reuse cheap. Since the looks were made cheaper, most of what is left is the models themselves (preprocessing, and Core ML's own side of each judgement) and the finder on calls the cache cannot answer. Settling takes as long as before, or a little longer: it is paced by the judging budget, which is unchanged.

**A playing video stays near a core.** While the screen changes, the watcher judges the newest frame as soon as the last one is done, so a cheaper frame shows as more frames judged (and fewer pictures left unjudged), not as a smaller share of a core, until a frame costs less than the time between two frames. In the harness's video a judged frame now costs 214 CPU-ms instead of 341; at 30 frames a second it would have to cost under about 33 ms. Judging fewer frames would save more, but it would leave new pixels unjudged for longer, so it is not done.

## In a virtual Mac (measured live, 20 November 2026)

The Testing edition, lab build, in a disposable virtual Mac (Tart, macOS 26.6.2, 1024 x 768 points at 2x, no Neural Engine, judging 250 to 470 ms a frame), read from Activity Monitor and the lab log. These figures are from before this change; they are why it was made.

- **On main before pull request 31, a still desktop never settled:** about 18 frames a second, each reported as the whole display changed, 117 to 170% of a core.
- **With pull request 31** (what changed read from the pixels): settling 100 to 160% of a core for about 5 minutes, 290 to 315 MB; settled 0.1 to 0.5% of a core, 230 to 270 MB, with a burst of 2 to 10% about every 30 s.
- **At the lock screen** capture kept running: about 26 frames a second captured and compared, 10 to 54% of a core.
- **The first launch** waited 12.3 s while Core ML built its cache.

They have not been measured again with this change; that needs another run in the virtual Mac. There, with no Neural Engine, each judgement costs many times what it does on a real Mac, so settling will still be heavy for a few minutes.

## The energy budget

The project holds itself to these figures (`EnergyBudget` in `Sources/SafeSightMacWatcher/Energy.swift`). The tests (`EnergyBudgetTests`, `EnergyHoldTests`, run on every pull request) fail when a count is exceeded: judgements and looks at a settled screen, judgements while settling, the pace of looks, capture during a hold. The CPU and settling-time figures need the real models, so only the lab harness (`safesightmac-harness energy --check`) checks them, by hand; CI has no models to run it with.

| Figure | Budget | Measured |
|---|---|---|
| Judgements at a settled still screen | 0 a minute | 0 |
| Looks asked for at a settled still screen | 0 a minute | 0 |
| Timer wake-ups at a settled still screen | 240 a minute (the quarter-second check) | 240 |
| Judgements while a still screen settles | the budget (40 a second) plus one burst of 400 | 41.5 a second, the first burst included; no judge call ever over its budget |
| Looks while a still screen settles | at most one a tick (240 a minute); one a second once nothing but covers waits | 814 looks in 257 s (190 a minute; 111 on main): most of the settling has background clean checks left, which keep the tick's pace, and a cheaper look leaves more ticks free |
| Time for the harness's still desktop to settle | 300 s (600 s in Low Power Mode or when hot) | 227 to 281 s in four runs (main: 222 to 264 s); 186 s in Low Power Mode with two clean checks, not measured again |
| CPU while it settles | 20 CPU-s a simulated minute | 14.9 (main: 27.2) |
| CPU for a reload of a judged busy page | 2 CPU-s | 0.1 |
| CPU while the harness's video plays | one core | 0.84 (main: 0.92) |
| The frame copy, 2880 x 1800 | 3 CPU-ms | 1.35 |

The CPU figures are for the reference Mac; a slower Mac uses more.

## How it was measured

On a developer Mac (Apple M1 Max, 64 GB, macOS 26.3), release lab build, the three real models (checked against the sealed hash list), the sealed cut-off table, Balanced. Nothing captured the screen: the harness feeds frames to the real cover layer and the real detector. The Mac was shared with other work at the time (load average about 4 to 16), so CPU times may read a little high; counts and settling times are less affected.

```
SAFESIGHTMAC_LAB=1 swift build -c release --scratch-path .build-lab
.build-lab/release/safesightmac-harness energy SCREENSHOT --models MODELS_DIR --windows WINDOWS_FILE \
    --pages LAB/data/finder-bench-heldout/screens --power full --json results/energy-after.json --check
```

- **The clock is simulated.** A still screen's minutes of settling run in the time the work itself takes, and only that work is counted. Looks come at the pace the app itself uses (`LookPace`). CPU time is the process's own (every thread, user and system) counted around the watcher's work; memory is the process's footprint.
- **Cases.** `still`: a harmless screenshot of a virtual Mac's desktop (1024 x 768 points at 2x, with its window list), from the first frame until nothing is drawn and no look is wanted, then a minute at rest. `reuse`: the busiest of the lab's harmless held-out pages (2880 x 1800), judged until it rests, then shown again. `video`: a 1280 x 720 pixel area of new harmless noise every frame at 30 frames a second over that page, for a minute, judged one frame at a time with only the newest frame taken. `copy`: the frame copy at 2880 x 1800 and 5120 x 2880. `tick`: the quarter-second check's system reads.
- **Capture and pacing** (pull request 34, the table just below): **before** is main at df457a6 with only the energy command added; **after** is that change. Results: `results/energy-before.json`, `results/energy-after.json` (full power and battery), `results/energy-low.json`, and the ones tried and dropped. The before and after still and reuse runs were made at different times on the shared Mac (load about 4 to 16, then 18 to 23); the video, copy and check figures come from the earlier after run, which had the same code for them.

| Harness case | Before | After |
|---|---|---|
| Still desktop: time to settle | 160 s | 156 s |
| Still desktop: judgements to settle (second clean checks among them) | 6,580 (1,924) | 6,568 (1,980) |
| Still desktop: looks | 337 | 307 |
| Still desktop: CPU to settle | 78.3 CPU-s | 68.6 CPU-s |
| Still desktop at rest, a minute | 0 judgements, 0 looks | 0 judgements, 0 looks |
| Busy page, first showing until it rests | 4,692 judgements, 48.0 CPU-s, 112 s | 5,204 judgements, 52.4 CPU-s, 127 s |
| Busy page shown again | 12 judgements, 0.1 CPU-s | 20 judgements, 0.1 CPU-s |
| Video, a minute | 150 frames judged, 92% of a core | 163 frames judged, 89% of a core |
| Frame copy, 2880 x 1800 / 5120 x 2880 | 4.2 / 12.3 CPU-ms | 1.35 / 4.1 CPU-ms |
| The quarter-second check | 0.13 CPU-ms a tick | 0.12 CPU-ms a tick |

Settling and first showings cost about what they did on main: the slower pace now applies only at the end of settling, once the background clean checks are done. The clear gains are elsewhere: no capture while asleep or locked, and the frame copy. The cost of the models on the Neural Engine and the GPU is not in these CPU figures.

### Cheaper looks and judgements

The finder, preprocessing, the finder cache and the hashing for the caches, measured the same way. **Before** is main at b68388f (three clean checks, sticky) with only this branch's harness changes (the stage timings and the `finder` case); **after** is this branch. The two runs were made one after the other on the shared Mac (load average about 5 to 10, then 10 to 12): `results/energy-looks-before.json`, `results/energy-looks-after.json`. The still case was run twice more for each, four at a time (`results/energy-looks-still-repeats.json`), because jitter and load move its settling time.

| Harness case | Before | After |
|---|---|---|
| Still desktop: CPU to settle | 100.6 CPU-s (85.7 and 88.4 in the repeats) | 63.9 CPU-s (56.3 and 59.0) |
| Still desktop: time to settle | 222 s (251 and 264 s) | 257 s (281 and 267 s) |
| Still desktop: judgements to settle (clean checks among them) | 8,952 (2,380) | 10,660 (2,666) |
| Still desktop: looks | 410 | 814 |
| Still desktop: judge calls, and how many the finder cache answered | 17,038, 479 | 112,176, 96,429 |
| Still desktop, where the time went (wall s): finder, hashing, preprocessing, Core ML | 48.1, 19.1, 25.1, 39.8 | 30.8, 1.3, 20.0, 44.3 |
| Still desktop at rest, a minute | 0 judgements, 0 looks | 0 judgements, 0 looks |
| Busy page, first showing until it rests | 7,796 judgements, 70.3 CPU-s, 193 s | 8,478 judgements, 65.1 CPU-s, 201 s |
| Busy page shown again | 30 judgements, 0.13 CPU-s | 42 judgements, 0.11 CPU-s |
| Video, a minute | 162 frames judged, 1,074 judgements, 92% of a core | 236 frames judged, 1,864 judgements, 84% of a core |
| Video: CPU for each frame judged | 341 CPU-ms | 214 CPU-ms |
| The finder alone: busy page 2880 x 1800, video frame 1280 x 720, still desktop 2048 x 1536 | 133, 86, 190 ms | 68, 35, 137 ms |
| Frame copy, 2880 x 1800 | 1.40 CPU-ms | 1.43 CPU-ms (unchanged code) |
| Memory: after loading the models, at the peak | 660 MB, 860 to 940 MB | 660 to 750 MB, 850 to 960 MB |

What got better: a third less CPU to settle a still screen, and less for each video frame. What did not: the still desktop took as long to settle, or a little longer (222 to 264 s before, 257 to 281 s after); the number of judgements it needs moves from run to run with jitter, and settling is paced by the budget. Covers waiting longer to lift is the safe side, but it is no better for the owner. A video still uses most of a core, for the reason above. The first figure after loading the models read 750 MB in two of the after runs and 660 MB in the others; nothing in this change runs before the cases start, so it looks like Core ML's own loading, but it was not tracked down.

What we found and left alone: in the harness's video, once the full re-judge every 30 s has come round, every frame is judged over the whole display, not only the video's area. That call never finishes (the whole pass over the display changes with every frame and the budget gives each frame a couple of judgements), so it is asked for again at the next frame, and at the end of the minute the whole display is covered or blurred (main does the same). Judging only the parts left unjudged would cost much less, but it would change what the finder proposes, so it needs its own change and review.

Since then (the `scroll-video` change): a call now leaves for later only the entries it left unjudged, each already held covered where it stands until its own clean rounds, so after a full re-judge the next calls are over what changes and what was left, not over the whole display. In the cover layer's simulation of the virtual Mac (`SustainedChangeTests`), a minute of video no longer ends in a cover of the whole display: the largest cover while it plays is 8% of the display, against 96% before. The full re-judge's slices that reach into the video's area still change with every frame, so they stay covered until the video stops (about 84% of the rest of the display in that simulation, as before). The live harness has not been run again. That simulation's fake judge, in its exact mode, makes a whole pass or slice new whenever a change reaches its place, so it is pessimistic for scrolling: the real detector keys entries by their pixels and anchors its slices to the scroll offset, so slices that only moved with the page come back from the cache.

## Option, not enabled: looking every tick while many covers wait

After a page scrolls, it can leave hundreds of small covers, each waiting for its four clean rounds. While only covers wait, a still screen is looked at once a second (`EnergyMode.lookEvery`). `LookPace.TICK_WHILE_COVERS_OVER` is an option to look every tick (4 times a second) instead while more than N covers wait. It would spend more energy to settle sooner. Nothing else changes: the same judging budget, the same four clean rounds, the same clean-cache rule, the same `TIME_TO_COVER`. A look with an empty bucket judges nothing extra, and covers found flagged are not counted. **It is off** (`nil`), and nothing in the app turns it on.

We measured it in the simulation (`LookPaceOptionTests`, the fake judge of `UsableCoversTests`, simulated time and CPU). The busy page is scrolled for 60 s and then left still. "Exact" is the fake judge's exact mode; "old" is the mode the tests were first written in. The still desktop is the one under the Dock's display-sized window, timed from its first frame. "Settled CPU" is the next two minutes with the menu bar clock ticking.

| Case | Setting | Settles in | CPU-s settling | Judgements | Looks | Settled CPU-s a minute |
|---|---|---|---|---|---|---|
| Scrolled page, exact | off (today) | 378.5 s | 363.7 | 15,206 | 1,248 | 0.90 |
| | N = 32 | 393.7 s | 381.9 | 15,810 | 1,315 | 0.72 |
| | N = 8 | 393.7 s | 381.9 | 15,810 | 1,315 | 0.72 |
| | N = 1 | 393.6 s | 382.1 | 15,810 | 1,320 | 0.72 |
| Scrolled page, old | off (today) | 80.0 s | 77.4 | 3,450 | 259 | 5.25 |
| | N = 32 | 91.4 s | 82.7 | 3,712 | 343 | 5.77 |
| | N = 8 | 91.4 s | 82.7 | 3,712 | 343 | 5.77 |
| | N = 1 | 91.2 s | 82.7 | 3,704 | 349 | 5.77 |
| Still desktop | off, 32, 8 and 1 | 44.4 s | 39.0 | 1,972 | 165 | 0.63 |
| `EnergyBudgetTests` desktop, full power | off, 32, 8 | 84.0 s | – | 1,754 | 134 | – |
| | N = 1 | 84.5 s | – | 1,764 | 145 | – |
| `EnergyBudgetTests` desktop, Low Power | off, 32, 8 | 85.0 s | – | 1,753 | 101 | – |
| | N = 1 | 86.5 s | – | 1,783 | 114 | – |

In every run, with the option on or off, no cover lifted before four clean rounds (checked after every frame), and judgements stayed within the budget plus its first burst. Every `EnergyBudgetTests` limit still holds with the option on, in every mode.

What this shows: **the option makes settling slower and costs more, not less.** The scrolled page's settling is held back by the judging budget, not by how often the watcher looks: 15,206 judgements at 40 a second is about 380 s, which is how long it takes. Looking four times as often hands each look a quarter of the budget. The cheaper entries get judged again before the dearer ones are reached, so about 4% more judgements go to the same covers, and settling takes 4% longer (15 s on the exact page, 11 s on the old one). The extra looks also cost CPU, about 5% more. The still desktop does not change at all: its settling is new pictures and background clean checks, which are already looked at every tick. The settled-minute CPU differs between the runs only because the clock and the 30-second full re-judge fall at different points of each run.

A setting that makes settling faster would need more judging budget, and that is a different trade. The `energy` harness command can measure the option with real models (`--tick-while-covers-over N`). It has not been run: it needs the models folder.

## What is not measured yet

- **Battery drain.** Nothing here measures watts. CPU time on a fast Mac is a stand-in, not a battery figure.
- **The Neural Engine and the GPU.** Core ML runs the models there; their work does not show as CPU time, and their power can only be read on a real Mac.
- **A fanless MacBook Air.** Under heat it slows itself down; how soon, and what that does to the time to cover, needs one.
- **ScreenCaptureKit's own cost**, and how many frames it really sends at a still screen. The Testing report counts frames by status, so a real run will show it.
- **A whole day:** memory with every cache full, and what a day of ordinary use costs.

## Measuring it on a real Mac

For the owner or any tester, on a Mac that is not the developer's own. `powermetrics` needs an administrator password, so the owner runs it; nothing here runs it for you.

**Before you start.** Charge to 100%, unplug, set the display to a fixed brightness (turn off automatic brightness and True Tone), close other apps, keep Wi-Fi on as usual. Note the Mac model, macOS version and battery health (System Settings, Battery).

**1. An hour idle.** Open a harmless page, leave the screen still with SafeSight Mac on for an hour, the display kept awake (`caffeinate -d -t 3600`). Then the same hour with SafeSight Mac quit. In another Terminal window, during each hour:

```
sudo powermetrics --samplers cpu_power,gpu_power,ane_power,tasks --show-process-energy -i 60000 -n 60 > idle-on.txt
```

**2. An hour of browsing.** A fixed script: the same list of harmless sites, opened in turn, each scrolled for a minute, for an hour; once with SafeSight Mac on and once with it quit. Record the battery percentage at the start and the end (`pmset -g batt`), and run the same `powermetrics` line to a second file.

**3. Activity Monitor**, during both: the Energy tab's Energy Impact and 12-hour average for SafeSight Mac; the CPU tab's % CPU and Idle Wake Ups; the Memory tab's figure.

**4. A video.** Ten minutes of a harmless full-screen video in a browser (not a streaming app: macOS hides those from capture), with the same readings.

**5. The lock screen.** Lock the screen for ten minutes and read SafeSight Mac's CPU time in Activity Monitor before and after (it should barely move).

**Targets we propose** (to be confirmed by those runs, and changed if they turn out wrong):

- At a settled screen: under 1% of a core on average, Energy Impact under 1, no more than 5 idle wake-ups a second.
- At the lock screen or with the display asleep: under 0.5% of a core.
- An hour of browsing: no more than 2 percentage points of battery above the same hour without SafeSight Mac, on a MacBook Air.
- A still screen settles within 5 minutes at full power.
- Memory: under 600 MB with every cache full.

Please send the files and readings with the Mac's model; we will put them here.
