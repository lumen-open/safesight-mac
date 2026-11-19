<!-- SPDX-License-Identifier: Apache-2.0 -->
# SafeSight Mac Testing: the Testing edition

19 November 2026, updated the same day after its first live run. Built and checked on a developer Mac (Apple M1 Max, macOS 26.3, Xcode 26.6, Swift 6.3.3) through tests, the lab harness and the checks CI runs. It has been run live only in a disposable virtual Mac (macOS 26.6.2 under Tart), never on a physical Mac: see "The first live runs" below.

Nobody's Mac should come to harm because they offered to help. So the Testing edition is built to be only a test, with each guarantee below enforced in code and checked, and the full system is held back until it has been tried safely.

So for now the Testing edition is the only thing helpers are offered. There is no installer for the full system in this repository, and none is offered.

## What it is

**SafeSight Mac Testing** is the cover-only app of step 1 ([STEP-1-STATUS.md](STEP-1-STATUS.md)), built as its own app for people who help test it:

- It checks the screen and covers explicit images and video, as the cover-only app does: the same detector, rules, covers and way out, from the same source files (a CI check holds them to that; see "How this differs from the real thing").
- It has **no lock and nothing that could add one**. It protects nothing against the person using it, and it is not meant to.
- It is clearly labelled everywhere: **"Testing edition: no lock. Quit any time with ⌃⌥⌘Q."**
- macOS keeps it in the **App Sandbox**: it can't write anywhere but its own folder, and it has no network access at all.
- It quits at once with **⌃⌥⌘Q**, even when a cover is in the way, and **removes its own data** with one click.
- Its **Testing report** shows the numbers a bug report needs, to copy by hand. It never holds a picture, a window title, an app's name or an address.

**Who it is for.** People who want to help find what the cover gets wrong. It is **not for anyone relying on it to stay away from explicit material**, or for recovery: it has no lock, it quits with one shortcut, and it blocks no site. If that is why you are here, wait for the full app, and talk to someone you trust in the meantime.

It is built with `SAFESIGHTMAC_TESTING=1` and assembled with `tools/make-app.sh --testing`. Its name is "SafeSight Mac Testing" and its bundle identifier must end in `.testing`, so it never shares a Screen Recording permission, settings or a sandbox with the full app.

## The guarantees, and how each is kept

Each guarantee is enforced in code and checked automatically. The checks run on every push and pull request (`.github/workflows/check.yml`).

### 1. No lock, ever

It contains no keeper, no installer, no updater, and no code that creates accounts, changes passwords, installs launch daemons or agents, privileged helpers, system extensions or profiles, adds a login item, or asks for an administrator.

**Enforced by the build.**
- `SAFESIGHTMAC_TESTING=1` (Package.swift) compiles the Testing edition. The keeper check (`PracticeState`, which looks for a root-owned keeper launch file in `/Library/LaunchDaemons`) is compiled out, so the app never even reads that folder. Its menu shows "Testing edition: no lock" instead of the practice state, and pausing is always allowed.
- The models come only from inside the app: the `SAFESIGHTMAC_MODELS` override and the working-folder fallback are compiled out. The app carries them already compiled (`make-app.sh` runs `xcrun coremlcompiler`), so it never compiles a model.
- The app links one module the release app does not, `SafeSightMacTestingEdition` (the emergency quit, the sandbox check, one copy at a time, the stall watchdog and the removal). Any future lock code (`keeper/`, the opener, the time lock) lives in other modules or projects and cannot reach the Testing app without changing its module list, which the check below refuses.

