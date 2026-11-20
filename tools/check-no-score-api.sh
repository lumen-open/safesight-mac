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
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/safesightmac-scoreapi.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  # The module alone, in a default build, then its symbol graph straight from the compiler's tool.
  (cd "$root" && swift build --target DetectorCore >"$tmp/build.txt" 2>&1) \
    || { tail -30 "$tmp/build.txt"; echo "FAIL: DetectorCore did not build"; exit 2; }
  bin=$(cd "$root" && swift build --show-bin-path)
  module=$(find "$bin" -name 'DetectorCore.swiftmodule' -not -path '*/DetectorCore.swiftmodule/*' | head -1)
  [ -n "$module" ] || { echo "FAIL: no DetectorCore.swiftmodule under $bin"; exit 2; }
  dir="$tmp/graphs"; mkdir -p "$dir"
  xcrun swift-symbolgraph-extract -module-name DetectorCore -I "$(dirname "$module")" -I "$bin" \
      -target "$(uname -m)-apple-macosx15.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
      -minimum-access-level public -output-dir "$dir" >"$tmp/extract.txt" 2>&1 \
    || { tail -30 "$tmp/extract.txt"; echo "FAIL: swift-symbolgraph-extract could not run"; exit 2; }
fi
[ -d "$dir" ] || { echo "FAIL: no folder $dir"; exit 2; }
python3 -I "$here/score_api_scan.py" "$dir" "$here/no-score-api-allow.txt" DetectorCore
