#!/usr/bin/env bash
# Step 4: compile raw -> trainable, honouring `steps.compile.enabled` in
# manifest.yaml.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Compile dataset"
activate_venv

enabled="$(read_config steps.compile.enabled true)"
if [[ "$enabled" != "true" ]]; then
  log "steps.compile.enabled=$enabled — skipping compile + post-validate + publish"
  # Signal downstream steps via Harness's output file (best-effort).
  echo "SKIP_COMPILE=1" >> "${HARNESS_OUTPUT_FILE:-/dev/null}" 2>/dev/null || true
  exit 0
fi

script_path="$(read_config steps.compile.script scripts/compile/compile.py)"
output_name="$(read_config output.name dataset-train)"
folder_path="$(read_config output.folder_path ./compiled)"

log "Running $script_path"
log "Expected output dir (output.folder_path) = $folder_path"
log "Expected artifact name (output.name)     = $output_name"

[[ -f "$DATASET_DIR/$script_path" ]] || die "Missing $DATASET_DIR/$script_path"

( cd "$DATASET_DIR" && python "$script_path" )

# Resolve folder_path relative to the dataset dir (supports "./compiled",
# "compiled", or an absolute path).
case "$folder_path" in
  /*) out_dir="$folder_path" ;;
  *)  out_dir="$DATASET_DIR/${folder_path#./}" ;;
esac

if [[ ! -d "$out_dir" ]] || [[ -z "$(ls -A "$out_dir" 2>/dev/null)" ]]; then
  die "compile.py did not produce any files under $out_dir"
fi

log "Compile OK — files in $out_dir:"
ls -la "$out_dir"
