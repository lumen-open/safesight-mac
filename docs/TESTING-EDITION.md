<!-- SPDX-License-Identifier: Apache-2.0 -->
# SafeSight Mac Testing: the Testing edition

19 November 2026. Built and checked on a developer Mac (Apple M1 Max, macOS 26.3, Xcode 26.6, Swift 6.3.3) through tests, the lab harness and the checks CI runs. **Like the cover-only app it comes from, it has not been run live on any Mac yet** (see "Not done yet").

The owner's words: "I don't want people screwing up their Macs because of me, so we should develop and offer some sort of JUST TESTING mode that guarantees it's just a testing mode, and we must do a very careful pass to make sure it won't mess anything up on the Macs of any helpers who install it. Probably even hold off on being able to install the actual full system."

So for now the Testing edition is the only thing helpers are offered. There is no installer for the full system in this repository, and none is offered.

## What it is

**SafeSight Mac Testing** is the cover-only app of step 1 ([STEP-1-STATUS.md](STEP-1-STATUS.md)), built as its own app for people who help test it:

- It checks the screen and covers explicit images and video, exactly as the cover-only app does: same detector, same covers, same way out.
- It has **no lock and nothing that could add one**. It protects nothing against the person using it, and it is not meant to.
- It is clearly labelled everywhere: **"Testing edition: no lock. Quit any time with ⌃⌥⌘Q."**
- macOS keeps it in the **App Sandbox**: it can't write anywhere but its own folder, and it has no network access at all.
- It quits at once with **⌃⌥⌘Q**, even when a cover is in the way, and **removes its own data** with one click.

It is built with `SAFESIGHTMAC_TESTING=1` and assembled with `tools/make-app.sh --testing`. Its name is "SafeSight Mac Testing" and its bundle identifier must end in `.testing`, so it never shares a Screen Recording permission, settings or a sandbox with the full app.

## The guarantees, and how each is kept

Each guarantee is enforced in code and checked automatically. The checks run on every push and pull request (`.github/workflows/check.yml`).

### 1. No lock, ever

It contains no keeper, no installer, no updater, and no code that creates accounts, changes passwords, installs launch daemons or agents, privileged helpers, system extensions or profiles, adds a login item, or asks for an administrator.

**Enforced by the build.**
- `SAFESIGHTMAC_TESTING=1` (Package.swift) compiles the Testing edition. The keeper check (`PracticeState`, which looks for a root-owned keeper launch file in `/Library/LaunchDaemons`) is compiled out, so the app never even reads that folder. Its menu shows "Testing edition: no lock" instead of the practice state, and pausing is always allowed.
- The models come only from inside the app: the `SAFESIGHTMAC_MODELS` override and the working-folder fallback are compiled out.
- The app links one module the release app does not, `SafeSightMacTestingEdition` (the emergency quit, the sandbox check, one copy at a time, the stall watchdog and the removal). Any future lock code (`keeper/`, the opener, the time lock) lives in other modules or projects and cannot reach the Testing app without changing its module list, which the check below refuses.

