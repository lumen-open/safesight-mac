<!-- SPDX-License-Identifier: Apache-2.0 -->
# Privacy

**Last updated: 19 November 2026.** Draft 0.1, written for the early preview. It hasn't been read by a lawyer.

SafeSight Mac is built to know nothing about the people who use it. There's no account to make, no server that receives your data, and nothing we could sell. The part that looks at your screen does its work on your Mac and keeps what it sees in memory only.

Some of SafeSight Mac is built and some is still being designed, so every promise on this page carries one of two labels:

- **Today**: true of the code in this repository now. You can check it.
- **Designed**: how an unfinished part is designed. It becomes "Today" only after the test behind it has passed, and until then we say "designed to", never more. The [claims ledger](claims-ledger.md) tracks each one.

## Who runs SafeSight Mac

SafeSight Mac is a free, open-source project under the Apache License 2.0. It isn't a company and it isn't a service: nobody runs a server for it, and there's no support desk that can see your Mac. The code is public, so anyone can check this page against it.

If an organization ever takes the project on, its name goes here, and this page stays true or changes in public with a new date.

## What SafeSight Mac collects

Nothing. There's no account, no email address, no payment, no analytics, no crash upload, no telemetry and no licence check. The project never receives anything about who uses it, not even an internet address. The public hosts listed below see an internet address the way any website does; the project doesn't.

- **Today:** the preview contains no networking code at all. A check on every commit (`tools/check-no-network.sh`) fails if any source names a networking API.
- **Designed:** the full product keeps to this. Build scans check every release for analytics, crash-reporting and telemetry code before it ships.

## What stays on your Mac

| What | Where it stays | Status |
|---|---|---|
| **What's on your screen** | Judged in memory by the watcher, on your Mac. Never written to a file, a log or a crash report, and never sent anywhere | Today, for the preview app |
| **What was covered** | Nowhere. No list is kept of what was covered, where or when | Today |
| **New pictures and videos you download** | Checked in memory on your Mac as they arrive. A clearly explicit file stays where it is, with its permissions changed so nothing can open or send it until your wait is over. Its contents are never changed, nothing about it is written down, and nothing is sent anywhere | Designed, for after the first release. Until then a downloaded file is covered on screen but not checked or locked |
| **Checked-picture memory** | A short memory of pictures already judged, so they aren't judged twice. It holds a fingerprint and a verdict, never the picture, lives in memory only and is gone when the app quits | Today |
| **Your settings** | The preview keeps one setting, the detector mode, in macOS's ordinary preferences. The full product keeps its settings in the lock's own root-only folder | Today / Designed |
| **The lock's records** | Your wait, your requests, the lock's clock, your keyholder's public key. In a root-only folder on your Mac, removed when you leave | Designed (written and tested, not yet installed on any Mac) |
| **The hidden admin password** | Made on your Mac and never shown. It leaves the Mac only inside a capsule that opens with your Recovery Key, after your wait | Designed |
| **Capsules** | One set on your Mac, and any copy you choose to keep elsewhere, such as your own cloud folder | Designed |
| **Your Recovery Key** | Your password manager. The app checks you saved it and doesn't keep it | Designed |

**The note for AI coding tools** (designed). SafeSight Mac leaves a short note on your Mac asking AI coding tools not to help get around the lock. Tools that read it pass it to their makers along with the rest of what you ask them, so those makers learn that this Mac has a content filter, and nothing more. You can switch the note off at setup.

macOS's own crash reports stay on your Mac under macOS's rules. Whether macOS can move the watcher's memory to disk is being checked for each macOS version we test.

## Read or send, never both

No part of SafeSight Mac both reads your screen and can use the network.

- The **watcher**, which reads the screen, has no network access.
- The **app**, which has network access, never sees the screen.
- The **keeper**, which holds the lock, has neither.

**Today:** the preview has no networking at all. **Designed:** macOS's App Sandbox keeps the watcher off the network, and that is proven on a test Mac before any release that has network access.

## The only network contacts

**Today the preview makes none.** When the lock ships, SafeSight Mac is designed to make exactly these, all from the app:

| Contact | Run by | When | What that host can see |
|---|---|---|---|
| Public time-signal rounds | Operators of drand mirrors (members of the League of Entropy) | About every 10 minutes while you're online, on the same rhythm whatever you're doing | Your internet address, and that the latest round was asked for |
| Update check and download | GitHub, the release host | On a fixed rhythm, and when a release is due for your Mac | Your internet address, and which public file was asked for |
| Public log lookup | Sigstore, the public transparency log | When a new release appears | Your internet address |

How these requests are designed:

- Plain public downloads. No account, cookie, identifier, query string or request body, and the same short set of headers from every Mac.
- The same rhythm whether or not you've asked to leave, so the traffic doesn't show what you're doing.
- The project has no access to these hosts' request logs.

What this doesn't hide: someone who can see your network traffic can tell that your Mac contacts these hosts, and could guess that SafeSight Mac is installed.

**If you install the optional browser extension** (designed, for the first full release, where it carries site blocking): Chrome and Edge check their stores for updates, as they do for any store extension, so Google or Microsoft can learn the extension is installed. The Firefox copy is signed by Mozilla, and what Firefox tells Mozilla about it will be recorded and listed here before it ships. The Safari copy comes inside the app. The extension itself sends nothing and keeps no history.

**If you choose the Hardcore lock**, Apple's own services are involved too. See "What device management can do" below.

## The keyholder page

**Built, not yet hosted.** The keyholder page is one static file that your friend opens on their phone.

- After it loads, it sends nothing. Its built-in content security policy forbids network requests, and it loads nothing from any other site.
- It keeps no cookies and no storage of any kind. The passkey it makes stays on your friend's phone.
- Your request code arrives in the part of the web address after `#`, which browsers never send to the host, and the page then removes it from the address bar.
- The host sees your friend's internet address and the time of the visit, like any website. It sees nothing about you, your Mac or your request.
- Your keyholder learns nothing about what you do. Whatever app you use to pass the codes between you can see them; they name nobody.

## The opener

**In progress, not yet released.** The opener opens a capsule with your Recovery Key once your wait is over, on any computer. It sends nothing about you or your capsule. It needs one public time-signal round: it can download that round from a mirror, which then sees your internet address and which round was asked for, or you can paste the round in and it makes no request at all.

## The website

