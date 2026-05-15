#!/usr/bin/env bash
# Step 2: clone the user-chosen dataset repo at the user-chosen branch,
# then run its `dataset/download.py` to acquire any remote raw files.
#
# Required env (injected by the pipeline):
#   DATASET_REPO     e.g. "your-org/instruction-tune-v1" or full URL
#   DATASET_BRANCH   e.g. "main"
#   GITHUB_TOKEN     PAT with read access (optional for public repos)

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Acquire dataset repo: ${DATASET_REPO} @ ${DATASET_BRANCH}"

[[ -n "${DATASET_REPO:-}" ]]   || die "DATASET_REPO is not set"
[[ -n "${DATASET_BRANCH:-}" ]] || die "DATASET_BRANCH is not set"

# Accept either "org/name" or a full URL.
if [[ "$DATASET_REPO" == http*://* ]]; then
  repo_url="$DATASET_REPO"
else
  repo_url="https://github.com/${DATASET_REPO}.git"
fi

# Insert token for private repos, if provided.
if [[ -n "${GITHUB_TOKEN:-}" && "$repo_url" == https://github.com/* ]]; then
  authed_url="${repo_url/https:\/\//https://x-access-token:${GITHUB_TOKEN}@}"
else
  authed_url="$repo_url"
fi

if [[ -d "$DATASET_DIR" ]]; then
  log "Removing previous clone at $DATASET_DIR"
  rm -rf "$DATASET_DIR"
fi

log "Cloning $repo_url (branch $DATASET_BRANCH)"
git clone --depth 1 --branch "$DATASET_BRANCH" "$authed_url" "$DATASET_DIR"

# Configure git identity for later commits/tags.
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

# Install dataset deps now that we have them.
if [[ -f "$DATASET_DIR/requirements.txt" ]]; then
  activate_venv
  log "Installing $DATASET_DIR/requirements.txt"
  python -m pip install --quiet -r "$DATASET_DIR/requirements.txt"
fi

# Run the dataset's own download script. For inline GitHub datasets this is a
# verification pass; for remote datasets it actually fetches.
activate_venv
banner "Run dataset/download.py"
( cd "$DATASET_DIR" && python dataset/download.py )

log "Acquire OK"