**Checked by `tools/check-testing-edition.sh`** (a CI step), on what is actually built:
1. **Modules.** The Testing app's dependency closure, from `swift package describe`, must be exactly nine known modules, with no outside package.
2. **Sources.** `tools/testing_edition_scan.py` reads every source file of those modules as the Testing build compiles them (comments dropped, code under `#if !SAFESIGHTMAC_TESTING` or the lab flag skipped, any other condition counted as compiled in; string interpolations and raw strings are read properly, and the scanner first checks itself on a made-up file, which a naive reader fails). It fails on any lock, install, admin, keychain, account, process, Apple-event, XPC, recording or screen-takeover API; on reaching code by name (`dlopen`, `dlsym`, `NSClassFromString`, `NSSelectorFromString`, `objc_getClass`), which no scan could follow; on watching other apps' keys, starting again at login, other apps' settings, opening other apps (`NSWorkspace.shared.open` is allowed on one line only, the one that opens the Screen Recording settings), screenshots and full-screen takeover; on writing data to any file (`Data.write(to:)`, `FileHandle` for writing, `fopen`, `fwrite`, output streams: the app writes no file of its own); on any of the words `launchctl`, `LaunchDaemons`, `LaunchAgents`, `PrivilegedHelperTools`, `LoginItems`, `sudo`, `osascript`, `dscl`, `sysadminctl`, `tccutil`, `mobileconfig` and others, and any string literal that starts with a system path (`/Library/`, `/System/`, `/usr/`, `/bin/`, `/etc/`, `/private/`, `/var/`, ...). This half exists because Swift keeps short strings (15 bytes or fewer, such as `"/bin/launchctl"`) inside the instructions, where no binary scan can see them.
3. **Binary.** In the release-built Testing app: `otool -L` must show none of ServiceManagement, SystemExtensions, Security, SecurityFoundation, OpenDirectory, Collaboration, NetworkExtension, Network, CFNetwork, WebKit, EndpointSecurity, IOKit, AVFoundation, ScriptingBridge and similar frameworks. `nm -u` must import none of `SMAppService`, `SMJobBless`, `SMLoginItemSetEnabled`, `LSSharedFileList…`, `Authorization…`, `SecKeychain…`, `SecItem…`, `OSSystemExtensionRequest`, `CSIdentity…`, `OD…`, `setuid`, `chown`, `posix_spawn`, `exec…`, `fork`, `system`, `popen`, `kill`, `NSTask`, `NSAppleScript`, `NSXPCConnection`, `socket`, `connect`, `NSURLSession`, `CGImageDestination…`, `AVAssetWriter`, `SCRecordingOutput`, `NSPasteboard`, `CGDisplayCapture`, `SetSystemUIMode`, `CGEventTapCreate`, `CGEventPost`, `IOPM…` and more. `strings` must show no launchd key or path, no command, no system path, no kiosk-mode, desktop-picture, other-app-settings, kill-app or save-picture method, and no lab stand-in.
4. **Bundle.** The assembled bundle must hold only `Contents/Info.plist`, the one executable, `Resources` and the signature: no `Library/LaunchServices`, `Library/LaunchDaemons`, `Library/LoginItems`, `Library/SystemExtensions`, `PlugIns`, `XPCServices`, `Helpers` or `Frameworks`, which are where macOS looks for things to install or start. Its Info.plist must have exactly the expected keys (nothing like `SMPrivilegedExecutables` or `LSEnvironment`).
5. **Release app.** The release app must import no hot-key API and link no Testing module: the emergency quit exists only in the Testing edition.

Given the path of an assembled app (`tools/check-testing-edition.sh "SafeSight Mac Testing.app"`), it checks that copy too, with its models (which may only be the three model packages) and an ad hoc or Developer ID signature. Run it on every copy before it reaches anyone.

The check was tested by breaking it on purpose: a scratch change that registered a login item with `SMAppService`, ran `/bin/launchctl` through `Process`, wrote a file under `/Library/LaunchAgents`, set kiosk-mode presentation options and added the network entitlement failed it on every count except one: `"/bin/launchctl"` was invisible to the binary scan (a short string), which is why the source scan was added. The source scan, tried on a probe file, caught it.

### 2. It can't change anything outside itself

**The App Sandbox, with one entitlement.** `tools/make-app.sh --testing` signs the app ad hoc, with the hardened runtime and `packaging/Testing.entitlements`, which holds one entitlement: `com.apple.security.app-sandbox`. That is the whole list. With nothing else, macOS lets it:
- write files only inside its container, `~/Library/Containers/<bundle id>/`;
- use no network at all (it has no `network.client` or `network.server` entitlement);
- reach no other app's data, no camera, microphone, contacts, calendars, location, user-chosen files or Apple events.

Screen Recording is not an entitlement: ScreenCaptureKit works in sandboxed apps once the person grants the permission in System Settings. Reading its own models (inside the app), drawing windows above other apps, registering its shortcut and reading the window list are all allowed in the sandbox.

