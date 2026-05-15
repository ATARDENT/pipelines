#!/usr/bin/env bash
# Step 3: run the dataset repo's pre-rules/validate.py against the raw files.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Pre-validate raw dataset"
activate_venv

[[ -d "$DATASET_DIR" ]] || die "DATASET_DIR ($DATASET_DIR) missing — did acquire run?"

( cd "$DATASET_DIR" && python pre-rules/validate.py )

log "Pre-validate OK"
