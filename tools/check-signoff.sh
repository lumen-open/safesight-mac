#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Fails if any commit in the given range, merge commits included, lacks a Signed-off-by line with a name and an
# email address (the DCO). A range git cannot read, or one that holds no commits, fails too: the check never passes
# because it looked at nothing.
# Usage: tools/check-signoff.sh <base>..<head>   (defaults to every commit reachable from HEAD)
set -eu
range="${1:-HEAD}"
commits=$(git rev-list "$range") || { echo "FAIL: git could not list the commits in $range"; exit 2; }
[ -n "$commits" ] || { echo "FAIL: $range holds no commits, so there is nothing to check"; exit 1; }
fail=0
n=0
for c in $commits; do
  n=$((n + 1))
  msg=$(git log -1 --format=%B "$c") || { echo "FAIL: git could not read commit $c"; exit 2; }
  if ! printf '%s\n' "$msg" | grep -qE '^Signed-off-by: [^<>]*[^<> ] <[^<> @]+@[^<> ]+>[[:space:]]*$'; then
    echo "commit without sign-off: $(git log -1 --format='%h %s' "$c")"; fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "Sign-off check: all $n commits are signed off"
exit "$fail"
