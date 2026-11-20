<!-- SPDX-License-Identifier: Apache-2.0 -->
# The detector contract

SafeSight Mac judges what is on the screen with a small set of image models. You can bring your own. This page says exactly what a model, or a whole detector, has to provide to plug in, and what the app promises in return. If your model meets it, you won't need to read the detector's code to use it.

There are two ways in:

- **Level 1, a drop-in model.** The common case. You bring one or more Core ML models, and the app's own detector runs them with its own rules: the picture finder, the slices, the jitter, the caches, the cover. You change files, not code.
- **Level 2, a drop-in detector.** You replace the whole judge with your own type. More work, and more for you to prove.

Either way, `tools/conformance/run.sh` checks your bundle and writes a short report you can keep with your release decision. [docs/BRING-YOUR-OWN-DETECTOR.md](../docs/BRING-YOUR-OWN-DETECTOR.md) walks through it step by step.

## What never changes

These hold for every model and every detector. They are why people trust the app with their screen.

- **Classes only leave the detector.** It answers `clear`, `contain` (a soft blur until cleared) or `cover`, with a reason and a rectangle. No score, no cut-off and no probability ever crosses the module's boundary, reaches the interface or is written to a log.
- **A fault covers more, never less.** A model that fails to load, a file that doesn't match its hash, an edited manifest, a model of the wrong shape: each one covers every display whole. A model that throws or returns a score that isn't a number from 0 to 1 at run time leaves that picture covered or blurred and judged again, never shown as clean.
- **Unjudged means covered.** When there is more on screen than the budget allows, what wasn't judged yet is covered or blurred, never shown.
- **Fewer models never means less covering.** With two families, the owner's rule decides (Balanced or Either). With one family, its flag alone covers.
- **Nothing leaves the Mac,** and nothing that reads the screen has any networking code.

## Level 1: a drop-in model

### 1. The model file

A Core ML package (`.mlpackage`).

- **Input** `image`: a float32 multi-array of shape `[1, 3, N, N]`, holding the byte values 0 to 255 as planar RGB, channel by channel. Any normalisation (scaling, mean and spread) happens inside the model.
- **Output** `probs`: a multi-array of `K` class probabilities, shape `[1, K]` (or `[K]`).
- **N** is declared in the manifest, and anything from 224 to 512 is fine.

The detector makes every input with the pinned preprocessing in [preprocess.md](preprocess.md) (`kestrel-preprocess/1`): alpha over black, crop, then an antialiased resample that squashes the crop to N by N. Tiles are kept at 2:1 or less, so your model never sees anything stretched further. Your model should be trained or checked on inputs made the same way.

The **flag score** is the sum of the probabilities at your flag classes. It should mean "explicit sexual content", and nothing else: the app hides only that by default.

The shape is checked when the model loads. A model whose input or output differs from what its manifest entry declares is refused, and every display is covered.

### 2. The bundle manifest

One file, `bundle-manifest.json`, beside the packages. It replaces the list of models that used to be written into the code.

```json
{
  "schema": "kestrel-models/1",
  "families": 2,
  "models": [
    {
      "id": "your-model-a",
      "slot": "A",
      "runtime": "coreml",
      "package": "your-model-a/your-model-a.mlpackage",
      "inputSide": 384,
      "classCount": 2,
      "flagClasses": [0],
      "computeUnits": "cpuAndNeuralEngine",
      "files": [{ "path": "your-model-a/your-model-a.mlpackage/Manifest.json", "sha256": "…" }]
    }
  ]
}
```

- **`families`**: `2` for the two-family rule, `1` for single-family mode (below).
- **`slot`**: `A` or `B` for the two families, or `tie-breaker`. Two families need at least one model in slot A and one in slot B, and there is at most one tie-breaker. Ideally A and B are different kinds of model (a vision transformer and a convolutional network, say), so they rarely fail on the same picture.
- **`runtime`**: `coreml`. The manifest has room for other runtimes later.
- **`flagClasses`**: indices into `probs`. At least one, all below `classCount`, and never all of them.
- **`computeUnits`**: `cpuAndNeuralEngine`, `cpuAndGPU`, `cpuOnly` or `all`. Choose the one your parity evidence covers.
- **`files`**: every file inside the package with its SHA-256. `tools/conformance/bundle.py fill` writes these for you.

The manifest is read strictly. An unknown key, a missing key, a fraction where a whole number belongs or a value out of range refuses the whole bundle, and the displays are covered.

**The manifest is sealed like a model file.** The hash list compiled into the build (`models/watcher-models.sha256`, carried in `Sources/SafeSightMacWatcher/CommittedModelData.swift`) names the manifest along with every model file. An edited manifest is refused exactly as an edited model is. The manifest and the sealed list must also agree on which model files there are, file for file.

### 3. The model card

`cards/<id>.json`, in the same shape as [models/cards](../models/cards):

