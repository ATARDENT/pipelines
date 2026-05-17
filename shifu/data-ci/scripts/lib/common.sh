#!/usr/bin/env bash
# Shared helpers for all pipeline scripts. Sourced, not executed.

set -Eeuo pipefail

# Colour-free logging — Harness terminals render plain text best.
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# Paths used by every step. Set once, used everywhere.
#   PIPELINE_ROOT  — checkout of THIS repo, scoped to shifu/data-ci
#   DATASET_DIR    — dataset repo; Harness GitClone puts it at the workspace
#                    root alongside pipeline-scripts/ and .venv/
#   VENV_DIR       — Python venv created by setup_env.sh and reused after
export PIPELINE_ROOT="${PIPELINE_ROOT:-$PWD/pipeline-scripts/shifu/data-ci}"
export DATASET_DIR="${DATASET_DIR:-$PWD}"
export VENV_DIR="${VENV_DIR:-$PWD/.venv}"

# Activate the venv if it exists (no-op before setup_env.sh runs).
activate_venv() {
  if [[ -d "$VENV_DIR" ]]; then
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
  fi
}

# Read a scalar value from manifest.yaml.
#   read_config output.name                  -> "example-instruction-train"
#   read_config steps.compile.enabled true   -> "true"
read_config() {
  local key="$1"
  local default="${2:-}"
  activate_venv
  python "$PIPELINE_ROOT/scripts/lib/read_config.py" \
    --config "$DATASET_DIR/manifest.yaml" \
    --key "$key" \
    --default "$default"
}

# Read any value from manifest.yaml and return it as a JSON string.
# Use this for blocks that are dicts or lists (variables, extensions, etc.).
#   read_config_json variables '{}'         -> '{"min_raw_rows": 30, ...}'
#   read_config_json steps.compile.extensions '[]' -> '[".jsonl"]'
read_config_json() {
  local key="$1"
  local default="${2:-null}"
  activate_venv
  python "$PIPELINE_ROOT/scripts/lib/read_config.py" \
    --config "$DATASET_DIR/manifest.yaml" \
    --key "$key" \
    --format json \
    --default "$default"
}

# Print a banner so step output is easy to scan in the Harness UI.
banner() {
  printf '\n========== %s ==========\n' "$*"
}