**Checked by `tools/check-testing-edition.sh`** (a CI step), on what is actually built. **The check is a tripwire for honest mistakes, not a proof:** it catches a lock, installer or file write added by accident, or by someone who did not know the rules. Someone set on hiding such code from a scan can, and no scan of Swift can stop that. The real boundary is macOS's App Sandbox (guarantee 2), which holds whatever the code says, and the second human reader every lock change needs.
1. **Modules.** The Testing app's dependency closure, from `swift package describe`, must be exactly nine known modules, with no outside package and no build-tool plugin. Every key `describe` prints for a module must be one the check knows; a `path:` override is followed, and the scan reads each module's declared folder, not a guessed one.
2. **Same screen path.** The eight modules that judge and cover must be the release app's eight, and none of the detector, rules, capture or cover modules may test the Testing flag (one file may: `PracticeState.swift`, for the keeper check). See "How this differs from the real thing".
3. **Sources.** `tools/testing_edition_scan.py` reads every source file of those modules as the Testing build compiles them (comments dropped, code under `#if !SAFESIGHTMAC_TESTING` or the lab flag skipped, any other condition counted as compiled in; string interpolations, raw strings and `#if` written inside a multi-line string are read properly). It reads each file as a whole, so a call split over several lines is caught, and a module-qualified name (`Foundation.Process`, `Darwin.open`) counts like the bare one. Before scanning, it checks itself on 21 made-up probes, among them the shapes an independent reviewer used to get past an earlier version; a naive reader fails them. It fails on any lock, install, admin, keychain, account, process, Apple-event, XPC, recording or screen-takeover API; on reaching code by name (`dlopen`, `dlsym`, `NSClassFromString`, `NSSelectorFromString`, `objc_getClass`, `CFBundleGetFunctionPointerForName`, `CFBundleGetDataPointerForName`, `CFBundleLoadExecutable`, `CFBundleCreate`, `classNamed:`, `principalClass`, `loadAndReturnError:`) and on talking to launchd directly (`launch_msg`, `bootstrap_look_up`), which no scan could follow; on reading other apps' window titles or names (`kCGWindowName`, `kCGWindowOwnerName`, `localizedName`, `frontmostApplication`); on watching other apps' keys, starting again at login, other apps' settings, opening other apps (`NSWorkspace.shared.open` is allowed on one line only, the one that opens the Screen Recording settings), screenshots and full-screen takeover; on writing data to any file (`Data.write(to:)`, `String.write(toFile:)`, `FileHandle` for writing, `open` with `O_CREAT` or `O_WRONLY`, `fopen`, `fwrite`, output streams: the app writes no file of its own); on moving, copying or removing files, except in the two files whose job it is (`CompiledModels.swift` may move and remove, `Removal.swift` may remove); on any of the words `launchctl`, `LaunchDaemons`, `LaunchAgents`, `PrivilegedHelperTools`, `LoginItems`, `sudo`, `osascript`, `dscl`, `sysadminctl`, `tccutil`, `mobileconfig` and others, and any string literal that starts with a system path (`/Library/`, `/System/`, `/usr/`, `/bin/`, `/etc/`, `/private/`, `/var/`, ...). This half exists because Swift keeps short strings (15 bytes or fewer, such as `"/bin/launchctl"`) inside the instructions, where no binary scan can see them.
4. **Binary.** In the release-built Testing app: `otool -L` must show none of ServiceManagement, SystemExtensions, Security, SecurityFoundation, OpenDirectory, Collaboration, NetworkExtension, Network, CFNetwork, WebKit, EndpointSecurity, IOKit, AVFoundation, ScriptingBridge and similar frameworks. `nm -u` must import none of `SMAppService`, `SMJobBless`, `SMLoginItemSetEnabled`, `LSSharedFileList…`, `Authorization…`, `SecKeychain…`, `SecItem…`, `OSSystemExtensionRequest`, `CSIdentity…`, `OD…`, `setuid`, `chown`, `posix_spawn`, `exec…`, `fork`, `system`, `popen`, `kill`, `NSTask`, `NSAppleScript`, `NSXPCConnection`, `socket`, `connect`, `NSURLSession`, `CGImageDestination…`, `AVAssetWriter`, `SCRecordingOutput`, `NSPasteboard`, `CGDisplayCapture`, `SetSystemUIMode`, `CGEventTapCreate`, `CGEventPost`, `IOPM…`, `CFBundleGetFunctionPointerForName`, `CFBundleLoadExecutable`, `launch_msg`, `bootstrap_look_up`, `NSLookupSymbol…` and more, and the selectors `classNamed:`, `loadAndReturnError:` and `principalClass` must not appear. `strings` must show no launchd key or path, no command, no system path, no kiosk-mode, desktop-picture, other-app-settings, kill-app or save-picture method, and no lab stand-in.
5. **Bundle.** The assembled bundle must hold only `Contents/Info.plist`, the one executable, `Resources` and the signature: no `Library/LaunchServices`, `Library/LaunchDaemons`, `Library/LoginItems`, `Library/SystemExtensions`, `PlugIns`, `XPCServices`, `Helpers` or `Frameworks`, which are where macOS looks for things to install or start. Its Info.plist must have exactly the expected keys (nothing like `SMPrivilegedExecutables` or `LSEnvironment`).
6. **Release app.** The release app must import no hot-key API and link no Testing module: the emergency quit exists only in the Testing edition.

Given the path of an assembled app (`tools/check-testing-edition.sh "SafeSight Mac Testing.app"`), it checks that copy too, with its models (only the three compiled models and their hash list, `compiled.sha256`) and an ad hoc or Developer ID signature. Run it on every copy before it reaches anyone.

The check was tested by breaking it on purpose: a scratch change that registered a login item with `SMAppService`, ran `/bin/launchctl` through `Process`, wrote a file under `/Library/LaunchAgents`, set kiosk-mode presentation options and added the network entitlement failed it on every count except one: `"/bin/launchctl"` was invisible to the binary scan (a short string), which is why the source scan was added. The source scan, tried on a probe file, caught it. After the independent review, each new rule was tried the same way: a probe that looked a function up through `CFBundleGetFunctionPointerForName` was caught by both the source and the binary scan and the screen-path step failed when a detector file was made to test the Testing flag.

### 2. It can't change anything outside itself

**The App Sandbox, with one entitlement.** `tools/make-app.sh --testing` signs the app ad hoc, with the hardened runtime and `packaging/Testing.entitlements`, which holds one entitlement: `com.apple.security.app-sandbox`. That is the whole list. With nothing else, macOS lets it:
- write files only inside its container, `~/Library/Containers/<bundle id>/`;
- use no network at all (it has no `network.client` or `network.server` entitlement);
- reach no other app's data, no camera, microphone, contacts, calendars, location, user-chosen files or Apple events.

Screen Recording is not an entitlement: ScreenCaptureKit works in sandboxed apps once the person grants the permission in System Settings. Reading its own models (inside the app), drawing windows above other apps, registering its shortcut and reading the window list are all allowed in the sandbox.

**It runs only inside the sandbox.** At start the app checks that it is sandboxed (`Sandbox.isSandboxed`: macOS sets `APP_SANDBOX_CONTAINER_ID` and gives a sandboxed app a home inside `~/Library/Containers`; both must be there). If not (run with `swift run`, or a bundle not made by `make-app.sh --testing`), it checks and covers nothing: its menu says "Not sandboxed: covering is off", nothing in it starts covering, and Quit and Remove work as usual.

**Checked:** the bundle check above requires the signature to carry exactly the App Sandbox and the hardened runtime. The removal (guarantee 5) touches only the container, and never follows a symbolic link.

**In the harness.** This work was done without running the menu-bar app or capturing a real screen, and running any sandboxed binary on the build Mac would have created a container in `~/Library/Containers`. macOS's own App Sandbox profile cannot be applied by hand (`sandbox-exec` refuses `application.sb`: "unsupported syntax"). So the harness, built as a lab Testing build, was run under a stricter hand-written Seatbelt profile: no network of any kind, no new processes, and no file writes anywhere except its own output and temporary folders. See "The harness inside a sandbox" below for what it did there.

