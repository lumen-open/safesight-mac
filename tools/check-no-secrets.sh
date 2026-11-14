#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# CI must hold no signing, notary or token secret (register: SD-168, ST-055).
# Fails if any workflow file references the secrets context.
set -eu
if grep -rn 'secrets\.' .github/workflows/ ; then
  echo "A workflow names a secret. CI must hold none."; exit 1
fi
echo "Secret check: no workflow names a secret"
