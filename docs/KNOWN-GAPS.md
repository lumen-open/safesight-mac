<!-- SPDX-License-Identifier: Apache-2.0 -->
# Known gaps

What isn't built or proven yet, in plain words. It's kept short on purpose; the details live in [STEP-1-STATUS.md](STEP-1-STATUS.md), [TESTING-EDITION.md](TESTING-EDITION.md) and [ARCHITECTURE.md](../ARCHITECTURE.md). Last updated 20 November 2026.

## Not proven

- **Nothing has run on real hardware yet.** The screen cover and the Testing edition are checked by tests, a lab harness and CI, with synthetic screens. Neither app has been opened on a Mac with a live screen, so how it behaves there, and how long a picture shows before its cover, isn't known.
- **Battery use isn't measured on a real Mac.** CPU time and memory were measured off the screen and in a virtual Mac; watts, the Neural Engine and a day on a MacBook Air's battery still need a real Mac ([ENERGY.md](ENERGY.md)).
- **The catch rate isn't measured.** Nobody knows yet how many explicit pictures the detector misses. False covers were counted on harmless screens in the lab, not in daily use.

## The lock

- **The lock isn't merged.** The keeper is on the `keeper-core` branch and the pull requests stacked with it, waiting for a second human reader, as all lock code must. On `main`, `keeper/` is only a stub. Nothing on `main` locks anything, and the opener and the keyholder approvals have nothing to work with yet.
- **Wiping the Mac removes it,** as the README says. The Hardcore lock is research toward closing that, and none of it is built.

## The cover

- **An app that raises its own window above the covers isn't itself covered.** While it sits over a cover, the rest of that display is covered whole, but the app's own window is not.
- **Assistive windows sit under a whole-screen cover.** When a whole display is covered, windows such as live captions or an on-screen keyboard are under that cover too while it's up.
- **Busy pages may be covered whole for a while.** A page with many new pictures can take longer to judge than the budget allows, so its pictures are blurred, and the window may be covered whole until judging catches up.
- **Protected video isn't checked,** because macOS hides it from screen capture.
- **The macOS password prompt is always left uncovered, on purpose.** So you can always type your password, the dialog macOS shows when something asks for an administrator's name and password stays clear while the screen around it is covered. That dialog shows the name and icon of the app that asked, and an app chooses both: its own icon, or a picture it names when it asks, drawn at about 64 by 64 points, and a line of text of its own. This is the cost we accept. To keep it small, the prompt is recognised by facts read from the system, never by a name (the program behind the window must be Apple's own SecurityAgent, on the read-only system volume, with System Integrity Protection and authenticated root on), its own content is still checked like any window's before its space is left clear, a small change in it (typing) is covered where it changed until checked, and once the changes since its last full check add up to more than a quarter of it, or reach a picture in it, the whole prompt is covered until it's checked again, a plain cover stays behind it so nothing shows through it, and its space is covered again as soon as it closes. If the screen can't be checked at all, the prompt is covered like everything else until checking works again. Two things are outside what this rule can tell: a Mac with System Integrity Protection or authenticated root turned off never gets the hole (the prompt stays covered there), and an administrator can install an authorization plug-in whose code runs inside SecurityAgent and could draw any window, which an owner who isn't an administrator can't do. And like every window under the cover, a change inside the prompt shows for a moment before its cover is drawn, as long as the capture takes to deliver it plus the look before; while a whole display is covered, the prompt is the one place where that can happen. On a busy Mac, with the judging budget spent, what you type into the prompt can stay covered until there's budget again: it never shows unchecked. While a whole display is covered for a window above the covers, the repair card, which sits in the middle, can be in front of the prompt: drag it aside.

## Planned for the first full release, not built yet

- site blocking, through the browser extension and the Mac's hosts file;
- optional switches to turn off ways of sending files, like AirDrop;
- safe admin tasks through Apple's own routes;
- the app with network access, setup with **Leave** and **Stay**, and the plain shield;
- signed, notarized releases, and the checks a Mac will do before it installs an update ([VERIFYING-A-DOWNLOAD.md](VERIFYING-A-DOWNLOAD.md)).

## After the first release

Designed, and coming later:

- **Cinema mode.** Until then, protected films in browsers stay held or black.
- **Checking and locking downloaded files.** Until then, an explicit download is covered on screen but could still be sent to a phone, which is why we recommend protecting the phone too.
- **A filter for the whole Mac's network.**
- **Instant installs of parts from known vendors.**
- **The Hardcore lock.**

If you find a way around the cover or the lock that isn't listed here, please report it privately as [SECURITY.md](../SECURITY.md) says.