**Not verified:** ScreenCaptureKit capture inside the real App Sandbox, on a live Mac. That is the first thing to check on the test Mac (see "Not done yet").

### 3. It can never trap anyone

- **Quit from the menu** at any time: "Quit SafeSight Mac Testing", which also shows ⌃⌥⌘Q.
- **⌃⌥⌘Q quits from anywhere** (`EmergencyQuit`). It is a Carbon hot key (`RegisterEventHotKey`): macOS matches the key press and tells the app that its own shortcut was pressed, whichever app is in front and whatever covers are up. The app never reads the keyboard: it asks macOS for no Accessibility or Input Monitoring permission, and this is the call sandboxed Mac App Store apps use for their global shortcuts. **Not proven here:** on the build Mac, every process started from the terminal inherits the terminal's Accessibility and Input Monitoring permissions (`AXIsProcessTrusted()` is true there), so a local test cannot tell. The test prints whether its process has the permission, so a CI log where it has none shows the registration working without it; the test Mac must confirm that a real ⌃⌥⌘Q quits while SafeSight Mac Testing is listed under neither permission. On ⌃⌥⌘Q the app takes its covers off and ends at once, without waiting on anything that could be stuck.
  - **Any keyboard layout.** A hot key is a place on the keyboard, but people press the key printed Q. On AZERTY (French, Belgian) that key is where QWERTY has A, and on Dvorak where QWERTY has X. The app finds the key that types Q in the layout in use (`KeyLayout`, with ⌘ held, so "Dvorak - QWERTY ⌘" works too) and registers it again when the layout changes. Tested on the US, French, Belgian, German, Dvorak and Dvorak-QWERTY ⌘ layouts, read without selecting them.
  - **Never a shortcut that does not work, as far as the app can tell.** The shortcut is registered exclusively. If another app holds ⌃⌥⌘Q exclusively, macOS refuses (checked with two processes on macOS 26), and every line then reads "Testing edition: no lock. Quit any time from its menu bar icon." with a note in the menu. Tested. An app that registered ⌃⌥⌘Q without exclusivity gets it as well (the Testing edition still quits), and a shortcut set in System Settings or a key remapper can take it first; neither can be seen from inside the app, which is why the menu always has Quit.
  - **Layout changes are followed in the background.** macOS holds back the "layout changed" notification from an app that is not in front, and a menu bar app almost never is, so the app also compares the layout's name every two seconds and registers the key again when it changes.
  - The whole path from a hot-key event to the quit is tested by sending the event to the app's own event target (no key is pressed in tests).
- **Covers vanish the instant it quits or crashes.** Covers are the app's own windows (`CoverPanel`, an `NSPanel` in the app's process), and the binary check shows the Testing app starts no other process, so nothing else can draw a cover. macOS's window server removes every window of a process when the process ends, however it ends. **Confirmed** by `tools/check-covers-vanish.sh` (CI): a child process makes a real cover window (invisible and off every display), the check finds it in the window list, then kills the child with SIGKILL, as abruptly as a crash, and fails if the window lingers for two seconds. On the developer Mac it was gone 3 ms after the kill, and 5 ms after a child that quit normally.
- **No whole-screen cover without the way out and the shortcut.** Whole-window and whole-display covers carry the way-out line and, under it, the Testing line with ⌃⌥⌘Q, from the moment they are drawn. In the Testing edition, so does **any cover that hides at least half a display**, even over a picture, and when several smaller covers together hide half a display, the largest of them that has room carries it (in the release edition picture covers stay wordless). The repair card, with Quit and the same two lines, appears after 2 s of a whole-display cover, on a display that is covered whole. A whole-display cover leaves the menu bar, and the app's menu, in sight while the menu bar is shown.
- **Nothing starts after a stop.** Pause, Quit or Remove while the models are still loading could let the capture start afterwards and cover every display whole, with no repair card (found by the independent review, below). A stopped capture now can never start again, and no cover is drawn once the watcher has stopped. This applies to both editions.
- **Its alerts sit above the covers.** The removal message is raised above them. A second copy's "already running" message is a panel of its own at the level above every cover, with a Quit button, and the second copy quits by itself after 30 s anyway, so a message hidden by the first copy's covers can never hold anything up. (Whether it shows above the first copy's covers on a real screen is on the test-Mac list.)
- **A stuck app ends itself** (`StallWatchdog`). This is the one place where a fault uncovers, against the rule that faults always cover more: that rule protects people who chose the lock, and the Testing edition has no lock and must never trap anyone. The watchdog is compiled into the Testing edition only; the check above fails if the release app links its module. Every way to quit runs on the app's main thread. If that thread stopped answering while a cover was up, the cover could stay, and an app with no Dock icon is not listed in the Force Quit window. A timer on another thread watches the main thread's heartbeat; after 8 s of silence with a cover up, it ends the app, and the covers go with it. It is armed before covers are drawn, so a hang while drawing them counts too. If the watching timer itself ran late (the Mac slept, App Nap, a debugger), it waits instead of quitting. Tested with a simulated clock.
- **No login item and no auto-start.** It adds none (the checks above forbid the APIs and the launchd words), it calls `disableRelaunchOnLogin()` so "Reopen windows when logging back in" does not start it again, and it keeps no window state. (The release app does the same: it no longer comes back through "Reopen windows" after a restart either. That is accepted for now, and recorded in [STEP-1-STATUS.md](STEP-1-STATUS.md).) It starts only when the helper opens it, or if the helper adds it to Login Items in System Settings themselves.
- **One copy at a time.** A second copy (say, one left in Downloads) says "SafeSight Mac Testing is already running" and quits, instead of drawing a second set of covers and fighting over ⌃⌥⌘Q.

### 4. No network, nothing recorded

- `tools/check-no-network.sh` (unchanged, CI) fails if any source names a networking API.
- In the sandbox, with no network entitlement, macOS blocks every connection.
- The binary check forbids the networking frameworks and calls (`socket`, `connect`, `getaddrinfo`, `NSURLSession`, `CFSocket`, `nw_…`), and every way to save or hand out a picture of the screen: `CGImageDestination…`, `AVAssetWriter`, `SCRecordingOutput`, `NSPasteboard`, `CGWindowListCreateImage`, `CGDisplayCreateImage`.
- As in the cover-only app, frames stay in memory and are never written to a file, a log or a crash report. The source scan fails on the ways of writing a file it knows. It is a tripwire, not a proof, and it cannot tell what bytes a write would carry, so this rests on the code, its review and the sandbox: inside it, any file the app could write would be in its own container, which Remove empties.
- The Testing report is shown as selectable text, kept in memory and never saved; the app does not put it on the clipboard (the pasteboard API stays forbidden). The helper selects it and copies it themselves.

### 5. Clean removal

**"Remove SafeSight Mac Testing"**, in its menu, one click:
1. stops covering and waits up to 3 s for judging to finish;
2. removes its settings (the detector mode) and empties the folders it keeps data in, inside its sandbox container: `Library/Caches` (where Core ML is expected to keep its cache for the models, about 200 MB), `Library/Application Support`, `Library/Saved Application State` (none of its windows keeps state, so there should be nothing), `tmp`, its own `Library/Preferences/<bundle id>.plist` and its per-Mac settings, `Library/Preferences/ByHost/<bundle id>.*.plist`; and the contents of the cache and temporary folders macOS gives a sandboxed app under `/var/folders`, but only when such a folder is named after the app's identifier (outside the sandbox those folders are shared, and are left alone);
3. says what macOS keeps and how to remove it, above any cover, with buttons to open the Screen Recording settings or show the app in Finder;
4. removes the same again, for anything written while the message was up, and quits.

The removal only works inside this app's own sandbox container (its `Data` folder, in a container named after the app's identifier; anywhere else it removes the settings alone), never removes the folders themselves (macOS made them), and never follows a symbolic link: a container holds links to the person's own Desktop, Documents and Downloads. A link directly in a cleared folder is left alone, and a link inside a removed folder goes as a link, never what it points to. Tested on a made-up container with links pointing out of it.

