#!/usr/bin/env bash
# Step 3: run the dataset's pre-rules validate script against raw files.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Pre-validate raw dataset"
activate_venv

# --- TEMP DEBUG: show what's actually on disk ----------------------------
log "PWD=$PWD"
log "DATASET_DIR=$DATASET_DIR"
log "----- top level of DATASET_DIR -----"
ls -la "$DATASET_DIR" || true
log "----- scripts/ subtree (if present) -----"
if [[ -d "$DATASET_DIR/scripts" ]]; then
  find "$DATASET_DIR/scripts" -maxdepth 4 -print
else
  log "(no scripts/ directory at \$DATASET_DIR)"
fi
log "----- git state of DATASET_DIR -----"
( cd "$DATASET_DIR" && git rev-parse HEAD 2>/dev/null && git log -1 --stat 2>/dev/null ) || log "(not a git repo or git not available)"
log "----- end debug -----"
# -------------------------------------------------------------------------

[[ -d "$DATASET_DIR" ]] || die "DATASET_DIR ($DATASET_DIR) missing — did acquire run?"

enabled="$(read_config steps.pre-rules.enabled true)"
if [[ "$enabled" != "true" ]]; then
  log "steps.pre-rules.enabled=$enabled — skipping"
  exit 0
fi

# Honour an explicit script path from manifest.yaml; fall back to the
# data-template convention.
script_path="$(read_config steps.pre-rules.script scripts/pre-rules/validate.py)"
log "Running $script_path"

[[ -f "$DATASET_DIR/$script_path" ]] || die "Missing $DATASET_DIR/$script_path"

( cd "$DATASET_DIR" && python "$script_path" )

log "Pre-validate OK"
