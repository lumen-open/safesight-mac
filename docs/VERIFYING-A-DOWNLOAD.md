<!-- SPDX-License-Identifier: Apache-2.0 -->
# Checking a download

**There are no releases yet.** This page is the plan for how you'll be able to check one once they exist, so that the steps are public before the first file is. Until then, the only way to run SafeSight Mac is to build it yourself from this repository.

## What each release will come with

Every release is built by the project's public `build-release` workflow (`.github/workflows/build-release.yml`), from a version tag on a commit that is already on `main`, after the same checks every pull request passes. For each file it builds, the workflow publishes:

- its SHA-256 hash, in a `SHA256SUMS` file;
- a signed build-provenance statement, made with GitHub's artifact attestations and recorded in the public Sigstore log. It says which repository, workflow, tag and commit built the file.

The app you download is then signed with the project's Developer ID and notarized by Apple. Signing happens on a maintainer's hardware token, never in CI.

## Checking a file

You'll need the [GitHub CLI](https://cli.github.com/) (`gh`). Replace `v1.2.3` with the release you downloaded.

**1. The hash matches.** In the folder with the download and `SHA256SUMS`:

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing
```

**2. The project's release workflow built it, from that tag.** Pin both the workflow and the tag, so a file built by any other workflow, branch or fork fails:

```sh
gh attestation verify FILE \
  --repo lumen-open/safesight-mac \
  --signer-workflow lumen-open/safesight-mac/.github/workflows/build-release.yml \
  --source-ref refs/tags/v1.2.3 \
  --deny-self-hosted-runners
```

A pass means the file's exact bytes were built by that workflow on GitHub's own runners, from the commit that tag points to. You can then read that commit's code and its checks on GitHub.

**3. The app is signed and notarized.** For the app itself:

```sh
codesign --verify --deep --strict --verbose=2 "SafeSight Mac.app"
spctl --assess --type execute --verbose "SafeSight Mac.app"
```

The second command should name the project's Developer ID and say the app was notarized.

## What isn't decided yet

- **Linking the signed app to the CI build.** Signing changes an app's bytes, so the signed app's hash differs from the unsigned file CI built. The plan is a signed release manifest that lists both, recorded in the public log, so you can check that the signed app is the CI build plus a signature and nothing else. Its format isn't written yet.
- **Checks the app does on its own.** Updates are designed to be checked by the Mac before they install, after 14 public days. That isn't built.
- **The Developer ID.** None exists yet, so step 3 can't name it yet. When it does, this page will say exactly what to expect.

If a check fails on a file you downloaded, don't open it. If you think a release itself is wrong, please report it privately as [SECURITY.md](../SECURITY.md) says.
