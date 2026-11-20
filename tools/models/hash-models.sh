#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Prints the watcher's model hash list for a local models folder: one "sha256  path" line per file of every model
# package the folder's bundle-manifest.json names, and one for the manifest itself, sorted by path. The committed list
# is models/watcher-models.sha256; the watcher refuses to load any file, the manifest included, that does not match it.
# tools/conformance/bundle.py fill writes the manifest's own file lists first; `bundle.py seal` writes every sealed
# file at once (spec/detector-contract.md).
# Usage: tools/models/hash-models.sh DIR > models/watcher-models.sha256
set -eu
dir="${1:?models folder}"
exec python3 -I "$(cd "$(dirname "$0")/.." && pwd)/conformance/bundle.py" hashlist "$dir"
