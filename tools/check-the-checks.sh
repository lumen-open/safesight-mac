#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Checks the project's own checks: each one is run on made-up bad input and must fail, and on made-up good input and
# must pass. A check that passes everything would otherwise look exactly like a clean repository. It also checks
# that the release workflow runs every check script the check workflow runs.
# Writes only to a temporary folder it removes. Needs a C compiler (Xcode's) for the binary cases.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/safesightmac-checks.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
wrong=0
n=0

# expect WANT NAME COMMAND...: WANT is "pass" (exit 0) or "fail" (any other exit).
expect() {
  want=$1; name=$2; shift 2
  n=$((n + 1))
  rc=0
  "$@" > "$tmp/out.txt" 2>&1 || rc=$?
  if { [ "$want" = pass ] && [ "$rc" -ne 0 ]; } || { [ "$want" = fail ] && [ "$rc" -eq 0 ]; }; then
    echo "WRONG: $name: wanted $want, got exit $rc"; sed 's/^/    /' "$tmp/out.txt"; wrong=$((wrong + 1))
  fi
}

# --- check-no-network.sh: sources -------------------------------------------------------------------------------
src="$tmp/src"
mkdir -p "$src/clean" "$src/net" "$src/remote" "$src/spawn" "$src/load" "$src/class" "$src/broken" "$src/listed"
printf 'let x = 1\n' > "$src/clean/A.swift"
printf 'import Network\n' > "$src/net/A.swift"
printf 'let d = try Data(contentsOf: URL(string: "https://example.com/x")!)\n' > "$src/remote/A.swift"
printf 'let p = Process()\n' > "$src/spawn/A.swift"
printf 'let h = dlopen("/tmp/x.dylib", 0)\n' > "$src/load/A.swift"
printf 'let c = NSClassFromString("NSURLSession")\n' > "$src/class/A.swift"
ln -s "$tmp/nowhere.swift" "$src/broken/A.swift"   # grep cannot read it: exit 2 must not pass
printf '    let s = try String(contentsOf: folder.appendingPathComponent("list"), encoding: .utf8)\n' > "$src/listed/A.swift"
: > "$tmp/allow-empty.txt"
printf '# reviewed\n%s: let s = try String(contentsOf: folder.appendingPathComponent("list"), encoding: .utf8)\n' "$src/listed/A.swift" > "$tmp/allow-listed.txt"
printf '%s: let gone = 1\n' "$src/clean/A.swift" > "$tmp/allow-stale.txt"
net="$here/check-no-network.sh"
expect pass "network: clean source"                     sh "$net" --sources "$src/clean" --allow "$tmp/allow-empty.txt"
expect fail "network: import Network"                   sh "$net" --sources "$src/net" --allow "$tmp/allow-empty.txt"
expect fail "network: Data(contentsOf:) a remote URL"   sh "$net" --sources "$src/remote" --allow "$tmp/allow-empty.txt"
expect fail "network: Process()"                        sh "$net" --sources "$src/spawn" --allow "$tmp/allow-empty.txt"
expect fail "network: dlopen"                           sh "$net" --sources "$src/load" --allow "$tmp/allow-empty.txt"
expect fail "network: NSClassFromString"                sh "$net" --sources "$src/class" --allow "$tmp/allow-empty.txt"
expect fail "network: unreadable source (grep exit 2)"  sh "$net" --sources "$src/broken" --allow "$tmp/allow-empty.txt"
expect fail "network: local read not on the list"       sh "$net" --sources "$src/listed" --allow "$tmp/allow-empty.txt"
expect pass "network: local read on the list"           sh "$net" --sources "$src/listed" --allow "$tmp/allow-listed.txt"
expect fail "network: stale allow-list entry"           sh "$net" --sources "$src/clean" --allow "$tmp/allow-stale.txt"

# --- check-no-network.sh: binaries ------------------------------------------------------------------------------
printf 'int main(void) { return 0; }\n' > "$tmp/clean.c"
printf '#include <sys/socket.h>\nint main(void) { return socket(AF_INET, SOCK_STREAM, 0); }\n' > "$tmp/socket.c"
printf '#include <netdb.h>\nint main(void) { struct addrinfo *r; return getaddrinfo("example.com", 0, 0, &r); }\n' > "$tmp/lookup.c"
cc -o "$tmp/clean" "$tmp/clean.c"
cc -o "$tmp/socket" "$tmp/socket.c"
cc -o "$tmp/lookup" "$tmp/lookup.c"
cc -o "$tmp/cfnetwork" "$tmp/clean.c" -framework CFNetwork
expect pass "network: clean binary"                     sh "$net" --binary "$tmp/clean"
expect fail "network: binary imports socket"            sh "$net" --binary "$tmp/socket"
expect fail "network: binary imports getaddrinfo"       sh "$net" --binary "$tmp/lookup"
expect fail "network: binary links CFNetwork"           sh "$net" --binary "$tmp/cfnetwork"
expect fail "network: missing binary"                   sh "$net" --binary "$tmp/none"

