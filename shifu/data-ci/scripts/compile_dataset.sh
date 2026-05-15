#!/usr/bin/env bash
# Step 4: compile raw -> trainable, honouring `compile: true|false` in
# the dataset's configuration.yaml.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Compile dataset"
activate_venv

compile_flag="$(read_config compile true)"
if [[ "$compile_flag" != "true" ]]; then
  log "configuration.yaml has compile=$compile_flag — skipping compile + post-validate + store"
  echo "SKIP_COMPILE=1" >> "${HARNESS_OUTPUT_FILE:-/dev/null}" 2>/dev/null || true
  exit 0
fi

output_name="$(read_config output.name dataset-train)"
log "Compiling -> compiled/${output_name}.jsonl (or whatever script/compile.py emits)"

( cd "$DATASET_DIR" && python script/compile.py )

# Verify something landed under compiled/.
if [[ ! -d "$DATASET_DIR/compiled" ]] || [[ -z "$(ls -A "$DATASET_DIR/compiled" 2>/dev/null)" ]]; then
  die "compile.py did not produce any files under compiled/"
fi

log "Compile OK — files in compiled/:"
ls -la "$DATASET_DIR/compiled"
