#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# CI must hold no signing, notary or token secret (register: SD-168, ST-055).
# Fails if any workflow file uses the secrets context in an expression (secrets.NAME, secrets['NAME'],
# toJSON(secrets) and the like) or passes secrets on with a secrets: key (secrets: inherit, or a mapping).
# A grep that cannot read the files fails the check.
# Usage: tools/check-no-secrets.sh [FOLDER]   (defaults to .github/workflows)
set -eu
cd "$(dirname "$0")/.."
dir="${1:-.github/workflows}"
[ -d "$dir" ] || { echo "FAIL: no folder $dir"; exit 2; }
files=$(find "$dir" -name '*.yml' -o -name '*.yaml' | sort)
[ -n "$files" ] || { echo "FAIL: no workflow files in $dir"; exit 2; }
pattern='\$\{\{([^}]*[^A-Za-z0-9_.-])?secrets([^A-Za-z0-9_-]|$)|^[[:space:]]*secrets[[:space:]]*:'
rc=0
# shellcheck disable=SC2086
grep -nE "$pattern" $files || rc=$?
case "$rc" in
  0) echo "A workflow names a secret. CI must hold none."; exit 1 ;;
  1) echo "Secret check: no workflow names a secret" ;;
  *) echo "FAIL: grep could not read the workflow files (exit $rc)"; exit 2 ;;
esac
