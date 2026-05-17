#!/usr/bin/env bash
# Shared helpers for all pipeline scripts. Sourced, not executed.

set -Eeuo pipefail

# Colour-free logging — Harness terminals render plain text best.
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# Workspace layout in Harness CI:
#
#   /harness                        ← CI Codebase (the DATASET repo, cloned by Harness)
#   /harness/pipeline-scripts       ← data-ci (cloned by the GitClone step)
#   /harness/.venv                  ← Python venv (created by setup_env.sh)
#
# So the path variables map as:
#   PIPELINE_ROOT  → /harness/pipeline-scripts   (where these scripts live)
#   DATASET_DIR    → /harness                    (the dataset repo working tree)
#   VENV_DIR       → /harness/.venv              (per-run venv at workspace root)
#
# Override any of these in your environment for local testing.
export PIPELINE_ROOT="${PIPELINE_ROOT:-$PWD/pipeline-scripts}"
export DATASET_DIR="${DATASET_DIR:-$PWD}"
export VENV_DIR="${VENV_DIR:-$PWD/.venv}"

# Always activate the venv inside step scripts (no-op if not created yet).
activate_venv() {
  if [[ -d "$VENV_DIR" ]]; then
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
  fi
}

# Read a dotted path from `configuration.yaml` inside the dataset repo.
#   read_config output.name             -> "instruction-tune-v1"
#   read_config output.hf_repo_id ""    -> "" if unset (with default)
read_config() {
  local key="$1"
  local default="${2:-}"
  activate_venv
  python "$PIPELINE_ROOT/scripts/lib/read_config.py" \
    --config "$DATASET_DIR/configuration.yaml" \
    --key "$key" \
    --default "$default"
}

# Print a banner so step output is easy to scan in the Harness UI.
banner() {
  printf '\n========== %s ==========\n' "$*"
}
