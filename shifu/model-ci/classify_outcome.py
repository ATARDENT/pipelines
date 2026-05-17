#!/usr/bin/env python3
"""README Step 7 — Classify final outcome for downstream stages.

Reads:
    /shared/training_status.json   Written by train_supervisor.py.
    Schema:
        {
            "state":      "completed" | "approved" | "rejected" | "spot_revoked",
            "exit_code":  int,
            "checkpoint": "/absolute/path/or/empty",
            ...
        }

Writes:
    $HARNESS_OUTPUT_FILE
        outcome=<state>
        checkpoint=<path>
"""
from __future__ import annotations
import json
import os
import sys


STATUS_FILE = "/shared/training_status.json"
VALID_STATES = {"completed", "approved", "rejected", "spot_revoked"}


def main() -> int:
    if not os.path.exists(STATUS_FILE):
        print(f"missing {STATUS_FILE} — supervisor did not write final state", file=sys.stderr)
        return 1

    with open(STATUS_FILE) as f:
        status = json.load(f)

    state = status.get("state")
    if state not in VALID_STATES:
        print(f"unknown state in status file: {state!r}", file=sys.stderr)
        return 1

    out = os.environ.get("HARNESS_OUTPUT_FILE")
    if out:
        with open(out, "a") as f:
            f.write(f"outcome={state}\n")
            f.write(f"checkpoint={status.get('checkpoint', '')}\n")

    print(f"✓ outcome: {state}  checkpoint: {status.get('checkpoint', '<none>')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