What macOS keeps, and how to remove it, is under "Removing it" below.

**Core ML's cache no longer grows.** Core ML keeps a cache for each compiled model (`com.apple.e5rt.e5bundlecache`, in the process's Caches folder), filed under the compiled model's path. When every start compiled the models to a new temporary path, that cache grew by about 200 MB at every start (found by the independent review: 2.0 GB for the lab harness). Now the app carries its models compiled, at one fixed path, and the harness, lab builds and tests compile each model once, into `<Caches>/<owner>/compiled-models/<hash of the package>/`, and load that path ever after (`CompiledModels`). Measured with the harness, three starts in a row, its Caches folder redirected to a scratch folder:

| | Core ML's cache after start 1 | 2 | 3 |
|---|---|---|---|
| Before (compiled to a new path each start) | 206 MB | 412 MB | 618 MB |
| After, from model packages (compiled once, 223 MB kept) | 206 MB | 206 MB | 206 MB |
| After, from the app's compiled models (nothing compiled) | 206 MB | 206 MB | 206 MB |

The temporary folder gained no compiled model in any of these runs.

### 6. Unmistakable labelling

"**Testing edition: no lock. Quit any time with ⌃⌥⌘Q.**" (`AppText.testingLine`) is on:
- the menu bar item: the icon with the word "Testing" beside it, and the line as its tooltip and spoken label;
- the top of its menu, with what the edition is ("It has no lock and installs nothing...");
- the repair card, under the way-out line, drawn the same way (words and key caps);
- one cover per display: the whole-display cover, else the largest whole-window cover or cover hiding half the display that has room, under its way-out line if it has one (several overlapping covers once drew two to four lines stacked on one another);
- the "How it works" window, which opens with it and leaves out the release app's "the lock comes in a later version";
- the app's name in Finder, the menu and the windows: "SafeSight Mac Testing".

All of its words are in `AppText`, with the product's name from `AppText.productName`, and pass the words test (`AppTextTests`: the line word for word, none of the phrases the project never uses). The lines and the card use the app's own drawing and colours (`WayOutArt`, `CoverTheme`): the desert look, with plain key caps, in light and dark. In "How it works" the line is set in the heading face, above the plain words.

## Building and running it from source

For developers. Helpers who do not build software should wait for the signed download (see "Not done yet").

**You need** a Mac with macOS 15 or later, Xcode 16 or later (Swift 6), and the watcher's three converted Core ML model packages (Marqo ViT-tiny, NSFWJS and the Bumble tie-breaker) in one folder matching `models/watcher-models.sha256`. The weights are not in git (`tools/models/fetch_upstream.py` fetches the upstream ones), and the conversion tools are not in this repository yet ([STEP-1-STATUS.md](STEP-1-STATUS.md), "What needs the maintainers"): they live in the project's detector lab, which isn't public yet, so for now the converted folder comes from the maintainers. `make-app.sh` refuses any copy that does not match the sealed hash list.

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
1. The menu says "Needs Screen Recording". Choose **Open Screen Recording settings…**. macOS answers with **two questions of its own**, described under "The two macOS permission prompts" below: first its "would like to record this computer's screen" message (choose **Open System Settings**, turn on SafeSight Mac Testing, give your password to System Settings, and choose **Quit & Reopen**), then, after it reopens, on macOS 26, "is requesting to bypass the system private window picker" (choose **Allow**).
2. The menu should say **"Covering: on"**. If it says "Not sandboxed: covering is off", the app was not made by `make-app.sh --testing`.
3. When it starts, and after sleep or a display change, each display is covered whole until it has been checked: a few seconds, longer the first time while the models load. The cover shows the way out and ⌃⌥⌘Q. Then the screen is checked picture by picture: on a slow Mac, pictures and text that look like pictures may stay blurred for a while the first time (up to a few minutes on a slow virtual Mac), and are cleared as each is judged clean. A still screen settles to nothing covered.

