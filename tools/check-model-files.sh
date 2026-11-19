#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Fails if a model folder holds anything the sealed hash list doesn't name: an extra file, a link, or anything other
# than plain files and folders. tools/make-app.sh runs it on the packages it copies, before checking their hashes, so
# nothing unlisted can ride into the app beside the models.
# Usage: tools/check-model-files.sh HASH_LIST FOLDER
set -eu
list="${1:?hash list, for example models/watcher-models.sha256}"
dir="${2:?folder holding the model packages}"
[ -r "$list" ] || { echo "FAIL: cannot read $list"; exit 2; }
[ -d "$dir" ] || { echo "FAIL: no folder $dir"; exit 2; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/safesightmac-modelfiles.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
awk 'NF == 2 { print $2 }' "$list" | LC_ALL=C sort > "$tmp/want.txt"
[ -s "$tmp/want.txt" ] || { echo "FAIL: $list lists no files"; exit 2; }
(cd "$dir" && find . ! -type d) | sed 's#^\./##' | LC_ALL=C sort > "$tmp/have.txt"
(cd "$dir" && find . ! -type d ! -type f) > "$tmp/odd.txt"
fail=0
extra=$(LC_ALL=C comm -13 "$tmp/want.txt" "$tmp/have.txt")
[ -z "$extra" ] || { echo "FAIL: the model folder holds files the hash list doesn't name:"; printf '  %s\n' $extra; fail=1; }
[ ! -s "$tmp/odd.txt" ] || { echo "FAIL: the model folder holds something other than plain files:"; cat "$tmp/odd.txt"; fail=1; }
[ "$fail" = 0 ] || exit 1
echo "Model files: only the $(wc -l < "$tmp/want.txt" | tr -d ' ') listed files"
