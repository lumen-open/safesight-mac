#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Vendored from the kestrel lab detector (v3-detector, commit 49ecdd9). Paths adjusted to this repository.
"""Fetch the detector's upstream models from their official sources, pinned by revision and hash.

Rules this script enforces:
  * Only the files named in tools/pins.json are downloaded, from revision-pinned URLs.
  * Every file must match its independent host checksum (Hugging Face LFS sha256, git blob
    sha1, or the Cloud Storage md5) and, once recorded, our own sha256. Any mismatch stops.
  * Nothing is ever unpickled or executed. Weights end up as .safetensors through data-only
    readers: the Hugging Face file is already safetensors; the NSFWJS TF.js shard is parsed
    from its JSON manifest and dequantised; the Bumble TensorFlow checkpoint is read with the
    checkpoint reader (a key/value bundle reader that runs no graph).
  * The card in models/cards/<id>.json gets the sha256 of every file kept.

Usage:  python3 -I tools/models/fetch_upstream.py [--only ID] [--record]
  --record writes our sha256 into pins.json for files whose host checksum already matched.
"""
import argparse
import base64
import hashlib
import json
import os
import struct
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
PINS = ROOT / "tools" / "models" / "pins.json"
CARDS = ROOT / "models" / "cards"
UPSTREAM = ROOT / "models" / "upstream"
UA = {"User-Agent": "model-fetch/1"}


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_blob_sha1(p):
    data = Path(p).read_bytes()
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def md5_b64(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return base64.b64encode(h.digest()).decode()


def download(url, dest, expected_bytes):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size == expected_bytes:
        return
    tmp = dest.with_suffix(dest.suffix + ".part")
    print(f"  downloading {url} ({expected_bytes / 1e6:.1f} MB)")
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA)) as r, open(tmp, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    tmp.rename(dest)


def check(p, pin, label):
    size = p.stat().st_size
    if size != pin["bytes"]:
        sys.exit(f"STOP: {label}: {size} bytes, pinned {pin['bytes']}")
    if pin.get("gitBlobSha1") and git_blob_sha1(p) != pin["gitBlobSha1"]:
        sys.exit(f"STOP: {label}: git blob sha1 mismatch")
    if pin.get("md5Base64") and md5_b64(p) != pin["md5Base64"]:
        sys.exit(f"STOP: {label}: md5 mismatch")
    actual = sha256_file(p)
    if pin.get("sha256") and actual != pin["sha256"]:
        sys.exit(f"STOP: {label}: sha256 mismatch ({actual})")
    independent = bool(pin.get("gitBlobSha1") or pin.get("md5Base64") or pin.get("sha256"))
    if not independent:
        sys.exit(f"STOP: {label}: no independent checksum pinned")
    return actual


def write_safetensors(tensors, path, metadata):
    """Minimal safetensors writer (format: 8-byte header length, JSON header, raw little-endian data)."""
    import numpy as np
    header, offset, blobs = {"__metadata__": metadata}, 0, []
    for name in sorted(tensors):
        a = np.ascontiguousarray(tensors[name])
        dtype = {np.dtype("float32"): "F32", np.dtype("float16"): "F16", np.dtype("int64"): "I64",
                 np.dtype("int32"): "I32"}[a.dtype]
        b = a.astype(a.dtype.newbyteorder("<"), copy=False).tobytes()
        header[name] = {"dtype": dtype, "shape": list(a.shape), "data_offsets": [offset, offset + len(b)]}
        offset += len(b)
        blobs.append(b)
    h = json.dumps(header, separators=(",", ":")).encode()
    h += b" " * ((8 - len(h) % 8) % 8)
    with open(path, "wb") as f:
        f.write(struct.pack("<Q", len(h)))
        f.write(h)
        for b in blobs:
            f.write(b)


def nsfwjs_to_safetensors(raw, out):
    """Parse the TF.js weights manifest and dequantise exactly as TF.js does: min + scale * q."""
    import numpy as np
    model = json.loads((raw / "models/mobilenet_v2/model.json").read_text())
    manifest = model["weightsManifest"]
    if len(manifest) != 1 or manifest[0]["paths"] != ["group1-shard1of1"]:
        sys.exit("STOP: NSFWJS manifest layout is not the pinned one")
    buf = (raw / "models/mobilenet_v2/group1-shard1of1").read_bytes()
    pos, tensors = 0, {}
    for w in manifest[0]["weights"]:
        n = int(np.prod(w["shape"])) if w["shape"] else 1
        q = w.get("quantization")
        if q:
            if q["dtype"] != "uint8":
                sys.exit(f"STOP: unexpected quantisation {q['dtype']}")
            vals = np.frombuffer(buf, dtype=np.uint8, count=n, offset=pos).astype(np.float32)
            vals = np.float32(q["min"]) + np.float32(q["scale"]) * vals
            pos += n
        else:
            if w["dtype"] != "float32":
                sys.exit(f"STOP: unexpected dtype {w['dtype']}")
            vals = np.frombuffer(buf, dtype="<f4", count=n, offset=pos).copy()
            pos += 4 * n
        tensors[w["name"]] = vals.reshape(w["shape"]).astype(np.float32)
    if pos != len(buf):
        sys.exit(f"STOP: shard has {len(buf) - pos} unread bytes")
    write_safetensors(tensors, out / "nsfwjs-mobilenet-v2.safetensors", {"source": "infinitered/nsfwjs models/mobilenet_v2", "dequantised": "min+scale*q"})
    (out / "topology.json").write_text(json.dumps(model["modelTopology"], indent=1))


def bumble_extract_and_convert(zpath, raw, out, members):
    with zipfile.ZipFile(zpath) as z:
        names = set(z.namelist())
        for m in members:
            if m not in names:
                sys.exit(f"STOP: {m} missing from archive")
            dest = raw / m
            dest.parent.mkdir(parents=True, exist_ok=True)
            with z.open(m) as src, open(dest, "wb") as f:
                while True:
                    chunk = src.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
        stray = [n for n in names if n.lower().endswith((".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"))]
        if stray:
            sys.exit(f"STOP: archive contains images {stray[:3]}; none were extracted")
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
    import numpy as np
    import tensorflow as tf
    reader = tf.train.load_checkpoint(str(raw / "private_detector/saved_model/variables/variables"))
    shapes = reader.get_variable_to_shape_map()
    dtypes = reader.get_variable_to_dtype_map()
    tensors = {}
    for name in shapes:
        if dtypes[name] in (tf.float32, tf.float16):
            tensors[name] = np.asarray(reader.get_tensor(name)).astype(np.float32)
    write_safetensors(tensors, out / "bumble-private-detector.safetensors", {"source": "bumble-tech/private-detector saved_model variables", "reader": "tf.train.load_checkpoint (data only)"})


def card_update(model_id, entries):
    p = CARDS / f"{model_id}.json"
    card = json.loads(p.read_text())
    card["files"] = entries
    p.write_text(json.dumps(card, indent=2) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    ap.add_argument("--record", action="store_true")
    args = ap.parse_args()
    pins = json.loads(PINS.read_text())
    for mid, pin in pins["models"].items():
        if args.only and mid != args.only:
            continue
        print(f"[{mid}] {pin['repo']} @ {pin['revision']}")
        base = UPSTREAM / mid
        raw, out = base / "raw", base
        entries = []
        if pin["host"] in ("huggingface", "github"):
            for fname, fpin in pin["files"].items():
                url = (f"https://huggingface.co/{pin['repo']}/resolve/{pin['revision']}/{fname}" if pin["host"] == "huggingface"
                       else f"https://raw.githubusercontent.com/{pin['repo']}/{pin['revision']}/{fname}")
                dest = raw / fname
                download(url, dest, fpin["bytes"])
                actual = check(dest, fpin, f"{mid}/{fname}")
                if args.record and not fpin.get("sha256"):
                    fpin["sha256"] = actual
                entries.append({"path": str(dest.relative_to(ROOT)), "sha256": actual, "kind": "upstream"})
        elif pin["host"] == "gcs-zip":
            zpath = base / "archive" / "private_detector.zip"
            download(pin["url"], zpath, pin["archive"]["bytes"])
            actual = check(zpath, pin["archive"], f"{mid}/archive")
            if args.record and not pin["archive"].get("sha256"):
                pin["archive"]["sha256"] = actual
            bumble_extract_and_convert(zpath, raw, out, pin["extractOnly"])
            zpath.unlink()  # the archive is not kept; the extracted members are hash-pinned below
            for m in pin["extractOnly"]:
                fp = raw / m
                h = sha256_file(fp)
                prev = pin["files"].get(m)
                if prev and prev["sha256"] != h:
                    sys.exit(f"STOP: {m} sha256 changed")
                pin["files"][m] = {"bytes": fp.stat().st_size, "sha256": h}
                entries.append({"path": str(fp.relative_to(ROOT)), "sha256": h, "kind": "upstream"})
        if mid == "nsfwjs-mobilenet-v2":
            nsfwjs_to_safetensors(raw, out)
        # Every kept weight file, including the data-only safetensors conversions.
        for fp in sorted(out.glob("*.safetensors")) + sorted(out.glob("topology.json")):
            entries.append({"path": str(fp.relative_to(ROOT)), "sha256": sha256_file(fp), "kind": "safetensors-from-upstream"})
        if mid == "marqo-vit-tiny-384":
            st = raw / "model.safetensors"
            link = out / "marqo-vit-tiny-384.safetensors"
            if not link.exists():
                os.link(st, link)
            entries = [e for e in entries if not e["path"].endswith("marqo-vit-tiny-384.safetensors")]
            entries.append({"path": str(link.relative_to(ROOT)), "sha256": sha256_file(link), "kind": "safetensors-from-upstream"})
        card_update(mid, entries)
        print(f"  ok: {len(entries)} files carded")
    if args.record:
        PINS.write_text(json.dumps(pins, indent=2) + "\n")


if __name__ == "__main__":
    main()
