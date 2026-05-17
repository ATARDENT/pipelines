# Harness pipeline for the training-template

Drop all files in this folder into the **root of your training-template
repo** (alongside `manifest.yaml` and `scripts/`). The pipeline YAML and
every helper script live side-by-side; the YAML uses bare filenames like
`python parse_manifest.py`, so the layout must be flat.

```
<repo-root>/
├── manifest.yaml
├── scripts/                       # user training code (main.py, stratify.py)
├── TrainingTemplateRunner.yaml    # the pipeline
├── README.md                      # this file
├── parse_manifest.py
├── validate_scripts_compile.sh
├── validate_scripts_lint.sh
├── validate_scripts_dry_run.py
├── clone_dataset.sh
├── validate_dataset.py
├── signal_supervisor.sh
├── classify_outcome.py
└── git_tag.sh
```

## Infrastructure

The pipeline targets a self-managed **Linux AMD64 VM** via Harness's
**VM Pool** build infrastructure:

```yaml
infrastructure:
  type: VM
  spec:
    type: Pool
    spec:
      poolName: <+pipeline.variables.vmPoolName>
      os: Linux
```

To set this up once on your VM:

1. Install a Harness delegate on the VM (Docker or systemd).
2. Configure a **VM pool** via the delegate's `pool.yml` (drone-runner-aws
   or equivalent). For a single-VM setup, the pool can have one entry
   pointing at `localhost`. Name it whatever you like; the YAML reads
   the name from the `vmPoolName` runtime variable (default
   `linux-amd64-pool`).
3. The delegate spawns a Docker container per step on that VM, using
   the `image:` and `connectorRef:` declared on each step.

`useFromStage: Validate` on every later stage routes the build back to
the same VM, so the workspace, `/shared`, and the Docker layer cache
persist across all five stages — no re-clone, no re-install.

## Shared workspace

All stages mount `/shared`. Files written there by one step are visible
to every later step in any stage (because `useFromStage` keeps us on the
same VM).

| Path                            | Producer                  | Consumers                                              |
|---------------------------------|---------------------------|--------------------------------------------------------|
| `/shared/manifest.json`         | `parse_manifest.py`       | every later script                                     |
| `/shared/dataset/raw/`          | `clone_dataset.sh`        | `validate_dataset.py`, `run_split.py`                  |
| `/shared/splits/`               | `run_split.py`            | `train_supervisor.py`, `run_eval.py`                   |
| `/shared/server_state.json`     | `provision.py`            | `train_supervisor.py`, `teardown.py`                   |
| `/shared/signal.txt`            | `signal_supervisor.sh`    | `train_supervisor.py` (polls for `interrupt` / `kill`) |
| `/shared/training_status.json`  | `train_supervisor.py`     | `stream_metrics.py`, `wait_terminal.py`, `classify_outcome.py` |
| `/shared/eval_metrics.json`     | `run_eval.py`             | `store_results.py`                                     |

## Output variables (Harness)

Scripts emit Harness output variables by appending `key=value` lines to
`$HARNESS_OUTPUT_FILE`. The YAML declares which names to capture under
each step's `outputVariables`.

| Step                      | Output variables                  |
|---------------------------|-----------------------------------|
| `ParseManifest`           | `manifest_version`, `dataset_deputy` |
| `Step1CloneDataset`       | `dataset_path`                    |
| `Step3SplitData`          | `splits_dir`                      |
| `Step4ProvisionBackend`   | `instance_id`, `backend`          |
| `Step5ResumeCheck`        | `resume_from`                     |
| `Step7ClassifyOutcome`    | `outcome`, `checkpoint`           |

## Step 7 protocol

The four outcomes from the README map onto this small protocol:

```
                   ┌────────────────────────────────┐
                   │ train_supervisor.py (Background) │
                   │  - owns mlrunner Server handle │
                   │  - submits scripts/main.py     │
                   │  - polls /shared/signal.txt    │
                   │  - writes training_status.json │
                   └──┬──────────────────┬──────────┘
                      │                  │
       writes terminal│                  │polls signal
                      ▼                  ▲
        /shared/training_status.json   /shared/signal.txt
                      ▲                  ▲
                      │                  │
              ┌───────┴────────┐  ┌──────┴──────────┐
              │ stream_metrics │  │ signal_supervisor│
              │  (parallel A)  │  │  (parallel B,   │
              │  exits on term │  │   after approval)│
              └────────────────┘  └─────────────────┘
```

`training_status.json` schema (single source of truth):
```json
{
  "state": "completed | approved | rejected | spot_revoked",
  "exit_code": 0,
  "checkpoint": "/shared/checkpoints/<run_id>/last"
}
```

State mapping:
- `completed`    — README 7.1 (training finished naturally)
- `approved`     — README 7.2 (user approved, supervisor caught SIGINT, saved checkpoint)
- `rejected`     — README 7.3 (user rejected, supervisor killed without saving)
- `spot_revoked` — README 7.4 (backend reclaimed instance, supervisor did emergency save)

The `condition` fields on the `PersistModel`, `Evaluate`, and `TagVersion`
stages branch on `outcome` to enact the README's "CI behaviour summary"
table.

## Scripts in this folder

### Extracted (formerly inline in the YAML)

- `parse_manifest.py` — schema-check manifest, write `/shared/manifest.json`
- `validate_scripts_compile.sh` — `py_compile` gate on `scripts/`
- `validate_scripts_lint.sh` — ruff bug-only rules on `scripts/`
- `validate_scripts_dry_run.py` — `--help` smoke test, catches import crashes
- `clone_dataset.sh` — internal `deputy-cli` wrapper
- `validate_dataset.py` — format/column/row sanity check
- `signal_supervisor.sh` — Step 7 approval → supervisor signal
- `classify_outcome.py` — Step 7 outcome → Harness output variable
- `git_tag.sh` — Step 11 tag + push

### To be written (referenced by the YAML, contracts above)

- `run_split.py`       — README Step 3 split into `/shared/splits/{train,val,test}`
- `provision.py`       — README Step 4 mlrunner backend provisioning (Colab → Thunder → AWS)
- `find_checkpoint.py` — README Step 5 lookup for resumable checkpoint matching `manifest.version`
- `train_supervisor.py`— README Steps 6 + 7 — **the core of the pipeline**, owns the mlrunner Server, polls signal file, handles spot revocation, writes `training_status.json`
- `stream_metrics.py`  — README Step 7 metrics tailer → wandb/tensorboard
- `wait_terminal.py`   — small helper: poll `training_status.json` until present, then exit
- `teardown.py`        — `Server.kill()` to stop the meter
- `store_artifact.py`  — README Step 8 push to `idrive_e2e` / `gdrive` / `huggingface`
- `run_eval.py`        — README Step 9 evaluation on test split
- `store_results.py`   — README Step 10 push eval metrics report

## Local development

Each script is runnable in isolation:

```bash
# Faking the workspace
sudo mkdir -p /shared && sudo chown $USER /shared
cp manifest.yaml .

# Run a single script
HARNESS_OUTPUT_FILE=/tmp/out.env python parse_manifest.py
cat /tmp/out.env
```

This is the main reason to keep logic outside the YAML: every script
gets a unit test in `tests/`, every change shows up as a real diff on
the PR.
