# SPDX-License-Identifier: Apache-2.0
"""The file side of the conformance kit (spec/detector-contract.md): a model bundle's manifest, cards, licences,
cut-offs and reference outputs, and the sealed files a build is made from. Standard library only; reads the bundle,
never changes it (except `fill`, which writes the manifest's file lists, and `seal`, which writes into a repository).

Usage: bundle.py check BUNDLE          every file the contract asks for, present, well formed and hashed
       bundle.py fill BUNDLE           writes each model's `files` in BUNDLE/bundle-manifest.json from its package
       bundle.py hashlist BUNDLE       prints the sealed hash list: every model file and the manifest, sorted by path
       bundle.py seal BUNDLE REPO      writes REPO/models/{bundle-manifest.json,watcher-models.sha256,thresholds.json}
                                       and REPO/Sources/SafeSightMacWatcher/CommittedModelData.swift from the bundle
       bundle.py packages BUNDLE       prints each model's package path, one a line
       bundle.py ids BUNDLE            prints each model's id, one a line

A bundle folder holds:
  bundle-manifest.json                  the manifest (kestrel-models/1)
  <package paths the manifest names>    the Core ML packages
  thresholds.json                       the cut-off table (kestrel-thresholds/1)
  cards/<id>.json                       one model card per model
  <licence files the cards name>
  conformance/<id>/reference.json       reference outputs (kestrel-parity/1) and the pictures they name
  conformance/<id>/broken/*.mlpackage   optional deliberately broken controls; each must fail parity
"""
import hashlib
import json
import os
import re
import sys

SCHEMA = "kestrel-models/1"
MANIFEST = "bundle-manifest.json"
SLOTS = {"A", "B", "tie-breaker"}
UNITS = {"cpuAndNeuralEngine", "cpuAndGPU", "cpuOnly", "all"}
BANDS = ["16-31", "32-63", "64-127", "128+"]
CUTS = ["cover", "clean", "strike", "gridMember", "gridLow"]
MODEL_KEYS = {"id", "slot", "runtime", "package", "inputSide", "classCount", "flagClasses", "computeUnits", "files"}
CARD_KEYS = ["id", "family", "inputSide", "classes", "flagClasses", "notMeantToFlag", "licence", "licenceFile", "source",
             "trainingDataAsStated", "files"]
MIN_REFERENCES = 100
problems = []


def bad(msg):
    problems.append(msg)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def relative(p):
    parts = p.split("/")
    return bool(p) and not p.startswith("/") and ".." not in parts and "." not in parts and "" not in parts


def whole(v):
    return isinstance(v, int) and not isinstance(v, bool)


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        bad(f"{what}: cannot read {path} ({e.__class__.__name__})")
        return None


