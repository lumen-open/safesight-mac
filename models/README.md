<!-- SPDX-License-Identifier: Apache-2.0 -->
# Models

No model weights are ever committed. This folder holds only:

- `cards/`: one card per model, with its licence evidence, its pinned source and the SHA-256 of every file.
- `thresholds.json`: the detector's committed cut-off table (`agreement+referee/1`, screen-level tuning), copied from the lab build's latest commit. Provisional until the cloud run measures what it catches.
- `watcher-models.sha256`: the hash list the watcher checks every model file against before it loads anything.

At run time the watcher loads the converted Core ML models from a local models folder (`--models DIR`, default `models/local/`), laid out as:

```
DIR/marqo-vit-tiny-384/marqo-vit-tiny-384.mlpackage
DIR/nsfwjs-mobilenet-v2/nsfwjs-mobilenet-v2.mlpackage
DIR/bumble-private-detector/bumble-private-detector.fp32.mlpackage
```

Upstream files are fetched with `tools/models/fetch_upstream.py`, which refuses any byte that does not match its pins. Conversion to Core ML (with parity checks and broken controls) is still done by the lab build's `convert/` tools and is not yet vendored here.
