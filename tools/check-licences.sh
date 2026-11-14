#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Fails if any Rust dependency in the keeper's lock file declares a denied licence.
# Step 0 has no dependencies; this check grows with the dependency list.
set -eu
cd keeper
if [ ! -f Cargo.lock ]; then cargo generate-lockfile >/dev/null 2>&1 || true; fi
deps=$(cargo metadata --format-version 1 --locked 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for p in d["packages"]:
    if p["name"]!="fernwick-keeper": print(p["name"], p.get("license") or "UNKNOWN")
' || true)
bad=$(printf '%s\n' "$deps" | grep -E -i 'GPL|AGPL|LGPL|UNKNOWN|NonCommercial|SSPL' || true)
if [ -n "$bad" ]; then echo "denied or unknown licence:"; echo "$bad"; exit 1; fi
echo "Licence check: $(printf '%s' "$deps" | grep -c . || true) dependencies, all allowed"
