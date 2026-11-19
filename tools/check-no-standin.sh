#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Builds release products WITHOUT the lab flag, and the normal Testing edition, and fails if any stand-in code, symbol
# or string, or the lab event log, is present in them (register SD-139, test ST-043). Only a lab build
# (SAFESIGHTMAC_LAB=1, or `tools/make-app.sh --testing --lab`) has them.
set -eu
cd "$(dirname "$0")/.."
unset SAFESIGHTMAC_LAB KESTREL_LAB SAFESIGHTMAC_TESTING
fail=0
scan() {
  for b in "$1"/*; do
    [ -f "$b" ] && [ -x "$b" ] || continue
    n=$( (nm "$b"; strings "$b") 2>/dev/null | grep -ciE 'standin|labforced|checkerstandin|labtilescores|LabTile|LabEventLog|lab-events' || true)
    echo "$2 $(basename "$b"): $n stand-in or lab references"
    [ "$n" = "0" ] || fail=1
  done
  [ ! -e "$1/Modules/LabStandIn.swiftmodule" ] || { echo "$2: LabStandIn module present"; fail=1; }
}
swift build -c release >/dev/null
scan "$(swift build -c release --show-bin-path)" release
SAFESIGHTMAC_TESTING=1 swift build -c release --scratch-path .build-testing --product safesight-mac >/dev/null
scan "$(SAFESIGHTMAC_TESTING=1 swift build -c release --scratch-path .build-testing --show-bin-path)" testing
[ "$fail" = 0 ] && echo "Stand-in check: release and Testing builds contain no lab stand-in" || { echo "FAIL"; exit 1; }
