#!/usr/bin/env bash
# Step 6: publish the compiled dataset.
#
#   - DVC-tracks compiled files (produces .dvc pointers + .gitignore entries).
#   - Uploads bytes to the chosen destination.
#       Currently implemented: huggingface
#       Stubbed:                gdrive, idrive_e2  (intentionally left for later)
#   - Commits the .dvc pointers + DVC config to `output.branch` in the source repo.
#   - Tags the commit as `<tag.prefix>-v<version>` if `tag.enabled: true`.
#
# Required env (injected by the pipeline):
#   GITHUB_TOKEN   PAT with write access (push to branch + tags)
#   HF_TOKEN       HF token with write access (only needed when destination=huggingface)

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Publish compiled dataset"
activate_venv

compile_flag="$(read_config compile true)"
if [[ "$compile_flag" != "true" ]]; then
  log "compile=false — no artefact to publish, skipping"
  exit 0
fi

destination="$(read_config output.destination huggingface)"
output_name="$(read_config output.name dataset-train)"
target_branch="$(read_config output.branch datasets)"
version="$(read_config version 0.0.0)"
tag_enabled="$(read_config tag.enabled false)"
tag_prefix="$(read_config tag.prefix dataset)"

log "destination       = $destination"
log "output.name       = $output_name"
log "output.branch     = $target_branch"
log "version           = $version"
log "tag.enabled       = $tag_enabled  (prefix=$tag_prefix)"

# ---------- DVC + remote upload ----------

case "$destination" in
  huggingface)
    hf_repo_id="$(read_config output.hf_repo_id "")"
    hf_repo_type="$(read_config output.hf_repo_type dataset)"
    hf_repo_branch="$(read_config output.hf_repo_branch main)"

    [[ -n "$hf_repo_id" ]] || die "output.hf_repo_id is empty in configuration.yaml"
    [[ -n "${HF_TOKEN:-}" ]] || die "HF_TOKEN is not set (configure it as a pipeline secret)"

    python "$PIPELINE_ROOT/scripts/lib/hf_dvc_publish.py" \
      --dataset-dir   "$DATASET_DIR" \
      --hf-repo-id    "$hf_repo_id" \
      --hf-repo-type  "$hf_repo_type" \
      --hf-repo-branch "$hf_repo_branch"
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

# ---------- Commit pointer files back to the source repo ----------

banner "Commit DVC pointers to ${target_branch}"

cd "$DATASET_DIR"

# Re-auth the remote in case the clone was anonymous.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  remote_url="$(git remote get-url origin)"
  if [[ "$remote_url" == https://github.com/* ]]; then
    git remote set-url origin "${remote_url/https:\/\//https://x-access-token:${GITHUB_TOKEN}@}"
  fi
fi

# Stash the DVC artefacts we just produced into a tarball before any branch
# switch, then restore them on top of the target branch. This works whether
# the target branch already exists (we overwrite its DVC config with ours)
# or doesn't (we create it as an orphan branch with clean history).
stash="$(mktemp).tar"
log "Stashing DVC artefacts in $stash"
artefact_list="$(mktemp)"
{
  [[ -d .dvc ]]               && echo .dvc
  [[ -f .dvcignore ]]         && echo .dvcignore
  [[ -f compiled/.gitignore ]] && echo compiled/.gitignore
  find compiled -maxdepth 1 -name '*.dvc' -type f 2>/dev/null || true
} > "$artefact_list"
log "Artefacts being stashed:"
sed 's/^/  /' "$artefact_list"
tar -cf "$stash" -T "$artefact_list"

if git ls-remote --exit-code --heads origin "$target_branch" >/dev/null 2>&1; then
  log "Target branch '$target_branch' exists on origin — checking out"
  git fetch origin "$target_branch" --depth 1
  git checkout -B "$target_branch" "origin/$target_branch" --
else
  log "Target branch '$target_branch' does not exist — creating orphan branch"
  git checkout --orphan "$target_branch"
  git rm -rf --quiet . || true
  cat > README.md <<EOF
# DVC pointers for $(basename "$DATASET_DIR")

This branch holds DVC pointer files (\`*.dvc\`) for compiled dataset artefacts.
Actual data lives at the DVC remote configured in \`.dvc/config\`.

To materialise the data locally:

\`\`\`bash
git checkout $target_branch
dvc pull
\`\`\`
EOF
fi

log "Restoring DVC artefacts on top of $target_branch"
tar -xf "$stash"
rm -f "$stash" "$artefact_list"

git add -A
if git diff --cached --quiet; then
  log "No changes to commit — pointer files already up to date"
else
  git commit -m "Publish ${output_name} v${version} via ${destination}"
  git push origin "$target_branch"
  log "Pushed DVC pointers to origin/$target_branch"
fi

# ---------- Tag ----------

if [[ "$tag_enabled" == "true" ]]; then
  tag_name="${tag_prefix}-v${version}"
  banner "Tag commit as $tag_name"
  if git rev-parse "$tag_name" >/dev/null 2>&1; then
    log "Tag $tag_name already exists locally — skipping"
  else
    git tag -a "$tag_name" -m "Dataset $output_name v$version"
    git push origin "$tag_name"
    log "Pushed tag $tag_name"
  fi
else
  log "tag.enabled=false — not tagging"
fi

log "Publish OK"
