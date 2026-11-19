# SPDX-License-Identifier: Apache-2.0
"""Reads `cargo metadata` JSON on stdin and fails unless every dependency has an allowed licence.

A licence expression passes if at least one of its OR choices is made only of allowed licences.
A missing or unreadable licence fails. Exit code 1 lists every failure.
"""
import json
import re
import sys

ALLOWED = {
    "MIT", "MIT-0", "Apache-2.0", "Apache-2.0 WITH LLVM-exception", "BSD-2-Clause", "BSD-3-Clause",
    "ISC", "Zlib", "0BSD", "CC0-1.0", "Unlicense", "Unicode-3.0", "Unicode-DFS-2016", "BSL-1.0",
}


def choices(expr):
    """Split an SPDX-ish expression into OR choices, each a list of AND parts."""
    expr = expr.replace("(", " ").replace(")", " ")
    out = []
    for alt in re.split(r"\s+OR\s+|/", expr):
        parts = [p.strip() for p in re.split(r"\s+AND\s+", alt) if p.strip()]
        if parts:
            out.append(parts)
    return out


def allowed(expr):
    if not expr or not expr.strip():
        return False
    return any(all(p in ALLOWED for p in parts) for parts in choices(expr))


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        print("Licence check: could not read cargo metadata")
        return 1
    root = {p for p in data.get("workspace_members", [])}
    bad, count = [], 0
    for pkg in data.get("packages", []):
        if pkg.get("id") in root:
            continue
        count += 1
        lic = pkg.get("license")
        if not allowed(lic or ""):
            bad.append(f"{pkg.get('name')} {pkg.get('version')}: {lic or 'no licence given'}")
    if bad:
        print("Licence check: not allowed or unknown:")
        print("\n".join("  " + b for b in bad))
        return 1
    print(f"Licence check: {count} dependencies, all allowed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
