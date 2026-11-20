#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# The conformance kit: checks a model bundle against spec/detector-contract.md and writes a short report.
#
#   1. files    the manifest, every model file hashed and nothing unlisted, cards, licences, cut-offs and reference
#               outputs (tools/conformance/bundle.py check)
#   2. seal     the bundle sealed into a scratch copy of this repository, as adopting it for real would do; the models
#               folder holds only the sealed files (tools/check-model-files.sh) and matches the sealed list
#   3. load     a release build loads the folder exactly as the app does: sealed list, manifest, shapes, cut-off table
#   4. parity   a lab build checks every model against its reference outputs; every broken control must fail
#   5. tests    the rule and contract tests, and the fault drills with the bundle plugged in
#   6. false covers on a harmless-screen set under Balanced and Either, as JSON (with --screens)
#
# It never changes the bundle or this repository: everything is built in a temporary folder it removes, and only the
# report folder is kept. It downloads nothing and installs nothing. Speed (the harness's bench) and the catch rate
# (measured privately on a licensed set, never in this repository) are not part of this run.
#
# Usage: tools/conformance/run.sh BUNDLE [--screens LIST --root DIR [--limit N]] [--out DIR]
#        tools/conformance/run.sh --stage files BUNDLE       the file checks only (fast, no build)
# Exit: 0 every stage passed; 1 a stage failed; 2 bad usage; 3 every stage run passed but some were skipped.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
only=""
[ "${1:-}" = "--stage" ] && { only="${2:?--stage files}"; shift 2; [ "$only" = files ] || { echo "only --stage files is supported"; exit 2; }; }
bundle="${1:-}"
[ -n "$bundle" ] || { sed -n '3,21p' "$0"; exit 2; }
shift
[ -d "$bundle" ] || { echo "FAIL: no bundle folder $bundle"; exit 2; }
bundle=$(cd "$bundle" && pwd)
screens="" screens_root="" limit="" out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --screens) screens="${2:?}"; shift 2 ;;
    --root) screens_root="${2:?}"; shift 2 ;;
    --limit) limit="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done

echo "== 1. files"
python3 -I "$here/bundle.py" check "$bundle" || { echo "conformance: FAILED at the file checks"; exit 1; }
[ "$only" = files ] && exit 0

[ -z "$screens" ] || [ -r "$screens" ] || { echo "FAIL: cannot read the screen list $screens"; exit 2; }
out="${out:-$(mktemp -d "${TMPDIR:-/tmp}/safesightmac-conformance-report.XXXXXX")}"
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/safesightmac-conformance.XXXXXX")
trap 'rm -rf "$work"' EXIT
unset SAFESIGHTMAC_LAB KESTREL_LAB SAFESIGHTMAC_TESTING
status() { printf '%s %s\n' "$1" "$2" >> "$out/stages.txt"; }
: > "$out/stages.txt"
status files pass
failed=0

echo "== 2. seal"
repo="$work/repo" models="$work/models"
mkdir -p "$repo" "$models"
rsync -a --exclude '/.build*' --exclude '/.git' --exclude '/keeper/target' "$root/" "$repo/"
python3 -I "$here/bundle.py" seal "$bundle" "$repo"
cp "$bundle/bundle-manifest.json" "$models/"
python3 -I "$here/bundle.py" packages "$bundle" | while IFS= read -r p; do
  mkdir -p "$models/$(dirname "$p")"
  cp -c -R "$bundle/$p" "$models/$p" 2>/dev/null || cp -R "$bundle/$p" "$models/$p"   # a clone where the disk allows it
done
if sh "$root/tools/check-model-files.sh" "$repo/models/watcher-models.sha256" "$models" \
   && (cd "$models" && shasum -a 256 -c "$repo/models/watcher-models.sha256" >/dev/null); then
  status seal pass
else
  status seal fail; echo "conformance: FAILED at the seal"; exit 1
fi

echo "== 3. load (release build)"
(cd "$repo" && swift build -c release --product safesightmac-harness >"$out/build-release.txt" 2>&1) \
  || { tail -20 "$out/build-release.txt"; echo "conformance: FAILED to build"; exit 1; }
