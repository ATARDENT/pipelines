#!/usr/bin/env bash
# Step 1: create a Python venv and install everything we'll need.
#
# Installs:
#   - PyYAML, DVC, huggingface_hub  (pipeline-side deps, always required)
#   - The dataset repo's `requirements.txt`, if present, so its validate.py
#     and compile.py have what they need.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Setup Python environment"

if ! command -v python3 >/dev/null; then
  die "python3 not found on the build image"
fi

if [[ ! -d "$VENV_DIR" ]]; then
  log "Creating venv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

log "Upgrading pip"
python -m pip install --upgrade pip --quiet

log "Installing pipeline dependencies (PyYAML, dvc, huggingface_hub)"
python -m pip install --quiet \
  "PyYAML>=6.0" \
  "dvc>=3.0,<4.0" \
  "huggingface_hub>=0.24,<1.0"

# Dataset-specific deps — only install if the dataset repo is already on disk
# AND has a requirements.txt. We don't fail the step if it isn't there yet;
# acquire_dataset.sh runs next and will pull it in.
if [[ -f "$DATASET_DIR/requirements.txt" ]]; then
  log "Installing dataset requirements from $DATASET_DIR/requirements.txt"
  python -m pip install --quiet -r "$DATASET_DIR/requirements.txt"
else
  log "No dataset requirements.txt found yet; will install after acquire if present"
fi

log "Python environment ready: $(python --version)"
