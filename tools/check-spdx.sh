#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Fails if any source file lacks an SPDX licence line in its first five lines.
set -eu
fail=0
for f in $(git ls-files '*.swift' '*.rs' '*.sh' '*.js' '*.py' 'Cargo.toml' 'Package.swift'); do
  if ! head -5 "$f" | grep -q 'SPDX-License-Identifier:'; then
    echo "missing SPDX line: $f"; fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "SPDX check: all source files carry a licence line"
exit "$fail"
