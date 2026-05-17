#!/usr/bin/env bash
# README Step 7 — Translate the human's HarnessApproval verdict into a
# supervisor signal, then block until the supervisor reports terminal
# state (so the parallel branch closes deterministically).
#
# Environment:
#   APPROVAL_STATUS   Set from <+steps.Step7AwaitApproval.status>
#                     One of: APPROVED | REJECTED | EXPIRED | ABORTED | …
#
# Writes:
#   /shared/signal.txt   "interrupt" (approve) | "kill" (reject) | (nothing on no-op)
#
# Reads:
#   /shared/training_status.json   Written by train_supervisor.py
#
# Outcome mapping (README Step 7 table):
#   APPROVED          → 7.2  interrupt → supervisor saves checkpoint, exits clean
#   REJECTED          → 7.3  kill      → supervisor exits without saving
#   EXPIRED / *       → 7.1  no-op     → supervisor finishes naturally
#                       7.4 (spot revoked) is detected by the supervisor itself.
set -euo pipefail

case "${APPROVAL_STATUS:-EXPIRED}" in
    APPROVED)
        echo "interrupt" > /shared/signal.txt
        echo "→ approve: requested checkpoint + exit"
        ;;
    REJECTED)
        echo "kill" > /shared/signal.txt
        echo "→ reject: requested abort"
        ;;
    *)
        echo "→ approval not acted on (status=${APPROVAL_STATUS:-EXPIRED}); leaving training alone"
        ;;
esac

# Block until supervisor reports terminal — this also closes the parallel
# block, regardless of which of the 4 outcomes actually fired.
python wait_terminal.py --status-file /shared/training_status.json --timeout-s 90000