- `id`, `family` and `inputSide`, matching the manifest;
- `classes` (all K names, in order) and `flagClasses` (the names, which must be the manifest's indices);
- `notMeantToFlag`: the classes the flag score leaves out on purpose, so a reader can see what the model is *not* for;
- `licence` and `licenceFile`, the licence text itself shipped in the bundle;
- `source`, with the exact upstream `revision`;
- `trainingDataAsStated`: the training data as its makers describe it;
- `files`: every file you started from or made, with its SHA-256.

### 4. The cut-off table

`thresholds.json` (`kestrel-thresholds/1`), with every model, the tie-breaker included, in every size band: `16-31`, `32-63`, `64-127` and `128+` detail pixels. Each band has all five values:

| value | what it does |
|---|---|
| `cover` | a score at or above it flags the picture |
| `clean` | a contained picture clears only at or below it |
| `strike` | the strength both families must reach for a strike |
| `gridMember` | the level for a tile inside a grid of pictures |
| `gridLow` | kept so the table's shape stays the same |

Make them with false-cover tuning on harmless screens: pick the lowest `cover` that keeps false covers within the project's mark, per band. Cut-offs are sealed in the build like the manifest, and a bundle with a model missing from the table, or missing a band, is refused rather than run on defaults. They never leave the module, and no interface or log may show them.

### 5. Parity evidence

Core ML's output, checked against the framework the model was made in, on a fixed set of harmless inputs, within a tolerance you state before you run it. Ship it as `conformance/<id>/reference.json`:

```json
{
  "schema": "kestrel-parity/1",
  "preprocess": "kestrel-preprocess/1",
  "reference": "PyTorch 2.x, float32, the published weights",
  "tolerance": { "cpuAndNeuralEngine": 0.02, "cpuAndGPU": 0.02, "cpuOnly": 0.001 },
  "inputs": [{ "file": "inputs/0001.png", "sha256": "…", "flagScore": 0.0123 }]
}
```

At least 100 inputs, each a harmless picture shipped beside the file and judged whole. The tolerance is the largest difference in flag score allowed on any single picture. It must cover the compute units your manifest declares; the kit also reports the others you list. Parity is a real check: a float16 build of one of today's models failed it, which is why that model runs in float32 on the GPU.

You may add deliberately broken controls (`conformance/<id>/broken/*.mlpackage`, for example with its colour channels swapped). Each must fail parity, which shows the check can tell. The kit always adds one control of its own: the same inputs with red and blue swapped must fail too.

### 6. Speed

About 10 ms a tile or less on an M1 Neural Engine or GPU, at batch sizes 1 to 8, with the memory it needs stated. The watcher's budget is 40 judgements a second sustained, with bursts of 400, and the goal is about a tenth of a second from a new picture to its cover.

### 7. Determinism

The same bytes in give the same class out on the same compute unit.

## Single-family mode

If you have one strong model rather than two different ones, set `"families": 1` and put every model in one slot, with no tie-breaker. Then that family's flag alone covers under every rule, as the Either rule does, and it makes a window cautious ("hot") as both families agreeing would. There is never a dispute to settle. Two families remain the default and the recommendation, because two different kinds of model rarely miss the same picture, but one family never covers less than its own flag.

Single-family mode is off unless the sealed manifest declares it.

## Level 2: a drop-in detector

If you replace the whole judge, your type takes an `RGBAImage` and a `JudgeContext`, honours the caller's `budget`, and returns a `FrameVerdict` holding **classes only**. It must keep every promise above, and pass the rules in `Tests/DetectorCoreTests/ContractTests.swift`, `RuleTests.swift` and `NoScoreLeaksTests.swift`:

- unjudged or over budget means covered or blurred, never clear;
- a fault means more covering, never less;
- no score crosses the boundary, in a verdict, a progress report or a log.

In between the two levels sits `ScoringModel`, a small public protocol: an `id`, a `family`, an input `side`, and `flagScores` for a batch of spec tensors. A model on another runtime can implement it and be built into a set with `ModelSet(scorers:tieBreaker:singleFamily:bundleVersion:)`, keeping all of the detector's rules. Scores go into the detector through it and never come back out.

## Checking your bundle

```
tools/conformance/run.sh BUNDLE --screens LIST --root DIR
```

It checks the files, cards, licences and hashes; seals your bundle into a scratch copy of the repository and builds it, so your manifest and models go through exactly the checks a release does; checks shapes and parity, broken controls included; runs the rule and contract tests with your models plugged in, with fault drills (a missing file, a changed byte, an unlisted file, an edited manifest, a model that fails to load); and counts false covers on your harmless-screen set under Balanced and Either. See [docs/BRING-YOUR-OWN-DETECTOR.md](../docs/BRING-YOUR-OWN-DETECTOR.md).

How well a model catches what it should is measured on a licensed set you hold privately, never in this repository. No explicit material ever enters it, in code, tests, fixtures or examples.
