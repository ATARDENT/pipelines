#!/usr/bin/env bash
# Step 6: publish the compiled dataset.
#
#   - DVC-tracks compiled files (produces .dvc pointers + .gitignore entries).
#   - Uploads bytes to the chosen destination.
#       Currently implemented: huggingface
#       Stubbed:                gdrive, idrive_e2  (intentionally left for later)
#   - Commits the .dvc pointers + DVC config to `output.dvc_branch` in the
#     source repo (default: "datasets") on an orphan history dedicated to
#     DVC artefacts — kept separate from human-readable source on `main`.
#   - Tags `steps.tag.github-branch` (default: "main") as
#     `<tag.prefix>-v<version>[-<tag.suffix>]` if `steps.tag.enabled: true`.
#
# Required env (injected by the pipeline):
#   GITHUB_APP_CLIENT_ID         Client ID of the GitHub App
#   GITHUB_APP_INSTALLATION_ID   Installation ID of the App on the target repo
#   GITHUB_APP_PRIVATE_KEY       PEM-encoded RSA private key for the App
#   HF_TOKEN                     HF token with write access
#                                (only needed when destination=huggingface)
#
# Optional env:
#   GITHUB_APP_COMMITTER_NAME    Override committer name (default: shifu-data-ci[bot])
#   GITHUB_APP_COMMITTER_EMAIL   Override committer email

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Publish compiled dataset"
activate_venv

# ---------- Read manifest ----------

compile_flag="$(read_config steps.compile.enabled true)"
if [[ "$compile_flag" != "true" ]]; then
  log "steps.compile.enabled=false — no artefact to publish, skipping"
  exit 0
fi

destination="$(read_config output.destination huggingface)"
output_name="$(read_config output.name dataset-train)"
target_branch="$(read_config output.dvc_branch datasets)"
version="$(read_config version 0.0.0)"

tag_enabled="$(read_config steps.tag.enabled false)"
tag_prefix="$(read_config steps.tag.prefix dataset)"
tag_suffix="$(read_config steps.tag.suffix "")"
tag_github_branch="$(read_config steps.tag.github-branch main)"

log "destination         = $destination"
log "output.name         = $output_name"
log "output.dvc_branch   = $target_branch"
log "version             = $version"
log "tag.enabled         = $tag_enabled  (prefix=$tag_prefix suffix=$tag_suffix)"
log "tag.github-branch   = $tag_github_branch"

# ---------- GitHub App token minting ----------
#
# Exchanges the App's private key + installation ID for a short-lived (~1 hour)
# installation access token. Functionally equivalent to a PAT for git operations
# but scoped to the App's permissions on the installation and auto-expires.
# Follows GitHub's official guidance:
# https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app
mint_github_app_token() {
  : "${GITHUB_APP_CLIENT_ID:?GITHUB_APP_CLIENT_ID is not set}"
  : "${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID is not set}"
  : "${GITHUB_APP_PRIVATE_KEY:?GITHUB_APP_PRIVATE_KEY is not set}"

  python - <<'PY'
import json, os, sys, time, urllib.request, urllib.error
import jwt  # PyJWT with cryptography extra for RS256

client_id = os.environ["GITHUB_APP_CLIENT_ID"]
inst_id   = os.environ["GITHUB_APP_INSTALLATION_ID"]
key       = os.environ["GITHUB_APP_PRIVATE_KEY"]

now = int(time.time())
app_jwt = jwt.encode(
    {
        "iat": now - 60,    # 60s in the past to allow for clock drift
        "exp": now + 600,   # 10 minute maximum (GitHub-enforced upper bound)
        "iss": client_id,   # Client ID is the GitHub-recommended value
    },
    key,
    algorithm="RS256",
)

req = urllib.request.Request(
    f"https://api.github.com/app/installations/{inst_id}/access_tokens",
    method="POST",
    headers={
        "Authorization": f"Bearer {app_jwt}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    },
)
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        sys.stdout.write(json.loads(r.read())["token"])
except urllib.error.HTTPError as e:
    sys.stderr.write(f"GitHub App token request failed: {e.code} {e.read().decode()}\n")
    sys.exit(1)
PY
}

# ---------- DVC + remote upload ----------

case "$destination" in
  huggingface)
    hf_repo_id="$(read_config output.hf_repo_id "")"
    hf_repo_type="$(read_config remote.huggingface.repo_type dataset)"
    hf_repo_branch="main"   # HF-side branch; not currently configurable

    [[ -n "$hf_repo_id" ]] || die "output.hf_repo_id is empty in configuration.yaml"
    [[ -n "${HF_TOKEN:-}" ]] || die "HF_TOKEN is not set (configure it as a pipeline secret)"

    python "$PIPELINE_ROOT/scripts/lib/hf_dvc_publish.py" \
      --dataset-dir     "$DATASET_DIR" \
      --hf-repo-id      "$hf_repo_id" \
      --hf-repo-type    "$hf_repo_type" \
      --hf-repo-branch  "$hf_repo_branch"
    ;;

  gdrive)
    # TODO: implement Google Drive upload (e.g. via PyDrive2 or gdown).
    die "destination=gdrive not implemented yet"
    ;;

  idrive_e2)
    # TODO: implement IDrive E2 upload (S3-compatible).
    die "destination=idrive_e2 not implemented yet"
    ;;

  github)
    # Storing compiled bytes inside the source repo defeats the point of DVC.
    die "destination=github not implemented yet (and probably shouldn't be)"
    ;;

  *)
    die "unknown output.destination: $destination"
    ;;
