# model-cd Inference Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a model-cd deploy run supply an inference config that is both applied to serving and recorded via a git commit + tag, mirroring how model-ci records training config.

**Architecture:** A new `inferenceConfigJson` pipeline variable feeds an `ApplyInferenceConfig` step that writes `inference_config.json`, commits it to `auto/deploy-<execId>`, and emits its path. The Serve steps pass that path to `serve_model.py`, which (because the remote runtime is a separate filesystem) reads the file and forwards the config inline to `serve_bootstrap.py`, which puts it on the FastAPI app's environment as generation defaults. On a live endpoint, a `TagDeploy` step tags the commit `deploy-<execId>`.

**Tech Stack:** Harness CI pipeline YAML; Python 3.11 (`python:3.11-slim` step image); `mlpipe.ci.mint_gh_token` for GitHub App auth; mlrunner's `pytest` unit suite; PyYAML for local pipeline validation.

**Repos touched (two separate git repos):**
- `/home/ardent/pipelines` — Part B (the model-cd pipeline YAML). Currently on `main`.
- `/home/ardent/mlrunner` — Part A (the serving contract). Currently on `feat/skypilot-spot-colab-timeout-ci-harness`.

**Spec:** `docs/superpowers/specs/2026-06-14-model-cd-inference-config-design.md`

---

## Preconditions (verify before starting)

