#!/usr/bin/env bash
# Step 6: compile raw dataset → trainable format.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Compile dataset"
activate_venv

enabled="$(read_config steps.compile.enabled true)"
if [[ "$enabled" != "true" ]]; then
  log "steps.compile.enabled=$enabled — skipping"
  exit 0
fi

script_path="$(read_config steps.compile.script scripts/compile/compile.py)"
[[ -f "$DATASET_DIR/$script_path" ]] || die "Missing $DATASET_DIR/$script_path"
log "Running $script_path"

# Raw input — data-template convention: dataset/*.csv
raw_file="$(find "$DATASET_DIR/dataset" -maxdepth 1 -name "*.csv" | sort | head -1)"
[[ -n "$raw_file" ]] || die "No CSV file found in $DATASET_DIR/dataset/"
log "Raw input: $raw_file"

# Resolve the output path from manifest.yaml
output_name="$(read_config output.name dataset-train)"
folder_path="$(read_config output.folder_path ./compiled)"
case "$folder_path" in
  /*) out_dir="$folder_path" ;;
  *)  out_dir="$DATASET_DIR/${folder_path#./}" ;;
esac

# Parse the extensions list from manifest.yaml and build the output filename.
# Using EXTENSIONS_JSON env var avoids any shell-quoting issues with JSON content.
extensions_json="$(read_config_json steps.compile.extensions '[".jsonl"]')"
log "Compile extensions: $extensions_json"

first_ext="$(EXTENSIONS_JSON="$extensions_json" python -c "
import os, json
exts = json.loads(os.environ['EXTENSIONS_JSON'])
print(exts[0] if exts else '.jsonl')
")"

# Build the full list of --extensions args as a bash array.
readarray -t ext_array < <(
  EXTENSIONS_JSON="$extensions_json" python -c "
import os, json
for e in json.loads(os.environ['EXTENSIONS_JSON']):
    print(e)
"
)

out_file="$out_dir/${output_name}${first_ext}"
log "Output file: $out_file"

# Pass the manifest variables block through as a JSON string.
variables_json="$(read_config_json variables '{}')"

( cd "$DATASET_DIR" && python "$script_path" \
    --input      "$raw_file" \
    --output     "$out_file" \
    --extensions "${ext_array[@]}" \
    --variables  "$variables_json" )

# Verify compile.py actually produced something.
if [[ ! -f "$out_file" ]] || [[ ! -s "$out_file" ]]; then
  die "Expected output file missing or empty: $out_file"
fi

log "Compile OK — output: $out_file ($(wc -l < "$out_file") lines)"
