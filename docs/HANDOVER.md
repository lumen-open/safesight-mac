<!-- SPDX-License-Identifier: Apache-2.0 -->
# Taking SafeSight Mac on

What an organization adopting SafeSight Mac needs to know: the licence and its paperwork, the third-party pieces, how to rebrand it, what has to be set up again under your own accounts, what isn't in this repository yet, how it fits an existing privacy policy, and the open questions that come with it. For how the parts work, read [ARCHITECTURE.md](../ARCHITECTURE.md) first.

Written 19 November 2026, while the project is an early preview: the screen cover is built and tested in the lab, the lock's core logic is built and tested on CI, and nothing has been signed, shipped or reviewed by anyone independent.

## 1. Licence and sign-off

- **Apache License 2.0** for everything in the repository ([LICENSE](../LICENSE), [NOTICE](../NOTICE)). You may use, change and ship it, commercially too, without asking. Keep the licence and NOTICE with what you ship, and mark files you change. The licence includes a patent grant from each contributor.
- **The name is not licensed.** Apache-2.0 grants no trademark rights, and the project's rule is that a fork uses its own name, identifiers and signing keys. The name "SafeSight Mac" has not had a trademark check.
- **Every commit is signed off** under the [Developer Certificate of Origin](../DCO). On 19 November 2026 `tools/check-signoff.sh` passed for every commit on `main` and on every open branch, and CI refuses any commit without a `Signed-off-by` line.
- **Copyright** is held by "The SafeSight Mac authors". So far every commit comes from one contributor account. Apache-2.0 is enough to adopt and ship the project. Owning the copyright outright, or relicensing, would need a separate written agreement with the contributors.
- **Built with AI help.** Most of the code was written by AI agents at the maintainer's direction, and the README says so. How that bears on copyright differs by country, so it's worth a line in your lawyer's review.
- **The free-forever core** ([CORE.md](../CORE.md)) is a public promise, not a licence term: the screen cover, the lock, the keyholder and updates stay free, and payment can never weaken or unlock anything. Anyone continuing under this name should keep it.

## 2. Third-party pieces

| Piece | Licence | Where it's recorded | What you must do |
|---|---|---|---|
| The detector's code, from the project's own lab build | Apache-2.0 | NOTICE; a header in each vendored file | Nothing beyond the licence |
| Model: nsfw-image-detection-384 by Marqo | Apache-2.0 | `models/cards/marqo-vit-tiny-384.json` | Attribution, licence text |
| Model: NSFWJS MobileNetV2 by Infinite Red | MIT | `models/cards/nsfwjs-mobilenet-v2.json`, `LICENSES/upstream-nsfwjs-MIT.txt` | Keep the MIT notice with the model |
| Model: Private Detector by Bumble | Apache-2.0 | `models/cards/bumble-private-detector.json`, `LICENSES/upstream-bumble-private-detector-Apache-2.0.txt` | Attribution, licence text |
| The keeper's Rust crates (on the `keeper-core` branch): arkworks, RustCrypto, `x25519-dalek`, `zeroize`, 64 crates in all | MIT, Apache-2.0 or BSD-3-Clause | `keeper/Cargo.toml`, `keeper/Cargo.lock`, `docs/STEP-2-STATUS.md` on that branch | Ship their notices with the keeper binary (no notice file exists yet) |
| Keyholder page, website | No dependencies | — | — |

About the models:

- **No weights are in git.** `tools/models/fetch_upstream.py` downloads them from their official sources at pinned revisions and refuses any byte that doesn't match its pins (`tools/models/pins.json`). Each card records the source, the revision, every file's hash and the training data as its makers describe it. None of the three publishes its training images, and no sample images were downloaded.
- **The NSFWJS weights come straight from the MIT upstream**, not from an AGPL-licensed browser extension that also carries a copy.
- **Shipping the app means redistributing the models.** `tools/make-app.sh` copies the models into the app but not yet their licence texts; add `LICENSE`, `NOTICE` and `LICENSES/` to the bundle before the first release.

