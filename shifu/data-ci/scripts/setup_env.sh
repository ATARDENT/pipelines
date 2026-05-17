#!/usr/bin/env bash
# Step 4: create a Python venv and install everything we'll need.
#
# Installs:
#   - PyYAML, DVC, huggingface_hub  (pipeline-side deps, always required)
#   - Every entry under `dependencies:` in the dataset's manifest.yaml so its
#     validate.py / compile.py scripts have what they need.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Setup Python environment"

command -v python3 >/dev/null || die "python3 not found on the build image"

# Ensure `python3 -m venv` will actually work. On Debian/Ubuntu, ensurepip
# lives in a separate apt package (python3-venv). On macOS and on Python
# Docker images this is already present and the check is a no-op.
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

# Install the dataset's declared dependencies from manifest.yaml. Format
# follows the data-template schema:
#   dependencies:
#     - name: pandas
#       version: "1.5.0"
#     - name: numpy            # version optional → unpinned install
#     - "scikit-learn==1.3.0"  # raw pip specifier strings also accepted
if [[ -f "$DATASET_DIR/manifest.yaml" ]]; then
  log "Installing dataset dependencies from manifest.yaml"
  python <<'PY'
import os, subprocess, sys, yaml

manifest = os.path.join(os.environ["DATASET_DIR"], "manifest.yaml")
with open(manifest) as f:
    data = yaml.safe_load(f) or {}

deps = data.get("dependencies") or []
specs = []
for d in deps:
    if isinstance(d, dict):
        name = d.get("name")
        if not name:
            continue
        version = d.get("version") or ""
        specs.append(f"{name}=={version}" if version else name)
    elif isinstance(d, str):
        specs.append(d)

if not specs:
    print("No dependencies declared in manifest.yaml — skipping")
    sys.exit(0)

print(f"Installing: {', '.join(specs)}")
subprocess.run(
    [sys.executable, "-m", "pip", "install", "--quiet", *specs],
    check=True,
)
PY
else
  log "No manifest.yaml at $DATASET_DIR — cannot install dataset deps"
fi

log "Python environment ready: $(python --version)"
