#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Fails unless every Rust dependency of the keeper has an allowed licence (tools/licence_policy.py).
# A failed metadata call fails the check; it never passes by default.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd keeper
if [ -f Cargo.lock ]; then lock=--locked; else lock=; fi
meta=$(cargo metadata --format-version 1 $lock) || { echo "Licence check: cargo metadata failed"; exit 1; }
printf '%s' "$meta" | python3 "$here/licence_policy.py"