**It runs only inside the sandbox.** At start the app checks that it is sandboxed (`Sandbox.isSandboxed`: macOS sets `APP_SANDBOX_CONTAINER_ID` and gives a sandboxed app a home inside `~/Library/Containers`; both must be there). If not (run with `swift run`, or a bundle not made by `make-app.sh --testing`), it checks and covers nothing: its menu says "Not sandboxed: covering is off", nothing in it starts covering, and Quit and Remove work as usual.

**Checked:** the bundle check above requires the signature to carry exactly the App Sandbox and the hardened runtime. The removal (guarantee 5) touches only the container, and never follows a symbolic link.

**In the harness.** The rules for this work forbid running the menu-bar app or capturing the real screen on the developer Mac, and running any sandboxed binary there creates a container in `~/Library/Containers`. macOS's own App Sandbox profile cannot be applied by hand (`sandbox-exec` refuses `application.sb`: "unsupported syntax"). So the harness, built as a lab Testing build, was run under a stricter hand-written Seatbelt profile: no network of any kind, no new processes, and no file writes anywhere except its own output and temporary folders. See "The harness inside a sandbox" below for what it did there.

**Not verified:** ScreenCaptureKit capture inside the real App Sandbox, on a live Mac. That is the first thing to check on the test Mac (see "Not done yet").

### 3. It can never trap anyone

- **Quit from the menu** at any time: "Quit SafeSight Mac Testing", which also shows ⌃⌥⌘Q.
- **⌃⌥⌘Q quits from anywhere** (`EmergencyQuit`). It is a Carbon hot key (`RegisterEventHotKey`): macOS matches the key press and tells the app that its own shortcut was pressed, whichever app is in front and whatever covers are up. The app never reads the keyboard: it asks macOS for no Accessibility or Input Monitoring permission, and this is the call sandboxed Mac App Store apps use for their global shortcuts. **Not proven here:** on the developer Mac, every process started from the terminal inherits the terminal's Accessibility and Input Monitoring permissions (`AXIsProcessTrusted()` is true there), so a local test cannot tell. The test prints whether its process has the permission, so a CI log where it has none shows the registration working without it; the test Mac must confirm that a real ⌃⌥⌘Q quits while SafeSight Mac Testing is listed under neither permission. On ⌃⌥⌘Q the app takes its covers off, removes its compiled models and ends at once, without waiting on anything that could be stuck.
  - **Any keyboard layout.** A hot key is a place on the keyboard, but people press the key printed Q. On AZERTY (French, Belgian) that key is where QWERTY has A, and on Dvorak where QWERTY has X. The app finds the key that types Q in the layout in use (`KeyLayout`, with ⌘ held, so "Dvorak - QWERTY ⌘" works too) and registers it again when the layout changes. Tested on the US, French, Belgian, German, Dvorak and Dvorak-QWERTY ⌘ layouts, read without selecting them.
  - **Never a shortcut that does not work, as far as the app can tell.** The shortcut is registered exclusively. If another app holds ⌃⌥⌘Q exclusively, macOS refuses (checked with two processes on macOS 26), and every line then reads "Testing edition: no lock. Quit any time from its menu bar icon." with a note in the menu. Tested. An app that registered ⌃⌥⌘Q without exclusivity gets it as well (the Testing edition still quits), and a shortcut set in System Settings or a key remapper can take it first; neither can be seen from inside the app, which is why the menu always has Quit.
  - **Layout changes are followed in the background.** macOS holds back the "layout changed" notification from an app that is not in front, and a menu bar app almost never is, so the app also compares the layout's name every two seconds and registers the key again when it changes.
  - The whole path from a hot-key event to the quit is tested by sending the event to the app's own event target (no key is pressed in tests).
