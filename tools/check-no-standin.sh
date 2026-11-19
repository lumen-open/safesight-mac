#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Builds release products WITHOUT the lab flag and fails if any stand-in code, symbol or string
# is present in them (register SD-139, test ST-043).
# Usage: tools/check-no-standin.sh            builds the release products and checks them
#        tools/check-no-standin.sh FILE...    checks these binaries only (tools/make-app.sh checks what it built)
set -eu
cd "$(dirname "$0")/.."
unset SAFESIGHTMAC_LAB KESTREL_LAB
fail=0
check() {
  [ -f "$1" ] || { echo "FAIL: no binary at $1"; exit 2; }
  syms=$(nm "$1" 2>/dev/null || true)
  text=$(strings -a "$1") || { echo "FAIL: strings could not read $1"; exit 2; }
  n=$(printf '%s\n%s\n' "$syms" "$text" | grep -ciE 'standin|labforced|checkerstandin|labtilescores|LabTile' || true)
  echo "$(basename "$1"): $n stand-in references"
  [ "$n" = "0" ] || fail=1
}
if [ "$#" -gt 0 ]; then
  for b in "$@"; do check "$b"; done
else
  swift build -c release >/dev/null
  bin=$(swift build -c release --show-bin-path)
  found=0
  for b in "$bin"/*; do
    [ -f "$b" ] && [ -x "$b" ] || continue
    found=1; check "$b"
  done
  [ "$found" = 1 ] || { echo "FAIL: no release products found in $bin"; exit 2; }
  [ ! -e "$bin/Modules/LabStandIn.swiftmodule" ] || { echo "LabStandIn module present"; fail=1; }
fi
[ "$fail" = 0 ] && echo "Stand-in check: release builds contain no lab stand-in" || { echo "FAIL"; exit 1; }