def manifest_of(bundle):
    """The manifest, checked as strictly as the Swift loader checks it (DetectorCore/ModelManifest.swift)."""
    m = load_json(os.path.join(bundle, MANIFEST), "manifest")
    if not isinstance(m, dict):
        if m is not None:
            bad("manifest: not an object")
        return None
    if set(m) != {"schema", "families", "models"}:
        bad(f"manifest: keys must be schema, families, models (has {sorted(m)})")
    if m.get("schema") != SCHEMA:
        bad(f"manifest: schema must be {SCHEMA}")
    fam = m.get("families")
    if fam not in (1, 2) or not whole(fam):
        bad("manifest: families must be 1 or 2")
    models = m.get("models")
    if not isinstance(models, list) or not models:
        bad("manifest: models must be a non-empty list")
        return None
    for i, e in enumerate(models):
        w = f"manifest: models[{i}]"
        if not isinstance(e, dict):
            bad(f"{w} is not an object")
            return None
        if set(e) != MODEL_KEYS:
            bad(f"{w}: keys must be {sorted(MODEL_KEYS)} (has {sorted(e)})")
        if not isinstance(e.get("id"), str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", e.get("id", "")):
            bad(f"{w}.id must be a plain name")
        if e.get("slot") not in SLOTS:
            bad(f"{w}.slot must be A, B or tie-breaker")
        if e.get("runtime") != "coreml":
            bad(f"{w}.runtime must be coreml")
        pkg = e.get("package")
        if not isinstance(pkg, str) or not relative(pkg) or not pkg.endswith(".mlpackage"):
            bad(f"{w}.package must be a relative path ending in .mlpackage")
        side, k, flags = e.get("inputSide"), e.get("classCount"), e.get("flagClasses")
        if not whole(side) or not 224 <= side <= 512:
            bad(f"{w}.inputSide must be a whole number from 224 to 512")
        if not whole(k) or not 2 <= k <= 1000:
            bad(f"{w}.classCount must be a whole number from 2 to 1000")
        elif not isinstance(flags, list) or not flags or not all(whole(c) and 0 <= c < k for c in flags) \
                or len(set(flags)) != len(flags) or len(flags) >= k:
            bad(f"{w}.flagClasses must be distinct indices below classCount, and not all of them")
        if e.get("computeUnits") not in UNITS:
            bad(f"{w}.computeUnits must be one of {sorted(UNITS)}")
        files = e.get("files")
        if not isinstance(files, list):
            bad(f"{w}.files must be a list")
            e["files"] = []
    ids = [e.get("id") for e in models]
    if len(set(ids)) != len(ids):
        bad("manifest: model ids must be unique")
    slots = [e.get("slot") for e in models]
    if slots.count("tie-breaker") > 1:
        bad("manifest: at most one tie-breaker")
    if fam == 2 and not ("A" in slots and "B" in slots):
        bad("manifest: two families need a model in slot A and one in slot B")
    if fam == 1 and ("tie-breaker" in slots or len(set(slots)) != 1):
        bad("manifest: a single-family bundle has all its models in one slot and no tie-breaker")
    return m


def package_files(bundle, pkg):
    """Every file inside a package, as a path relative to the bundle; a link or anything but a plain file is a fault."""
    root = os.path.join(bundle, pkg)
    if os.path.islink(root) or not os.path.isdir(root):
        bad(f"package {pkg}: missing, or not a plain folder")
        return []
    out = []
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            p = os.path.join(d, n)
            rel = os.path.relpath(p, bundle)
            if os.path.islink(p):
                bad(f"package {pkg}: {rel} is a link")
            elif n in files and not os.path.isfile(p):
                bad(f"package {pkg}: {rel} is not a plain file")
            elif n in files and n != ".DS_Store":
                out.append(rel)
    return sorted(out)


def check_files(bundle, m):
    for e in m["models"]:
        pkg, listed = e.get("package", ""), {}
        for f in e["files"]:
            if not isinstance(f, dict) or set(f) != {"path", "sha256"} or not isinstance(f.get("path"), str) \
                    or not isinstance(f.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", f["sha256"]):
                bad(f"manifest: {e.get('id')}: each file is {{path, sha256}} with 64 lower-case hex digits")
                continue
            if not relative(f["path"]) or not f["path"].startswith(pkg + "/"):
                bad(f"manifest: {e.get('id')}: {f['path']} is not inside {pkg}")
            if f["path"] in listed:
                bad(f"manifest: {f['path']} is listed twice")
            listed[f["path"]] = f["sha256"]
        if not listed:
            bad(f"manifest: {e.get('id')} lists no files (bundle.py fill writes them)")
        have = package_files(bundle, pkg)
        for p in sorted(set(have) - set(listed)):
            bad(f"files: {p} is in the package but the manifest doesn't list it")
        for p, h in sorted(listed.items()):
            full = os.path.join(bundle, p)
            if not os.path.isfile(full):
                bad(f"files: {p} is listed but missing")
            elif sha256(full) != h:
                bad(f"files: {p} doesn't match its hash")


def check_cards(bundle, m):
    for e in m["models"]:
        mid = e.get("id")
        c = load_json(os.path.join(bundle, "cards", f"{mid}.json"), f"card {mid}")
        if not isinstance(c, dict):
            continue
        for k in CARD_KEYS:
            if k not in c or c[k] in ("", None, [], {}):
                bad(f"card {mid}: {k} is missing or empty")
        if c.get("id") != mid:
            bad(f"card {mid}: its id is {c.get('id')!r}")
        if c.get("inputSide") != e.get("inputSide"):
            bad(f"card {mid}: inputSide {c.get('inputSide')} differs from the manifest's {e.get('inputSide')}")
        classes, flags = c.get("classes"), c.get("flagClasses")
        if isinstance(classes, list) and whole(e.get("classCount")) and len(classes) != e["classCount"]:
            bad(f"card {mid}: {len(classes)} classes, the manifest says {e['classCount']}")
        elif isinstance(classes, list) and isinstance(flags, list) and isinstance(e.get("flagClasses"), list):
            named = sorted(classes.index(f) for f in flags if f in classes)
            if named != sorted(x for x in e["flagClasses"] if whole(x)):
                bad(f"card {mid}: its flag classes {flags} are not the manifest's indices {e['flagClasses']}")
            nmf = c.get("notMeantToFlag")
            if isinstance(nmf, list) and any(f in nmf for f in flags):
                bad(f"card {mid}: a class is both a flag class and not meant to flag")
        if not isinstance(c.get("source"), dict) or not c["source"].get("revision"):
            bad(f"card {mid}: source.revision (the exact upstream revision) is missing")
        lf = c.get("licenceFile")
        if isinstance(lf, str) and (not relative(lf) or not os.path.isfile(os.path.join(bundle, lf))):
            bad(f"card {mid}: its licence file {lf} is not in the bundle")
        for f in c.get("files") or []:
            if not isinstance(f, dict) or not re.fullmatch(r"[0-9a-f]{64}", str(f.get("sha256", ""))):
                bad(f"card {mid}: each file needs a sha256")
                break


def check_thresholds(bundle, m):
    t = load_json(os.path.join(bundle, "thresholds.json"), "cut-offs")
    if not isinstance(t, dict):
        return
    if t.get("schema") != "kestrel-thresholds/1":
        bad("cut-offs: schema must be kestrel-thresholds/1")
    models = t.get("models") if isinstance(t.get("models"), dict) else {}
    for e in m["models"]:
        mid = e.get("id")
        for b in BANDS:
            c = models.get(mid, {}).get(b) if isinstance(models.get(mid), dict) else None
            if not isinstance(c, dict) or set(c) != set(CUTS):
                bad(f"cut-offs: {mid} {b} needs exactly {', '.join(CUTS)}")
                continue
            if not all(isinstance(c[k], (int, float)) and not isinstance(c[k], bool) and 0 < c[k] <= 1 for k in CUTS):
                bad(f"cut-offs: {mid} {b}: every value is a number above 0 and at most 1")
            elif c["clean"] > c["cover"]:
                bad(f"cut-offs: {mid} {b}: clean is above cover")


def check_references(bundle, m):
    for e in m["models"]:
        mid = e.get("id")
        d = os.path.join(bundle, "conformance", str(mid))
        r = load_json(os.path.join(d, "reference.json"), f"reference {mid}")
        if not isinstance(r, dict):
            continue
        if r.get("schema") != "kestrel-parity/1" or r.get("preprocess") != "kestrel-preprocess/1":
            bad(f"reference {mid}: schema kestrel-parity/1 and preprocess kestrel-preprocess/1 are required")
        if not isinstance(r.get("reference"), str) or not r["reference"]:
            bad(f"reference {mid}: say which framework made the reference outputs")
        tol = r.get("tolerance")
        if not isinstance(tol, dict) or e.get("computeUnits") not in tol or \
                not all(k in UNITS and isinstance(v, (int, float)) and 0 < v < 0.5 for k, v in tol.items()):
            bad(f"reference {mid}: tolerance must give a number for the declared compute units ({e.get('computeUnits')})")
        inputs = r.get("inputs")
        if not isinstance(inputs, list) or len(inputs) < MIN_REFERENCES:
            bad(f"reference {mid}: at least {MIN_REFERENCES} inputs")
            continue
        for x in inputs:
            if not isinstance(x, dict) or not isinstance(x.get("file"), str) or not relative(x["file"]) or \
                    not isinstance(x.get("flagScore"), (int, float)) or not 0 <= x["flagScore"] <= 1:
                bad(f"reference {mid}: each input is {{file, sha256, flagScore 0..1}}")
                break
            p = os.path.join(d, x["file"])
            if not os.path.isfile(p) or sha256(p) != x.get("sha256"):
                bad(f"reference {mid}: {x['file']} is missing or doesn't match its hash")
                break


def check(bundle):
    m = manifest_of(bundle)
    if m is not None:
        check_files(bundle, m)
        check_cards(bundle, m)
        check_thresholds(bundle, m)
        check_references(bundle, m)
    if problems:
        for p in problems:
            print("FAIL: " + p)
        return 1
    print(f"Bundle files: {len(m['models'])} models, every file hashed and nothing unlisted; cards, licences, "
          f"cut-offs and reference outputs present")
    return 0


def hashlist(bundle, m):
    lines = [(f["path"], f["sha256"]) for e in m["models"] for f in e["files"]]
    lines.append((MANIFEST, sha256(os.path.join(bundle, MANIFEST))))
    return "".join(f"{h}  {p}\n" for p, h in sorted(lines))


def dump(m):
    return json.dumps(m, indent=2) + "\n"


def committed_swift(hash_list, thresholds):
    for name, text in (("hash list", hash_list), ("cut-off table", thresholds)):
        if '"""' in text or "\\" in text:
            raise SystemExit(f"the {name} cannot be sealed as a Swift literal")
    return ("// SPDX-License-Identifier: Apache-2.0\n"
            "// GENERATED from models/watcher-models.sha256 and models/thresholds.json; a test checks they match.\n"
            "// The hash list and the cut-off table are sealed inside the signed app, so the watcher checks every\n"
            "// model file against them before loading (register SD-223 (b)). The hash list names the bundle's manifest\n"
            "// (models/bundle-manifest.json) too, so an edited manifest is refused like an edited model.\n\n"
            "enum CommittedModelData {\n"
            f'    static let hashList = """\n{hash_list.rstrip(chr(10))}\n"""\n\n'
            f'    static let thresholdsJSON = #"""\n{thresholds.rstrip(chr(10))}\n"""#\n'
            "}\n")


def main(argv):
    if len(argv) < 2 or argv[0] not in ("check", "fill", "hashlist", "seal", "packages", "ids"):
        print(__doc__)
        return 2
    cmd, bundle = argv[0], argv[1]
    if not os.path.isdir(bundle):
        print(f"FAIL: no bundle folder {bundle}")
        return 2
    if cmd == "check":
        return check(bundle)
    m = manifest_of(bundle)
    if m is None or (problems and cmd != "fill"):
        for p in problems:
            print("FAIL: " + p)
        return 1
    if cmd == "packages":
        print("\n".join(e["package"] for e in m["models"]))
    elif cmd == "ids":
        print("\n".join(e["id"] for e in m["models"]))
    elif cmd == "fill":
        for e in m["models"]:
            e["files"] = [{"path": p, "sha256": sha256(os.path.join(bundle, p))} for p in package_files(bundle, e["package"])]
        if problems:
            for p in problems:
                print("FAIL: " + p)
            return 1
        with open(os.path.join(bundle, MANIFEST), "w", encoding="utf-8") as f:
            f.write(dump(m))
        print(f"wrote the file lists of {len(m['models'])} models into {os.path.join(bundle, MANIFEST)}")
    elif cmd == "hashlist":
        sys.stdout.write(hashlist(bundle, m))
    elif cmd == "seal":
        if len(argv) != 3 or not os.path.isfile(os.path.join(argv[2], "Package.swift")):
            print("seal needs BUNDLE and a repository folder holding Package.swift")
            return 2
        repo = argv[2]
        check_files(bundle, m)
        if problems:
            for p in problems:
                print("FAIL: " + p)
            return 1
        with open(os.path.join(bundle, MANIFEST), encoding="utf-8") as f:
            manifest_text = f.read()
        with open(os.path.join(bundle, "thresholds.json"), encoding="utf-8") as f:
            thresholds = f.read()
        lst = hashlist(bundle, m)
        out = {"models/bundle-manifest.json": manifest_text, "models/watcher-models.sha256": lst,
               "models/thresholds.json": thresholds,
               "Sources/SafeSightMacWatcher/CommittedModelData.swift": committed_swift(lst, thresholds)}
        for rel, text in out.items():
            with open(os.path.join(repo, rel), "w", encoding="utf-8") as f:
                f.write(text)
        print(f"sealed {len(lst.splitlines())} files into {repo}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
