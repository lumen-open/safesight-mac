<!-- SPDX-License-Identifier: Apache-2.0 -->
# Bring your own detector

SafeSight Mac is built so that a maintainer bringing their own model can plug it in without learning the detector's code. The models it runs are named in a sealed manifest, not in the code; the rules that turn their scores into covers stay exactly as they are; and one command checks your bundle and writes a report you can keep with your release decision.

The full contract is [spec/detector-contract.md](../spec/detector-contract.md). This page is the short route through it.

## 1. Put the bundle together

One folder holding:

```
bundle-manifest.json                  which models, in which slot, with which input side and flag classes
your-model/your-model.mlpackage       each Core ML package the manifest names
thresholds.json                       the cut-offs, per model and size band
cards/your-model.json                 a model card per model
LICENSES/...                          the licence files the cards name
conformance/your-model/reference.json reference outputs from the framework the model was made in
conformance/your-model/inputs/...     the harmless pictures they were made from (PNG is safest)
conformance/your-model/broken/...     optional: deliberately broken copies, which must fail parity
```

Start the manifest from [models/bundle-manifest.json](../models/bundle-manifest.json), which describes today's three models. With two different models, use slots `A` and `B` and keep `"families": 2`; add a `tie-breaker` if you have one. With one strong model, use `"families": 1`: a single model covers whatever it flags, under either rule.

Leave each model's `files` empty and let the kit fill them in:

```
python3 -I tools/conformance/bundle.py fill BUNDLE
```

## 2. Check it

```
tools/conformance/run.sh BUNDLE --screens LIST --root DIR
```

`LIST` is a file of harmless screenshots, one path a line, relative to `DIR`. The run takes a while: it builds the detector three times (release, lab and test builds) in a scratch copy of the repository. It never changes your bundle or your checkout, and it downloads nothing. It checks, in order:

1. **Files.** The manifest, every model file hashed and nothing unlisted, the cards, licences, cut-offs and reference outputs. `run.sh --stage files BUNDLE` runs this part alone, in a second.
2. **Seal.** Your bundle sealed into the scratch copy, exactly as adopting it would seal it.
3. **Load.** A release build loads the folder as the app does: the sealed list, the manifest, each model's shape, the cut-off table.
4. **Parity.** Each model against its reference outputs, on the compute units it declares, with its broken controls and one of the kit's own, which must all fail.
5. **Tests.** The rule and contract tests, and fault drills with your bundle plugged in: a missing file, a changed byte, an unlisted file, an edited manifest and a model that fails to load must each be refused, which covers every display whole.
6. **False covers** on your harmless screens, under Balanced and under Either.

The report is `report.json` in the folder the run names, with the parity and false-cover details beside it. Exit code 0 means every stage passed; 3 means every stage it ran passed but some were skipped (no `--screens`, say); 1 means something failed, and the output says what.

Two things the kit doesn't measure for you: speed (the lab harness's `bench` command, against the budget in the contract), and how well your model catches what it should, which you measure privately on a licensed set. No explicit material ever goes into this repository.

## 3. Adopt it

When the report is clean:

```
python3 -I tools/conformance/bundle.py seal BUNDLE .
```

This writes `models/bundle-manifest.json`, `models/watcher-models.sha256`, `models/thresholds.json` and the sealed copy the build carries (`Sources/SafeSightMacWatcher/CommittedModelData.swift`). Add your cards under `models/cards/`, update the test that pins today's three models (`BundleManifestTests.theManifestBuildsTheSetThatWasHardCoded`) to pin yours, and build the app with `tools/make-app.sh`, which copies the packages and the manifest the sealed list names.

## If you need another runtime

Models run through `ScoringModel`, a small public protocol in `DetectorCore`: an id, a family, an input side, and flag scores for a batch of tensors. A runtime other than Core ML implements it and builds a set with `ModelSet(scorers:tieBreaker:singleFamily:bundleVersion:)`; the manifest's `runtime` field is where it would be named. The detector's rules stay the same, and scores still never leave the detector.
