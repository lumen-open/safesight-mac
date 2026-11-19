#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Covers go the moment the app ends, however it ends (docs/TESTING-EDITION.md, guarantee 3). A child process makes a
# real cover window (invisible, one point square, off every display: nothing is shown or captured); the check
# finds it in the window list, kills the child as abruptly as a crash, and again lets one quit, and fails if
# either window outlives its process by two seconds.
set -eu
cd "$(dirname "$0")/.."
unset SAFESIGHTMAC_LAB KESTREL_LAB SAFESIGHTMAC_TESTING
swift build -c release --product safesightmac-harness >/dev/null
"$(swift build -c release --show-bin-path)/safesightmac-harness" vanish \
  && echo "Vanish check: a killed or quitting process's cover windows are gone at once" \
  || { echo "FAIL: a cover window outlived its process"; exit 1; }
