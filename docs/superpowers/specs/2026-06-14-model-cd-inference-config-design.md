# model-cd inference config — design

**Date:** 2026-06-14
**Status:** Approved for planning
**Scope:** `shifu/model-cd/pipeline.yaml` (this repo) + `ci/serve_model.py`, `ci/serve_bootstrap.py` (mlrunner codebase repo). **No change to model-ci.**

## Problem

When deploying a model, the operator currently cannot pass an inference/generation
config, and nothing about the inference run is recorded. We want to:

1. Let a deploy run **supply an inference config**.
2. **Apply** that config to serving (it changes generation behavior).
3. **Record** the config so the run is traceable — via git commit + tag, mirroring
   how model-ci records training config on its `auto/run-<execId>` branch.

Training is already well-recorded (model-ci Mode B commits config overrides to
`auto/run-<execId>` and the final tag points at that commit), so **model-ci is left
unchanged**. All new work is in model-cd plus a coordinated mlrunner change so
serving can consume the config.

## Decisions

| Topic | Decision |
|---|---|
| Training-side recording | No model-ci change; git auto-branch already covers it |
| Where inference config is recorded | Git commit to `auto/deploy-<execId>` + `deploy-<execId>` tag (mirror training) |
| Is the config used or just recorded | **Consumed by serving AND recorded** |
| Input format | `inferenceConfigJson` JSON-string pipeline variable (mirrors `configOverridesJson`) |
| Serve contract | File-path on delegate → inline arg to remote → env var in the FastAPI app |
| Git auth in model-cd | GitHub App token via `mlpipe.ci.mint_gh_token` (add `CloneMlpipe` step + `GITHUB_APP_*` secrets) |
| Tag timing | Tag only on a **live endpoint** (successful serve); failed deploys leave the branch but no tag |
| Committed file | `inference_config.json` at the codebase repo root |

## Why this shape (key constraint)

The serving chain is two-hop across **two filesystems**:

- `ci/serve_model.py` runs on the **Harness delegate** (shares the Deploy stage
  workspace, so the committed file is on disk here).
- It provisions a runtime and runs `ci/serve_bootstrap.py` on the **remote**
  (Colab kernel / Spheron box) via `server.run_python_file(..., args=(...))`. The
  remote is a **separate filesystem** and does **not** clone the codebase repo.
- The actual generation logic lives in the FastAPI app (`APP_CODE_HF`) that
  bootstrap writes and runs on the remote.

Therefore the **only reliable channel to the remote is the `run_python_file`
args** — not shared disk, not delegate env vars. The config must travel:
file (delegate) → inline JSON arg (remote process) → env var (FastAPI app).

## Data flow

```
inferenceConfigJson (pipeline var, default "{}")
   └─ ApplyInferenceConfig writes ──► inference_config.json   (committed to auto/deploy-<execId>, later tagged)
          │ INFERENCE_CONFIG_PATH (env on delegate)
          ▼
   serve_model.py  (delegate) ── reads file, appends ──► --inference-config '<compact-json>'
          │                                               (run_python_file arg → remote)
          ▼
   serve_bootstrap.py (remote) ── if non-empty ──► env["MODEL_INFERENCE_CONFIG"] = value
          ▼
   FastAPI app (APP_CODE_HF) ── json.loads(MODEL_INFERENCE_CONFIG) → generation defaults
                                 (per-request body overrides; active config echoed in /health)
```

Empty / `"{}"` config → `ApplyInferenceConfig` is a no-op, `INFERENCE_CONFIG_PATH`
is empty, `serve_model.py` passes no `--inference-config`, and behavior is
**identical to today**.

## Component 1 — model-cd pipeline (`shifu/model-cd/pipeline.yaml`)

### New pipeline variable

```yaml
- name: inferenceConfigJson
  type: String
  description: |
    Optional. JSON object of inference/generation settings recorded with
    the deploy and applied to serving. Example:
        {"max_new_tokens": 512, "temperature": 0.7, "top_p": 0.9}
    Empty / "{}" → no config recorded, serve with built-in defaults.
  value: <+input>.default("{}")
```

### Deploy stage changes

- Add `sharedPaths: [/tmp/shared]` to the Deploy stage spec (so the mlpipe clone
  persists across steps, mirroring model-ci).
- Step order (new steps in **bold**):

