"""Print a dotted-path value from a YAML file, used by shell scripts.

    python read_config.py --config foo.yaml --key output.name --default ""
    python read_config.py --config foo.yaml --key variables --format json --default "{}"
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--config", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--default", default="")
    p.add_argument(
        "--format",
        default="text",
        choices=["text", "json"],
        help="Output format: 'text' for scalar values (default), "
             "'json' for any value including dicts and lists.",
    )
    args = p.parse_args()

    cfg_path = Path(args.config)
    if not cfg_path.exists():
        print(args.default)
        return 0

    data = yaml.safe_load(cfg_path.read_text()) or {}
    node = data
    for part in args.key.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            print(args.default)
            return 0

    if node is None:
        print(args.default)
    elif args.format == "json":
        print(json.dumps(node))
    elif isinstance(node, bool):
        print("true" if node else "false")
    else:
        print(node)
    return 0


if __name__ == "__main__":
    sys.exit(main())
