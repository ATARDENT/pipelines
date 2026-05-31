# Harness pipeline for the training-template

Drop all files in this folder into the **root of your training-template
repo** (alongside `manifest.yaml` and `scripts/`).

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
├── train_supervisor.py            # ← Step 7 lives here
├── classify_outcome.py
└── git_tag.sh
```

## Infrastructure

Linux AMD64 VM via Harness **VM Pool**:

```yaml
infrastructure:
  type: VM
  spec:
    type: Pool
    spec:
      poolName: <+pipeline.variables.vmPoolName>
      os: Linux
```

Set up once on your VM:

1. Install a Harness delegate.
2. Configure a VM pool via the delegate (drone-runner-aws or equivalent).
   For a single-VM setup, a pool of one entry pointing at `localhost`
   works fine. Default name `linux-amd64-pool` — override with the
   `vmPoolName` pipeline variable.
3. The delegate spawns a Docker container per step on that VM.

`useFromStage: Validate` on every later CI stage routes the build back
to the same VM, so the workspace, `/shared/`, and the Docker layer cache
persist across stages.

## Stages

```
Validate ──┬── Train  ────── PersistModel ── Evaluate ── TagVersion
           └── ApprovalGate
              (parallel)
```

- **Validate** (CI) — manifest schema, script gates, dataset clone + check, split.
- **Train** (CI) — provision provider machine, run supervisor, classify outcome, tear down.
- **ApprovalGate** (Approval) — `HarnessApproval`, parallel with Train.
  The supervisor inside Train polls Harness's REST API for this stage's
  status to learn about approve/reject decisions in real time.
- **PersistModel** (CI) — Step 8. Skipped if `training_state == "rejected"`.
- **Evaluate** (CI) — Steps 9, 10. Skipped if `training_state` is anything
  other than `completed` or `approved`.
- **TagVersion** (CI) — Step 11. Skipped if `training_state == "rejected"`.

## Step 7 mapping (all four cases)

| README case | Cause                       | Mechanism                                                                              | `training_state` |
|-------------|-----------------------------|----------------------------------------------------------------------------------------|------------------|
| 7.1 | Training finishes naturally        | Job reaches `COMPLETED` in mlrunner; supervisor exits                                  | `completed`      |
| 7.2 | Approver clicks Approve            | Supervisor polls Harness API, sees Approval=Success, calls `Server.interrupt(job)` → SIGINT → `scripts/main.py` saves checkpoint and exits | `approved`       |
| 7.3 | Approver clicks Reject             | Supervisor sees Approval=Failed(ApprovalRejection), calls `Server.kill()` — job killed, provider machine destroyed | `rejected`       |
| 7.4 | Spot revocation                    | Supervisor catches `BackendError`/connection failure, does best-effort emergency save  | `spot_revoked`   |

### Contract for `scripts/main.py`

For case 7.2 to actually save a checkpoint, the training script **must
handle SIGINT** and write a checkpoint before exiting. Common frameworks
do this for free:

- **Hugging Face Trainer** — saves a checkpoint when SIGINT is received.
- **PyTorch Lightning** — same; uses `Trainer(enable_signals=True)`.
- **Custom loop** — install a handler:
  ```python
  import signal
  def on_sigint(_sig, _frame):
      save_checkpoint(f"/shared/checkpoints/{run_id}/last")
      sys.exit(0)
  signal.signal(signal.SIGINT, on_sigint)
  ```

The training script also needs to handle SIGTERM for spot revocation
(this is already in the training-template README's
"Implementing this template" section, point 4).

### Required CLI args for `scripts/main.py`

The supervisor invokes it with:

```
python scripts/main.py \
    --train     /shared/splits/train \
    --val       /shared/splits/val \
    --test      /shared/splits/test \
    --config    /shared/manifest.json \
    --run-id    <pipeline execution id> \
    [--resume-from /path/to/checkpoint]    # only if Step 5 found one