The licence policy for new dependencies: Apache-2.0, MIT, BSD, ISC or similar; nothing under GPL, AGPL or a non-commercial licence ([CONTRIBUTING.md](../CONTRIBUTING.md), `tools/check-licences.sh`).

## 3. Rebranding

### The name

| Where | What to change |
|---|---|
| `Sources/SafeSightMacCore/AppText.swift` | `productName`. Every piece of the app's own text reads the name from here, and a test fails if the name is written anywhere else in the Swift code |
| `README.md` | The promise must match `AppText.honestPromise` word for word; a test compares them |
| `packaging/Info.plist` | `CFBundleName`, `CFBundleDisplayName`, the copyright line |
| `keyholder/core.js`, `keyholder/src/page.html`, `keyholder/src/page.js` (on the `keyholder-page` branch) | The name the passkey shows, the title and the page's sentences. Rebuild `index.html` afterwards; its published hash changes |
| `site/index.html`, `site/terms.html`, `site/check.mjs` (on the `website` branch) | The pages, and the check's list of allowed link hosts |
| `NOTICE`, `CORE.md`, `SECURITY.md`, `TERMS-AND-RISKS.md`, `docs/PRIVACY.md` | The name and "The SafeSight Mac authors" |

### Identifiers

| Identifier | Where | Notes |
|---|---|---|
| Bundle identifier | `tools/make-app.sh` takes it as an argument | None has been chosen, so pick your own reverse-domain prefix |
| The keeper's launch file, `<prefix>.safesightmac.keeper.plist` | `Sources/SafeSightMacWatcher/PracticeState.swift` | Any prefix is accepted already; the `safesightmac` stem must match the keeper's launch label once it exists |
| Executables and packages | `Package.swift` (`safesight-mac`, `safesightmac-harness`, `safesightmac-hello`), `keeper/Cargo.toml` (`safesightmac-keeper`), `.github/workflows/build-release.yml` | Rename together |
| Development switches | `SAFESIGHTMAC_LAB`, `SAFESIGHTMAC_MODELS`, `SAFESIGHTMAC_COVER_FORM` | Developer-facing only |

**Don't rename the format tags** inside data: the keeper's record tag `SSMK`, the keyholder codes' tag `SM`, and the detector's `kestrel-*` format names. They identify file and wire formats, not the brand. Renaming them breaks compatibility and counts as a change to the lock.

### The look

- **Covers, the way-out line and the repair card:** every colour is in `CoverTheme` (`Sources/SafeSightMacCover/Theme.swift`), light and dark. Tests require covers to stay opaque and neutral (a brand colour on a cover is a bad idea: it should feel calm), words at a contrast of at least 7:1 and key-cap letters at least 4.5:1.
- **Keyholder page:** `keyholder/src/page.css`. The build writes the page's content security policy and a new hash.
- **Website:** colour variables at the top of each page's style block. After a CSS change, put the new hash from `node site/check.mjs --print-csp` in that page's policy.
- **Icon:** the menu-bar item uses a system symbol; there's no custom artwork yet.

## 4. What must be set up again under your own accounts

Nothing has shipped and no Mac holds the lock, so today every identity below can change for free. After the first lock release, several of them are built into the lock, and changing them waits each owner's own wait plus 2 days or makes people enrol again.