1. **`CloneMlpipe`** — `GitClone` of `mlpipe` (pinned tag, kept in lockstep with
   model-ci's pin) into `/tmp/shared/mlpipe`. Needed for `mint_gh_token`.
2. `InitAndTest` — unchanged.
3. **`ApplyInferenceConfig`** — see below.
4. `FetchModel` — unchanged.
5. `ServeColab` — add env `INFERENCE_CONFIG_PATH:
   <+steps.ApplyInferenceConfig.output.outputVariables.inference_config_path>`.
6. `ServeSpheron` — same `INFERENCE_CONFIG_PATH` env addition.
7. **`TagDeploy`** — see below.

### `ApplyInferenceConfig` step

- Env: `INFERENCE_CONFIG_JSON: <+pipeline.variables.inferenceConfigJson>`,
  `HARNESS_EXECUTION_ID`, `REPO_URL: <+codebase.repoUrl>`, and the
  `GITHUB_APP_*` secrets.
- Logic (bash, `python:3.11-slim`):
  - `rm -f /tmp/.harness_outputs.env`; install git; `pip install /tmp/shared/mlpipe[ci]`.
  - Strip wrapping quotes that Harness's `.default("...")` leaves
    (`${VAR%\"}` / `${VAR#\"}`), exactly as `ApplyOverrides` does.
  - If the value is empty or `{}`: emit `config_applied=false`,
    `inference_config_path=`, `auto_branch=`, `auto_commit_sha=` and exit 0.
  - Else: `json.loads`-validate it; write `inference_config.json` at the repo root
    containing the config plus a metadata header (`modelRunId`, `modelSource`,
    `hfRepoId`, `deployTarget`, `executionId`). Set bot identity
    (`git config user.email "ml-ci@atardent.noreply"`, `user.name "mlpipe-ci"`).
    Mint a token (`GH_TOKEN="$(python -m mlpipe.ci.mint_gh_token)"`), create branch
    `auto/deploy-${HARNESS_EXECUTION_ID}`, commit the file, push via
    `https://x-access-token:${GH_TOKEN}@<repo-no-scheme>`. Emit
    `config_applied=true`, `inference_config_path=<abs path in workspace>`,
    `auto_branch`, `auto_commit_sha`.
- Output variables: `config_applied`, `inference_config_path`, `auto_branch`,
  `auto_commit_sha`.
- Re-source `/tmp/.harness_outputs.env` with `set -a; . ...; set +a` so lowercase
  output vars are bound under `set -u` (same pattern as every other step).

### `TagDeploy` step

- Runs `when: stageStatus == Success` **and**
  `<+steps.ApplyInferenceConfig.output.outputVariables.config_applied> == "true"`.
  (Stage success implies the active Serve step bound an endpoint, so the tag marks
  a deploy that actually went live.)
- Env: `GITHUB_APP_*`, `REPO_URL`, `HARNESS_EXECUTION_ID`,
  `AUTO_COMMIT_SHA: <+steps.ApplyInferenceConfig.output.outputVariables.auto_commit_sha>`.
- Logic: install git + `mlpipe[ci]`; mint token; set bot identity; tag
  `deploy-${HARNESS_EXECUTION_ID}` at `AUTO_COMMIT_SHA`; push. Idempotent — skip if
  the tag already exists on origin (mirror Step 9's idempotency check).

### Secrets to add to model-cd

`GITHUB_APP_CLIENT_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY`
(already used by model-ci in the same `Project_Shifu`; model-cd just references them).

## Component 2 — mlrunner codebase (separate repo; defined here, implemented there)

- **`ci/serve_model.py`** — read optional `INFERENCE_CONFIG_PATH`. If set and the
  file exists, `json.load` it and append `"--inference-config", <compact-json>` to
  the `run_python_file` args in **both** the cpu-ondemand and gpu-spheron paths.
  If unset/empty, pass nothing (current behavior).
- **`ci/serve_bootstrap.py`** — add `ap.add_argument("--inference-config",
  default="")`. If non-empty, set `env["MODEL_INFERENCE_CONFIG"] = args.inference_config`
  before launching uvicorn.
- **`APP_CODE_HF`** — at module load, `_CFG = json.loads(os.environ.get(
  "MODEL_INFERENCE_CONFIG", "{}") or "{}")`. Use `_CFG` to seed generation
  defaults: `max_new_tokens`, `temperature`, `top_p`, `top_k`,
  `repetition_penalty`, `do_sample`, and optional `system_prompt` /
  `enable_thinking` (Qwen). The request body still overrides per call (e.g. `Req`
  fields default to `_CFG` values). Echo the active config in `/health`.
- **`APP_CODE_FILE`** (R2 single-file path) — pass `MODEL_INFERENCE_CONFIG`
  through so the user's placeholder `predict()` can read it; no enforced schema.

## Edge cases & invariants

- **No model ownership required** — recording is git-side and independent of
  `modelSource`; public repos like `Qwen/*` work fine.
- **Idempotent tag push** — re-running with the same exec id (or a retried stage)
  must not fail on an existing tag; check origin before pushing.
- **Branch/tag sprawl** — one `auto/deploy-<execId>` branch per *configured*
  deploy only (no-op when config is empty); same trade-off training already accepts.
- **`set -u` safety & "null" literal** — reuse the existing quote-strip and
  `[ "$x" = "null" ] && x=""` guards present in both pipelines.
- **Backward compatibility** — with no `inferenceConfigJson` supplied, serving is
  byte-for-byte unchanged: `ApplyInferenceConfig` and `TagDeploy` no-op and
  `serve_model.py` passes no `--inference-config`. `CloneMlpipe` does run
  unconditionally (cheap, same `GitClone` model-ci uses), so it must not introduce
  a new failure mode for no-config deploys; if that risk is a concern during
  implementation, gate `CloneMlpipe`/`ApplyInferenceConfig` on a non-empty config.

## Out of scope

- Any model-ci change.
- Uploading the config into the model store (HF/R2) next to the model files
  (explicitly rejected — git commit+tag is the chosen record).
- A default inference config carried with the model at training time.
- Changes to the R2 single-file `predict()` beyond passing the config through.

## Testing strategy

- **Pipeline lint** — the new YAML parses and Harness accepts the expressions;
  dry-run with `inferenceConfigJson="{}"` shows `ApplyInferenceConfig`/`TagDeploy`
  as no-ops and serving unchanged.
- **mlrunner unit** — `serve_model.py` builds the correct `run_python_file` args
  with and without `INFERENCE_CONFIG_PATH`; `serve_bootstrap.py` sets
  `MODEL_INFERENCE_CONFIG` only when `--inference-config` is non-empty.
- **App behavior** — `APP_CODE_HF` applies `_CFG` defaults and lets the request
  body override; `/health` reports the active config.
- **End-to-end (manual)** — a real deploy with a non-empty config produces an
  `auto/deploy-<execId>` branch, a `deploy-<execId>` tag on success, and a served
  endpoint whose `/health` reflects the config.