```

### Checkpoint location convention

Default: `/shared/checkpoints/<run_id>/last`. If your training script
saves elsewhere, update `_find_checkpoint()` in `train_supervisor.py`.

## Required Harness secrets

| Secret                       | Used by                            | Purpose                              |
|------------------------------|------------------------------------|--------------------------------------|
| `harness_api_token`          | `Step6Supervisor`                  | Polling the ApprovalGate stage       |
| `wandb_api_key`              | `Step6Supervisor`                  | Streaming metrics during training    |
| `colab_client_id`, `colab_client_secret`, `colab_env` | `Step4ProvisionBackend` | Colab backend auth         |
| `aws_access_key`, `aws_secret_key` | `Step4ProvisionBackend`     | AWS fallback                         |
| `thundercompute_api_key`     | `Step4ProvisionBackend`            | Thunder fallback                     |
| `hf_token`                   | `Step8StoreModel`                  | Hugging Face Hub push                |
| `idrive_access_key`, `idrive_secret_key` | `Step8StoreModel`      | iDrive E2 push                       |
| `github_pat`                 | `Step11GitTag`                     | Pushing the git tag                  |

The `harness_api_token` needs read access to pipeline executions on the
project containing this pipeline.

## Shared workspace

All CI stages mount `/shared`. Files written there by one step are
visible to every later step.

| Path                            | Producer                  | Consumers                                          |
|---------------------------------|---------------------------|----------------------------------------------------|
| `/shared/manifest.json`         | `parse_manifest.py`       | every later script                                 |
| `/shared/dataset/raw/`          | `clone_dataset.sh`        | `validate_dataset.py`, `run_split.py`              |
| `/shared/splits/`               | `run_split.py`            | `train_supervisor.py`, `run_eval.py`               |
| `/shared/server_state.json`     | `provision.py`            | `train_supervisor.py`, `teardown.py`               |
| `/shared/training_status.json`  | `train_supervisor.py`     | `classify_outcome.py`                              |
| `/shared/checkpoints/<run_id>/` | `scripts/main.py`         | `store_artifact.py`, `run_eval.py`                 |
| `/shared/eval_metrics.json`     | `run_eval.py`             | `store_results.py`                                 |

## Output variables (Harness)

| Step                      | Output variables                  |
|---------------------------|-----------------------------------|
| `ParseManifest`           | `manifest_version`, `dataset_deputy` |
| `Step1CloneDataset`       | `dataset_path`                    |
| `Step3SplitData`          | `splits_dir`                      |
| `Step4ProvisionBackend`   | `instance_id`, `backend`          |
| `Step5ResumeCheck`        | `resume_from`                     |
| `Step6ClassifyTraining`   | `training_state`, `checkpoint`    |

## `training_status.json` schema

```json
{
  "state":      "completed | approved | rejected | spot_revoked | failed",
  "exit_code":  0,
  "checkpoint": "/shared/checkpoints/<run_id>/last"
}
```

## Scripts in this folder

### Written and ready

- `parse_manifest.py` — schema-check manifest, write `/shared/manifest.json`
- `validate_scripts_compile.sh` — `py_compile` gate on `scripts/`
- `validate_scripts_lint.sh` — ruff bug-only rules on `scripts/`
- `validate_scripts_dry_run.py` — `--help` smoke test, catches import crashes
- `clone_dataset.sh` — internal `deputy-cli` wrapper
- `validate_dataset.py` — format/column/row sanity check
- `train_supervisor.py` — **Step 6 + 7 supervisor** — owns the polling loop
- `classify_outcome.py` — emits `training_state` + `checkpoint` Harness output variables
- `git_tag.sh` — Step 11 tag + push

### To be written (contracts above)

- `run_split.py`       — README Step 3: split into `/shared/splits/{train,val,test}`
- `provision.py`       — README Step 4: mlrunner backend provisioning (Colab → Thunder → AWS).
                          Writes `/shared/server_state.json` with the backend name,
                          `ServerSpec` fields, and the resulting `instance_id`.
- `find_checkpoint.py` — README Step 5: search for resumable checkpoint matching `manifest.version`
- `teardown.py`        — `Server.kill()` to stop the meter
- `store_artifact.py`  — README Step 8 push to `idrive_e2e` / `gdrive` / `huggingface`
- `run_eval.py`        — README Step 9 evaluation on test split
- `store_results.py`   — README Step 10 push eval metrics report

## How the parallel approval coordination works

```
                Step4ProvisionBackend
                writes /shared/server_state.json
                          │
                          ▼
        ┌─────────────────────────────────────┐
        │  Step6Supervisor (train_supervisor) │
        │                                     │
        │  while True:                        │
        │      job.status?         ─────►  COMPLETED      → "completed"
        │      backend reachable?  ─────►  no             → "spot_revoked"
        │      Harness API:                                 ▲
        │        ApprovalGate=Success    ────►  interrupt  │
        │        ApprovalGate=Failed     ────►  kill       │
        │      stream metrics                              │
        │      sleep 30s                                   │
        └──────────────────────────────────────────────────┘
                                                           ▲
                                                           │
                          ┌────────────────────────────────┘
                          │
                  ApprovalGate stage
                  ─ HarnessApproval (24h timeout)
                  ─ failureStrategies: Reject + Timeout → MarkAsSuccess
                    (the supervisor handles the actual semantics)