harness="$repo/.build/release/safesightmac-harness"
if "$harness" bundlecheck --models "$models" | tee "$out/load.txt"; then status load pass; else status load fail; failed=1; fi

echo "== 4. parity (lab build)"
(cd "$repo" && SAFESIGHTMAC_LAB=1 swift build -c release --scratch-path .build-lab --product safesightmac-harness >"$out/build-lab.txt" 2>&1) \
  || { tail -20 "$out/build-lab.txt"; echo "conformance: FAILED to build the lab harness"; exit 1; }
if "$repo/.build-lab/release/safesightmac-harness" parity --bundle "$bundle" --json "$out/parity.json" > "$out/parity.txt" 2>&1; then
  status parity pass
else
  status parity fail; failed=1
fi
grep -E '^(FAIL|parity:)' "$out/parity.txt" || true

echo "== 5. rule and contract tests, fault drills"
if (cd "$repo" && SAFESIGHTMAC_BUNDLE="$models" swift test --filter 'DetectorCoreTests|PluggedInBundleTests' >"$out/tests.txt" 2>&1); then
  status tests pass
else
  status tests fail; failed=1
fi
grep -E '^Test Suite .All tests. (passed|failed)|Executed [0-9]+ tests, with|^.{0,4}Test run with' "$out/tests.txt" | tail -3 || true

echo "== 6. false covers"
if [ -n "$screens" ]; then
  list="$screens"
  if [ -n "$limit" ]; then list="$work/screens.txt"; grep -v '^[[:space:]]*$' "$screens" | head -n "$limit" > "$list"; fi
  fc=0
  for rule in balanced either; do
    if "$harness" falsecovers --models "$models" --list "$list" --root "${screens_root:-.}" --rule "$rule" \
         --json "$out/falsecovers-$rule.json" > "$out/falsecovers-$rule.txt" 2>&1; then
      tail -1 "$out/falsecovers-$rule.txt"
    else
      status "falsecovers-$rule" fail; failed=1; fc=1
    fi
  done
  [ "$fc" = 1 ] || status falsecovers measured
else
  echo "skipped: no --screens list"; status falsecovers skipped
fi

python3 -I - "$out" "$bundle" <<'EOF'
import json, os, sys
out, bundle = sys.argv[1], sys.argv[2]
stages = dict(l.split() for l in open(os.path.join(out, "stages.txt")) if l.strip())
report = {"run": "safesightmac-conformance/1", "bundle": os.path.basename(bundle), "stages": stages}
try:
    p = json.load(open(os.path.join(out, "parity.json")))
    report["parity"] = [{"model": m["model"], "declaredUnits": m["declaredUnits"],
                         "units": {u["units"]: {k: u.get(k) for k in ("maxDiff", "tolerance", "pass", "required")} for u in m["parity"]},
                         "controlsFailedAsTheyShould": all(c["failed"] for c in m["controls"]), "controls": len(m["controls"])}
                        for m in p["models"]]
except (OSError, ValueError, KeyError):
    pass
for rule in ("balanced", "either"):
    try:
        f = json.load(open(os.path.join(out, f"falsecovers-{rule}.json")))
        t = f.get("total", f)
        report[f"falseCovers{rule.title()}"] = {k: t[k] for k in ("screens", "screensWithFalseCover", "falseCoverEntries", "judgedEntries") if k in t}
    except (OSError, ValueError):
        pass
report["notRunHere"] = ["speed (safesightmac-harness bench, lab build)", "catch rate (private, on a licensed set)"]
json.dump(report, open(os.path.join(out, "report.json"), "w"), indent=1, sort_keys=True)
print(json.dumps(report, indent=1, sort_keys=True))
EOF
echo "report: $out/report.json"
if [ "$failed" = 1 ]; then echo "conformance: FAILED"; exit 1; fi
if grep -q skipped "$out/stages.txt"; then echo "conformance: passed every stage it ran; some were skipped"; exit 3; fi
echo "conformance: passed"
