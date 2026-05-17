#!/usr/bin/env bash
# Step 2: Prepare the dataset workspace.
#
# The dataset repo is ALREADY cloned by Harness (CI Codebase) into
# $HARNESS_WORKSPACE / $DATASET_DIR. This script just:
#   1. Sets git identity for the commit + tag that publish.sh will make later.
#   2. Verifies the repo follows the data-template layout.
#   3. Installs the dataset's requirements.txt if present.
#   4. Runs the dataset's own dataset/download.py to fetch remote raw files.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Prepare dataset workspace at $DATASET_DIR"

[[ -d "$DATASET_DIR" ]] || die "DATASET_DIR ($DATASET_DIR) not found — is the codebase clone configured?"

# Configure git identity for later commits/tags from publish.sh.
git -C "$DATASET_DIR" config user.email "${GIT_AUTHOR_EMAIL:-harness-bot@example.com}"
git -C "$DATASET_DIR" config user.name  "${GIT_AUTHOR_NAME:-harness-bot}"

# Sanity checks on the data-template layout.
for required in dataset/source.yaml dataset/download.py configuration.yaml \
                pre-rules/validate.py post-rules/validate.py script/compile.py; do
  if [[ ! -f "$DATASET_DIR/$required" ]]; then
    die "Repo does not match data-template layout: missing $required"
  fi
done
log "Repo layout OK"

# Install dataset-specific Python deps.
if [[ -f "$DATASET_DIR/requirements.txt" ]]; then
  activate_venv
  log "Installing $DATASET_DIR/requirements.txt"
  python -m pip install --quiet -r "$DATASET_DIR/requirements.txt"
fi

# Run the dataset's own download script. For inline (location: github) datasets
# this is a verification pass; for remote (location: remote) datasets it
# actually fetches the raw files.
activate_venv
banner "Run dataset/download.py"
( cd "$DATASET_DIR" && python dataset/download.py )

log "Prepare OK"