esac

# ---------- Commit pointer files to the DVC branch ----------

banner "Commit DVC pointers to ${target_branch}"

cd "$DATASET_DIR"

# Mint a fresh installation token and use it for the push.
log "Minting GitHub App installation token"
GITHUB_TOKEN="$(mint_github_app_token)"
[[ -n "$GITHUB_TOKEN" ]] || die "Failed to mint GitHub App installation token"

remote_url="$(git remote get-url origin)"
if [[ "$remote_url" == https://github.com/* ]]; then
  git remote set-url origin "${remote_url/https:\/\//https://x-access-token:${GITHUB_TOKEN}@}"
fi

# Identify as the App (commits will show as "<app-name>[bot]").
git config user.name  "${GITHUB_APP_COMMITTER_NAME:-shifu-data-ci[bot]}"
git config user.email "${GITHUB_APP_COMMITTER_EMAIL:-shifu-data-ci[bot]@users.noreply.github.com}"

# Build the publish commit in a disposable worktree instead of switching
# branches in the live workspace. An in-place `git checkout` cannot work here:
#   - `dvc init` stages an empty .dvc/config and `dvc remote add` then edits
#     it in the worktree, so the same path tracked on the target branch makes
#     the checkout abort with "local changes would be overwritten";
#   - anything ever committed to the target branch that also exists untracked
#     in the workspace (.venv, compiled pointers) aborts the checkout too;
#   - even a successful checkout would strip manifest.yaml from the worktree,
#     breaking the register/notify/trigger steps that run after publish.
worktree_root="$(mktemp -d)"
worktree="$worktree_root/publish"
cleanup_worktree() {
  git -C "$DATASET_DIR" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  git -C "$DATASET_DIR" worktree prune >/dev/null 2>&1 || true
  rm -rf "$worktree_root"
}
trap cleanup_worktree EXIT
git worktree prune >/dev/null 2>&1 || true

if git ls-remote --exit-code --heads origin "$target_branch" >/dev/null 2>&1; then
  log "Target branch '$target_branch' exists on origin — building on top of it"
  git fetch origin "$target_branch" --depth 1
  dvc_tip="$(git rev-parse FETCH_HEAD)"
  git worktree add --no-checkout --detach "$worktree" "$dvc_tip"
  # Start from an empty index: the publish commit contains exactly what is
  # staged below, so junk that ever lands on the branch (e.g. the .venv an
  # early version of this script committed) is dropped again on the next
  # publish. Pointer files from earlier publishes are carried over so a
  # renamed output doesn't orphan its history.
  git -C "$worktree" read-tree --empty
  git -C "$worktree" checkout "$dvc_tip" -- compiled 2>/dev/null || true
else
  log "Target branch '$target_branch' does not exist — creating orphan branch"
  git branch -D "$target_branch" >/dev/null 2>&1 || true  # stale leftover from a retried run
  git worktree add --no-checkout --detach "$worktree"
  git -C "$worktree" checkout --orphan "$target_branch"
  # `checkout --orphan` re-populates the index from the previous HEAD on some
  # git versions — force it empty so nothing from main leaks onto the branch.
  git -C "$worktree" read-tree --empty
fi

log "Assembling DVC artefacts in $worktree"
mkdir -p "$worktree/.dvc" "$worktree/compiled"
[[ -f .dvcignore ]]          && cp .dvcignore          "$worktree/.dvcignore"
[[ -f .dvc/config ]]         && cp .dvc/config         "$worktree/.dvc/config"
[[ -f .dvc/.gitignore ]]     && cp .dvc/.gitignore     "$worktree/.dvc/.gitignore"
[[ -f compiled/.gitignore ]] && cp compiled/.gitignore "$worktree/compiled/.gitignore"
compgen -G "compiled/*.dvc" >/dev/null && cp compiled/*.dvc "$worktree/compiled/"

cat > "$worktree/README.md" <<EOF
# DVC pointers for ${output_name}

This branch holds DVC pointer files (\`*.dvc\`) for compiled dataset artefacts.
The actual data lives in a HuggingFace dataset repo, configured as a DVC
remote in \`.dvc/config\`.

This branch is machine-owned: every publish rebuilds it from scratch, so
manual commits here will be discarded on the next pipeline run.

## To materialise the data locally

1. Get a HuggingFace token with read access:
   https://huggingface.co/settings/tokens

2. Authenticate (one-time):
   \`\`\`bash
   huggingface-cli login
   # or: export HF_TOKEN=hf_xxxxxxxxxxxxx
   \`\`\`

3. Pull the data:
   \`\`\`bash
   git checkout $target_branch
   dvc pull
   \`\`\`
EOF

# Branch-scoped .gitignore so junk never gets staged by anyone checking this
# branch out by hand — only DVC pointers and DVC's own config are tracked.
cat > "$worktree/.gitignore" <<'EOF'
# Virtualenvs and Python noise
.venv/
__pycache__/
*.pyc

# Cloned pipeline scripts (CI-only)
pipeline-scripts/

# Compiled data — only DVC pointers should be tracked.
# `!compiled/**/` re-includes the *directories* so DVC's ignore-aware stage
# walk can descend into compiled/ and discover the *.dvc pointers. Without it,
# `compiled/**` prunes the whole subtree: git still tracks the pointers (via the
# negation below), but `dvc pull` sees "no data tracked in this project",
# reports "Everything is up to date", and materialises nothing.
compiled/**
!compiled/**/
!compiled/**/*.dvc
!compiled/**/.gitignore

# DVC cache and runtime state
.dvc/cache/
.dvc/tmp/
EOF

# Stage an explicit allowlist rather than `git add -A`, so even if the
# .gitignore above misses something, junk never lands on this branch.
(
  cd "$worktree"
  git add .gitignore README.md
  [[ -f .dvcignore ]]          && git add .dvcignore
  [[ -f .dvc/config ]]         && git add .dvc/config
  [[ -f .dvc/.gitignore ]]     && git add .dvc/.gitignore
  [[ -f compiled/.gitignore ]] && git add compiled/.gitignore
  compgen -G "compiled/*.dvc" >/dev/null && git add compiled/*.dvc

  if git diff --cached --quiet; then
    log "No changes to commit — pointer files already up to date"
  else
    git commit -m "Publish ${output_name} v${version} via ${destination}"
    git push origin "HEAD:refs/heads/${target_branch}"
    log "Pushed DVC pointers to origin/$target_branch"
  fi
)

# ---------- Tag ----------

if [[ "$tag_enabled" == "true" ]]; then
  tag_name="${tag_prefix}-v${version}"
  [[ -n "$tag_suffix" ]] && tag_name="${tag_name}-${tag_suffix}"

  banner "Tag $tag_name on branch $tag_github_branch"

  # Tag points at the tip of steps.tag.github-branch (e.g. main),
  # NOT at the DVC pointer commit. Releases mark source-code branches.
  #
  # Existence is checked on ORIGIN, not in the local clone: the CI workspace
  # is a fresh shallow clone every run, so the tag is never present locally —
  # a local check re-created existing tags and the push died with
  # "already exists" (and, inversely, a stale local tag from a retried run
  # would silently skip a push that never happened).
  if ! git ls-remote --exit-code --heads origin "$tag_github_branch" >/dev/null 2>&1; then
    log "WARNING: $tag_github_branch does not exist on origin — skipping tag"
  elif git ls-remote --exit-code --tags origin "refs/tags/$tag_name" >/dev/null 2>&1; then
    log "Tag $tag_name already exists on origin — skipping"
  else
    git fetch origin "$tag_github_branch" --depth 1
    tag_commit="$(git rev-parse FETCH_HEAD)"

    # -f: overwrite a stale local tag left behind by a retried run
    git tag -fa "$tag_name" "$tag_commit" -m "Dataset $output_name v$version"
    git push origin "refs/tags/$tag_name"
    log "Pushed tag $tag_name → $tag_commit ($tag_github_branch)"
  fi
else
  log "steps.tag.enabled=false — not tagging"
fi

log "Publish OK"
