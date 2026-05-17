#!/usr/bin/env python3
"""README Steps 6 + 7 — The supervisor.

Runs as a single synchronous Run step in the Train stage. While training
executes on the provider machine (Colab / Thunder / AWS via mlrunner),
this script polls three things in a loop:

  1. The training Job's status (via the mlrunner Server handle)
  2. Spot revocation signals (best-effort, backend-specific)
  3. The sibling ApprovalGate stage's status (via the Harness REST API)

The first event to reach a terminal state wins. Mapping to README Step 7:

  Approver clicks Approve  → Server.interrupt(job)  → "approved"      (7.2)
  Approver clicks Reject   → Server.kill()          → "rejected"      (7.3)
  Backend reclaims VM      → emergency save attempt → "spot_revoked"  (7.4)
  Job finishes on its own  → nothing extra          → "completed"     (7.1)
  Anything else fails      → log + status           → "failed"

────────────────────────────────────────────────────────────────────────
Contract for the user's `scripts/main.py`
────────────────────────────────────────────────────────────────────────
- Must handle SIGINT and save a checkpoint before exiting (7.2 path).
  Hugging Face Trainer and PyTorch Lightning do this by default.
- Must handle SIGTERM for spot revocation (per training-template README).
- Must accept --train, --val, --test, --config, --run-id, --resume-from
  as command-line arguments.
- Must write its checkpoint under /shared/checkpoints/<run_id>/last
  (otherwise update `find_checkpoint` below).

────────────────────────────────────────────────────────────────────────
Reads
────────────────────────────────────────────────────────────────────────
  /shared/manifest.json
  /shared/server_state.json    {instance_id, backend, spec, backend_config}
  Env:
    SPLITS_DIR, RESUME_FROM, RUN_ID
    WANDB_API_KEY                                  (optional)
    HARNESS_API_TOKEN                              (required for approval polling)
    HARNESS_EXECUTION_ID, HARNESS_ACCOUNT_ID,
    HARNESS_ORG_ID, HARNESS_PROJECT_ID,
    APPROVAL_STAGE_ID

────────────────────────────────────────────────────────────────────────
Writes
────────────────────────────────────────────────────────────────────────
  /shared/training_status.json
    {
      "state": "completed" | "approved" | "rejected" | "spot_revoked" | "failed",
      "exit_code": int,
      "checkpoint": "/absolute/path/or/empty"
    }
"""
from __future__ import annotations
import json
import logging
import os
import pathlib
import subprocess
import sys
import time
from typing import Optional


# ── Tunables ─────────────────────────────────────────────────────────────
POLL_INTERVAL_S = 30          # how often the loop fires
INTERRUPT_GRACE_S = 300       # 5 min for graceful save after SIGINT
SPOT_GRACE_S = 60             # 1 min to flush on spot revocation
STATUS_FILE = "/shared/training_status.json"
CHECKPOINT_ROOT = "/shared/checkpoints"
HARNESS_API_BASE = "https://app.harness.io/gateway/pipeline/api"


