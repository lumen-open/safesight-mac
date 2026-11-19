#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Fails unless every Rust dependency of the keeper has an allowed licence (tools/licence_policy.py).
# The keeper's Cargo.lock is committed and used as it is (--locked): a missing or stale lock file fails, and so does
# a failed metadata call. It never passes by default.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../keeper"
[ -f Cargo.lock ] || { echo "Licence check: keeper/Cargo.lock is missing"; exit 1; }
meta=$(cargo metadata --format-version 1 --locked) || { echo "Licence check: cargo metadata failed"; exit 1; }
printf '%s' "$meta" | python3 "$here/licence_policy.py"
