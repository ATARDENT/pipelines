#!/usr/bin/env python3
"""Parse manifest.yaml, sanity-check it, expose key fields downstream.

Reads:
    ./manifest.yaml          (workspace root)

Writes:
    /shared/manifest.json    (canonical JSON form, consumed by later steps)
    $HARNESS_OUTPUT_FILE     manifest_version=<x>, dataset_deputy=<uuid>

Exits non-zero on missing required keys or invalid split ratios.
"""
from __future__ import annotations
import json
import os
import subprocess
import sys


REQUIRED_KEYS = ["version", "model", "dataset", "split", "training", "backend", "output"]


def _ensure_pyyaml() -> None:
    try:
        import yaml  # noqa: F401
    except ImportError:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "pyyaml"])


def main() -> int:
    _ensure_pyyaml()
    import yaml

    with open("manifest.yaml") as f:
        m = yaml.safe_load(f)

    missing = [k for k in REQUIRED_KEYS if k not in m]
    if missing:
        print(f"manifest.yaml missing required keys: {missing}", file=sys.stderr)
        return 1

    splits = m["split"]
    total = sum(splits.get(k, 0) for k in ("train", "val", "test"))
    if abs(total - 1.0) > 1e-9:
        print(f"split.{{train,val,test}} must sum to 1.0, got {total}", file=sys.stderr)
        return 1

    os.makedirs("/shared", exist_ok=True)
    with open("/shared/manifest.json", "w") as f:
        json.dump(m, f)

    out = os.environ.get("HARNESS_OUTPUT_FILE")
    if out:
        with open(out, "a") as f:
            f.write(f"manifest_version={m['version']}\n")
            f.write(f"dataset_deputy={m['dataset']['deputy']}\n")

    print(f"✓ manifest OK  version={m['version']}  deputy={m['dataset']['deputy']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
