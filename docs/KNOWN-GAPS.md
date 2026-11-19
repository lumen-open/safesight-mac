<!-- SPDX-License-Identifier: Apache-2.0 -->
# Known gaps

What isn't built or proven yet, in plain words. It's kept short on purpose; the details live in [STEP-1-STATUS.md](STEP-1-STATUS.md), [TESTING-EDITION.md](TESTING-EDITION.md) and [ARCHITECTURE.md](../ARCHITECTURE.md). Last updated 19 November 2026.

## Not proven

- **Nothing has run on real hardware yet.** The screen cover and the Testing edition are checked by tests, a lab harness and CI, with synthetic screens. Neither app has been opened on a Mac with a live screen, so how it behaves there, and how long a picture shows before its cover, isn't known.
- **The catch rate isn't measured.** Nobody knows yet how many explicit pictures the detector misses. False covers were counted on harmless screens in the lab, not in daily use.

## The lock

- **The lock isn't merged.** The keeper is on the `keeper-core` branch and the pull requests stacked with it, waiting for a second human reader, as all lock code must. On `main`, `keeper/` is only a stub. Nothing on `main` locks anything, and the opener and the keyholder approvals have nothing to work with yet.
- **Wiping the Mac removes it,** as the README says. The Hardcore lock is research toward closing that, and none of it is built.

## The cover

- **An app that raises its own window above the covers isn't itself covered.** While it sits over a cover, the rest of that display is covered whole, but the app's own window is not.
- **Assistive windows sit under a whole-screen cover.** When a whole display is covered, windows such as live captions or an on-screen keyboard are under that cover too while it's up.
- **Busy pages may be covered whole for a while.** A page with many new pictures can take longer to judge than the budget allows, so its pictures are blurred, and the window may be covered whole until judging catches up.
- **Protected video isn't checked,** because macOS hides it from screen capture.

## Designs only

None of these is built yet:

- site blocking;
- checks of downloaded files;
- cinema mode;
- the browser extension and the optional browser settings;
- the plain shield, the app with network access, and setup with **Leave** and **Stay**;
- signed, notarized releases, and the checks a Mac will do before it installs an update ([VERIFYING-A-DOWNLOAD.md](VERIFYING-A-DOWNLOAD.md)).

If you find a way around the cover or the lock that isn't listed here, please report it privately as [SECURITY.md](../SECURITY.md) says.
