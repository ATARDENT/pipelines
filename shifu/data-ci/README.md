# data-pipeline

A Harness CI pipeline that compiles raw datasets into trainable datasets,
following the [`ATARDENT/data-template`](https://github.com/ATARDENT/data-template) layout.

```
choose repo + branch  →  setup env  →  acquire  →  pre-validate  →
                         compile     →  post-validate            →
                         publish (DVC + HF)  →  register  →  notify  →  trigger training
```

## Layout

```
data-ci/
├── pipeline.yaml                     # The Harness pipeline (orchestration only)
├── input-sets/
│   └── example_dataset.yaml          # Preset inputs for quick smoke tests
│
├── scripts/                          # All real logic lives here
│   ├── setup_env.sh                  # 1. Create venv + install deps
│   ├── acquire_dataset.sh            # 2. Clone dataset repo + run download.py
│   ├── pre_validate.sh               # 3. Run pre-rules/validate.py
│   ├── compile_dataset.sh            # 4. Run script/compile.py
│   ├── post_validate.sh              # 5. Run post-rules/validate.py
│   ├── publish.sh                    # 6. DVC + HF upload + commit pointers + tag
│   ├── register_deputy.sh            # 7. TODO — deputy service
│   ├── notify.sh                     # 8. TODO — email
│   ├── trigger_training.sh           # 9. TODO — downstream pipeline
│   └── lib/
│       ├── common.sh                 # Shared bash helpers
│       ├── read_config.py            # YAML dotted-path reader
│       └── hf_dvc_publish.py         # The DVC + Hugging Face publisher
│
└── example-dataset/                  # A working data-template instance for testing
    ├── configuration.yaml
    ├── dataset/{source.yaml,download.py,raw.csv}
    ├── pre-rules/{metadata.yaml,validate.py}
    ├── script/compile.py
    ├── post-rules/{metadata.yaml,validate.py}
    └── requirements.txt
```

**Why this split.** Pipeline YAML is short and only describes *order + secrets + inputs*; every step calls one script. To change behaviour, edit the script. To add a step, add a script and add a `Run` step block. The pipeline never needs to grow.

## Pipeline inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `DATASET_REPO` | yes | — | GitHub repo with the dataset-template instance, e.g. `your-org/instruction-tune-v1` (or full URL). |
| `DATASET_BRANCH` | yes | `main` | Branch of the dataset repo to compile from. |

## Required secrets / connectors

Configure these in your Harness account before running. The IDs in
`pipeline.yaml` are placeholders — adjust to whatever your account uses.

| Pipeline ref | What | Scope |
|---|---|---|
| `account.github_pipeline_repo` | GitHub connector pointing at THIS pipeline repo. Used by Harness to clone it as the codebase. | Read |
| `account.github_token` | PAT for the dataset repo — used to clone (private repos) and push DVC pointers + tags back. | Read + Write |
| `account.hf_token` | Hugging Face access token. | Write to target dataset repo |

## What the publish step does

1. `dvc init` inside the dataset repo (idempotent).
2. `dvc add compiled/*` — generates `<file>.dvc` pointer files and a `compiled/.gitignore`.
3. For each compiled file, extract the md5 from its `.dvc` and upload the actual bytes to Hugging Face at `dvc-store/<md5[:2]>/<md5[2:]>`. This path layout is what DVC's HTTP remote expects, so downstream consumers can `dvc pull` and get the data back from HF.
4. Configure `.dvc/config` to use the HF dataset repo as the default DVC remote.
5. Switch to `output.branch` in the source repo (creating it as an orphan branch if it doesn't exist), restore the DVC artefacts, commit, and push.
6. If `tag.enabled: true`, tag the commit as `<prefix>-v<version>` and push the tag.

The HF dataset repo is auto-created on first run if it doesn't exist.

## Quick start

### 1. Test the example dataset locally

```bash
cd example-dataset
pip install -r requirements.txt
python dataset/download.py
python pre-rules/validate.py
python script/compile.py
python post-rules/validate.py
```

All four scripts should exit 0. A `compiled/instruction-tune-v1.jsonl` is produced.

### 2. Test the full pipeline locally (without HF upload)

```bash
# From the repo root
export HARNESS_WORKSPACE=$PWD
./scripts/setup_env.sh
# Then either set DATASET_REPO=... and run acquire_dataset.sh,
# or just symlink: ln -s example-dataset dataset-repo
./scripts/pre_validate.sh
./scripts/compile_dataset.sh
./scripts/post_validate.sh
# publish.sh requires HF_TOKEN + a real HF repo + a real GitHub remote.
```

### 3. Wire up Harness

1. Push this repo to GitHub as `your-org/data-pipeline`.
2. In Harness, create a GitHub connector named `github_pipeline_repo` pointing at it.
3. Create secrets `github_token` (GitHub PAT) and `hf_token` (HF token).
4. Import the pipeline from Git: `pipeline.yaml`.
5. Run it with `DATASET_REPO=your-org/your-dataset` and `DATASET_BRANCH=main`.

## Extending

- **Add a new step**: drop a new script under `scripts/`, then add a `Run` step block to `pipeline.yaml` pointing at it.
- **Add a new output destination**: extend the `case` in `scripts/publish.sh` and add a sibling to `lib/hf_dvc_publish.py`. The `gdrive` and `idrive_e2` branches are pre-stubbed.
- **Replace placeholders**: `register_deputy.sh`, `notify.sh`, `trigger_training.sh` each contain a comment block describing the contract.
- **Switch to Harness step templates**: each script already has a single responsibility, so wrapping each in a Step Template and referencing by `templateRef` is a one-for-one swap if you later want template-library reuse.

## Conventions

- Bash scripts use `set -Eeuo pipefail` (via `lib/common.sh`) — they fail fast.
- Python helpers exit non-zero with a descriptive stderr message on any failure.
- Steps share state via the filesystem (`DATASET_DIR`, `VENV_DIR`) — no hidden global state.
- All configuration lives in the **dataset repo's** `configuration.yaml`, not in the pipeline. This pipeline works for any dataset repo that follows the template.
