#!/usr/bin/env bash
# Step 3: create a Python venv and install everything we'll need.
#
# Installs:
#   - PyYAML, DVC, huggingface_hub  (pipeline-side deps, always required)
#   - The dataset repo's `requirements.txt`, if present, so its validate.py
#     and compile.py have what they need.
#
# Note: on the Linux Docker delegate, the default image ships python3 but not
# `python3-venv` (which provides ensurepip). We install it on demand.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Setup Python environment"

command -v python3 >/dev/null || die "python3 not found on the build image"

# Ensure `python3 -m venv` will actually work. On Debian/Ubuntu, ensurepip
# lives in a separate apt package (python3-venv). On the macOS delegate and
# on Python Docker images this is already present and the check is a no-op.
ensure_venv_module() {
  if python3 -c "import ensurepip" 2>/dev/null; then
    return 0
  fi
  log "ensurepip missing — installing python3-venv"
  local SUDO=""
  if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq
    # Install the version-specific package (e.g. python3.8-venv) if it exists;
    # fall back to the generic python3-venv otherwise. apt-cache search is
    # used to avoid hard-coding the Python minor version.
    local py_minor
    py_minor="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    if $SUDO apt-get install -y --no-install-recommends "python${py_minor}-venv" 2>/dev/null; then
      :
    else
      $SUDO apt-get install -y --no-install-recommends python3-venv
    fi
  else
    die "Cannot install python3-venv automatically — no apt-get on this image. \
Set the Run step's image to one that ships venv (e.g. python:3.11-slim)."
  fi
}

if [[ ! -d "$VENV_DIR" ]]; then
  ensure_venv_module
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

# Dataset-specific deps — only install if the dataset repo is on disk and has
# a requirements.txt. (The GitClone for the dataset runs before this step, so
# by now $DATASET_DIR should be populated.)
if [[ -f "$DATASET_DIR/requirements.txt" ]]; then
  log "Installing dataset requirements from $DATASET_DIR/requirements.txt"
  python -m pip install --quiet -r "$DATASET_DIR/requirements.txt"
else
  log "No dataset requirements.txt — skipping"
fi

log "Python environment ready: $(python --version)"