```

The two stages run on **completely separate execution paths**: Train
runs on the VM in a Docker container, ApprovalGate runs on the Harness
manager (no infrastructure). They share state through the Harness REST
API, not through `/shared/`. The supervisor's polling loop is the only
place that interprets "approval status" into "training action".

## Local development

Each script is runnable in isolation:

```bash
sudo mkdir -p /shared && sudo chown $USER /shared
cp manifest.yaml .

HARNESS_OUTPUT_FILE=/tmp/out.env python parse_manifest.py
cat /tmp/out.env
```

For `train_supervisor.py`, a useful local-test mode: stub out the
Harness API check by leaving `HARNESS_API_TOKEN` unset, and the
approval-polling branch is a no-op.

# model-ci v0.3

Generic Harness pipeline for any training-template instance. Stage shape:

```
ValidateCode → ValidateDataset → parallel{Train, ApprovalGate}
             → PersistModel    → TagVersion
```

The Train stage has, in order:
- Step 5 — ResumeCheck (look for a resumable checkpoint in R2)
- Step 6 — RunTraining: one of TWO variants, gated by `backend_name`:
  - **Colab** (`backend_name == "colab"`): provisions a Colab kernel via
    `colab-cli`, runs `mlpipe-train-remote` on it, polls. Image:
    `atardent/mlrunner-ci:latest`.
  - **SkyPilot** (everything else): translates the manifest into a
    SkyPilot task spec, launches a cluster, polls. Image:
    `berkeleyskypilot/skypilot:latest`. Covers AWS / GCP / Azure /
    Lambda / Vast / RunPod / Spheron / Kubernetes / etc.
- Step 7 — ClassifyOutcome (read `/tmp/shared/training_status.json`,
  emit Harness output vars).

The ApprovalGate runs in parallel. The supervisor inside Step 6 polls
the gate via the Harness REST API and aborts it on natural completion
so the parallel block doesn't sit on the 25h approval timeout.

## Two trigger modes

### Mode A — train a commit (default)

Pick a branch / tag / commit of a training repo. The pipeline clones it,
parses the manifest as-is, trains, tags. The final git tag points at
that commit.

### Mode B — custom-config build from a commit hash

Set the `configOverridesJson` pipeline variable to a JSON object with
dotted-path keys:

```json
{
  "training.max_epochs": 20,
  "training.hyperparameters.learning_rate": 1e-4,
  "dataset.deputy": "01999f0a-1234-5678-9abc-def012345678"
}
```

The `ApplyOverrides` step in `ValidateCode`:
1. Deep-merges the overrides into `manifest.yaml`
2. Commits to a new branch `auto/run-<executionId>`
3. Pushes the branch (if `github_pat` is configured)
4. Emits `auto_commit_sha` as an output variable

Subsequent stages train against the rewritten manifest. The final
`TagVersion` step tags the auto-branch commit — so the trained model
is permanently traceable to its exact config via a real git reference.

If `configOverridesJson` is empty or `"{}"`, ApplyOverrides is a no-op
and the pipeline behaves like Mode A.

## Pipeline variables

| Variable | Default | Description |
|---|---|---|
| `trainingRunId` | `<pipeline.executionId>` | Embedded in R2 keys + git tag |
| `configOverridesJson` | `"{}"` | Mode B overrides; JSON object with dotted keys |
| `replaceExistingColab` | `"false"` | Colab-only: replace running server (default: abort) |
| `mlpipeGitUrl` | `git+https://github.com/<org>/mlpipe.git@v0.3.0` | Pin the mlpipe version |

