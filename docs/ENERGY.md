<!-- SPDX-License-Identifier: Apache-2.0 -->
# Energy

SafeSight Mac runs all day on your own Mac, often on a laptop's battery. It should cost you next to nothing when the screen is still, a fair share while you browse or watch, and never more just because something went wrong. This page says what it does in each state, what we have measured and how, what we have not measured yet, and how anyone can measure it on a real Mac.

One rule comes before any saving: **saving energy never shows anything sooner.** On battery, in Low Power Mode or when the Mac is hot, the only trade allowed is to keep a cover up a little longer and judge later. A cover needs the same evidence to lift in every mode (four clean judgements in a row of everything it hides), no cut-off or count changes, new pictures are judged at the full budget, and a fault covers more.

## What it does, state by state

Figures are from the lab harness on the reference Mac (below), unless marked as measured in a virtual Mac.

| State | What runs | What wakes it | Judgements | CPU |
|---|---|---|---|---|
| **Still screen, settled** (nothing covered, nothing left to judge) | Nothing is judged. The quarter-second check reads the display lists and the session state. | The check, 4 times a second. A capture frame when the screen changes; one whose pixels are all the same as before judges nothing. | 0 | the check: 0.12 CPU-ms a tick, 0.03 CPU-s a minute (0.05% of a core). In a virtual Mac, the whole app: 0.1 to 0.5% |
| **Still screen, settling** (covers waiting to lift) | A look at the last frame while covers wait for their four clean judgements; a full re-judge every 30 s while looks go on | The check, plus a look once a second (every tick while new pictures are left over; every 2 s in Low Power Mode or when hot) | the budget: 40 a second, plus one first burst of 400 | 11.7 CPU-s a simulated minute (about a fifth of a core) for 3.6 minutes on the harness's desktop |
| **Scrolling and browsing** | Each new frame's changed parts: the picture finder, the caches, the models on new pictures, covers moved with the content | Capture frames at the display's own rate while things move; one frame judged at a time, the newest | up to the budget, in bursts of up to 400 | a busy page shown for the first time: 22.8 CPU-s until it rests; shown again: 0.3 CPU-s |
| **A full-screen video** | The video's area, judged frame after frame, as fast as judging allows | Capture frames at the display's rate | about 1,000 a minute in the harness's case | 89% of a core |
| **Display asleep, Mac asleep, screen locked** (the screensaver too, once the lock screen is up) **or another account on the screen** | Nothing is captured or judged. Every display is held covered, or, at the lock screen, the covers are taken off. | The check only, which also ends the hold | 0 | the check's cost |
| **On battery** | The same as on power: the settings that cost least in total are already the ones used on power | as on power | as on power | as on power |
| **Low Power Mode, or the Mac is hot** | As on power, but a look every 2 s while only covers wait to lift | Fewer looks | the same budget | settling: half the power at any moment (6.4 CPU-s a minute), the same total, over a longer time (6.5 minutes) |

A few notes:

- **The quarter-second check** is the one timer that runs at a settled screen. It backs up macOS's own notices: a display change nobody announced, the lock screen, judging that has stalled, frames left waiting too long. It keeps the same rate in every mode, because it is part of how the cover fails safe.
- **Capture frames.** ScreenCaptureKit sends a frame when the screen changes. Each frame with new pixels is copied once into the watcher's memory on the capture queue, and compared with the last frame to find what really changed. Frames that come while another is judged wait in a mailbox of one per display, which keeps only the newest pixels and adds up what changed, so nothing is dropped unjudged.
- **Coming back** (wake, unlock, back from another account): every display stays covered whole until a frame from a stream started after you came back has been judged.
- **Lid closed:** with no other display, the Mac sleeps (the row above). With an external display, the built-in display is simply gone, and the rest goes on as usual.
- **Memory.** In the harness, the process uses about 660 MB with the three models loaded and about 900 MB at its peak, with a busy Retina page, its caches and the harness's own pictures. The app in a virtual Mac used 230 to 315 MB. Models stay loaded while the screen is still, so a new picture never waits for them.

## What changed for energy

