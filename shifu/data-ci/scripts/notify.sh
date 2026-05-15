#!/usr/bin/env bash
# Step 8: send a notification email about the compiled dataset.
# TODO: implement when the mail service is chosen (SMTP, SendGrid, SES, ...).

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

banner "Email notification (TODO)"

# When implemented, this script will likely:
#   - Read recipient list from a pipeline variable or configuration.yaml.
#   - Build a short HTML body with: dataset name, version, HF link, status, link to this Harness run.
#   - Send via SMTP or transactional-mail API; secrets pulled from the pipeline.
log "Skipping — email notification not implemented yet."

exit 0