# --- check-signoff.sh -------------------------------------------------------------------------------------------
repo="$tmp/repo"
git init -q "$repo"
g() { git -C "$repo" -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
g commit -q --allow-empty -m "First" -m "Signed-off-by: Test <test@example.invalid>"
base=$(g rev-parse HEAD)
g commit -q --allow-empty -m "Signed" -m "Signed-off-by: Test <test@example.invalid>"
signed=$(g rev-parse HEAD)
g commit -q --allow-empty -m "Unsigned"
unsigned=$(g rev-parse HEAD)
g checkout -q -b side "$signed"
g commit -q --allow-empty -m "Side" -m "Signed-off-by: Test <test@example.invalid>"
g merge -q --no-ff --no-edit -m "Merge without sign-off" "$unsigned" >/dev/null
merge=$(g rev-parse HEAD)
g checkout -q -b bare "$signed"
g commit -q --allow-empty -m "Bare" -m "Signed-off-by:"
bare=$(g rev-parse HEAD)
so="$here/check-signoff.sh"
expect pass "signoff: signed range"                     sh -c 'cd "$1" && sh "$2" "$3..$4"' _ "$repo" "$so" "$base" "$signed"
expect fail "signoff: unsigned commit"                  sh -c 'cd "$1" && sh "$2" "$3..$4"' _ "$repo" "$so" "$signed" "$unsigned"
expect fail "signoff: unsigned merge commit"            sh -c 'cd "$1" && sh "$2" "$3..$4"' _ "$repo" "$so" "$unsigned" "$merge"
expect fail "signoff: empty Signed-off-by line"         sh -c 'cd "$1" && sh "$2" "$3..$4"' _ "$repo" "$so" "$signed" "$bare"
expect fail "signoff: a range git cannot read"          sh -c 'cd "$1" && sh "$2" "nosuchbase..$3"' _ "$repo" "$so" "$signed"
expect fail "signoff: an empty range"                   sh -c 'cd "$1" && sh "$2" "$3..$3"' _ "$repo" "$so" "$signed"

# --- check-no-secrets.sh ----------------------------------------------------------------------------------------
wf="$tmp/wf"
for c in clean dot index tojson inherit mapping; do mkdir -p "$wf/$c"; done
printf '# Holds no secrets.\non: push\njobs:\n  a:\n    runs-on: x\n    steps:\n      - run: echo "${{ github.sha }}"\n' > "$wf/clean/a.yml"
printf 'jobs:\n  a:\n    steps:\n      - run: echo "${{ secrets.TOKEN }}"\n' > "$wf/dot/a.yml"
printf "jobs:\n  a:\n    steps:\n      - run: echo \"\${{ secrets['TOKEN'] }}\"\n" > "$wf/index/a.yml"
printf 'jobs:\n  a:\n    env:\n      ALL: ${{ toJSON(secrets) }}\n' > "$wf/tojson/a.yaml"
printf 'jobs:\n  a:\n    uses: ./.github/workflows/b.yml\n    secrets: inherit\n' > "$wf/inherit/a.yml"
printf 'jobs:\n  a:\n    uses: ./.github/workflows/b.yml\n    secrets:\n      t: x\n' > "$wf/mapping/a.yml"
sec="$here/check-no-secrets.sh"
expect pass "secrets: clean workflow"                   sh "$sec" "$wf/clean"
expect fail "secrets: secrets.NAME"                     sh "$sec" "$wf/dot"
expect fail "secrets: secrets['NAME']"                  sh "$sec" "$wf/index"
expect fail "secrets: toJSON(secrets)"                  sh "$sec" "$wf/tojson"
expect fail "secrets: secrets: inherit"                 sh "$sec" "$wf/inherit"
expect fail "secrets: secrets: mapping"                 sh "$sec" "$wf/mapping"
expect fail "secrets: missing folder"                   sh "$sec" "$wf/none"

# --- check-spdx.sh ----------------------------------------------------------------------------------------------
printf '# SPDX-License-Identifier: Apache-2.0\nname: x\n' > "$tmp/good.yml"
printf 'name: x\n' > "$tmp/bad.yml"
printf '<!doctype html>\n<title>x</title>\n' > "$tmp/bad.html"
printf 'export const x = 1;\n' > "$tmp/bad.mjs"
sp="$here/check-spdx.sh"
expect pass "spdx: file with a licence line"            sh "$sp" "$tmp/good.yml"
expect fail "spdx: yml without one"                     sh "$sp" "$tmp/good.yml" "$tmp/bad.yml"
expect fail "spdx: html without one"                    sh "$sp" "$tmp/bad.html"
expect fail "spdx: mjs without one"                     sh "$sp" "$tmp/bad.mjs"
expect fail "spdx: unreadable file"                     sh "$sp" "$tmp/none.yml"
# The default run finds every kind of file: a repository holding one unlicensed file of each kind must fail.
for k in swift rs sh js mjs py toml yml yaml html css; do
  r="$tmp/spdx-$k"
  mkdir -p "$r/tools"
  cp "$sp" "$r/tools/check-spdx.sh"
  printf 'x\n' > "$r/file.$k"
  git -C "$r" init -q && git -C "$r" add -A
  expect fail "spdx: the default run finds an unlicensed .$k file" sh "$r/tools/check-spdx.sh"
done

# --- check-no-standin.sh ----------------------------------------------------------------------------------------
printf '#!/bin/sh\necho LabTileScores\n' > "$tmp/standin"; chmod +x "$tmp/standin"
expect pass "standin: clean binary"                     sh "$here/check-no-standin.sh" "$tmp/clean"
expect fail "standin: binary holding the stand-in"      sh "$here/check-no-standin.sh" "$tmp/standin"

# --- check-model-files.sh ---------------------------------------------------------------------------------------
mf="$tmp/models"
mkdir -p "$mf/a.mlpackage/Data"
printf 'm' > "$mf/a.mlpackage/Data/model.mlmodel"
printf 'j' > "$mf/a.mlpackage/Manifest.json"
(cd "$mf" && shasum -a 256 a.mlpackage/Data/model.mlmodel a.mlpackage/Manifest.json) > "$tmp/list.sha256"
expect pass "models: only listed files"                 sh "$here/check-model-files.sh" "$tmp/list.sha256" "$mf"
printf 'x' > "$mf/a.mlpackage/Data/extra.bin"
expect fail "models: an extra file"                     sh "$here/check-model-files.sh" "$tmp/list.sha256" "$mf"
rm "$mf/a.mlpackage/Data/extra.bin"
ln -s /etc/hosts "$mf/a.mlpackage/link"
expect fail "models: a link"                            sh "$here/check-model-files.sh" "$tmp/list.sha256" "$mf"

# --- site/check.mjs ---------------------------------------------------------------------------------------------
expect pass "site: its own self-test (refresh and others)" node "$root/site/check.mjs" --self-test

# --- the release workflow runs what the check workflow runs ----------------------------------------------------
scripts() { grep -oE 'tools/[a-z-]+\.sh|node site/check\.mjs|node --test keyholder' "$1" | sort -u; }
scripts "$root/.github/workflows/check.yml" > "$tmp/check-runs.txt"
scripts "$root/.github/workflows/build-release.yml" > "$tmp/release-runs.txt"
expect pass "workflows: build-release runs every check that check.yml runs" \
  sh -c '[ -s "$1" ] && [ -z "$(comm -23 "$1" "$2")" ] || { comm -23 "$1" "$2"; exit 1; }' _ "$tmp/check-runs.txt" "$tmp/release-runs.txt"
for wf in check.yml build-release.yml; do
  expect pass "workflows: $wf pins Xcode with DEVELOPER_DIR" grep -qE 'DEVELOPER_DIR: /Applications/Xcode_[0-9.]+\.app/Contents/Developer' "$root/.github/workflows/$wf"
  expect fail "workflows: $wf runs cargo without --locked" \
    sh -c 'grep -E "cargo (build|test|run|metadata)" "$1" | grep -v -- "--locked"' _ "$root/.github/workflows/$wf"
done

if [ "$wrong" -ne 0 ]; then
  echo "FAIL: $wrong of $n check cases did not behave as expected"; exit 1
fi
echo "Checks of the checks: all $n cases behaved as expected (each check fails on bad input and passes on good)"
