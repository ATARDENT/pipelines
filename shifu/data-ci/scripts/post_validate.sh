#!/usr/bin/env bash
# Step 7: run the dataset's post-rules/validate.py against the compiled output.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Post-validate compiled dataset"
activate_venv

enabled="$(read_config steps.post-rules.enabled true)"
if [[ "$enabled" != "true" ]]; then
  log "steps.post-rules.enabled=$enabled — skipping"
  exit 0
fi

script_path="$(read_config steps.post-rules.script scripts/post-rules/validate.py)"
[[ -f "$DATASET_DIR/$script_path" ]] || die "Missing $DATASET_DIR/$script_path"
log "Running $script_path"

# Re-derive the compiled output path the same way compile_dataset.sh did.
output_name="$(read_config output.name dataset-train)"
folder_path="$(read_config output.folder_path ./compiled)"
case "$folder_path" in
  /*) out_dir="$folder_path" ;;
  *)  out_dir="$DATASET_DIR/${folder_path#./}" ;;
esac

# Find the compiled file; prefer an exact name match, fall back to first file.
extensions_json="$(read_config_json steps.compile.extensions '[".jsonl"]')"
first_ext="$(EXTENSIONS_JSON="$extensions_json" python -c "
import os, json
exts = json.loads(os.environ['EXTENSIONS_JSON'])
print(exts[0] if exts else '.jsonl')
")"

compiled_file="$out_dir/${output_name}${first_ext}"

if [[ ! -f "$compiled_file" ]]; then
  # Fallback: pick the first file in out_dir if the expected name is missing.
  compiled_file="$(find "$out_dir" -maxdepth 1 -type f | sort | head -1)"
  [[ -n "$compiled_file" ]] || die "No compiled file found in $out_dir — did compile_dataset run?"
  log "WARN: expected $out_dir/${output_name}${first_ext}, using $compiled_file instead"
fi

compiled_filename="$(basename "$compiled_file")"
log "Validating: $compiled_filename ($compiled_file)"

# Pass the manifest variables block through as a JSON string.
variables_json="$(read_config_json variables '{}')"

( cd "$DATASET_DIR" && python "$script_path" \
    --filename  "$compiled_filename" \
    --filepath  "$compiled_file" \
    --variables "$variables_json" )

log "Post-validate OK"
