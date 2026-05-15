#!/usr/bin/env bash
# Step 5: run the dataset's post-rules/validate.py against the compiled output.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Post-validate compiled dataset"
activate_venv

compile_flag="$(read_config compile true)"
if [[ "$compile_flag" != "true" ]]; then
  log "compile=false — nothing to post-validate, skipping"
  exit 0
fi

( cd "$DATASET_DIR" && python post-rules/validate.py )

log "Post-validate OK"