| What | Why it matters | Cost of changing later |
|---|---|---|
| **Apple Developer Program** (as an organization) and a **Developer ID** certificate, with Apple's **notarization** | macOS checks the signature; the lock checks the Team ID | A Team ID change is a change to the lock |
| **Two hardware signing tokens**, a working one and a backup kept elsewhere, each with a Developer ID certificate and a release-manifest key | A maintainer signs only what public CI built; CI never holds a signing secret | Both manifest keys are built into the lock from version 1.0 |
| **GitHub organization and repository** | Today `lumen-open/safesight-mac`. Turn on private vulnerability reporting, protect `main` (the `check` workflow must pass) and `v*` tags, and allow Actions. Releases and their build-provenance statements come from here | The app's release host name is an ordinary change |
| **The keyholder page's web address** | Not chosen. A passkey belongs to one host name, and on a shared `github.io` host every site of the same account shares it, so use a dedicated host name you control and set `PINNED_ORIGIN` in `keyholder/core.js` | Once built into the lock, a new address makes every keyholder enrol again |
| **Website domain and hosting** | Not published yet | Ordinary |
| **Browser extension stores**, if the extension is built | Chrome Web Store, Edge Add-ons, Mozilla's add-on signing; Safari's copy ships inside the app | Ordinary |
| **Security contact** | GitHub's private vulnerability reporting today; a project mailbox is planned | Ordinary |
| **Time-signal mirrors** | No account, but the list (at least two independent operators) must be chosen before the lock ships | Built into the lock |
| **Independent outside review** | Required before version 1.0: a Mac-security reviewer who has the full source and a locked test Mac | — |
| **Test hardware** | A real Apple-silicon test Mac held by a tester, never anyone's daily Mac. The Hardcore lock's tests need a second Mac beside it | — |

## 5. What isn't in this repository yet

- **The detector lab.** Converting the models to Core ML with parity checks, the converted model files the sealed hash list expects (`models/watcher-models.sha256`), and the harmless-screen sets behind the false-cover and speed results all live in the project's separate detector lab. Code comments call it `v3-detector`, and some commands in `docs/STEP-1-STATUS.md` read it from a sibling folder. Without it you can fetch the pinned upstream models but can't rebuild the exact converted files. Ask for it in the handover, or vendor the conversion tools here.
- **The design record.** The decision register, its chapters, three red-team reviews and the research behind the Hardcore lock are in a separate planning repository. Code comments cite its decision numbers (`SD-018` and so on). It comes with the project.
- **Step documents written for one person.** `docs/STEP-0-OWNER.md` and "What needs the founder" in `docs/STEP-1-STATUS.md` describe one maintainer's setup and accounts. Rewrite them for your team.

## 6. How SafeSight Mac fits SHIFT's privacy policy

[docs/PRIVACY.md](PRIVACY.md) follows the same shape as SHIFT's privacy policy (last updated 26 October 2026), so the two can be read side by side.

**Where they already agree:** collect as little as possible, never sell data, no advertising use, list exactly what device management can do, say plainly what happens to the camera and microphone, honour deletion, keep a "Last updated" date.

**Where SafeSight Mac goes further, because of how it's built:**

- No account, no email address and no payment, so there's nothing to retain, delete within 30 days or expose in a breach.
- No analytics of any kind, aggregated or not.
- No server. The project receives nothing, not even an internet address.
- The part that reads the screen can't use the network.
- In the Hardcore lock, device management runs on the owner's own Mac and nobody else holds it, with fewer rights than a typical management server: no erase, no app list, no app installs.

**What SHIFT would add to its policy if it adopted SafeSight Mac:**

- **A Mac section:** what the Mac app keeps and doesn't keep (the tables in PRIVACY.md), the read-or-send rule, and the three public hosts and what each can see.
- **The Hardcore lock's device management,** listed the way SHIFT already lists its phone management permissions, stating that the server is the keeper on the owner's Mac and that SHIFT doesn't run it or hold it.
- **SHIFT's own flows,** if it adds them: account sign-in, payment through Stripe, its own release host, website analytics. Those are SHIFT's data and belong in its policy. They must stay outside the parts that read the screen or hold the lock, and a payment state can never weaken or unlock anything.
- **Age and ownership:** SafeSight Mac is for people protecting their own Mac, and for parents and guardians protecting a child's account on a Mac they own (a parent setup is being designed). It collects nothing about children either, so SHIFT's children's data sections would apply only to whatever SHIFT itself adds, such as accounts. In a parent setup the parent holds the lever for the child's account; for an adult protecting themselves, nobody does.

