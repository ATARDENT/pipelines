#!/usr/bin/env bash
# Step 7: register the dataset with the deputy service.
# TODO: implement when the deputy service API is available.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Register dataset to deputy service (TODO)"

# When implemented, this script will likely:
#   1. Read configuration.yaml for dataset name + version.
#   2. POST a registration payload (name, version, HF URI, .dvc commit SHA)
#      to the deputy service.
#   3. Fail loudly on a non-2xx response.
log "Skipping — deputy registration not implemented yet."
log "Expected payload would include:"
log "  name=$(read_config output.name)"
log "  version=$(read_config version)"
log "  destination=$(read_config output.destination)"
log "  hf_repo_id=$(read_config output.hf_repo_id)"

exit 0
