#!/usr/bin/env bash
# Step 5: run the dataset's pre-rules validate script against raw files.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Pre-validate raw dataset"
activate_venv

[[ -d "$DATASET_DIR" ]] || die "DATASET_DIR ($DATASET_DIR) missing"
[[ -f "$DATASET_DIR/manifest.yaml" ]] || die "manifest.yaml not found in $DATASET_DIR"

enabled="$(read_config steps.pre-rules.enabled true)"
if [[ "$enabled" != "true" ]]; then
  log "steps.pre-rules.enabled=$enabled — skipping"
  exit 0
fi

script_path="$(read_config steps.pre-rules.script scripts/pre-rules/validate.py)"
[[ -f "$DATASET_DIR/$script_path" ]] || die "Missing $DATASET_DIR/$script_path"
log "Running $script_path"

# Find the primary raw input file (data-template convention: dataset/*.csv).
raw_file="$(find "$DATASET_DIR/dataset" -maxdepth 1 -name "*.csv" | sort | head -1)"
[[ -n "$raw_file" ]] || die "No CSV file found in $DATASET_DIR/dataset/"
raw_filename="$(basename "$raw_file")"
log "Raw input: $raw_filename ($raw_file)"

# Read the manifest's variables block as a JSON string and pass it through.
variables_json="$(read_config_json variables '{}')"
log "Variables: $variables_json"

( cd "$DATASET_DIR" && python "$script_path" \
    --filename  "$raw_filename" \
    --filepath  "$raw_file" \
    --variables "$variables_json" )

log "Pre-validate OK"
