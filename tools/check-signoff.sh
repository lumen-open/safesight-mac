#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Fails if any commit in the given range lacks a Signed-off-by line (the DCO).
# Usage: tools/check-signoff.sh <base>..<head>   (defaults to all commits)
set -eu
range="${1:-HEAD}"
fail=0
for c in $(git rev-list --no-merges "$range"); do
  if ! git log -1 --format=%B "$c" | grep -q '^Signed-off-by: '; then
    echo "commit without sign-off: $(git log -1 --format='%h %s' "$c")"; fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "Sign-off check: every commit is signed off"
exit "$fail"
