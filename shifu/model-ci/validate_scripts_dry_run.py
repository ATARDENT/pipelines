#!/usr/bin/env python3
"""Smoke-test the training scripts by invoking them with --help.

The contract from README "Implementing this template" point 4:
    main.py takes split paths + config as args.

At minimum the script must respond to --help without importing CUDA libs
or otherwise crashing — that's the cheapest "is it runnable" probe before
we book a GPU. We allow a non-zero return code (some scripts don't wire
up --help and exit 2 from argparse, which is fine) but we DO NOT allow
an import-time crash, which would show as a Traceback in stderr.
"""
from __future__ import annotations
import subprocess
import sys


SCRIPTS = ("scripts/main.py", "scripts/stratify.py")
TIMEOUT_S = 30


def main() -> int:
    for s in SCRIPTS:
        r = subprocess.run(
            [sys.executable, s, "--help"],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_S,
        )
        if "Traceback" in r.stderr:
            print(r.stderr, file=sys.stderr)
            print(f"✗ {s} crashes on import", file=sys.stderr)
            return 1
        print(f"✓ {s} runnable (rc={r.returncode})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