| What | Where | Before | After |
|---|---|---|---|
| Capture while asleep, locked or switched away | `CoverCoordinator.willChange` and `tick` (`pauseForHold`), `StreamScheduler.pause` | streams kept running for nothing: about 26 frames a second captured and compared at the lock screen in the virtual Mac, 10 to 54% of a core | streams stopped; started again after the wake, every display covered whole until a frame of the new streams is judged |
| Settling on a still screen | `EnergyMode.lookEvery`, `WatcherController.askForLooks`, `DisplayPipeline.hasLeftOverWork` | a look every quarter second, each with what a quarter second of budget brings | a look a second, each with a second's budget; every tick while new pictures are left over. **78.3 to 42.5 CPU-s** to settle the harness's desktop (46% less); 160 s to 217 s to settle |
| Low Power Mode and heat | `EnergyMode`, `PowerState` | the same as on power | a look every 2 s: half the CPU at any moment, the same total, 389 s to settle |
| The capture callback's frame copy, every frame with new pixels | `RGBAImage.fromBGRA` | 4.2 CPU-ms a 2880 x 1800 frame (12.3 at 5120 x 2880): 25% of a core at 60 frames a second | **1.35 CPU-ms** (4.1 at 5120 x 2880), byte for byte the same: 8% of a core at 60 frames a second |
| A slow first load (Core ML building its cache, 12.3 s in the virtual Mac, past the 10 s `WARM_UP_LIMIT`) | `WatcherController.loadDetector`, `Register.WARM_UP_SLOW_LIMIT` | a detector failure: covered whole until someone pressed Try again | covered whole with the repair card at 10 s, as before; if the warm-up then ends well within 120 s, covering starts by itself. Nothing is judged or shown before the models are ready |

The energy mode follows macOS's own notices (power source, Low Power Mode, thermal state); nothing polls for it. The Testing edition follows Low Power Mode and heat only: it links no IOKit, which the power source needs.

**What we tried and dropped,** measured the same way (`results/energy-tried-*.json`):

- **A duty cycle for settling** (looks may take at most a quarter of the judging time): the desktop took 842 s to settle instead of 160 s, and 419 CPU-s instead of 78. Most of a look's CPU time is its fixed cost (the window split, finding pictures, hashing every picture for the cache), not its judgements, so stretching the looks out multiplied that cost.
- **A smaller share of the budget on battery** (half, a look every 2 s): 617 s and 67.5 CPU-s to settle, more in total than at full power, because the checks that come round every 30 s kept coming for longer.
- **A quarter of the budget in Low Power Mode** (a look every 4 s): it had not settled after 20 minutes. Slower settling is safe (covers stay up), but it was not gentler.

So no mode lowers the judging budget. Saving comes from fewer, larger looks.

**The burst about every 30 s at a settled screen is kept.** A frame whose pixels are all the same as before judges nothing at a settled screen (main does this since pull request 31, and `EnergyBudgetTests` holds it). What is most likely left is the full re-judge (`FULL_REJUDGE`): the first frame with a real change (the menu bar clock, say) more than 30 s after the last full pass judges the whole display again, not only the change. That is a protection: a picture shown as clean gets another look with fresh jitter. Most of it comes from the caches; the cost is the picture finder and hashing over the display, a short burst, and its average stays well under the 1% target below.

**Settling stays the main cost.** It is the price of the rule that a cover lifts only after four clean judgements of everything it hides: on a busy desktop that is thousands of judgements, a third of them second clean checks that make later reuse cheap. Making each look and each judgement cheaper is the way to cut it further.

## In a virtual Mac (measured live, 20 November 2026)

The Testing edition, lab build, in a disposable virtual Mac (Tart, macOS 26.6.2, 1024 x 768 points at 2x, no Neural Engine, judging 250 to 470 ms a frame), read from Activity Monitor and the lab log. These figures are from before this change; they are why it was made.

- **On main before pull request 31, a still desktop never settled:** about 18 frames a second, each reported as the whole display changed, 117 to 170% of a core.
- **With pull request 31** (what changed read from the pixels): settling 100 to 160% of a core for about 5 minutes, 290 to 315 MB; settled 0.1 to 0.5% of a core, 230 to 270 MB, with a burst of 2 to 10% about every 30 s.
- **At the lock screen** capture kept running: about 26 frames a second captured and compared, 10 to 54% of a core.
- **The first launch** waited 12.3 s while Core ML built its cache.

They have not been measured again with this change; that needs another run in the virtual Mac. There, with no Neural Engine, each judgement costs many times what it does on a real Mac, so settling will still be heavy for a few minutes.

## The energy budget