- **Covers vanish the instant it quits or crashes.** Covers are the app's own windows (`CoverPanel`, an `NSPanel` in the app's process), and the binary check shows the Testing app starts no other process, so nothing else can draw a cover. macOS's window server removes every window of a process when the process ends, however it ends. **Confirmed** by `tools/check-covers-vanish.sh` (CI): a child process makes a real cover window (invisible and off every display), the check finds it in the window list, then kills the child with SIGKILL, as abruptly as a crash, and fails if the window lingers for two seconds. On the developer Mac it was gone 3 ms after the kill, and 5 ms after a child that quit normally.
- **No whole-screen cover without the way out and the shortcut.** Whole-window and whole-display covers carry the way-out line and, under it, the Testing line with ⌃⌥⌘Q, from the moment they are drawn. In the Testing edition, so does **any cover that hides at least half a display**, even over a picture, and when several smaller covers together hide half a display, the largest of them that has room carries it (in the release edition picture covers stay wordless). The repair card, with Quit and the same two lines, appears after 2 s of a whole-display cover, on a display that is covered whole. A whole-display cover leaves the menu bar, and the app's menu, in sight while the menu bar is shown.
- **Nothing starts after a stop.** Pause, Quit or Remove while the models are still loading could let the capture start afterwards and cover every display whole, with no repair card (found by the independent review, below). A stopped capture now can never start again, and no cover is drawn once the watcher has stopped. This applies to both editions.
- **Its alerts sit above the covers** (the removal message, and "already running" in a second copy, which the first copy's covers could otherwise hide).
- **A stuck app ends itself** (`StallWatchdog`). This is the one place where a fault uncovers, against the rule that faults always cover more: that rule protects people who chose the lock, and the Testing edition has no lock and must never trap anyone. The watchdog is compiled into the Testing edition only; the check above fails if the release app links its module. Every way to quit runs on the app's main thread. If that thread stopped answering while a cover was up, the cover could stay, and an app with no Dock icon is not listed in the Force Quit window. A timer on another thread watches the main thread's heartbeat; after 8 s of silence with a cover up, it ends the app, and the covers go with it. It is armed before covers are drawn, so a hang while drawing them counts too. If the watching timer itself ran late (the Mac slept, App Nap, a debugger), it waits instead of quitting. Tested with a simulated clock.
- **No login item and no auto-start.** It adds none (the checks above forbid the APIs and the launchd words), it calls `disableRelaunchOnLogin()` so "Reopen windows when logging back in" does not start it again, and it keeps no window state. It starts only when the helper opens it, or if the helper adds it to Login Items in System Settings themselves.
- **One copy at a time.** A second copy (say, one left in Downloads) says "SafeSight Mac Testing is already running" and quits, instead of drawing a second set of covers and fighting over ⌃⌥⌘Q.

### 4. No network, nothing recorded

- `tools/check-no-network.sh` (unchanged, CI) fails if any source names a networking API.
- In the sandbox, with no network entitlement, macOS blocks every connection.
- The binary check forbids the networking frameworks and calls (`socket`, `connect`, `getaddrinfo`, `NSURLSession`, `CFSocket`, `nw_…`), and every way to save or hand out a picture of the screen: `CGImageDestination…`, `AVAssetWriter`, `SCRecordingOutput`, `NSPasteboard`, `CGWindowListCreateImage`, `CGDisplayCreateImage`.
- As in the cover-only app, frames stay in memory and are never written to a file, a log or a crash report. The source scan fails on any way of writing data to a file. A scan cannot tell what bytes a write would carry, so this rests on that rule, the code and the sandbox: inside it, any file the app could write would be in its own container, which Remove empties.

### 5. Clean removal

**"Remove SafeSight Mac Testing"**, in its menu, one click:
1. stops covering and waits up to 3 s for judging to finish;
2. removes its settings (the detector mode) and empties the folders it keeps data in, inside its sandbox container: `Library/Caches` (where Core ML is expected to keep its caches for the models, which can be a few hundred MB), `Library/Application Support`, `Library/Saved Application State` (none of its windows keeps state, so there should be nothing), `tmp` (the compiled models) and its own `Library/Preferences/<bundle id>.plist`; and the contents of the cache and temporary folders macOS gives a sandboxed app under `/var/folders`, but only when such a folder is named after the app's identifier (outside the sandbox those folders are shared, and are left alone);
3. says what macOS keeps and how to remove it, above any cover, with buttons to open the Screen Recording settings or show the app in Finder;
4. removes the same again, for anything written while the message was up, and quits.

The removal only works inside this app's own sandbox container (its `Data` folder, in a container named after the app's identifier; anywhere else it removes the settings alone), never removes the folders themselves (macOS made them), and never follows a symbolic link: a container holds links to the person's own Desktop, Documents and Downloads. A link directly in a cleared folder is left alone, and a link inside a removed folder goes as a link, never what it points to. Tested on a made-up container with links pointing out of it.

