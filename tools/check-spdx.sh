#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Fails if any source file lacks an SPDX licence line in its first five lines: every kind of file in the repository
# that has a comment syntax (code, scripts, workflows, web pages, styles, manifests).
# Usage: tools/check-spdx.sh [FILE...]   (defaults to every such file git tracks)
set -eu
if [ "$#" -eq 0 ]; then
  cd "$(dirname "$0")/.."
  files=$(git ls-files '*.swift' '*.rs' '*.sh' '*.js' '*.mjs' '*.py' '*.toml' '*.yml' '*.yaml' '*.html' '*.css' 'Package.swift') \
    || { echo "FAIL: git ls-files failed"; exit 2; }
  [ -n "$files" ] || { echo "FAIL: no source files found"; exit 2; }
  set -- $files
fi
fail=0
for f in "$@"; do
  [ -r "$f" ] || { echo "FAIL: cannot read $f"; exit 2; }
  if ! head -5 "$f" | grep -q 'SPDX-License-Identifier:'; then
    echo "missing SPDX line: $f"; fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "SPDX check: all $# source files carry a licence line"
exit "$fail"