The project holds itself to these figures (`EnergyBudget` in `Sources/SafeSightMacWatcher/Energy.swift`). The tests (`EnergyBudgetTests`, `EnergyHoldTests`) and the harness (`safesightmac-harness energy --check`) fail when one is exceeded.

| Figure | Budget | Measured |
|---|---|---|
| Judgements at a settled still screen | 0 a minute | 0 |
| Looks asked for at a settled still screen | 0 a minute | 0 |
| Timer wake-ups at a settled still screen | 240 a minute (the quarter-second check) | 240 |
| Judgements while a still screen settles | the budget (40 a second) plus one burst of 400 | 40.8 a second; no judge call ever over its budget |
| Looks while only covers wait to lift | one a second at full power | 242 looks in 217 s, ticks with new pictures left over included |
| Time for the harness's still desktop to settle | 300 s (600 s in Low Power Mode or when hot) | 217 s (389 s) |
| CPU while it settles | 18 CPU-s a simulated minute | 11.7 |
| CPU for a reload of a judged busy page | 2 CPU-s | 0.3 |
| CPU while the harness's video plays | one core | 0.89 |
| The frame copy, 2880 x 1800 | 3 CPU-ms | 1.35 |

The CPU figures are for the reference Mac; a slower Mac uses more.

## How it was measured

On a developer Mac (Apple M1 Max, 64 GB, macOS 26.3), release lab build, the three real models (checked against the sealed hash list), the sealed cut-off table, Balanced. Nothing captured the screen: the harness feeds frames to the real cover layer and the real detector. The Mac was shared with other work at the time (load average about 4 to 16), so CPU times may read a little high; counts and settling times are less affected.

```
SAFESIGHTMAC_LAB=1 swift build -c release --scratch-path .build-lab
.build-lab/release/safesightmac-harness energy SCREENSHOT --models MODELS_DIR --windows WINDOWS_FILE \
    --pages LAB/data/finder-bench-heldout/screens --power full --json results/energy-after.json --check
```

- **The clock is simulated.** A still screen's minutes of settling run in the time the work itself takes, and only that work is counted. Looks come as the watcher would ask for them. CPU time is the process's own (every thread, user and system) counted around the watcher's work; memory is the process's footprint.
- **Cases.** `still`: a harmless screenshot of a virtual Mac's desktop (1024 x 768 points at 2x, with its window list), from the first frame until nothing is drawn and no look is wanted, then a minute at rest. `reuse`: the busiest of the lab's harmless held-out pages (2880 x 1800), judged until it rests, then shown again. `video`: a 1280 x 720 pixel area of new harmless noise every frame at 30 frames a second over that page, for a minute, judged one frame at a time with only the newest frame taken. `copy`: the frame copy at 2880 x 1800 and 5120 x 2880. `tick`: the quarter-second check's system reads.
- **Before** is main at df457a6 with only the energy command added; **after** is this change. Results: `results/energy-before.json`, `results/energy-after.json` (full power and battery), `results/energy-low.json`, and the three tried and dropped.

| Harness case | Before | After |
|---|---|---|
| Still desktop: time to settle | 160 s | 217 s |
| Still desktop: judgements to settle (second clean checks among them) | 6,580 (1,924) | 8,868 (3,256) |
| Still desktop: looks | 337 | 242 |
| Still desktop: CPU to settle | 78.3 CPU-s | 42.5 CPU-s |
| Still desktop at rest, a minute | 0 judgements, 0 looks | 0 judgements, 0 looks |
| Busy page, first showing until it rests | 4,692 judgements, 48.0 CPU-s, 112 s | 5,418 judgements, 22.8 CPU-s, 127 s |
| Busy page shown again | 12 judgements, 0.1 CPU-s | 40 judgements, 0.3 CPU-s |
| Video, a minute | 150 frames judged, 92% of a core | 163 frames judged, 89% of a core |
| Frame copy, 2880 x 1800 / 5120 x 2880 | 4.2 / 12.3 CPU-ms | 1.35 / 4.1 CPU-ms |
| The quarter-second check | 0.13 CPU-ms a tick | 0.12 CPU-ms a tick |

Settling now makes a third more judgements, mostly second clean checks, because a look a second leaves more of the budget spare for them. Their cost on the Neural Engine and the GPU is not in these CPU figures; the real-Mac runs below will say whether the trade holds there too.

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