## 7. Open design questions you inherit

The design record lists each with its default. The ones that matter most:

**The lock**
- The Hardcore lock on real hardware. Its first trial worked on a virtual Mac: macOS took its settings from a management server running on the Mac itself, with no outside server and no push certificate. Recovery Lock came on, and leaving still worked with that server deleted. Activation Lock and restores from a second Mac need a spare Apple-silicon Mac.
- The keeper's open points: missing fields that block replaying the request journal after a crash, field sizes for some records, a second reader for the cryptography crates, and vectors from the reference time-lock and `age` tools.
- Which macOS mechanism draws the plain shield.
- Whether Stay needs the password (default: no).
- The 7-day wait for administrator tasks, and its closed list of allowed tasks.
- How long a lock weakness stays private after its fix ships (default: 400 days, to protect owners with a one-year wait).
- Whether signing tokens sit with an organization or with people, and who holds the backup.
- Which time-signal mirrors to trust.

**The cover and the detector**
- **The catch rate is not measured.** One sealed measurement is planned before 1.0; until then no accuracy figure may be published.
- Balanced or Either as the default rule. Balanced showed far fewer false covers on 932 harmless screens (8 against 194); what it misses is unmeasured. The shipped cut-off table differs from the values in the design record.
- How long a picture shows before its cover on a real screen, and how long busy pages stay blurred.
- Strict cover mode (nothing unjudged reaches the screen) isn't built.
- Models are compiled at load; the release should ship them compiled.

**The keyholder**
- The page's web address; whether real phones make the right kind of passkey; the approval code is about 440 characters, more than twice the design's estimate.

**Law and policy**
- A lawyer's read: consumer law for a lock the owner chooses, whether anyone has a right to faster removal, Apple's terms for a Mac that manages itself, and whether an organization should hold the project before the lock ships.
- Erasing the Mac is still a way out, said up front. The Hardcore lock is the research toward closing it.
- Browser-store copies of the extension update outside the 14-day public wait.

## 8. Taking one part on its own

| Part | How separate it is | What still ties it |
|---|---|---|
| **Detector** | Its own library (`DetectorCore`, with `Preprocess` and `RegionFinder`), no knowledge of the screen, a written preprocessing spec with vectors | Nothing product-specific beyond comments |
| **Cover layer and covers** | `SafeSightMacWatcher` is pure logic, driven in tests with synthetic frames; `SafeSightMacCapture` and `SafeSightMacCover` are separate targets | Not yet exported as package products; they read their words from `SafeSightMacCore`; the practice-state check knows the keeper's launch file name |
| **The lock** | The keeper is a Rust crate with no Swift dependency; every edge to macOS is a trait with a fake | The watcher's heartbeat and the app's messages are designed, not built |
| **Keyholder page** | One file, no dependencies, documented code formats | Approvals are checked by the keeper |
| **Opener** | Built from the keeper's own core | Reads the capsule format the keeper writes |

**Recommended before a handover,** none of them done yet:

1. Export the watcher, capture and cover targets as library products, so a team can take the cover and detector as one package.
2. Gather the identifiers (code stem, launch labels, bundle prefix, development switches) into one identity file that the Swift code, the keeper and `tools/make-app.sh` all read.
3. Keep the colours in one token file that feeds `CoverTheme`, the keyholder page and the website, with a check that they agree.
4. Give the keyholder page one constant for the product name.
5. Copy `LICENSE`, `NOTICE` and `LICENSES/` into the app bundle, and add a third-party notice file for the keeper's crates.
6. Vendor or publish the model conversion tools, and a public set of harmless test screens.
7. Rewrite the step documents for a team, and publish the design record or a cleaned copy of it.
