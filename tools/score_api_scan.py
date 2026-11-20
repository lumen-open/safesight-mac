# SPDX-License-Identifier: Apache-2.0
"""Scans the detector's public API, as the compiler sees it, for floating-point types (half of
tools/check-no-score-api.sh). Every score and cut-off is a floating-point number, so a public declaration that names
one could carry a score out of DetectorCore. Only the uses listed in tools/no-score-api-allow.txt may: times in
milliseconds and seconds, and the one place scores come in (`ScoringModel.flagScores`).

It reads the symbol graphs Swift emits for the module (`DetectorCore.symbols.json` and `DetectorCore@*.symbols.json`,
the module's extensions of other modules' types), so multi-line declarations, `public extension` members, `open`
members, nested types and files in any folder are all seen exactly as the compiler sees them. A type alias of a
floating-point type counts as one, followed to any depth. Lab-only code is not in the default build, so it is not in
the graph.

Usage: score_api_scan.py GRAPH_DIR ALLOW_FILE [MODULE]
       score_api_scan.py --self-test
"""
import json
import os
import sys
import tempfile

FLOAT_NAMES = {"Float", "Double", "CGFloat", "Float16", "Float32", "Float64", "Float80", "TimeInterval", "CFTimeInterval",
               "NSTimeInterval", "Decimal"}
FLOAT_IDS = {"s:Sf", "s:Sd", "s:s7Float16V", "s:s7Float80V", "s:s7Float32a", "s:s7Float64a", "s:So14NSTimeIntervala",
             "s:14CoreFoundation7CGFloatV", "s:12CoreGraphics7CGFloatV", "s:So15CFTimeIntervala"}


def graphs(folder, module):
    names = sorted(n for n in os.listdir(folder) if n == f"{module}.symbols.json" or
                   (n.startswith(module + "@") and n.endswith(".symbols.json")))
    if f"{module}.symbols.json" not in names:
        raise SystemExit(f"FAIL: no {module}.symbols.json in {folder}")
    return [json.load(open(os.path.join(folder, n))) for n in names]


def scan(folder, module):
    """Every public or open symbol of `module` whose declaration names a floating-point type: 'Path: Type' lines."""
    symbols = [s for g in graphs(folder, module) for s in g.get("symbols", [])]
    names, ids = set(FLOAT_NAMES), set(FLOAT_IDS)
    # Type aliases of floating-point types, to any depth.
    changed = True
    while changed:
        changed = False
        for s in symbols:
            if s["kind"]["identifier"] != "swift.typealias":
                continue
            frags = s.get("declarationFragments", [])
            if any(f["kind"] == "typeIdentifier" and (f["spelling"] in names or f.get("preciseIdentifier") in ids)
                   for f in frags):
                pid = s["identifier"]["precise"]
                if pid not in ids:
                    ids.add(pid); names.add(s["names"]["title"]); changed = True
    out = set()
    for s in symbols:
        if s.get("accessLevel") not in ("public", "open"):
            continue
        hit = sorted({f["spelling"] for f in s.get("declarationFragments", [])
                      if f["kind"] == "typeIdentifier" and (f["spelling"] in names or f.get("preciseIdentifier") in ids)})
        if hit:
            out.add(f"{'.'.join(s['pathComponents'])}: {', '.join(hit)}")
    return out


def check(folder, allow_file, module="DetectorCore"):
    found = scan(folder, module)
    allow = {l.strip() for l in open(allow_file) if l.strip() and not l.lstrip().startswith("#")}
    bad = 0
    for f in sorted(found - allow):
        print(f"FAIL: a public declaration in {module} names a floating-point type, and {os.path.basename(allow_file)} "
              f"doesn't list it: {f}")
        bad = 1
    for a in sorted(allow - found):
        print(f"FAIL: {os.path.basename(allow_file)} lists a declaration that is no longer there: {a}")
        bad = 1
    if not bad:
        print(f"Score API check: {module}'s public API names a floating-point type only in the {len(found)} reviewed places")
    return bad


def self_test():
    def graph(symbols):
        return {"symbols": symbols}

    def sym(path, spelling, pid=None, access="public", kind="swift.property", title=None):
        f = {"kind": "typeIdentifier", "spelling": spelling}
        if pid:
            f["preciseIdentifier"] = pid
        return {"kind": {"identifier": kind}, "identifier": {"precise": "id:" + ".".join(path)}, "pathComponents": path,
                "accessLevel": access, "names": {"title": title or path[-1]},
                "declarationFragments": [{"kind": "keyword", "spelling": "var"}, f]}

    cases = [
        ("a public Float", [sym(["T", "score"], "Float", "s:Sf")], {"T.score: Float"}),
        ("an open Double", [sym(["T", "x"], "Double", access="open")], {"T.x: Double"}),
        ("a CGFloat", [sym(["T", "x"], "CGFloat")], {"T.x: CGFloat"}),
        ("a Float16", [sym(["T", "x"], "Float16")], {"T.x: Float16"}),
        ("a Float32", [sym(["T", "x"], "Float32")], {"T.x: Float32"}),
        ("a Float by its id alone", [sym(["T", "x"], "Renamed", "s:Sf")], {"T.x: Renamed"}),
        ("a type alias of Float, two deep",
         [sym(["Score"], "Float", "s:Sf", kind="swift.typealias"), sym(["Level"], "Score", "id:Score", kind="swift.typealias"),
          sym(["T", "x"], "Level", "id:Level")], {"Score: Float", "Level: Score", "T.x: Level"}),
        ("an internal Float is not public API", [sym(["T", "x"], "Float", access="internal")], set()),
        ("an Int is fine", [sym(["T", "x"], "Int")], set()),
    ]
    wrong = 0
    with tempfile.TemporaryDirectory() as d:
        for name, symbols, want in cases:
            for f in os.listdir(d):
                os.remove(os.path.join(d, f))
            json.dump(graph(symbols[:1]), open(os.path.join(d, "M.symbols.json"), "w"))
            # The rest as an extension graph, as for `public extension` members of other modules' types.
            json.dump(graph(symbols[1:]), open(os.path.join(d, "M@Swift.symbols.json"), "w"))
            got = scan(d, "M")
            if got != want:
                print(f"WRONG: {name}: wanted {sorted(want)}, got {sorted(got)}"); wrong += 1
    print("score_api_scan self-test: " + ("all cases behaved as expected" if not wrong else f"{wrong} wrong"))
    return 1 if wrong else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if len(sys.argv) not in (3, 4):
        print(__doc__); sys.exit(2)
    sys.exit(check(sys.argv[1], sys.argv[2], *sys.argv[3:]))