## Output variables

| Step | Output |
|---|---|
| `ApplyOverrides` | `overrides_applied`, `auto_branch`, `auto_commit_sha` |
| `ParseManifest` | `manifest_version`, `dataset_deputy`, `backend_name` |
| `Step1CloneDataset` | `dataset_path` |
| `Step3SplitData` | `splits_dir` |
| `Step5ResumeCheck` | `resume_from` |
| `Step6RunTraining{Colab,SkyPilot}` | `training_state`, `checkpoint_uri` |
| `Step7ClassifyOutcome` | `training_state`, `checkpoint` (= R2 URI) |

## Required Harness secrets

| Secret | Used by |
|---|---|
| `harness_api_token` | Step 6 (approval polling) |
| `wandb_api_key` | Step 6 |
| `R2_BUCKET`, `R2_ACCOUNT_ID`, `R2_ACCESS_KEY`, `R2_SECRET_KEY` | Step 5, Step 6, Step 8 |
| `COLAB_CREDENTIALS_JSON` | Step 6 (Colab variant only) |
| `aws_access_key`, `aws_secret_key` | Step 6 (SkyPilot variant, AWS) |
| `gcp_service_account_json` | Step 6 (SkyPilot variant, GCP) |
| `hf_token` | Step 8 (HuggingFace push) |
| `idrive_access_key`, `idrive_secret_key` | Step 8 (iDrive E2 push) |
| `github_pat` | ApplyOverrides (push auto-branch), Step 9 (tag push) |

## What changed from v0.2

- The `Validate` mega-stage split into `ValidateCode` + `ValidateDataset`
  (faster fail on script bugs).
- `ProvisionBackend`, separate `Evaluate`, `TeardownBackend` stages are
  GONE. Step 6 is now a single supervisor that owns provision → submit →
  poll → teardown, and eval runs inside `mlpipe-train-remote` on the
  provider VM right after training (Option B from the design doc).
- Step 6 forks at the YAML level on `backend_name`. The mlrunner
  abstraction over multiple backends is decommissioned in v0.3.0.
- Legacy `.py` / `.sh` scripts that lived in this directory are gone.
  Everything is `python -m mlpipe.ci.<name>` now.
- New `ApplyOverrides` step enables Mode B.

## Local development

The CI helpers each run standalone. Quick check against any
training-template repo:

```bash
cd training-template-repo
mkdir -p /tmp/shared
python -m mlpipe.ci.parse_manifest
cat /tmp/.harness_outputs.env

# Mode-B dry run (commits locally only, no GH_TOKEN needed)
git init -q  # if not already
git add . && git commit -q -m initial
CONFIG_OVERRIDES_JSON='{"training.max_epochs": 5}' \
HARNESS_EXECUTION_ID="local-test-1" \
python -m mlpipe.ci.apply_overrides
git log --oneline auto/run-local-test-1
```