### The two macOS permission prompts

Neither prompt comes from the app, and either answer is safe.

- **"SafeSight Mac Testing would like to record this computer's screen and audio."** macOS shows it the first time the app asks for Screen Recording, with **Open System Settings** and **Deny**. It is an ordinary window: it does not stay in front, and if another window comes up it slips behind it and waits there, unanswered, until you answer it or quit the app (in the first live run it sat behind System Settings, and later under the covers). So the first time, the app asks macOS and nothing else: it no longer opens System Settings over that message (not yet seen live). Answer it with Open System Settings. If you choose the menu item again, macOS does not ask again, and the app opens System Settings itself.
- **"SafeSight Mac Testing is requesting to bypass the system private window picker and directly access your screen and audio."** On macOS 26, after you turn the permission on and the app reopens, macOS asks this once more when the app first reads the screen, with **Allow** and **Open System Settings**. Until it is answered, nothing is checked, so every display stays covered whole, with the way out, ⌃⌥⌘Q and, after two seconds, the card with Quit. In the first live run the question showed above the covers. If you ever cannot see it, quit with ⌃⌥⌘Q: macOS keeps asking, and the question is in sight once the app has quit.

**A lab build for developers.** `tools/make-app.sh --testing --lab <rd>.safesightmac.lab.testing <models>` builds "SafeSight Mac Testing LAB.app" (`.build-testing-lab/`), a lab Testing build (`SAFESIGHTMAC_LAB=1`): the same app, sandboxed with the same one entitlement, that also covers the lab stand-in (the synthetic magenta-and-green checker, never a real picture) and keeps a lab event log in its own container (`Library/Caches/lab-events.log`: frame statuses, counts, timings, and window levels and rectangles in points; never a pixel, a window title, an app's name or an address). Its identifier must end in `.lab.testing` and it says LAB in its name. It is for a developer's test Mac only, never for helpers. `tools/check-no-standin.sh` proves the release build and the normal Testing build contain no stand-in and no lab log; `tools/check-testing-edition.sh` checks the normal Testing app, not this one.

**After a rebuild.** An ad hoc signature is new with every build, so macOS treats each build as a new app for Screen Recording: the old entry stays in the list but no longer applies. Remove it with the minus button and grant the new build again (or run `tccutil reset ScreenCapture <bundle id>`).

## Removing it

1. In its menu, choose **Remove SafeSight Mac Testing**. It removes its settings and data and quits.
2. Remove the **Screen Recording permission**: System Settings, Privacy & Security, Screen & System Audio Recording, select SafeSight Mac Testing and click the minus button. macOS may ask for your password: that is System Settings asking, not the app. (Developers: `tccutil reset ScreenCapture <bundle id>`.)
3. Drag **SafeSight Mac Testing** from Applications to the Trash.
4. Optional: macOS keeps the app's sandbox folder, emptied of its data by step 1. In Finder, choose Go, Go to Folder, type `~/Library/Containers`, and move the folder for SafeSight Mac Testing (Finder shows its name; the folder is named after its bundle identifier) to the Trash. If `~/Library/Application Scripts` has a folder with the same identifier, it is empty and can go too. macOS may ask you to confirm.

If you dragged the app to the Trash without step 1, its container still holds its settings and Core ML's cache: step 4 removes them.

**What macOS itself keeps,** all small and holding nothing from your screen:
- **The app's folders under `/var/folders`.** macOS gives each sandboxed app a cache folder and a temporary folder there (`/var/folders/…/C/<bundle id>` and `/var/folders/…/T/<bundle id>`). Remove empties them but leaves the folders, which macOS made; it clears the temporary ones by itself over time, and at restart.
- **The Screen Recording record.** Step 2 removes the permission. macOS's screen-sharing service also notes when an app was last allowed, in `ScreenCaptureApprovals.plist` (on recent versions, in `~/Library/Group Containers/group.com.apple.replayd/`); it holds the app's identifier and dates, and is macOS's to manage. Leave it.
- **LaunchServices and Gatekeeper.** macOS remembers that the app existed (for "Open With" and the like) and, for a downloaded copy, that you opened it. These records refer to a path that no longer exists and are tidied by macOS; there is nothing to do.

Other things that are macOS's, not the app's: if you added it to Login Items yourself, remove it there (System Settings, General, Login Items). If it ever crashed, macOS kept a crash report in `~/Library/Logs/DiagnosticReports` (it holds no picture of your screen; it is sent to Apple only if you share analytics). macOS's own logs rotate by themselves.

## What helpers can test, and the one rule

**Never test it with explicit material.** Not to see whether it works, not once. Use it with what you normally do. Developers who need a picture that must be covered use the lab stand-in, a synthetic magenta-and-green checker that exists only in lab builds (`SAFESIGHTMAC_LAB=1`): the harness, and the lab Testing build above (open a picture of the checker in Preview and it is covered). The Testing edition helpers get has no stand-in.

What helps most:
- **False covers:** anything harmless that gets covered or blurred, and in which app or site. Describe it; send a screenshot only if nothing private is on screen.
- **Speed:** a picture you could see before its cover, pages that stay blurred for long, lag, fan noise, battery drain.
- **Displays:** external displays, plugging and unplugging, sleep and wake, mirroring, resolution changes, full-screen apps.
- **Getting out:** any moment when you could not quit or leave a page as the covers say, or anything it left behind after removal.

Report in a GitHub issue, with the **Testing report** form (`.github/ISSUE_TEMPLATE/testing_report.yml`). If you find a way around the cover or the lock of the full app, report it privately as [SECURITY.md](../SECURITY.md) says, never in public.

## A guide for helpers

**Before you start.** Read "Who it is for" at the top. Know the three ways out: **⌃⌥⌘Q** (Control, Option, Command and Q together), **Quit** in the menu under "Testing" in the menu bar, and the **Quit** button on the card that appears when a display has been covered whole for two seconds.

**What to do.** Use your Mac as you normally do, for an hour or a day, with the app on. Then try the things on the list above that you can: an external display, sleep and wake, a full-screen app, a different keyboard layout. Once, press ⌃⌥⌘Q while a cover is up, to see that it quits.

**What you will see.** At start, and after sleep or a display change, each display is covered whole for a few seconds until it has been checked. That is on purpose: what has not been checked stays covered. Pictures it judges explicit are covered; a busy page may be blurred for a moment first.

**Reporting.** In the menu, choose **Testing report…**. A window shows numbers about your Mac and the run (listed below) and updates every two seconds. Type what happened in the note field at the top (in your own words; no names or addresses needed), then select the report's text, copy it, and paste it into a new issue with the Testing report form. The app puts nothing on your clipboard, saves nothing and sends nothing: what you paste is all anyone sees.

**What the report holds:** the Mac's model and macOS version; the number of displays, their sizes, scale and whether each is built in or mirrored; the edition, version and the first characters of the app's and the models' hashes; whether ⌃⌥⌘Q is the app's; how long it has covered, frames judged and how many a second; the CPU it used; the Mac's heat and whether Low Power Mode is on; how long judging and capture-to-cover take (median, 90%, 99%); frames captured by the status macOS gave them (new pixels, nothing changed, and the rest); frames judged with new pixels and frames on which covers waiting to lift were judged again; updates drawn on screen and how many had a cover or blur (every update drawn, not only each frame's final plan: the first live run's report said 0 over a covered screen), the covers and blurs drawn and what is on screen now; how many times a whole display was covered on screen, and why; and how often the slow paths fired (changed parts blurred at once, pictures blurred first, parts left for later, entries left unjudged, covers judged on their own, and timer ticks that covered changes left waiting). **Never** a picture, a window title, an app's or site's name, an address, or what was covered. The battery's charge is not shown: reading it needs a framework (IOKit) the Testing app is not allowed to link. Battery drain is best judged from macOS's own battery settings.

**When you are done.** Choose **Remove SafeSight Mac Testing** in its menu, then follow "Removing it" above.

**Never** test it with explicit material, and never paste a screenshot of anything private.

## What it cannot protect against

- **The person using it.** It has no lock; one shortcut ends it. That is the point of this edition, and why it is not for recovery.
- **Sites and files.** It blocks no website, checks no download and has no browser extension. It only covers what is drawn on screen, after it is drawn: a picture can be in sight for a fraction of a second before its cover.
- **What it misses.** The detector makes mistakes both ways. Anything it misses stays in sight.
- **Other apps' shortcuts.** If another app or a key remapper takes ⌃⌥⌘Q first, the shortcut may not reach it; the menu bar icon and the repair card still quit it.
- **System panels.** Notifications, Spotlight and system prompts can sit under a whole-display cover. Quitting shows them.
- **A copy built by someone else.** The guarantees hold for a copy made by `make-app.sh --testing` from this repository and checked by `tools/check-testing-edition.sh`. A copy from anywhere else may be anything; until signed downloads exist, run only one you built or that the project gave you.

## How this differs from the real thing

The Testing edition is built from the same source files as the cover-only app of step 1. What judges the screen and draws the covers (the detector, its rules, the region finder, capture and the cover layer) is the same code, and a CI step keeps it so: `tools/check-testing-edition.sh` fails if the Testing app's screen-path modules are not exactly the release app's, or if any of them tests the Testing flag (apart from the one file noted below). What is different, and why each difference is needed for safety:

- **There is no lock, no site blocking, no file checks and no browser extension yet.** The release app of step 1 has none of these either: they are later steps. The full SafeSight Mac will have them; the Testing edition never will.
- **The App Sandbox.** The release app of step 1 is not sandboxed. Capture inside the sandbox is the first thing to check on the test Mac; if it behaves differently there, that is a difference in what helpers see.
- **The keeper check is compiled out** (`PracticeState.swift`), so the app never reads `/Library/LaunchDaemons`. The menu shows "Testing edition: no lock" instead of the practice state, and pausing is always allowed.
- **Models only from inside the app.** The release app's developer overrides (`SAFESIGHTMAC_MODELS`, the working folder) are compiled out. Both editions load compiled models from the bundle the same way.
- **The Testing line** on whole-window and whole-display covers, on the card, and on any cover, or the largest of several, hiding half a display. In the release edition picture covers stay wordless. This changes how big covers look, not where they go.
- **The stall watchdog** quits the app after 8 s of a stuck main thread under a cover. The release app keeps covering instead (faults cover more).
- **⌃⌥⌘Q, one copy at a time, Remove, and the Testing report,** none of which is in the release app.
- **Not sandboxed means not covering.** A Testing copy outside the sandbox covers nothing.

Everything else, from when a display is covered whole to how long a cover stays after a picture is gone, is the release app's behaviour, so what helpers find applies to it.

## Asked for, and not done

- **A stand-in demonstration** (a built-in harmless picture that the app covers, so a helper can see it work). Not done for helpers. The stand-in exists only in lab builds, and `tools/check-no-standin.sh` keeps it out of the release app and the Testing app helpers get, on purpose (SD-139): a picture the detector is built to flag, shipped in an app, is a way to make it look better than it is, and it would show the fast path for a picture it already knows, not real speed. Developers see it work through the real app in the lab Testing build (`make-app.sh --testing --lab`), and in the harness's `demo`.
- **The battery's charge in the live read-out.** Not done: it needs IOKit, which the Testing app may not link. The read-out shows CPU use, heat and Low Power Mode instead.
- **Copying the report to the clipboard with a button.** Not done: the pasteboard stays forbidden, so the helper copies it by hand and sees what they copy.

## The safety pass (19 November 2026)

Every way the Testing edition could get in a helper's way or leave something behind, walked through from install to reinstall. **Fixed** means changed in code and tested; **by design** means it stays, and is escapable and documented.

| When | What could go wrong | What was done |
|---|---|---|
| Install | An unsigned or ad hoc app downloaded from someone else is stopped by Gatekeeper, and the usual advice is to bypass it | No download is offered until it is signed and notarized. Helpers are never asked to bypass Gatekeeper |
| Install | It shared an identity with the full app (Screen Recording, settings, sandbox) | **Fixed:** its own name, and an identifier that must end in `.testing` (`make-app.sh` refuses others; the check verifies) |
| Install | `make-app.sh` built a lab app, stand-in included, if `SAFESIGHTMAC_LAB` was set in the shell | **Fixed:** it unsets the lab variables, for both editions |
| Install | Anything in the bundle that macOS would install or start | None; the check fails on any bundle that is not a plain app |
| First run | A copy outside the sandbox (`swift run`, a hand-made bundle) | **Fixed:** it checks and covers nothing and says why |
| First run | Two copies running (Downloads and Applications) | **Fixed:** the second says so in a panel above every cover, and quits (by itself after 30 s) |
| First run | Every display covered until its first judged frame, longer while the models load | By design (unjudged means covered); the covers show the way out and ⌃⌥⌘Q at once, and the repair card follows |
| First run | Models missing or changed: every display covered whole | By design (faults cover more); the card offers Quit; `make-app.sh` refuses models that do not match |
| Permission | A surprise permission prompt at launch | None: macOS is asked only when the helper chooses "Open Screen Recording settings…" |
| Permission | macOS 15 and later may ask from time to time whether to keep allowing screen recording; under a whole-display cover the question can be hidden | By design; quitting (menu, card, ⌃⌥⌘Q) shows it. Either answer is safe |
| Permission | An ad hoc rebuild is a new app to macOS: the old entry stays listed but no longer applies | Documented ("After a rebuild") |
| Normal use | A big picture cover had no words: a screen mostly covered gave no hint how to quit | **Fixed:** in the Testing edition any cover hiding half a display carries the Testing line |
| Normal use | ⌃⌥⌘Q missed on AZERTY and Dvorak keyboards (a fixed key code is a place, not a letter) | **Fixed:** the Q key is found in the layout in use, and again when it changes |
| Normal use | ⌃⌥⌘Q already used by another app | **Fixed:** exclusive registration; when taken, every line says to quit from the menu bar icon |
| Normal use | 220 MB of compiled models left in the temporary folder at every start, never removed (144 copies, 9.1 GB, had piled up on the developer Mac from lab runs) | **Fixed for both editions:** the app carries its models compiled and never compiles; development runs compile each model once, to a place named after it |
| Normal use | Core ML's cache for the models grew by about 200 MB at every start | **Fixed for both editions** (independent review): the models load from one fixed path, so the cache stays at about 200 MB (measured, above); inside the container, removed by Remove |
| Normal use | Energy and heat while it runs | Not measured (ST-038); the Testing report shows CPU use and heat live; pause or quit it when you don't need it |
| Normal use | A crowded menu bar (a notch) can hide its icon | ⌃⌥⌘Q works without the icon |
| Normal use | The app's main thread stuck while a cover is up; an app with no Dock icon is not in the Force Quit window | **Fixed:** the stall watchdog ends it after 8 s |
| Normal use | "How it works" cut off the last word of a paragraph on a Retina display | **Fixed for both editions:** paragraphs are measured with room for an extra line |
| Normal use | Pause, Quit or Remove while the models were loading could start capturing afterwards and cover every display whole, with no card | **Fixed for both editions** (independent review): a stopped capture never starts again, and nothing is drawn after a stop |
| Normal use | Several smaller covers hiding most of a display, with no line | **Fixed:** the largest carries the Testing line |
| Displays | With a third display (beyond `DISPLAYS_MAX`, 2) covered for good, the repair card sat in the middle of the main display and never went away | **Fixed for both editions:** the card sits on a display that is covered whole |
| Displays | Plugging, unplugging or a resolution change covers a display whole until it is judged | By design; the covers show the way out and ⌃⌥⌘Q |
| Sleep and wake | Covered whole on sleep and until judged after wake | By design. The lock screen is above every cover, so unlocking is never blocked. If capture does not come back, the card offers Try again, Pause and Quit |
| Locking | The canvas was taken off as soon as the session said "locked", seconds before the lock screen was drawn on a slow Mac, and the desktop was in sight meanwhile (first live run) | **Fixed for both editions:** every display stays covered whole, below the lock screen's level, until the lock screen is seen over it, and 10 s at most |
| Normal use | On a slow Mac a still screen never settled; covers flickered between covered whole and blurred (first live run) | **Fixed for both editions:** see "The first live runs" |
| macOS update | "Reopen windows when logging back in" would start it again after the restart | **Fixed for both editions:** `disableRelaunchOnLogin()`, and no window state is kept |
| macOS update | An update may reset Screen Recording, or change capture | It then says "Needs Screen Recording" and covers nothing, or covers whole with the card. Nothing is locked |
| Crash | Covers left on screen | Not possible: confirmed gone 3 ms after the process is killed |
| Crash | Compiled models left behind | None: the app compiles nothing |
| Crash | A crash report | macOS's, in `~/Library/Logs/DiagnosticReports`; documented. It holds no screen pictures |
| Crash | Restarted automatically | Never: it has no launchd job and no login item |
| Force quit | Not in the Force Quit window (no Dock icon) | ⌃⌥⌘Q, its menu, the repair card, Activity Monitor; and the stall watchdog |
| Uninstall | The Trash alone leaves the container: settings, Core ML's cache | **Fixed:** "Remove SafeSight Mac Testing" clears them first; the empty folders macOS keeps are documented |
| Uninstall | Per-Mac (ByHost) settings left in the container | **Fixed** (independent review): removed too |
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

**A second review** the same day found that the check could be fooled by lookups the scanner did not know (`CFBundleGetFunctionPointerForName`, `launch_msg` and others), by a call split over lines, a module-qualified name, `#if` inside a multi-line string, a `path:` override or a build-tool plugin; that Core ML's cache grew about 200 MB at every start; that Remove missed the per-Mac settings; and that the second copy's message could sit under the first copy's covers. All four were fixed as described above, and the check's wording changed: it is a tripwire for honest mistakes, and the sandbox is the real boundary. It also noted that the release app no longer reopens through "Reopen windows", which is accepted.

Not changed: the sandbox check relies on what macOS tells a sandboxed app (an environment variable and its home folder); a person who crafts both for a copy run outside the sandbox gets what they asked for, and the removal still touches only a folder named after the app. The review found no memory-safety problem in the hot-key code.

## The first live runs (19 November 2026)

**The first run,** in a disposable virtual Mac (Tart, macOS 26.6.2, 1024 by 768 points at 2x), was unusable: on a still, harmless desktop nearly everything stayed blurred or covered for minutes, the covers flipped between covered whole and blurred about 20 times a second, the app used about 150% of a core, two to four Testing lines stacked, the repair card's buttons were cut off, the report said "Frames with a cover or blur: 0" over a covered screen, and the desktop was in sight for a moment while the screen locked. Capture inside the App Sandbox worked, ⌃⌥⌘Q quit with a real key press, and covers vanished with a killed process. The causes, found by reproducing the still desktop off the screen with the real models (`safesightmac-harness static`, on a harmless screenshot taken in the virtual Mac), and what changed, are in [STEP-1-STATUS.md](STEP-1-STATUS.md), "The first live run". In short: the judging budget went to the same borderline pictures in every frame and the rest of the screen was never judged; a cover could only lift in one call that judged everything over it; covers grew into whole-window covers; a still screen was never looked at again; every frame blurred things first; the window server's own screen-recording indicator counted as another app's window over the covers; and the app's own menu bar item, which on macOS 26 the capture sees, kept changing.

**Off the screen, after the fixes** (the virtual Mac's desktop screenshot, real models, judging slowed by 10 ms a judgement to about the virtual Mac's speed, the register's budget of 40 judgements a second): the code that ran live never settled (after 90 seconds at full speed, 234 covers; the same few judgements every frame). Now most of the desktop clears in about 100 seconds (19 covers left), the last covers (the whole-window covers made while the models first worked through the screen, which need four clean rounds of every picture in the window) lift by about 200 seconds, and then nothing is drawn and nothing is judged: the screen stayed clear for the remaining 157 seconds of the run and the watcher stopped judging. On a slow Mac a busy screen is therefore covered for minutes the first time it is seen, not for ever; afterwards each new thing on screen is judged in turn (new things before old).

**The second run,** to see the fixes live, stopped at the Screen Recording permission: an ad hoc signature is new with every build, so each build needs the permission again, and turning it on asks for the administrator's password, which the agent doing the run may not type into a system dialog. The lab Testing build in the virtual Mac is now signed with a signing identity made inside that virtual Mac, so the permission survives rebuilds once it has been given; it still has to be given once, by the owner. The window server's user was read as 88 inside the sandbox, and the lock screen's windows (levels 2001 and 2004, covering the display) were seen in the window list there.

## Not done yet

- **Not yet run on a physical Mac.** It has run only in a disposable virtual Mac (see "The first live runs"): the rules for this work forbid running it or capturing the screen on the developer Mac. On a physical test Mac, check first, in this order:
  1. the menu reads "Covering: on" (capture works inside the App Sandbox);
  2. ⌃⌥⌘Q quits with a real key press while SafeSight Mac Testing is listed under neither Accessibility nor Input Monitoring, also with a password field focused, in a full-screen app and on an AZERTY layout;
  3. the lab stand-in, opened in Preview with the lab Testing build (`make-app.sh --testing --lab`) running, is covered and the Testing line shows;
  4. with a copy covering, opening a second copy shows "already running" **above** the first copy's covers, and the second copy quits;
  5. Core ML's cache in the container stays about the same size over three starts;
  6. the Testing report opens, updates, and shows the right displays;
  7. "Remove SafeSight Mac Testing" leaves only what is listed under "Removing it".
- **Signed, notarized downloads come later,** once the project has an Apple Developer Program membership. Until then the Testing edition is built from source and signed ad hoc, for the builder's own Mac or a test Mac; it is never handed out.
- **The App Sandbox itself** was not exercised in a real container here (see guarantee 2). Where Core ML and Metal keep their caches for a sandboxed app (the container's `Library/Caches`, or the per-app folder under `/var/folders`) is expected, not seen; the test Mac should confirm that Remove leaves neither.
