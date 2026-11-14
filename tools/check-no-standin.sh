#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Builds release products WITHOUT the lab flag and fails if any stand-in code, symbol or string
# is present in them (register SD-139, test ST-043).
set -eu
cd "$(dirname "$0")/.."
unset SAFESIGHTMAC_LAB KESTREL_LAB
swift build -c release >/dev/null
bin=$(swift build -c release --show-bin-path)
fail=0
for b in "$bin"/*; do
  [ -f "$b" ] && [ -x "$b" ] || continue
  n=$( (nm "$b"; strings "$b") 2>/dev/null | grep -ciE 'standin|labforced|checkerstandin|labtilescores|LabTile' || true)
  echo "$(basename "$b"): $n stand-in references"
  [ "$n" = "0" ] || fail=1
done
[ ! -e "$bin/Modules/LabStandIn.swiftmodule" ] || { echo "LabStandIn module present"; fail=1; }
[ "$fail" = 0 ] && echo "Stand-in check: release builds contain no lab stand-in" || { echo "FAIL"; exit 1; }
