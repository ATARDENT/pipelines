#!/usr/bin/env bash
# Shared helpers for all pipeline scripts. Sourced, not executed.

set -Eeuo pipefail

# Colour-free logging — Harness terminals render plain text best.
log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# Paths used by every step. Set once, used everywhere.
#   PIPELINE_ROOT  — checkout of THIS repo, scoped to shifu/data-ci
#                    (Step 0 clones the whole monorepo into ./pipeline-scripts;
#                     the data-ci tree lives at pipeline-scripts/shifu/data-ci)
#   DATASET_DIR    — clone of the user's dataset repo. Harness's GitClone step
#                    appears to ignore cloneDirectory when the cloned repo
#                    matches the default codebase, so the dataset ends up at
#                    the workspace root alongside pipeline-scripts/ and .venv/.
#                    That's fine — they don't collide.
#   VENV_DIR       — Python venv created in setup_env.sh and reused after
export PIPELINE_ROOT="${PIPELINE_ROOT:-$PWD/pipeline-scripts/shifu/data-ci}"
export DATASET_DIR="${DATASET_DIR:-$PWD}"
export VENV_DIR="${VENV_DIR:-$PWD/.venv}"

# Always activate the venv inside step scripts (no-op if not created yet).
activate_venv() {
  if [[ -d "$VENV_DIR" ]]; then
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
  fi
}

# Read a dotted path from `manifest.yaml` inside the dataset repo.
#   read_config output.name                     -> "instruction-tune-v1"
#   read_config remote.huggingface.repo_id ""   -> "" if unset (with default)
read_config() {
  local key="$1"
  local default="${2:-}"
  activate_venv
  python "$PIPELINE_ROOT/scripts/lib/read_config.py" \
    --config "$DATASET_DIR/manifest.yaml" \
    --key "$key" \
    --default "$default"
}

# Print a banner so step output is easy to scan in the Harness UI.
banner() {
  printf '\n========== %s ==========\n' "$*"
}
