#!/usr/bin/env bash
# Shared helpers for all pipeline scripts. Sourced, not executed.

set -Eeuo pipefail

# Colour-free logging — Harness terminals render plain text best.
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# Paths used by every step. Set once, used everywhere.
#   PIPELINE_ROOT  — checkout of THIS repo (pipeline scripts + templates)
#   DATASET_DIR    — clone of the user's dataset repo at the requested branch
#   VENV_DIR       — Python venv created in setup_env.sh and reused after
export PIPELINE_ROOT="${PIPELINE_ROOT:-$HARNESS_WORKSPACE}"
export DATASET_DIR="${DATASET_DIR:-$PIPELINE_ROOT/dataset-repo}"
export VENV_DIR="${VENV_DIR:-$PIPELINE_ROOT/.venv}"

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
