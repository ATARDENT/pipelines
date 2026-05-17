#!/usr/bin/env python3
"""README Step 2 — Validate dataset schema, row count, file presence.

Environment:
    DATASET_PATH   Absolute path under /shared/dataset/raw (set by Step 1)

Reads:
    /shared/manifest.json   (written by parse_manifest.py)

Aborts on:
    - No files of the declared format
    - Missing required columns (input / target / label per manifest)
"""
from __future__ import annotations
import json
import os
import pathlib
import subprocess
import sys


REQS = ["pyyaml", "pandas", "pyarrow"]


def _ensure_deps() -> None:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", *REQS])


def _peek(path: pathlib.Path, fmt: str):
    import pandas as pd
    if fmt == "jsonl":
        return pd.read_json(path, lines=True, nrows=1)
    if fmt == "csv":
        return pd.read_csv(path, nrows=1)
    return pd.read_parquet(path).head(1)


def _count_rows(path: pathlib.Path, fmt: str) -> int:
    import pandas as pd
    if fmt == "jsonl":
        with open(path, errors="ignore") as f:
            return sum(1 for _ in f)
    if fmt == "csv":
        return len(pd.read_csv(path))
    return len(pd.read_parquet(path))


def main() -> int:
    _ensure_deps()

    with open("/shared/manifest.json") as f:
        m = json.load(f)

    fmt = m["dataset"]["format"]
    cols = m["dataset"]["columns"]
    root = pathlib.Path(os.environ.get("DATASET_PATH", "/shared/dataset/raw"))

    if fmt not in ("jsonl", "csv", "parquet"):
        print(f"unsupported format for this validator: {fmt}", file=sys.stderr)
        return 1

    files = sorted(root.rglob(f"*.{fmt}"))
    if not files:
        print(f"no .{fmt} files under {root}", file=sys.stderr)
        return 1

    total = 0
    for path in files:
        df = _peek(path, fmt)
        for role, col in cols.items():
            if col is not None and col not in df.columns:
                print(f"column '{col}' (role={role}) missing in {path}", file=sys.stderr)
                return 1
        total += _count_rows(path, fmt)

    print(f"✓ dataset OK — {len(files)} file(s), ~{total} rows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
