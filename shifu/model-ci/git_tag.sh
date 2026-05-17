#!/bin/sh
# README Step 11 — Create and push the version tag.
#
# Environment:
#   GH_TOKEN          GitHub PAT with repo:write
#   MANIFEST_VERSION  e.g. "1.0.0" — exported by ParseManifest
#   RUN_ID            Pipeline execution id (annotation in the tag message)
#   REPO_URL          <+codebase.repoUrl> from Harness
#
# Reads:
#   /shared/manifest.json (for tag.prefix, tag.suffix, tag.github_branch)
#
# Tag format (per README): <prefix>-v<version><suffix>   e.g. model-v1.0.0
set -e

# alpine/git: pull in python3 just to read the manifest JSON.
apk add --no-cache python3 >/dev/null

PREFIX=$(python3 -c "import json; print(json.load(open('/shared/manifest.json')).get('tag',{}).get('prefix','model'))")
SUFFIX=$(python3 -c "import json; print(json.load(open('/shared/manifest.json')).get('tag',{}).get('suffix',''))")
BRANCH=$(python3 -c "import json; print(json.load(open('/shared/manifest.json')).get('tag',{}).get('github_branch','main'))")

TAG="${PREFIX}-v${MANIFEST_VERSION}${SUFFIX}"

git config user.email "ci@harness"
git config user.name  "harness-ci"
git tag -a "$TAG" -m "Auto-tag from run ${RUN_ID}"

# REPO_URL like https://github.com/org/repo — splice the token in.
PUSH_URL=$(echo "$REPO_URL" | sed "s#https://#https://x-access-token:${GH_TOKEN}@#")
git push "$PUSH_URL" "$TAG"

echo "✓ tagged $TAG on $BRANCH"