What macOS keeps, and how to remove it, is under "Removing it" below.

### 6. Unmistakable labelling

"**Testing edition: no lock. Quit any time with ⌃⌥⌘Q.**" (`AppText.testingLine`) is on:
- the menu bar item: the icon with the word "Testing" beside it, and the line as its tooltip and spoken label;
- the top of its menu, with what the edition is ("It has no lock and installs nothing...");
- the repair card, under the way-out line, drawn the same way (words and key caps);
- whole-window and whole-display covers, under the way-out line, and any cover hiding half a display;
- the "How it works" window, which opens with it and leaves out the release app's "the lock comes in a later version";
- the app's name in Finder, the menu and the windows: "SafeSight Mac Testing".

All of its words are in `AppText`, with the product's name from `AppText.productName`, and pass the words test (`AppTextTests`: the line word for word, none of the phrases the project never uses). The lines and the card use the app's own drawing and colours (`WayOutArt`, `CoverTheme`): the desert look, with plain key caps, in light and dark. In "How it works" the line is set in the heading face, above the plain words.

## Building and running it from source

For developers. Helpers who do not build software should wait for the signed download (see "Not done yet").

**You need** a Mac with macOS 15 or later, Xcode 16 or later (Swift 6), and the watcher's three converted Core ML model packages (Marqo ViT-tiny, NSFWJS and the Bumble tie-breaker) in one folder matching `models/watcher-models.sha256`. The weights are not in git (`tools/models/fetch_upstream.py` fetches the upstream ones), and the conversion tools are not in this repository yet ([STEP-1-STATUS.md](STEP-1-STATUS.md), "What needs the founder"), so for now the converted folder comes from the founder. `make-app.sh` refuses any copy that does not match the sealed hash list.

```sh
# Build and test the Testing edition
SAFESIGHTMAC_TESTING=1 swift build -c release --scratch-path .build-testing
SAFESIGHTMAC_TESTING=1 swift test --scratch-path .build-testing
tools/check-testing-edition.sh
tools/check-covers-vanish.sh

# Assemble the app: .build-testing/SafeSight Mac Testing.app, ad hoc signed, sandboxed
tools/make-app.sh --testing <rd>.safesightmac.testing /path/to/converted-models
```

`<rd>` is the reverse-domain prefix (not chosen yet; any you control will do for your own Mac). The identifier must end in `.testing`.

**Running it.** Move the app to Applications if you like, and open it. There is no Dock icon: look for "Testing" in the menu bar.
1. The menu says "Needs Screen Recording". Choose **Open Screen Recording settings…**, turn on SafeSight Mac Testing in System Settings, Privacy & Security, Screen & System Audio Recording, and let macOS quit and reopen it.
2. The menu should say **"Covering: on"**. If it says "Not sandboxed: covering is off", the app was not made by `make-app.sh --testing`.
3. When it starts, and after sleep or a display change, each display is covered whole until it has been checked: a few seconds, longer the first time while the models load. The cover shows the way out and ⌃⌥⌘Q.

**After a rebuild.** An ad hoc signature is new with every build, so macOS treats each build as a new app for Screen Recording: the old entry stays in the list but no longer applies. Remove it with the minus button and grant the new build again (or run `tccutil reset ScreenCapture <bundle id>`).

## Removing it

1. In its menu, choose **Remove SafeSight Mac Testing**. It removes its settings and data and quits.
2. Remove the **Screen Recording permission**: System Settings, Privacy & Security, Screen & System Audio Recording, select SafeSight Mac Testing and click the minus button. macOS may ask for your password: that is System Settings asking, not the app. (Developers: `tccutil reset ScreenCapture <bundle id>`.)
3. Drag **SafeSight Mac Testing** from Applications to the Trash.
4. Optional: macOS keeps the app's sandbox folder, emptied of its data by step 1. In Finder, choose Go, Go to Folder, type `~/Library/Containers`, and move the folder for SafeSight Mac Testing (Finder shows its name; the folder is named after its bundle identifier) to the Trash. If `~/Library/Application Scripts` has a folder with the same identifier, it is empty and can go too. macOS may ask you to confirm.

