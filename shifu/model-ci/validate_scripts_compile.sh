#!/usr/bin/env bash
# Verify that scripts/main.py and scripts/stratify.py at least PARSE.
# py_compile catches every syntax error without importing the modules
# (which would require GPU deps we don't carry on the CI runner).
#
# Exits 1 if any script is missing, empty, or won't compile.
set -euo pipefail

for f in scripts/main.py scripts/stratify.py; do
    if [ ! -f "$f" ]; then
        echo "MISSING: $f"
        exit 1
    fi
    if [ ! -s "$f" ]; then
        echo "EMPTY: $f — fill it in before merging"
        exit 1
    fi
    if ! python -m py_compile "$f"; then
        echo "SYNTAX FAIL: $f"
        exit 1
    fi
done

echo "✓ all scripts compile"
