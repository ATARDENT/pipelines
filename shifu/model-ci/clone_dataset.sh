#!/usr/bin/env bash
# README Step 1 — Clone dataset from internal deputy.
#
# Environment:
#   DEPUTY_UUID    UUID from manifest.yaml (mandatory fallback)
#   OVERRIDE_UUID  Optional override supplied at pipeline runtime
#
# Output:
#   $HARNESS_OUTPUT_FILE: dataset_path=<absolute path>
#
# Assumes `deputy-cli` is on PATH (baked into internal/ci-tools image).
set -euo pipefail

UUID="${OVERRIDE_UUID:-$DEPUTY_UUID}"
if [ -z "$UUID" ]; then
    echo "no deputy UUID resolved (neither OVERRIDE_UUID nor DEPUTY_UUID set)" >&2
    exit 1
fi

mkdir -p /shared/dataset
deputy-cli download "$UUID" --output /shared/dataset/raw

if [ -n "${HARNESS_OUTPUT_FILE:-}" ]; then
    echo "dataset_path=/shared/dataset/raw" >> "$HARNESS_OUTPUT_FILE"
fi
echo "✓ dataset cloned to /shared/dataset/raw"