If you dragged the app to the Trash without step 1, its container still holds its settings and Core ML's caches: step 4 removes them.

Other things that are macOS's, not the app's: if you added it to Login Items yourself, remove it there (System Settings, General, Login Items). If it ever crashed, macOS kept a crash report in `~/Library/Logs/DiagnosticReports` (it holds no picture of your screen; it is sent to Apple only if you share analytics). macOS's own logs rotate by themselves.

## What helpers can test, and the one rule

**Never test it with explicit material.** Not to see whether it works, not once. Use it with what you normally do. Developers who need a picture that must be covered use the lab stand-in, a synthetic magenta-and-green checker that exists only in lab builds (`SAFESIGHTMAC_LAB=1`) and the harness; the Testing edition has no stand-in.

What helps most:
- **False covers:** anything harmless that gets covered or blurred, and in which app or site. Describe it; send a screenshot only if nothing private is on screen.
- **Speed:** a picture you could see before its cover, pages that stay blurred for long, lag, fan noise, battery drain.
- **Displays:** external displays, plugging and unplugging, sleep and wake, mirroring, resolution changes, full-screen apps.
- **Getting out:** any moment when you could not quit or leave a page as the covers say, or anything it left behind after removal.

Report in a GitHub issue. If you find a way around the cover or the lock of the full app, report it privately as [SECURITY.md](../SECURITY.md) says, never in public.

## The safety pass (19 November 2026)

Every way the Testing edition could get in a helper's way or leave something behind, walked through from install to reinstall. **Fixed** means changed in code and tested; **by design** means it stays, and is escapable and documented.