# ── Dependency bootstrap ─────────────────────────────────────────────────
def _ensure_deps() -> None:
    """Install runtime deps. Idempotent — pip skips already-installed."""
    subprocess.check_call([
        sys.executable, "-m", "pip", "install", "-q",
        "mlrunner[colab,skypilot-aws]",
        "requests",
        "wandb",
    ])


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s [supervisor] %(message)s",
    )
    log = logging.getLogger(__name__)
    _ensure_deps()

    # Import after install so first-run works in a fresh container.
    import mlrunner
    from mlrunner import Server, ServerSpec, get_backend, JobStatus

    manifest = json.load(open("/shared/manifest.json"))
    server_state = json.load(open("/shared/server_state.json"))

    # Re-attach to the Server provisioned in Step4ProvisionBackend.
    # mlrunner doesn't expose a public "reattach"; we construct a fresh
    # Server and seat the existing instance_id. This works because Server
    # holds no significant local state beyond _instance_id and _backend.
    backend = get_backend(server_state["backend"], **server_state.get("backend_config", {}))
    spec = ServerSpec(**server_state["spec"])
    server = Server(backend, spec, auto_teardown=False)
    server._instance_id = server_state["instance_id"]
    log.info("attached to %s instance %s", server_state["backend"], server._instance_id)

    # Submit training. The user's scripts/main.py runs on the provider machine.
    args = _build_training_args()
    log.info("submitting scripts/main.py args=%s", args)
    job = server.run_python_file("scripts/main.py", args=tuple(args))

    state, checkpoint = "failed", ""
    try:
        state, checkpoint = _poll_loop(server, job, manifest, log, JobStatus)
    except Exception as e:
        log.exception("supervisor crashed: %s", e)
        state, checkpoint = "failed", ""
    finally:
        _write_status(state, job, checkpoint)
        log.info("final state=%s checkpoint=%s", state, checkpoint or "<none>")

    return 0


# ─────────────────────────────────────────────────────────────────────────
# Polling loop
# ─────────────────────────────────────────────────────────────────────────
def _poll_loop(server, job, manifest, log, JobStatus) -> tuple[str, str]:
    """Returns (state, checkpoint_path). One of the 5 terminal states."""
    import requests
    from mlrunner.core.exceptions import BackendError

    wandb_run = _init_wandb(manifest, log)
    terminal = {JobStatus.COMPLETED, JobStatus.FAILED, JobStatus.INTERRUPTED}

    while True:
        # ── 1. Training job status (authoritative) ──
        if job.status in terminal:
            if job.status == JobStatus.COMPLETED:
                return "completed", _find_checkpoint()
            if job.status == JobStatus.INTERRUPTED:
                # We didn't ask for an interrupt and no approval fired —
                # treat as failure rather than approval.
                return "failed", _find_checkpoint()
            return "failed", ""

        # ── 2. Spot revocation / backend unreachable ──
        stats = None
        try:
            stats = server.stats()
        except (BackendError, ConnectionError, requests.RequestException) as e:
            log.warning("backend unreachable (%s) — assuming spot revocation", e)
            _emergency_save(server, job, log)
            return "spot_revoked", _find_checkpoint()

        # ── 3. Approval status (parallel sibling stage) ──
        approval = _check_harness_approval(log)
        if approval == "APPROVED":
            log.info("approval received — Server.interrupt(job)")
            server.interrupt(job)
            try:
                job.wait(timeout=INTERRUPT_GRACE_S)
            except TimeoutError:
                log.warning("graceful interrupt exceeded %ds — Server.kill()",
                            INTERRUPT_GRACE_S)
                server.kill()
            return "approved", _find_checkpoint()
        if approval == "REJECTED":
            log.info("rejection received — Server.kill()")
            server.kill()
            return "rejected", ""

        # ── 4. Stream metrics ──
        if wandb_run and stats:
            _log_metrics(wandb_run, stats, log)

        time.sleep(POLL_INTERVAL_S)


