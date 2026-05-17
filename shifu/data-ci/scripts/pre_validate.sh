#!/usr/bin/env bash
# Step 5: run the dataset's pre-rules validate script against raw files.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Pre-validate raw dataset"
activate_venv

[[ -d "$DATASET_DIR" ]] || die "DATASET_DIR ($DATASET_DIR) missing — did acquire run?"
[[ -f "$DATASET_DIR/manifest.yaml" ]] || die "manifest.yaml not found in $DATASET_DIR"

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