| When | What could go wrong | What was done |
|---|---|---|
| Install | An unsigned or ad hoc app downloaded from someone else is stopped by Gatekeeper, and the usual advice is to bypass it | No download is offered until it is signed and notarized. Helpers are never asked to bypass Gatekeeper |
| Install | It shared an identity with the full app (Screen Recording, settings, sandbox) | **Fixed:** its own name, and an identifier that must end in `.testing` (`make-app.sh` refuses others; the check verifies) |
| Install | `make-app.sh` built a lab app, stand-in included, if `SAFESIGHTMAC_LAB` was set in the shell | **Fixed:** it unsets the lab variables, for both editions |
| Install | Anything in the bundle that macOS would install or start | None; the check fails on any bundle that is not a plain app |
| First run | A copy outside the sandbox (`swift run`, a hand-made bundle) | **Fixed:** it checks and covers nothing and says why |
| First run | Two copies running (Downloads and Applications) | **Fixed:** the second says so and quits |
| First run | Every display covered until its first judged frame, longer while the models load | By design (unjudged means covered); the covers show the way out and ⌃⌥⌘Q at once, and the repair card follows |
| First run | Models missing or changed: every display covered whole | By design (faults cover more); the card offers Quit; `make-app.sh` refuses models that do not match |
| Permission | A surprise permission prompt at launch | None: macOS is asked only when the helper chooses "Open Screen Recording settings…" |
| Permission | macOS 15 and later may ask from time to time whether to keep allowing screen recording; under a whole-display cover the question can be hidden | By design; quitting (menu, card, ⌃⌥⌘Q) shows it. Either answer is safe |
| Permission | An ad hoc rebuild is a new app to macOS: the old entry stays listed but no longer applies | Documented ("After a rebuild") |
| Normal use | A big picture cover had no words: a screen mostly covered gave no hint how to quit | **Fixed:** in the Testing edition any cover hiding half a display carries the Testing line |
| Normal use | ⌃⌥⌘Q missed on AZERTY and Dvorak keyboards (a fixed key code is a place, not a letter) | **Fixed:** the Q key is found in the layout in use, and again when it changes |
| Normal use | ⌃⌥⌘Q already used by another app | **Fixed:** exclusive registration; when taken, every line says to quit from the menu bar icon |
| Normal use | 220 MB of compiled models left in the temporary folder at every start, never removed (144 copies, 9.1 GB, had piled up on the developer Mac from lab runs) | **Fixed for both editions:** compiled into a folder of the run's own, removed at quit, and swept at the next start after a crash; in the Testing edition all of it is inside the container |
| Normal use | Core ML's cache for the models (hundreds of MB) | Inside the container; removed by Remove |
| Normal use | Energy and heat while it runs | Not measured (ST-038); pause or quit it when you don't need it |
| Normal use | A crowded menu bar (a notch) can hide its icon | ⌃⌥⌘Q works without the icon |
| Normal use | The app's main thread stuck while a cover is up; an app with no Dock icon is not in the Force Quit window | **Fixed:** the stall watchdog ends it after 8 s |
| Normal use | "How it works" cut off the last word of a paragraph on a Retina display | **Fixed for both editions:** paragraphs are measured with room for an extra line |
| Normal use | Pause, Quit or Remove while the models were loading could start capturing afterwards and cover every display whole, with no card | **Fixed for both editions** (independent review): a stopped capture never starts again, and nothing is drawn after a stop |
| Normal use | Several smaller covers hiding most of a display, with no line | **Fixed:** the largest carries the Testing line |
| Displays | With a third display (beyond `DISPLAYS_MAX`, 2) covered for good, the repair card sat in the middle of the main display and never went away | **Fixed for both editions:** the card sits on a display that is covered whole |
| Displays | Plugging, unplugging or a resolution change covers a display whole until it is judged | By design; the covers show the way out and ⌃⌥⌘Q |
| Sleep and wake | Covered whole on sleep and until judged after wake | By design. The lock screen is above every cover, so unlocking is never blocked. If capture does not come back, the card offers Try again, Pause and Quit |
| macOS update | "Reopen windows when logging back in" would start it again after the restart | **Fixed for both editions:** `disableRelaunchOnLogin()`, and no window state is kept |
| macOS update | An update may reset Screen Recording, or change capture | It then says "Needs Screen Recording" and covers nothing, or covers whole with the card. Nothing is locked |
| Crash | Covers left on screen | Not possible: confirmed gone 3 ms after the process is killed |
| Crash | Compiled models left behind | **Fixed:** swept at the next start, or by Remove |
| Crash | A crash report | macOS's, in `~/Library/Logs/DiagnosticReports`; documented. It holds no screen pictures |
| Crash | Restarted automatically | Never: it has no launchd job and no login item |
| Force quit | Not in the Force Quit window (no Dock icon) | ⌃⌥⌘Q, its menu, the repair card, Activity Monitor; and the stall watchdog |
| Uninstall | The Trash alone leaves the container: settings, Core ML caches, maybe compiled models | **Fixed:** "Remove SafeSight Mac Testing" clears them first; the empty folders macOS keeps are documented |
| Uninstall | Saved window state | **Fixed for both editions:** no window is restorable, and none is kept at quit |
| Uninstall | The removal message under a cover, or written over after the removal | **Fixed:** raised above covers; the removal runs again after it |
| Uninstall | Removing through a link and deleting the person's own files | Not possible: links are never followed (tested) |
| Reinstall | Old settings come back | Only the detector mode, in its own container; Remove clears it |