# ─────────────────────────────────────────────────────────────────────────
# Harness approval polling
# ─────────────────────────────────────────────────────────────────────────
def _check_harness_approval(log) -> Optional[str]:
    """Returns 'APPROVED', 'REJECTED', or None if still pending / unreachable.

    Hits the Harness "pipeline execution detail" endpoint and inspects the
    status of the stage whose identifier matches APPROVAL_STAGE_ID.
    """
    import requests

    token = os.environ.get("HARNESS_API_TOKEN")
    if not token:
        return None

    url = f"{HARNESS_API_BASE}/pipelines/execution/v2/{os.environ['HARNESS_EXECUTION_ID']}"
    params = {
        "accountIdentifier": os.environ["HARNESS_ACCOUNT_ID"],
        "orgIdentifier":     os.environ["HARNESS_ORG_ID"],
        "projectIdentifier": os.environ["HARNESS_PROJECT_ID"],
    }
    try:
        r = requests.get(url, headers={"x-api-key": token},
                         params=params, timeout=10)
        r.raise_for_status()
        data = r.json()
    except requests.RequestException as e:
        log.warning("Harness API unreachable: %s", e)
        return None

    nodes = (
        data.get("data", {})
            .get("pipelineExecutionSummary", {})
            .get("layoutNodeMap", {})
    )
    target = os.environ.get("APPROVAL_STAGE_ID", "ApprovalGate")

    for node in nodes.values():
        if node.get("identifier") != target:
            continue
        status = node.get("status", "")
        # Harness stage statuses:
        #   NotStarted / Queued / Running / Paused → still waiting
        #   Success                                → approved
        #   Failed / Aborted / ApprovalRejection   → rejected
        #   Expired                                → timed out (no decision)
        if status == "Success":
            return "APPROVED"
        if status in ("Failed", "Aborted", "ApprovalRejection", "AbortedByFreeze"):
            return "REJECTED"
        return None  # Running / NotStarted / Expired / etc.

    return None


# ─────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────
def _build_training_args() -> list[str]:
    splits = os.environ["SPLITS_DIR"]
    args = [
        "--train",    f"{splits}/train",
        "--val",      f"{splits}/val",
        "--test",     f"{splits}/test",
        "--config",   "/shared/manifest.json",
        "--run-id",   os.environ["RUN_ID"],
    ]
    resume = os.environ.get("RESUME_FROM", "").strip()
    if resume:
        args += ["--resume-from", resume]
    return args


def _find_checkpoint() -> str:
    """Default convention: scripts/main.py saves to /shared/checkpoints/<run>/last.

    Override here if your training script uses a different layout.
    """
    path = pathlib.Path(CHECKPOINT_ROOT) / os.environ["RUN_ID"] / "last"
    return str(path) if path.exists() else ""


def _init_wandb(manifest, log):
    monitoring = manifest.get("training", {}).get("monitoring", {})
    if monitoring.get("backend") != "wandb":
        return None
    if not os.environ.get("WANDB_API_KEY"):
        return None
    try:
        import wandb
        return wandb.init(
            project=monitoring.get("project_name", "default"),
            id=os.environ["RUN_ID"],
            resume="allow",
        )
    except Exception as e:
        log.warning("wandb init failed: %s", e)
        return None


def _log_metrics(wandb_run, stats, log) -> None:
    """Stream resource-utilisation metrics. Training-specific metrics
    (loss, lr, eval) should be logged by scripts/main.py directly to wandb
    using the same RUN_ID — they'll merge in the same wandb run."""
    try:
        payload = {
            "cpu_percent": stats.cpu_percent,
            "ram_used_gb": stats.ram_used_gb,
        }
        if stats.gpus:
            g = stats.gpus[0]
            payload["gpu_util"]   = g.utilization_percent
            payload["gpu_mem_mb"] = g.memory_used_mb
        wandb_run.log(payload)
    except Exception as e:
        log.warning("metrics log failed: %s", e)


def _emergency_save(server, job, log) -> None:
    """Best-effort: try a graceful interrupt before the box vanishes."""
    try:
        server.interrupt(job)
        job.wait(timeout=SPOT_GRACE_S)
    except Exception as e:
        log.warning("emergency save did not complete cleanly: %s", e)


def _write_status(state: str, job, checkpoint: str) -> None:
    exit_code = 0
    try:
        if job._result is not None:
            exit_code = job._result.exit_code
    except Exception:
        pass
    payload = {"state": state, "exit_code": exit_code, "checkpoint": checkpoint}
    with open(STATUS_FILE, "w") as f:
        json.dump(payload, f)


if __name__ == "__main__":
    sys.exit(main())