**Live at [lumen-open.github.io/safesight-mac](https://lumen-open.github.io/safesight-mac/).** Two static pages with no scripts, no cookies, no analytics and no trackers, and nothing loaded from any other site. Its content security policy enforces that. It's hosted on GitHub Pages: GitHub sees visits like any web host does, and the project gets no visitor logs from it.

## Camera, microphone and location

- **Microphone:** never used. Screen capture is set to record no sound. **Today.**
- **Camera:** designed to be used only when you choose to scan your keyholder's code with your Mac, and asked for then. The picture is read in the app and dropped. The keyholder page never asks for the camera. **Designed.**
- **Location:** never collected.
- **Eye tracking:** none.

SafeSight Mac doesn't switch off your Mac's camera or microphone; it simply doesn't use them.

## What device management can do

This section is about the **Hardcore lock**, a stronger optional tier that comes after the first release: even a full restore from another Mac won't free the Mac before the wait ends. Apple's own receipt process stays open as the one way back that Apple keeps.

**Status: research only.** Nothing of it is built, and no Mac has been enrolled. The first test may change the design, and this section will be updated before anything ships.

**The principle.** The Hardcore lock uses Apple's device management, but the management server is the keeper on your own Mac. No company, project or person runs it or holds it. Its keys are made on your Mac when you set it up and never leave it, and nothing it reads leaves your Mac.

You install the enrollment yourself and approve it in System Settings. It asks Apple for the smallest set of rights the lock needs. Apple doesn't allow rights to be added later.

**It can see** (on your Mac, for the keeper's own checks):

- which configuration profiles are installed;
- device information: model, macOS version, serial number, and whether the Mac is supervised;
- which management restrictions are in force;
- security state: Recovery Lock, startup security and FileVault status.

**It can change:**

- install and remove its own configuration profiles;
- set Recovery Lock, the password on your Mac's recovery system, to a random value the keeper seals and nobody sees;
- apply a short list of restrictions: erasing blocked, new user accounts blocked, startup disk locked, and installing other profiles blocked;
- use the device settings Apple's management offers, only for Recovery Lock and Activation Lock.

Apple bundles the right to set Recovery Lock with the power to lock the Mac remotely. SafeSight Mac never uses that power, and the keeper treats any lock command it didn't expect as a fault.

**It cannot:**

- erase your Mac;
- list your apps;
- install, update or remove apps;
- read network information;
- see your files, messages, browsing, screen or location.

**Apple's part.** The Hardcore lock turns on Find My under a separate "lock" Apple Account made just for this Mac, whose password the keeper seals during your wait. Apple's servers then hold this Mac's Activation Lock, as they do for any Mac with Find My on, under Apple's own privacy policy. Whoever signs in to that account can see the Mac in Find My, including its location; during your wait nobody holds that password, and after you leave it's yours. The keeper never fetches the code that would let someone skip Activation Lock, and it clears it.

**If Apple's design needs a wake-up message.** Device management usually relies on Apple's push service to wake a Mac. If our first test shows a server on the Mac itself needs that, a small relay would only be able to wake Macs, never unlock or read anything, and this page will say exactly what it sees before it exists.

## Does SafeSight Mac sell my data?

No. It has none to sell. There are no ads, no advertising identifiers and nothing shared for marketing. The core is free forever ([CORE.md](../CORE.md)); if a paid extra ever exists, payment can never weaken or unlock anything.

## Who it's for

SafeSight Mac is for people protecting their own Mac, and for parents and legal guardians protecting their child's account on a Mac they own. It's never for setting up on another adult's Mac, and never a condition of a job, a home or anyone's support. Even on a child's account it collects nothing and reports nothing: it only covers explicit sexual content on that screen, and no one, the parent included, is shown what was covered. A parent setup is being designed now, so this section will be updated as it's built.

## Keeping and deleting

Nothing is held anywhere but your Mac, so deleting your data means removing SafeSight Mac.

- **Today:** quit the preview and delete it. Its one stored setting, the detector mode, is in its macOS preferences file. Core ML, which runs the models, also keeps a cache for them in `~/Library/Caches`, under the app's identifier, which you can delete. The preview's own compiled copies of the models are removed when it quits. The Testing edition, the build for helpers, keeps all of this inside its sandbox and removes it with one click ([TESTING-EDITION.md](TESTING-EDITION.md)).
- **Designed:** when you leave after your wait, the exit steps remove the lock's records, the capsules on your Mac and the model files.
- What you saved yourself stays yours: your Recovery Key, any capsule copy you kept, and your keyholder's passkey on their phone.

**The diagnostics file** (designed) is made only when you tap for it. It holds part versions, the macOS version, states and counts, and never pictures, window titles, app names, web addresses or anything about what was covered. You read it before you decide to attach it to an issue, and issues are public.

## Security

- The lock's secrets are made on your Mac and kept in a root-only folder. Capsules use the standard `age` encryption and drand's published time lock.
- Every protection is designed to hold with all the code public. Nothing rests on secret code or secret thresholds.
- Every change runs public checks. Releases are designed to be signed, notarized by Apple and public for 14 days before any Mac installs them.
- If you find a weakness, please report it privately ([SECURITY.md](../SECURITY.md)).

No software is perfectly secure. The known gaps are listed in the [README](../README.md) and in [STEP-1-STATUS.md](STEP-1-STATUS.md).

## Your rights

The project holds no personal data about you, so there's nothing on our side to access, correct, export or delete, wherever you live. That includes the rights to know and to delete under California's privacy law and the rights under Europe's data protection law. You don't have to take our word for it: the code is public. If a future version ever needed to collect anything, this page would change first.

## International transfers

The project transfers nothing. The public hosts above (GitHub, Sigstore and the drand mirrors) are run around the world by their own operators, under their own policies.

## Changes to this page

This page changes only with a release. When it does, the "Last updated" date at the top changes and the release notes say what changed. Every change is in the public history of this repository, and releases are designed to wait 14 public days before any Mac installs them, so a change to what SafeSight Mac does is visible before it reaches you.

## Contact

Questions go in the public issue tracker. Anything that could help someone get around SafeSight Mac goes privately through [SECURITY.md](../SECURITY.md). There's no project mailbox yet.
