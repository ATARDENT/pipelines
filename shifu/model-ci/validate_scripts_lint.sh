#!/usr/bin/env bash
# Lint the user training scripts with ruff, restricted to rules that
# mean "this script can't run":
#   E9  — syntax errors
#   F63 — invalid raise / assert tuple
#   F7  — semantic errors (return outside func, etc.)
#   F82 — undefined name
#
# Style/formatting noise is intentionally NOT included — that belongs
# in a separate lint job, not in the training pipeline.
set -euo pipefail

pip install --quiet ruff==0.6.9
ruff check --select=E9,F63,F7,F82 scripts/
