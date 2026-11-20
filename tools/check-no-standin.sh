#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Builds release products and the normal Testing edition WITHOUT the lab flag, and fails if any stand-in code, symbol or
# string, or the lab event log, is present in them (register SD-139, test ST-043). Only a lab build (SAFESIGHTMAC_LAB=1,
# or `tools/make-app.sh --testing --lab`) has them.
# Usage: tools/check-no-standin.sh                 builds the release products and the Testing app, and checks them
#        tools/check-no-standin.sh FILE...         checks these binaries only (tools/make-app.sh checks what it built)
#        tools/check-no-standin.sh --lab FILE      the explicit lab path, for `make-app.sh --testing --lab` only: FILE
#                                                  must be a lab build (it must hold the stand-in), so that a lab app is
#                                                  never taken for a normal one, and a normal one never passes as lab
set -eu
cd "$(dirname "$0")/.."
unset SAFESIGHTMAC_LAB KESTREL_LAB SAFESIGHTMAC_TESTING
pattern='standin|labforced|checkerstandin|labtilescores|LabTile|LabEventLog|lab-events'
fail=0
count() {
  [ -f "$1" ] || { echo "FAIL: no binary at $1"; exit 2; }
  syms=$(nm "$1" 2>/dev/null || true)
  text=$(strings -a "$1") || { echo "FAIL: strings could not read $1"; exit 2; }
  printf '%s\n%s\n' "$syms" "$text" | grep -ciE "$pattern" || true
}
check() {
  n=$(count "$1")
  echo "$2$(basename "$1"): $n stand-in or lab-log references"
  [ "$n" = "0" ] || fail=1
}
if [ "${1:-}" = "--lab" ]; then
  [ "$#" -eq 2 ] || { echo "usage: $0 --lab FILE"; exit 2; }
  n=$(count "$2")
  [ "$n" != "0" ] || { echo "FAIL: $2 is not a lab build (no stand-in in it), so it may not take the lab path"; exit 1; }
  echo "Stand-in check: $(basename "$2") is a lab build ($n references), as its lab path says"
  exit 0
fi
if [ "$#" -gt 0 ]; then
  for b in "$@"; do check "$b" ""; done
else
  scan() {
    found=0
    for b in "$1"/*; do
      [ -f "$b" ] && [ -x "$b" ] || continue
      found=1; check "$b" "$2 "
    done
    [ "$found" = 1 ] || { echo "FAIL: no products found in $1"; exit 2; }
    [ ! -e "$1/Modules/LabStandIn.swiftmodule" ] || { echo "$2: LabStandIn module present"; fail=1; }
  }
  swift build -c release >/dev/null
  scan "$(swift build -c release --show-bin-path)" release
  SAFESIGHTMAC_TESTING=1 swift build -c release --scratch-path .build-testing --product safesight-mac >/dev/null
  scan "$(SAFESIGHTMAC_TESTING=1 swift build -c release --scratch-path .build-testing --show-bin-path)" testing
fi
[ "$fail" = 0 ] && echo "Stand-in check: no lab stand-in and no lab event log" || { echo "FAIL"; exit 1; }
