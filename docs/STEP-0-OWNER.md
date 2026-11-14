<!-- SPDX-License-Identifier: Apache-2.0 -->
# Step 0: what the founder does

Step 0 ends with a signed, notarized "hello" build whose hashes match the public CI build (test ST-028). The repository, rules and checks already exist. These steps need you, because they involve accounts, payments or publishing.

## 1. Apple Developer Program (individual), about $99 a year

1. Go to developer.apple.com/programs/enroll and choose **Individual**.
2. Sign in with your Apple Account. Two-factor sign-in must be on. Adding two hardware security keys is recommended.
3. Pay the $99 yearly fee.
4. Wait for approval. It can take a few days; the other steps run meanwhile.

You type every password and payment detail yourself.

## 2. The public GitHub repository

1. Choose which GitHub account hosts it.
2. Create a **public** repository named `fernwick-open`, then push this folder's `main` branch to it. Claude can do the creating and pushing once you say which account.
3. In the repository's settings:
   - **Code security:** turn on **Private vulnerability reporting**.
   - **Rules:** protect `main` (no force pushes; require the `check` workflow to pass), and protect tags matching `v*` so only you can push them.
   - **Actions:** allow GitHub Actions.

Public repositories get GitHub's Mac build machines free.

## 3. The first CI run

After the first push, open the **Actions** tab. The `check` workflow should pass:
- sign-off on every commit;
- a licence line in every file;
- no secrets in any workflow;
- dependency licences;
- the Swift and keeper builds and tests.

The keeper is in Rust, which is not installed on this Mac, so the keeper is built and tested only on CI for now.

## 4. Signing and notarizing "hello" (after Apple approves)

1. Create a **Developer ID Application** certificate.
2. Push a version tag, for example `v0.0.1`. The `build-release` workflow builds both parts unsigned, lists their hashes and publishes a provenance statement for each.
3. Sign the CI-built files with your certificate. Notarize them with Apple's notary tool. Check that the signed files match CI's unsigned output plus the signature.

Claude can prepare exact commands for step 4 when you get there. You enter your own credentials.

## 5. Two quotes for the outside review

Version 1.0 cannot ship until an independent reviewer has had the full source and a locked test Mac (test ST-001). Ask two people or firms for a quote now, so the cost is known early. Either is fine:
- a Mac-security freelancer;
- a small audit firm.

## 6. Test machines

| What | Status |
|---|---|
| Virtual test Mac | A virtual Mac covers tests that need no real hardware |
| Real test Mac | A used Apple-silicon Mac, held by a helper, comes before the lock is tested (step 2). It is not needed for step 0 |

## Done when

- [ ] The Apple Developer membership is active.
- [ ] The public repository exists, with private vulnerability reporting and branch and tag protection on.
- [ ] `check` passes on CI.
- [ ] A signed, notarized `v0.0.1` "hello" release exists, and its hashes match CI's build (ST-028).
- [ ] Two quotes for the outside review are in hand.