- [ ] **Secrets exist in `Project_Shifu`:** `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY` (already used by model-ci). model-cd will reference them by these ids.
- [ ] **GitHub App write access:** the App behind those secrets must have **write** access to the codebase repo deployed by model-cd (the `ML_Runner` connector's repo). Without it, `ApplyInferenceConfig`/`TagDeploy` pushes fail.
- [ ] **mlpipe pin:** use tag `v0.3.8` for the new model-cd `CloneMlpipe` step (matches model-ci's current Train/Persist/Tag stages). If model-ci's pin has since moved, match the newest pin used elsewhere in model-ci.
- [ ] **Feature branches created** (commits land here, not on `main`):

```bash
cd /home/ardent/mlrunner   && git checkout -b feat/inference-config
cd /home/ardent/pipelines  && git checkout -b feat/model-cd-inference-config
```

---

## File Structure

**Part A — `/home/ardent/mlrunner`**
- Modify: `ci/serve_bootstrap.py` — add `--inference-config` arg → `MODEL_INFERENCE_CONFIG` env; add tested pure helpers `apply_inference_config_env`, `resolve_generation_kwargs`, constant `GENERATION_PARAM_KEYS`; consume the config in `APP_CODE_HF` (generation defaults + `/health`) and pass it through in `APP_CODE_FILE`.
- Modify: `ci/serve_model.py` — add `import json`; add tested helpers `build_bootstrap_args`, `_read_inference_config`; read `INFERENCE_CONFIG_PATH` in `main()`.
- Modify: `tests/unit/test_serve_bootstrap.py` — append helper tests.
- Create: `tests/unit/test_serve_model.py` — new test module (by-path loader).

**Part B — `/home/ardent/pipelines`**
- Modify: `shifu/model-cd/pipeline.yaml` — new `inferenceConfigJson` variable; Deploy stage `sharedPaths`; new steps `CloneMlpipe`, `ApplyInferenceConfig`, `TagDeploy`; `INFERENCE_CONFIG_PATH` env on `ServeColab`/`ServeSpheron`; updated description.

**Contract note (resolves a spec detail):** the recorded file is `{"inference": {<generation params>}, "deploy": {<metadata>}}`. Serving extracts the `inference` sub-object (tolerating a bare config object), so the FastAPI app always sees **flat** generation keys while the record keeps deploy metadata.

---

# Part A — mlrunner serving contract

### Task A1: serve_bootstrap pure helpers (config env + kwargs merge)

**Files:**
- Modify: `/home/ardent/mlrunner/ci/serve_bootstrap.py`
- Test: `/home/ardent/mlrunner/tests/unit/test_serve_bootstrap.py`

- [ ] **Step 1: Write the failing tests** (append to `tests/unit/test_serve_bootstrap.py`)

```python
def test_apply_inference_config_env_sets_when_present(sb):
    env = {}
    sb.apply_inference_config_env(env, '{"temperature": 0.7}')
    assert env["MODEL_INFERENCE_CONFIG"] == '{"temperature": 0.7}'


def test_apply_inference_config_env_noop_when_blank(sb):
    env = {}
    sb.apply_inference_config_env(env, "")
    sb.apply_inference_config_env(env, "   ")
    assert "MODEL_INFERENCE_CONFIG" not in env


def test_resolve_generation_kwargs_defaults_from_config(sb):
    out = sb.resolve_generation_kwargs(
        {"temperature": 0.7, "top_p": 0.9, "ignored": 1}, {}
    )
    assert out["temperature"] == 0.7
    assert out["top_p"] == 0.9
    assert "ignored" not in out          # only recognised keys pass through
    assert out["max_new_tokens"] == 256  # always bounded


def test_resolve_generation_kwargs_request_overrides_config(sb):
    out = sb.resolve_generation_kwargs(
        {"temperature": 0.7, "max_new_tokens": 64},
        {"temperature": 0.2, "max_new_tokens": None},  # None = not supplied
    )
    assert out["temperature"] == 0.2     # request wins
    assert out["max_new_tokens"] == 64   # None ignored -> config value kept
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /home/ardent/mlrunner && python3 -m pytest tests/unit/test_serve_bootstrap.py -q`
Expected: FAIL — `AttributeError: module 'serve_bootstrap' has no attribute 'apply_inference_config_env'`.

- [ ] **Step 3: Implement the helpers** — add to `ci/serve_bootstrap.py` near the top-level helpers (e.g. just after the `PORT_BASE, PORT_SPAN = ...` line):

```python
# Generation parameters the served app understands. The inference config seeds
# these as defaults; a per-request body field of the same name overrides for that
# call. Module-level so the unit tests and the embedded APP_CODE_HF agree on the
# recognised keys (APP_CODE_HF embeds the same merge because it runs on the remote
# and cannot import this module).
GENERATION_PARAM_KEYS = (
    "max_new_tokens", "temperature", "top_p", "top_k",
    "repetition_penalty", "do_sample",
)


def apply_inference_config_env(env, raw):
    """Put the inference-config JSON on the remote app's environment.

    `raw` is the JSON string passed via --inference-config (the only channel that
    reaches this remote process). Blank/whitespace -> leave env untouched so the
    app serves with built-in defaults. Returns `env` for convenience."""
    if raw and raw.strip():
        env["MODEL_INFERENCE_CONFIG"] = raw
    return env


def resolve_generation_kwargs(cfg, overrides):
    """Merge inference-config defaults with per-request overrides.

    Tested reference for what APP_CODE_HF does at request time. Only
    GENERATION_PARAM_KEYS pass through; a None in `overrides` means "not supplied"
    so the config default wins. Always yields max_new_tokens so generate() is
    bounded."""
    out = {k: cfg[k] for k in GENERATION_PARAM_KEYS
           if k in cfg and cfg[k] is not None}
    for k in GENERATION_PARAM_KEYS:
        if overrides.get(k) is not None:
            out[k] = overrides[k]
    out.setdefault("max_new_tokens", 256)
    return out
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/ardent/mlrunner && python3 -m pytest tests/unit/test_serve_bootstrap.py -q`
Expected: PASS (the 5 original tests + 4 new).

- [ ] **Step 5: Commit**

```bash
cd /home/ardent/mlrunner
git add ci/serve_bootstrap.py tests/unit/test_serve_bootstrap.py
git commit -m "serve_bootstrap: pure helpers for inference config (env + kwargs merge)"
```

---

### Task A2: serve_bootstrap main() — accept --inference-config

**Files:**
- Modify: `/home/ardent/mlrunner/ci/serve_bootstrap.py` (the `main()` function)

- [ ] **Step 1: Add the argparse flag** — in `main()`, alongside the existing arguments:

```python
    ap.add_argument("--model-url", required=True)   # https URL or hf://<org/name>
    ap.add_argument("--run-id", default="unknown")
    ap.add_argument("--inference-config", default="")
    args = ap.parse_args()
```

- [ ] **Step 2: Wire it onto the env** — immediately after `env = dict(os.environ)`:

```python
    env = dict(os.environ)
    apply_inference_config_env(env, args.inference_config)
```

- [ ] **Step 3: Verify the module still imports and tests pass**

Run: `cd /home/ardent/mlrunner && python3 -m pytest tests/unit/test_serve_bootstrap.py -q`
Expected: PASS.

- [ ] **Step 4: Verify the flag is wired (grep check)**

Run: `cd /home/ardent/mlrunner && grep -n -- "--inference-config" ci/serve_bootstrap.py && grep -n "apply_inference_config_env(env" ci/serve_bootstrap.py`
Expected: both lines present (the argparse add and the call in `main()`).

- [ ] **Step 5: Commit**

```bash
cd /home/ardent/mlrunner
git add ci/serve_bootstrap.py
git commit -m "serve_bootstrap: accept --inference-config and export MODEL_INFERENCE_CONFIG"
```

---

### Task A3: serve_model — read INFERENCE_CONFIG_PATH, forward inline

**Files:**
- Modify: `/home/ardent/mlrunner/ci/serve_model.py`
- Test: `/home/ardent/mlrunner/tests/unit/test_serve_model.py` (create)

- [ ] **Step 1: Write the failing tests** (create `tests/unit/test_serve_model.py`)

```python
"""Unit tests for the pure arg-building helpers in ci/serve_model.py.

serve_model.py is a standalone script; its only import-time dependency is
`from mlrunner import Server, ServerSpec` (mlrunner is installed in dev), so we
load it by path like test_serve_bootstrap does and exercise the helpers that
decide what reaches the remote serve_bootstrap process.
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

_SM_PATH = Path(__file__).resolve().parents[2] / "ci" / "serve_model.py"


@pytest.fixture(scope="module")
def sm():
    spec = importlib.util.spec_from_file_location("serve_model", _SM_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_build_args_without_config(sm):
    args = sm.build_bootstrap_args("hf://x/y", "run-1")
    assert args == ("--model-url", "hf://x/y", "--run-id", "run-1")


def test_build_args_extracts_inference_subobject(sm, tmp_path):
    p = tmp_path / "inference_config.json"
    p.write_text('{"inference": {"temperature": 0.7}, "deploy": {"modelRunId": "r"}}')
    args = sm.build_bootstrap_args("hf://x/y", "run-1", str(p))
    i = args.index("--inference-config")
    assert json.loads(args[i + 1]) == {"temperature": 0.7}  # only the inference part


def test_build_args_accepts_bare_config(sm, tmp_path):
    p = tmp_path / "c.json"
    p.write_text('{"temperature": 0.5}')
    args = sm.build_bootstrap_args("hf://x/y", "run-1", str(p))
    i = args.index("--inference-config")
    assert json.loads(args[i + 1]) == {"temperature": 0.5}


def test_build_args_omits_when_inference_empty(sm, tmp_path):
    p = tmp_path / "c.json"
    p.write_text('{"inference": {}, "deploy": {"x": 1}}')
    args = sm.build_bootstrap_args("hf://x/y", "run-1", str(p))
    assert "--inference-config" not in args


def test_build_args_ignores_null_literal(sm):
    args = sm.build_bootstrap_args("hf://x/y", "run-1", "null")
    assert "--inference-config" not in args


def test_build_args_ignores_missing_file(sm, tmp_path):
    args = sm.build_bootstrap_args("hf://x/y", "run-1", str(tmp_path / "nope.json"))
    assert "--inference-config" not in args
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /home/ardent/mlrunner && python3 -m pytest tests/unit/test_serve_model.py -q`
Expected: FAIL — `AttributeError: module 'serve_model' has no attribute 'build_bootstrap_args'`.

- [ ] **Step 3: Implement the helpers** — in `ci/serve_model.py`, add `import json` to the imports, then add these top-level functions (e.g. just after `def emit(...)`):

```python
def _read_inference_config(path):
    """Return the inference config as a compact one-line JSON string, or "" when
    none is usable.

    The Deploy stage records the config wrapped with metadata:
        {"inference": {<generation params>}, "deploy": {<metadata>}}
    Serving needs only the generation params, so unwrap the "inference"
    sub-object (tolerating a bare config object too). Missing path, the Harness
    "null" literal, a missing file, or an empty config all mean "serve with
    defaults"."""
    if not path or path.strip().lower() == "null":
        return ""
    p = path.strip()
    if not os.path.isfile(p):
        sys.stderr.write(f"INFERENCE_CONFIG_PATH={p!r} not found; serving with defaults.\n")
        return ""
    with open(p) as f:
        data = json.load(f)                       # validates it's real JSON
    cfg = data.get("inference", data) if isinstance(data, dict) else data
    if not cfg:
        return ""
    return json.dumps(cfg, separators=(",", ":"))


def build_bootstrap_args(model_url, run_id, inference_config_path=None):
    """Args for ci/serve_bootstrap.py on the remote.

    The remote runtime is a SEPARATE filesystem, so the only channel for the
    config is the command line: read the recorded file here (on the delegate) and
    pass its inference params inline. No/empty config -> omit the flag so behavior
    is unchanged."""
    args = ["--model-url", model_url, "--run-id", run_id]
    raw = _read_inference_config(inference_config_path)
    if raw:
        args += ["--inference-config", raw]
    return tuple(args)
```

- [ ] **Step 4: Wire `main()` to use it** — replace the `run_python_file(...)` call's `args=(...)`:

```python
    model_url = os.environ["MODEL_URL"]
    run_id = os.environ.get("RUN_ID", "unknown")
    inference_config_path = os.environ.get("INFERENCE_CONFIG_PATH", "")
```

and

```python
        job = server.run_python_file(
            "ci/serve_bootstrap.py",
            args=build_bootstrap_args(model_url, run_id, inference_config_path),
        )
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd /home/ardent/mlrunner && python3 -m pytest tests/unit/test_serve_model.py -q`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
cd /home/ardent/mlrunner
git add ci/serve_model.py tests/unit/test_serve_model.py
git commit -m "serve_model: forward INFERENCE_CONFIG_PATH inline to the remote bootstrap"
```

---

### Task A4: Consume the config in the served apps (APP_CODE_HF / APP_CODE_FILE)

**Files:**
- Modify: `/home/ardent/mlrunner/ci/serve_bootstrap.py` (the `APP_CODE_HF` and `APP_CODE_FILE` string constants)
- Test: `/home/ardent/mlrunner/tests/unit/test_serve_bootstrap.py` (append wiring assertions)

> The app strings run on the remote with torch/fastapi and can't be exec'd in unit tests, so the merge **semantics** are already covered by `resolve_generation_kwargs` (Task A1). Here we add **wiring assertions** that the embedded apps actually read `MODEL_INFERENCE_CONFIG` and apply the recognised keys, so the wiring can't be silently dropped.

- [ ] **Step 1: Write the failing wiring tests** (append to `tests/unit/test_serve_bootstrap.py`)

```python
def test_hf_app_reads_inference_config(sb):
    code = sb.APP_CODE_HF
    assert "MODEL_INFERENCE_CONFIG" in code
    assert "import os, sys, json" in code          # json available in the app
    # request body fields exist for per-call overrides of the recognised keys
    for key in ("temperature", "top_p", "max_new_tokens"):
        assert key in code
    assert "inference_config" in code              # surfaced in /health


def test_file_app_passes_config_through(sb):
    code = sb.APP_CODE_FILE
    assert "MODEL_INFERENCE_CONFIG" in code
    assert "inference_config" in code              # surfaced in /health
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /home/ardent/mlrunner && python3 -m pytest tests/unit/test_serve_bootstrap.py -q -k inference`
Expected: FAIL on `test_hf_app_reads_inference_config` / `test_file_app_passes_config_through`.

- [ ] **Step 3: Update `APP_CODE_HF`** — make these edits inside the triple-quoted string:

Imports line — add `json`:
```python
import os, sys, json, traceback, torch
```

After `REPO = os.environ["MODEL_REF"]`, add config parsing:
```python
REPO = os.environ["MODEL_REF"]
# Inference config (generation defaults) passed in via --inference-config; flat
# keys. Mirrors serve_bootstrap.GENERATION_PARAM_KEYS / resolve_generation_kwargs
# (the tested reference for this merge).
_CFG = json.loads(os.environ.get("MODEL_INFERENCE_CONFIG", "") or "{}")
_GEN_KEYS = ("max_new_tokens", "temperature", "top_p", "top_k",
             "repetition_penalty", "do_sample")
_SYSTEM_PROMPT = _CFG.get("system_prompt")
_M = {}
```

Replace the `Req` model so per-request overrides are optional:
```python
class Req(BaseModel):
    prompt: str
    max_new_tokens: int | None = None
    temperature: float | None = None
    top_p: float | None = None
    top_k: int | None = None
    repetition_penalty: float | None = None
    do_sample: bool | None = None
```

Replace the `/health` body to surface the active config:
```python
@app.get("/health")
def health():
    return {"ok": "model" in _M, "repo": REPO,
            "build": os.environ.get("MODEL_BUILD", ""),
            "slug": os.environ.get("MODEL_SLUG", ""),
            "inference_config": _CFG, **_device_info()}
```

Replace `/generate` to merge config defaults with request overrides:
```python
@app.post("/generate")
def generate(req: Req):
    tok, model = _M["tok"], _M["model"]
    messages = []
    if _SYSTEM_PROMPT:
        messages.append({"role": "system", "content": _SYSTEM_PROMPT})
    messages.append({"role": "user", "content": req.prompt})
    text = tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    inputs = tok(text, return_tensors="pt").to(model.device)
    # config defaults, then per-request overrides (None = not supplied).
    gen = {k: _CFG[k] for k in _GEN_KEYS if _CFG.get(k) is not None}
    req_over = req.dict(exclude={"prompt"})
    for k in _GEN_KEYS:
        if req_over.get(k) is not None:
            gen[k] = req_over[k]
    gen.setdefault("max_new_tokens", 256)
    with torch.no_grad():
        out = model.generate(**inputs, **gen)
    out_ids = out[0][inputs["input_ids"].shape[1]:]
    return {"output": tok.decode(out_ids, skip_special_tokens=True)}
```

- [ ] **Step 4: Update `APP_CODE_FILE`** — pass the config through for the user's `predict()`:

Imports line — add `json`:
```python
import os, json, traceback
```

After `_MODEL = {"weights": None}`, add:
```python
_MODEL = {"weights": None}
# Inference config available to your custom predict(); no enforced schema.
_CFG = json.loads(os.environ.get("MODEL_INFERENCE_CONFIG", "") or "{}")
```

Replace the `/health` body:
```python
@app.get("/health")
def health():
    return {"ok": _MODEL["weights"] is not None,
            "build": os.environ.get("MODEL_BUILD", ""),
            "slug": os.environ.get("MODEL_SLUG", ""),
            "inference_config": _CFG}
```

- [ ] **Step 5: Run the wiring tests to verify they pass**

Run: `cd /home/ardent/mlrunner && python3 -m pytest tests/unit/test_serve_bootstrap.py -q`
Expected: PASS (all serve_bootstrap tests).

- [ ] **Step 6: Run the full mlrunner unit suite (no regressions)**

Run: `cd /home/ardent/mlrunner && python3 -m pytest tests/unit -q`
Expected: PASS (existing tests + new serve_model/serve_bootstrap tests).

- [ ] **Step 7: Commit**

```bash
cd /home/ardent/mlrunner
git add ci/serve_bootstrap.py tests/unit/test_serve_bootstrap.py
git commit -m "serve_bootstrap: apply inference config in served apps + /health"
```

---

# Part B — model-cd pipeline (pipelines repo)

> All Part B work is in `/home/ardent/pipelines` on `shifu/model-cd/pipeline.yaml`. There is no Harness-side test harness locally, so each task uses a PyYAML structural check as its "test": run the check (fails → feature absent), edit the YAML, run the check (passes), commit. Run every check from `/home/ardent/pipelines`.

### Task B1: Add `inferenceConfigJson` variable, Deploy `sharedPaths`, and `CloneMlpipe`

**Files:**
- Modify: `shifu/model-cd/pipeline.yaml`

- [ ] **Step 1: Write the failing check** — run this verifier:

```bash
cd /home/ardent/pipelines && python3 - <<'PY'
import yaml, sys
d = yaml.safe_load(open("shifu/model-cd/pipeline.yaml"))
p = d["pipeline"]
vars_ = {v["name"]: v for v in p["variables"]}
deploy = next(s["stage"] for s in p["stages"] if s.get("stage", {}).get("identifier") == "Deploy")
spec = deploy["spec"]
steps = [s["step"] for s in spec["execution"]["steps"]]
ids = [s["identifier"] for s in steps]
assert "inferenceConfigJson" in vars_, "missing inferenceConfigJson variable"
assert '<+input>.default("{}")' in str(vars_["inferenceConfigJson"]["value"]), "wrong default"
assert "/tmp/shared" in (spec.get("sharedPaths") or []), "Deploy stage missing sharedPaths /tmp/shared"
assert ids[0] == "CloneMlpipe", f"first Deploy step should be CloneMlpipe, got {ids[0]}"
cm = steps[0]["spec"]
assert cm.get("cloneDirectory") == "/tmp/shared/mlpipe", "CloneMlpipe cloneDirectory wrong"
print("OK B1")
PY
```

Expected: FAIL (`AssertionError: missing inferenceConfigJson variable`).

- [ ] **Step 2: Add the pipeline variable** — under `pipeline.variables`, add (e.g. after `modelRunId`):

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

- [ ] **Step 3: Add `sharedPaths` to the Deploy stage** — under the Deploy stage `spec:` (alongside `cloneCodebase: true` / `delegateSelectors:`):

```yaml
        spec:
          cloneCodebase: true
          delegateSelectors:
            - linux-amd64
          sharedPaths:
            - /tmp/shared
```

- [ ] **Step 4: Add `CloneMlpipe` as the first Deploy step** — make it the first entry under `execution.steps` (before `InitAndTest`):

```yaml
              - step:
                  identifier: CloneMlpipe
                  name: Clone mlpipe
                  type: GitClone
                  spec:
                    connectorRef: githubconnector
                    repoName: mlpipe
                    build:
                      type: tag
                      spec:
                        tag: v0.3.8
                    cloneDirectory: /tmp/shared/mlpipe
```

- [ ] **Step 5: Run the check to verify it passes**

Run: the same heredoc from Step 1.
Expected: prints `OK B1`.

- [ ] **Step 6: Commit**

```bash
cd /home/ardent/pipelines
git add shifu/model-cd/pipeline.yaml
git commit -m "model-cd: add inferenceConfigJson var, Deploy sharedPaths + CloneMlpipe"
```

---

### Task B2: Add the `ApplyInferenceConfig` step

**Files:**
- Modify: `shifu/model-cd/pipeline.yaml`

- [ ] **Step 1: Write the failing check**

```bash
cd /home/ardent/pipelines && python3 - <<'PY'
import yaml
d = yaml.safe_load(open("shifu/model-cd/pipeline.yaml"))
p = d["pipeline"]
deploy = next(s["stage"] for s in p["stages"] if s.get("stage", {}).get("identifier") == "Deploy")
steps = {s["step"]["identifier"]: s["step"] for s in deploy["spec"]["execution"]["steps"]}
order = [s["step"]["identifier"] for s in deploy["spec"]["execution"]["steps"]]
assert "ApplyInferenceConfig" in steps, "missing ApplyInferenceConfig step"
st = steps["ApplyInferenceConfig"]
outs = {o["name"] for o in st["spec"].get("outputVariables", [])}
assert {"config_applied", "inference_config_path", "auto_branch", "auto_commit_sha"} <= outs, outs
env = st["spec"]["envVariables"]
assert env["INFERENCE_CONFIG_JSON"] == "<+pipeline.variables.inferenceConfigJson>"
assert 'GITHUB_APP_PRIVATE_KEY' in str(env)
assert order.index("ApplyInferenceConfig") < order.index("FetchModel"), "must run before FetchModel"
assert order.index("InitAndTest") < order.index("ApplyInferenceConfig"), "must run after InitAndTest"
print("OK B2")
PY
```

Expected: FAIL (`AssertionError: missing ApplyInferenceConfig step`).

- [ ] **Step 2: Insert the step** — add this step **after `InitAndTest` and before `FetchModel`**:

```yaml
              - step:
                  identifier: ApplyInferenceConfig
                  name: Apply Inference Config
                  type: Run
                  spec:
                    connectorRef: dockerhubconnector
                    image: python:3.11-slim
                    shell: Bash
                    envVariables:
                      INFERENCE_CONFIG_JSON: <+pipeline.variables.inferenceConfigJson>
                      HARNESS_EXECUTION_ID: <+pipeline.executionId>
                      REPO_URL: <+codebase.repoUrl>
                      MODEL_RUN_ID: <+pipeline.variables.modelRunId>
                      MODEL_SOURCE: <+pipeline.variables.modelSource>
                      HF_REPO_ID: <+pipeline.variables.hfRepoId>
                      DEPLOY_TARGET: <+pipeline.variables.deployTarget>
                      GH_CLIENT_ID: <+secrets.getValue("GITHUB_APP_CLIENT_ID")>
                      GH_APP_INSTALLATION_ID: <+secrets.getValue("GITHUB_APP_INSTALLATION_ID")>
                      GH_APP_PRIVATE_KEY: <+secrets.getValue("GITHUB_APP_PRIVATE_KEY")>
                    command: |
                      set -euo pipefail
                      export GIT_TERMINAL_PROMPT=0
                      rm -f /tmp/.harness_outputs.env
                      apt-get update -qq && apt-get install -y -qq git >/dev/null
                      pip install --quiet /tmp/shared/mlpipe[ci]

                      # Strip wrapping quotes Harness's .default("...") leaves embedded.
                      export INFERENCE_CONFIG_JSON="${INFERENCE_CONFIG_JSON%\"}"
                      export INFERENCE_CONFIG_JSON="${INFERENCE_CONFIG_JSON#\"}"

                      # Empty / "{}" / Harness "null" literal => no config, no record.
                      CFG="${INFERENCE_CONFIG_JSON:-}"
                      [ "$CFG" = "null" ] && CFG=""
                      CFG_TRIMMED="$(printf '%s' "$CFG" | tr -d '[:space:]')"
                      if [ -z "$CFG_TRIMMED" ] || [ "$CFG_TRIMMED" = "{}" ]; then
                        echo "No inference config supplied — serving with defaults."
                        {
                          echo "config_applied=false"
                          echo "inference_config_path="
                          echo "auto_branch="
                          echo "auto_commit_sha="
                        } >> /tmp/.harness_outputs.env
                        set -a; . /tmp/.harness_outputs.env; set +a
                        exit 0
                      fi

                      # Validate JSON and write the recorded artifact (config + metadata).
                      CONFIG_PATH="$(pwd)/inference_config.json"
                      python - "$CONFIG_PATH" <<'PY'
                      import json, os, sys
                      cfg = json.loads(os.environ["INFERENCE_CONFIG_JSON"])  # aborts on bad JSON
                      doc = {
                          "inference": cfg,
                          "deploy": {
                              "modelRunId":   os.environ.get("MODEL_RUN_ID", ""),
                              "modelSource":  os.environ.get("MODEL_SOURCE", ""),
                              "hfRepoId":     os.environ.get("HF_REPO_ID", ""),
                              "deployTarget": os.environ.get("DEPLOY_TARGET", ""),
                              "executionId":  os.environ.get("HARNESS_EXECUTION_ID", ""),
                          },
                      }
                      with open(sys.argv[1], "w") as f:
                          json.dump(doc, f, indent=2, sort_keys=True)
                          f.write("\n")
                      print(f"wrote {sys.argv[1]}")
                      PY

                      GH_TOKEN="$(python -m mlpipe.ci.mint_gh_token)"
                      git config user.email "ml-ci@atardent.noreply"
                      git config user.name  "mlpipe-ci"

                      BRANCH="auto/deploy-${HARNESS_EXECUTION_ID}"
                      git checkout -b "${BRANCH}"
                      git add inference_config.json
                      git commit -m "Inference config for deploy ${HARNESS_EXECUTION_ID}"
                      COMMIT_SHA="$(git rev-parse HEAD)"

                      REPO_NO_SCHEME="${REPO_URL#https://}"
                      AUTHED_URL="https://x-access-token:${GH_TOKEN}@${REPO_NO_SCHEME}"
                      git push "${AUTHED_URL}" "${BRANCH}"

                      {
                        echo "config_applied=true"
                        echo "inference_config_path=${CONFIG_PATH}"
                        echo "auto_branch=${BRANCH}"
                        echo "auto_commit_sha=${COMMIT_SHA}"
                      } >> /tmp/.harness_outputs.env
                      set -a; . /tmp/.harness_outputs.env; set +a
                      echo "✓ recorded inference config on ${BRANCH} (${COMMIT_SHA})"
                    outputVariables:
                      - name: config_applied
                      - name: inference_config_path
                      - name: auto_branch
                      - name: auto_commit_sha
```

> **Indentation note:** the inner `python - "$CONFIG_PATH" <<'PY' ... PY` heredoc body must start at column 0 inside the rendered shell script. Harness strips the YAML block-scalar indentation uniformly, so keep the heredoc body left-aligned relative to the rest of the `command:` block exactly as shown (all `command:` lines share the same indent; the heredoc lines are dedented to match the script, not the YAML). If unsure, verify by running the rendered command locally (see Task B5 dry-run).

- [ ] **Step 3: Run the check to verify it passes**

Run: the heredoc from Step 1.
Expected: prints `OK B2`.

- [ ] **Step 4: Commit**

```bash
cd /home/ardent/pipelines
git add shifu/model-cd/pipeline.yaml
git commit -m "model-cd: ApplyInferenceConfig step (record config to auto/deploy branch)"
```

---

### Task B3: Pass `INFERENCE_CONFIG_PATH` to the Serve steps

**Files:**
- Modify: `shifu/model-cd/pipeline.yaml`

- [ ] **Step 1: Write the failing check**

```bash
cd /home/ardent/pipelines && python3 - <<'PY'
import yaml
d = yaml.safe_load(open("shifu/model-cd/pipeline.yaml"))
p = d["pipeline"]
deploy = next(s["stage"] for s in p["stages"] if s.get("stage", {}).get("identifier") == "Deploy")
steps = {s["step"]["identifier"]: s["step"] for s in deploy["spec"]["execution"]["steps"]}
expr = "<+steps.ApplyInferenceConfig.output.outputVariables.inference_config_path>"
for sid in ("ServeColab", "ServeSpheron"):
    env = steps[sid]["spec"]["envVariables"]
    assert env.get("INFERENCE_CONFIG_PATH") == expr, f"{sid} missing INFERENCE_CONFIG_PATH"
print("OK B3")
PY
```

Expected: FAIL (`AssertionError: ServeColab missing INFERENCE_CONFIG_PATH`).

- [ ] **Step 2: Add the env var to `ServeColab`** — in its `envVariables:` map, add:

```yaml
                      INFERENCE_CONFIG_PATH: <+steps.ApplyInferenceConfig.output.outputVariables.inference_config_path>
```

- [ ] **Step 3: Add the same env var to `ServeSpheron`** — in its `envVariables:` map, add the identical line:

```yaml
                      INFERENCE_CONFIG_PATH: <+steps.ApplyInferenceConfig.output.outputVariables.inference_config_path>
```

- [ ] **Step 4: Run the check to verify it passes**

Run: the heredoc from Step 1.
Expected: prints `OK B3`.

- [ ] **Step 5: Commit**

```bash
cd /home/ardent/pipelines
git add shifu/model-cd/pipeline.yaml
git commit -m "model-cd: pass INFERENCE_CONFIG_PATH into ServeColab/ServeSpheron"
```

---

### Task B4: Add the `TagDeploy` step

**Files:**
- Modify: `shifu/model-cd/pipeline.yaml`

- [ ] **Step 1: Write the failing check**

```bash
cd /home/ardent/pipelines && python3 - <<'PY'
import yaml
d = yaml.safe_load(open("shifu/model-cd/pipeline.yaml"))
p = d["pipeline"]
deploy = next(s["stage"] for s in p["stages"] if s.get("stage", {}).get("identifier") == "Deploy")
order = [s["step"]["identifier"] for s in deploy["spec"]["execution"]["steps"]]
steps = {s["step"]["identifier"]: s["step"] for s in deploy["spec"]["execution"]["steps"]}
assert "TagDeploy" in steps, "missing TagDeploy step"
st = steps["TagDeploy"]
cond = st["when"]["condition"]
assert "config_applied" in cond and '== "true"' in cond, cond
assert st["when"]["stageStatus"] == "Success"
assert order[-1] == "TagDeploy", f"TagDeploy should be last, order={order}"
env = st["spec"]["envVariables"]
assert env["AUTO_COMMIT_SHA"] == "<+steps.ApplyInferenceConfig.output.outputVariables.auto_commit_sha>"
print("OK B4")
PY
```

Expected: FAIL (`AssertionError: missing TagDeploy step`).

- [ ] **Step 2: Append the step** — add as the **last** step under the Deploy stage `execution.steps` (after `ServeSpheron`):

```yaml
              - step:
                  identifier: TagDeploy
                  name: Tag Deploy
                  type: Run
                  when:
                    stageStatus: Success
                    condition: <+steps.ApplyInferenceConfig.output.outputVariables.config_applied> == "true"
                  spec:
                    connectorRef: dockerhubconnector
                    image: python:3.11-slim
                    shell: Bash
                    envVariables:
                      GH_CLIENT_ID: <+secrets.getValue("GITHUB_APP_CLIENT_ID")>
                      GH_APP_INSTALLATION_ID: <+secrets.getValue("GITHUB_APP_INSTALLATION_ID")>
                      GH_APP_PRIVATE_KEY: <+secrets.getValue("GITHUB_APP_PRIVATE_KEY")>
                      REPO_URL: <+codebase.repoUrl>
                      EXECUTION_ID: <+pipeline.executionId>
                      AUTO_COMMIT_SHA: <+steps.ApplyInferenceConfig.output.outputVariables.auto_commit_sha>
                    command: |
                      set -euo pipefail
                      export GIT_TERMINAL_PROMPT=0
                      apt-get update -qq && apt-get install -y -qq git >/dev/null
                      pip install --quiet /tmp/shared/mlpipe[ci]
                      GH_TOKEN="$(python -m mlpipe.ci.mint_gh_token)"
                      git config user.email "ml-ci@atardent.noreply"
                      git config user.name  "mlpipe-ci"
                      TAG="deploy-${EXECUTION_ID}"
                      REPO_NO_SCHEME="${REPO_URL#https://}"
                      AUTHED_URL="https://x-access-token:${GH_TOKEN}@${REPO_NO_SCHEME}"
                      # Idempotent: skip if the tag already exists on origin.
                      if git ls-remote --tags "${AUTHED_URL}" "refs/tags/${TAG}" | grep -q "${TAG}"; then
                        echo "tag ${TAG} already exists on origin — nothing to do."
                        exit 0
                      fi
                      git tag -a "${TAG}" "${AUTO_COMMIT_SHA}" -m "Deploy ${EXECUTION_ID}"
                      git push "${AUTHED_URL}" "${TAG}"
                      echo "✓ tagged ${TAG} → ${AUTO_COMMIT_SHA}"
```

- [ ] **Step 3: Run the check to verify it passes**

Run: the heredoc from Step 1.
Expected: prints `OK B4`.

- [ ] **Step 4: Commit**

```bash
cd /home/ardent/pipelines
git add shifu/model-cd/pipeline.yaml
git commit -m "model-cd: TagDeploy step (deploy-<execId> tag on a live endpoint)"
```

---

### Task B5: Update description + full-pipeline validation

**Files:**
- Modify: `shifu/model-cd/pipeline.yaml` (the top-level `description`)

- [ ] **Step 1: Append to the pipeline `description`** — add a paragraph at the end of the existing `pipeline.description` block:

```
    Inference config: set inferenceConfigJson (a JSON object of generation
    settings) to record it on an auto/deploy-<execId> branch, tag the deploy
    (deploy-<execId>) when the endpoint goes live, and apply it to serving
    (forwarded to serve_model.py -> serve_bootstrap.py -> the FastAPI app).
    Empty / "{}" → serve with built-in defaults, no branch/tag created.
```

- [ ] **Step 2: Run the full structural + syntax validation**

```bash
cd /home/ardent/pipelines && python3 - <<'PY'
import yaml
d = yaml.safe_load(open("shifu/model-cd/pipeline.yaml"))           # syntax OK
p = d["pipeline"]
vars_ = {v["name"] for v in p["variables"]}
deploy = next(s["stage"] for s in p["stages"] if s.get("stage", {}).get("identifier") == "Deploy")
order = [s["step"]["identifier"] for s in deploy["spec"]["execution"]["steps"]]
assert "inferenceConfigJson" in vars_
assert order == ["CloneMlpipe", "InitAndTest", "ApplyInferenceConfig",
                 "FetchModel", "ServeColab", "ServeSpheron", "TagDeploy"], order
assert "/tmp/shared" in deploy["spec"]["sharedPaths"]
print("OK full pipeline:", order)
PY
```

Expected: prints `OK full pipeline: [...]` with the steps in that exact order.

- [ ] **Step 3 (optional but recommended): Render-and-lint the ApplyInferenceConfig command locally** — confirm the embedded heredoc indentation survives. Extract the `command:` block and shell-check it:

```bash
cd /home/ardent/pipelines && python3 - <<'PY'
import yaml, subprocess, tempfile, os
d = yaml.safe_load(open("shifu/model-cd/pipeline.yaml"))
deploy = next(s["stage"] for s in d["pipeline"]["stages"] if s["stage"]["identifier"] == "Deploy")
steps = {s["step"]["identifier"]: s["step"] for s in deploy["spec"]["execution"]["steps"]}
cmd = steps["ApplyInferenceConfig"]["spec"]["command"]
f = tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False)
f.write(cmd); f.close()
print(subprocess.run(["bash", "-n", f.name]).returncode == 0 and "bash -n OK" or "bash -n FAILED")
os.unlink(f.name)
PY
```

Expected: `bash -n OK` (syntax of the rendered script is valid).

- [ ] **Step 4: Commit**

```bash
cd /home/ardent/pipelines
git add shifu/model-cd/pipeline.yaml
git commit -m "model-cd: document inferenceConfigJson in the pipeline description"
```

---

## Final Verification

- [ ] **mlrunner unit suite green:**

```bash
cd /home/ardent/mlrunner && python3 -m pytest tests/unit -q
```
Expected: all pass.

- [ ] **model-cd pipeline structurally valid** (Task B5 Step 2 prints the expected step order).

- [ ] **End-to-end (manual, in Harness — not scriptable here):** run model-cd with a non-empty `inferenceConfigJson` (e.g. `{"max_new_tokens": 64, "temperature": 0.7}`) against an owned/public model and confirm:
  1. an `auto/deploy-<execId>` branch with `inference_config.json` appears in the codebase repo;
  2. a `deploy-<execId>` tag is pushed after the endpoint goes live;
  3. the endpoint's `GET /health` reports the `inference_config`;
  4. a run with empty `inferenceConfigJson` creates no branch/tag and serves as before.

---

## Self-Review notes (author)

- **Spec coverage:** new variable (B1) ✓; git commit to `auto/deploy-<execId>` (B2) ✓; `deploy-<execId>` tag on success, idempotent (B4) ✓; consumed by serving via file→inline-arg→env (A2/A3/A4) ✓; GitHub App auth via `mint_gh_token` + CloneMlpipe (B1/B2/B4) ✓; backward-compatible no-op on empty config (A3 `_read_inference_config`, B2 early-exit) ✓; mlrunner serve_model/serve_bootstrap/app changes (A1–A4) ✓.
- **Refinement over spec:** the recorded file wraps config as `{"inference": ..., "deploy": ...}`; serving extracts the `inference` sub-object so the app sees flat keys (documented in File Structure + A3).
- **Naming consistency:** `GENERATION_PARAM_KEYS`/`_GEN_KEYS`, `build_bootstrap_args`, `_read_inference_config`, `apply_inference_config_env`, `resolve_generation_kwargs`, outputs `config_applied`/`inference_config_path`/`auto_branch`/`auto_commit_sha`, env `INFERENCE_CONFIG_PATH`/`MODEL_INFERENCE_CONFIG` — used identically across tasks.
- **Known limitation:** app-string behavior is guarded by wiring assertions (A4) plus the tested reference helper (A1), not by executing the remote app (torch/fastapi unavailable in unit tests); real generation is exercised by the existing startup smoke test on the remote during a live deploy.
