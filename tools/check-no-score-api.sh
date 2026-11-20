#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# No score leaves the detector: DetectorCore's public API, read from the symbol graph the compiler emits for a default
# build (no lab code), names a floating-point type only where tools/no-score-api-allow.txt says, each a reviewed use.
# A new use fails until someone has looked at it and listed it; an entry that no longer matches fails too.
#
# Usage: tools/check-no-score-api.sh                 emits the symbol graphs (a default build), then checks them
#        tools/check-no-score-api.sh --graphs DIR    checks symbol graphs already emitted into DIR
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
python3 -I "$here/score_api_scan.py" --self-test >/dev/null || { python3 -I "$here/score_api_scan.py" --self-test; exit 1; }
if [ "${1:-}" = "--graphs" ]; then
  dir="${2:?symbol graph folder}"
else
  unset SAFESIGHTMAC_LAB KESTREL_LAB SAFESIGHTMAC_TESTING
  (cd "$root" && swift package dump-symbol-graph --minimum-access-level public >/dev/null 2>&1) \
    || { echo "FAIL: swift package dump-symbol-graph could not run"; exit 2; }
  dir=$(cd "$root" && find "$(swift build --show-bin-path)/../symbolgraph" -maxdepth 0 2>/dev/null || true)
  [ -n "$dir" ] && [ -d "$dir" ] || { echo "FAIL: no symbol graphs were written"; exit 2; }
fi
[ -d "$dir" ] || { echo "FAIL: no folder $dir"; exit 2; }
exec python3 -I "$here/score_api_scan.py" "$dir" "$here/no-score-api-allow.txt" DetectorCore
