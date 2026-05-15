#!/usr/bin/env bash
# Step 9: trigger the downstream training pipeline.
# TODO: implement when the training pipeline identifier is known.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Trigger training pipeline (TODO)"

# When implemented, this will likely call the Harness API:
#   curl -X POST \
#     "https://app.harness.io/gateway/pipeline/api/pipeline/execute/${TRAINING_PIPELINE_ID}/..." \
#     -H "x-api-key: ${HARNESS_API_KEY}" \
#     -d '{ "dataset_name": "...", "dataset_version": "...", "hf_repo_id": "..." }'
#
# Inputs to pass forward:
#   - output.name + version
#   - HF repo + branch  (so training can `dvc pull` or hf-download)
#   - .dvc pointer commit SHA on the source repo
log "Skipping — training trigger not implemented yet."

exit 0
