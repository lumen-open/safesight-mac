#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Prints the watcher's model hash list for a local models folder: one "sha256  path" line per
# file of the three watcher model packages, sorted by path. The committed list is
# models/watcher-models.sha256; the watcher refuses to load any file that does not match it.
# Usage: tools/models/hash-models.sh DIR > models/watcher-models.sha256
set -eu
dir="${1:?models folder}"
cd "$dir"
for p in marqo-vit-tiny-384/marqo-vit-tiny-384.mlpackage \
         nsfwjs-mobilenet-v2/nsfwjs-mobilenet-v2.mlpackage \
         bumble-private-detector/bumble-private-detector.fp32.mlpackage; do
  [ -d "$p" ] || { echo "missing: $p" >&2; exit 1; }
  find "$p" -type f ! -name '.DS_Store'
done | LC_ALL=C sort | while read -r f; do shasum -a 256 "$f"; done