Not changed, and why:
- **Secure input.** Whether ⌃⌥⌘Q fires while a password field has the keyboard is not verified. Registered hot keys are matched by macOS rather than read from the keyboard, so it is expected to; the menu works either way.
- **System panels under covers.** Notifications, Spotlight and system prompts sit under a whole-display cover (the cover layer's working level, ST-032). Quitting shows them.

## The harness inside a sandbox

The harness was built as a lab Testing build (`SAFESIGHTMAC_LAB=1 SAFESIGHTMAC_TESTING=1`, so it has the stand-in) and run with `sandbox-exec` under this profile, where any refused operation stops the process at once:

```
(version 1)
(allow default)
(deny network* (with send-signal SIGKILL))
(deny process-fork (with send-signal SIGKILL))
(deny process-exec (with send-signal SIGKILL))
(allow process-exec (literal "<the harness>"))
(deny file-write* (with send-signal SIGKILL))
(allow file-write* (subpath "<its output folder>") (subpath "<its temporary folder>")
                   (literal "/dev/null") (literal "/dev/dtracehelper") (literal "/dev/tty"))
(allow file-write-data (literal "<the folder holding the harness>"))
```

- **`demo`**, twice: the real pipeline (null models and the stand-in) covered the stand-in, lifted the cover after four clean judgements, covered the whole display on a blank frame and lowered it on the next frame, as it does outside the sandbox. It wrote its PNGs and nothing else; its temporary folder stayed empty.
- **`wayout`**, light and dark, twice: the synthetic desktops with whole-window and whole-display covers, the repair card and "How it works", every one with the Testing line, drawn and written.
- **Two controls were stopped,** as they should be: the same run pointed at an output folder outside the allowed ones, and `vanish`, which starts a process.
- **One allowance was needed:** AppKit checks whether the folder holding an unbundled program is writable (a `file-write-data` check on the folder itself; nothing is written there). Inside the App Sandbox such a check is simply refused.

So the judging and drawing code, Testing line included, needs no network, starts nothing and writes nothing outside its own folders. This is not the App Sandbox itself: macOS's profile cannot be loaded this way, so the container, the entitlement and capture inside the sandbox are still to be seen on a test Mac.

Looking at the scenes it drew found one bug: in "How it works", the last word of the Testing edition's second paragraph was cut off. A line that only just fits when measured can wrap when drawn on a Retina display. Paragraphs are now measured 8 points narrower than they are drawn, and a test checks that every paragraph, in both editions, has room for that.

## Independent review (19 November 2026)

A second reviewer read the code, without this document's conclusions, looking for traps, writes outside the container, holes in the checks and claims not shown true. Found and fixed:
- **Covers after a stop** (the most serious): see "Nothing starts after a stop" under guarantee 3. Fixed in `ScreenCapture` (a closed capture never starts) and `WatcherController` (no plan is drawn once stopped; the capture handle is read on the main thread only).
- **The layout notification held back** while the app is not in front: the two-second check.
- **"Registration fails if another app holds the shortcut"** was only true for an exclusive holder: the wording is now exact, and the menu always offers Quit.
- **The stall watchdog was armed after drawing**: now before.
- **Several smaller covers** could hide most of a display with no line: the largest now carries it.
- **Alerts could sit under covers**: they are raised above them.
- **Removal** now needs the container to be this app's own (a crafted home folder could otherwise point it at another app's container), runs twice, and clears the app's own system cache folders. The compiled-models sweep no longer removes a folder that another process may have just made.
- **The checks** now also catch reaching code by name, file writes, opening other apps, watching keys, settings for other apps and more; the source scanner reads interpolations and raw strings and tests itself; and the check can be run on a finished, signed app. The release app's check no longer depends on the shell's variables.

Not changed: the sandbox check relies on what macOS tells a sandboxed app (an environment variable and its home folder); a person who crafts both for a copy run outside the sandbox gets what they asked for, and the removal still touches only a folder named after the app. The review found no memory-safety problem in the hot-key code.

## Not done yet

- **Nothing has been run live.** The app has not been opened on any Mac: the rules for this work forbid running it or capturing the screen on the developer Mac. On the test Mac, check first, in this order: the menu reads "Covering: on" (capture works inside the App Sandbox); ⌃⌥⌘Q quits with a real key press, also with a password field focused and in a full-screen app; the lab stand-in (in a lab Testing build) is covered and the Testing line shows; "Remove SafeSight Mac Testing" leaves only what is listed under "Removing it".
- **Signed, notarized downloads come later,** once the founder joins the Apple Developer Program. Until then the Testing edition is built from source and signed ad hoc, for the builder's own Mac or a test Mac; it is never handed out.
- **The App Sandbox itself** was not exercised in a real container here (see guarantee 2). Where Core ML and Metal keep their caches for a sandboxed app (the container's `Library/Caches`, or the per-app folder under `/var/folders`) is expected, not seen; the test Mac should confirm that Remove leaves neither.
