"""Publish a compiled dataset to Hugging Face Hub with a DVC pointer.

What this does end-to-end
-------------------------
1. `dvc init` inside the dataset repo (idempotent).
2. `dvc add compiled/<file>` for every file under `compiled/` →
   produces a `.dvc` pointer next to each.
3. Reads the md5 from each .dvc file and uploads the actual data blob to
   the Hugging Face dataset repo at `dvc-store/<md5[:2]>/<md5[2:]>`.
   This layout matches what DVC's HTTP remote expects, so downstream
   `dvc pull` works.
4. Writes `.dvc/config` so the HF dataset repo IS the DVC remote.

The shell wrapper then takes the resulting .dvc files / .dvc/config /
.dvcignore / compiled/.gitignore and commits them to the target branch
in the source GitHub repo.

This script does NOT touch git — that's the wrapper's job.

Required env:
    HF_TOKEN       Hugging Face access token with write scope on the repo

Required CLI args:
    --dataset-dir          Path to the cloned dataset repo
    --hf-repo-id           e.g. "your-org/instruction-tune-v1"
    --hf-repo-type         "dataset" | "model"
    --hf-repo-branch       Branch in the HF repo (usually "main")
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

import yaml


def log(msg: str) -> None:
    print(f"[publish] {msg}", flush=True)


def die(msg: str) -> "None":
    print(f"[publish] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def run(cmd: list[str], cwd: Path) -> None:
    log(f"$ {' '.join(cmd)}  (cwd={cwd})")
    res = subprocess.run(cmd, cwd=cwd, check=False)
    if res.returncode != 0:
        die(f"command failed with exit {res.returncode}: {' '.join(cmd)}")


def dvc_init_if_needed(repo: Path) -> None:
    if (repo / ".dvc").exists():
        log(".dvc/ already exists — skipping dvc init")
        return
    run(["dvc", "init", "-q"], cwd=repo)


def dvc_add_compiled(repo: Path) -> list[Path]:
    """Run `dvc add` on every regular file under compiled/. Returns the
    list of resulting .dvc pointer files."""
    compiled = repo / "compiled"
    if not compiled.exists():
        die(f"{compiled} does not exist — did compile run?")

    targets: list[Path] = []
    for entry in sorted(compiled.iterdir()):
        if not entry.is_file():
            continue
        if entry.name.endswith(".dvc") or entry.name == ".gitignore":
            continue
        targets.append(entry)

    if not targets:
        die(f"no files to track under {compiled}")

    rel_targets = [str(t.relative_to(repo)) for t in targets]
    run(["dvc", "add", *rel_targets], cwd=repo)

    return [Path(f"{t}.dvc") for t in [repo / r for r in rel_targets]]


def parse_md5_from_dvc(dvc_file: Path) -> tuple[str, str]:
    """Return (md5, outfile_name) from a .dvc pointer file."""
    data = yaml.safe_load(dvc_file.read_text()) or {}
    outs = data.get("outs") or []
    if not outs:
        die(f"{dvc_file} has no outs entry")
    out = outs[0]
    md5 = out.get("md5") or out.get("hash") or ""
    name = out.get("path") or ""
    if not md5 or not name:
        die(f"{dvc_file} is missing md5/path under outs")
    return md5, name


def upload_to_hf(
    *,
    local_file: Path,
    md5: str,
    repo_id: str,
    repo_type: str,
    branch: str,
    token: str,
) -> str:
    """Upload `local_file` to HF at dvc-store/<md5[:2]>/<md5[2:]>.
    Returns the HF-side path."""
    from huggingface_hub import HfApi

    hf_path = f"dvc-store/{md5[:2]}/{md5[2:]}"
    api = HfApi(token=token)
    log(f"Uploading {local_file.name} -> hf://{repo_type}/{repo_id}@{branch}/{hf_path}")

    api.upload_file(
        path_or_fileobj=str(local_file),
        path_in_repo=hf_path,
        repo_id=repo_id,
        repo_type=repo_type,
        revision=branch,
        commit_message=f"DVC store: add {local_file.name} ({md5[:8]})",
    )
    return hf_path


def ensure_hf_repo(*, repo_id: str, repo_type: str, token: str) -> None:
    """Create the HF repo if it doesn't exist yet — keeps the pipeline
    self-bootstrapping for first-run datasets."""
    from huggingface_hub import HfApi
    from huggingface_hub.utils import HfHubHTTPError

    api = HfApi(token=token)
    try:
        api.repo_info(repo_id=repo_id, repo_type=repo_type)
        log(f"HF repo {repo_id} ({repo_type}) exists")
    except HfHubHTTPError:
        log(f"HF repo {repo_id} ({repo_type}) not found — creating")
        api.create_repo(repo_id=repo_id, repo_type=repo_type, exist_ok=True, private=False)


def write_dvc_remote_config(
    *, repo: Path, repo_id: str, repo_type: str, branch: str
) -> None:
    """Configure DVC's HTTP remote so `dvc pull` resolves through HF."""
    prefix = "datasets/" if repo_type == "dataset" else ""
    base_url = f"https://huggingface.co/{prefix}{repo_id}/resolve/{branch}/dvc-store"

    dvc_dir = repo / ".dvc"
    dvc_dir.mkdir(exist_ok=True)
    config = dvc_dir / "config"

    run(
        ["dvc", "remote", "add", "-d", "-f", "hf", base_url],
        cwd=repo,
    )
    log(f".dvc/config now points to {base_url}")
    if config.exists():
        log(f"--- .dvc/config ---\n{config.read_text()}-------------------")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--dataset-dir", required=True)
    p.add_argument("--hf-repo-id", required=True)
    p.add_argument("--hf-repo-type", default="dataset", choices=["dataset", "model"])
    p.add_argument("--hf-repo-branch", default="main")
    args = p.parse_args()

    token = os.environ.get("HF_TOKEN", "")
    if not token:
        die("HF_TOKEN env var is empty")
    if not args.hf_repo_id:
        die("--hf-repo-id is empty")

    repo = Path(args.dataset_dir).resolve()
    if not repo.exists():
        die(f"dataset-dir does not exist: {repo}")

    ensure_hf_repo(
        repo_id=args.hf_repo_id, repo_type=args.hf_repo_type, token=token
    )

    dvc_init_if_needed(repo)
    pointer_files = dvc_add_compiled(repo)

    for pointer in pointer_files:
        md5, name = parse_md5_from_dvc(pointer)
        actual = pointer.parent / name
        if not actual.exists():
            die(f"expected file {actual} (referenced by {pointer.name}) missing")
        upload_to_hf(
            local_file=actual,
            md5=md5,
            repo_id=args.hf_repo_id,
            repo_type=args.hf_repo_type,
            branch=args.hf_repo_branch,
            token=token,
        )

    write_dvc_remote_config(
        repo=repo,
        repo_id=args.hf_repo_id,
        repo_type=args.hf_repo_type,
        branch=args.hf_repo_branch,
    )

    log(f"Done. {len(pointer_files)} pointer file(s) ready for commit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
