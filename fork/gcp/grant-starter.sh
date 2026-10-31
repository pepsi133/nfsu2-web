#!/usr/bin/env bash
# Let one Google account start the game VM, and nothing else: the custom role nfsu2Starter, bound on the VM only.
#
#   fork/gcp/grant-starter.sh <email>
#   DRY_RUN=1 fork/gcp/grant-starter.sh <email>
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"

EMAIL="${1:-}"
valid_email "$EMAIL" || die "usage: grant-starter.sh <email of a Google account>"
load_config

ROLE="nfsu2Starter"
if gc_probe iam roles describe "$ROLE"; then
  say "role $ROLE exists"
else
  gc iam roles create "$ROLE" --title="nfsu2 starter" \
    --description="Start the nfsu2 game VM" \
    --permissions=compute.instances.start,compute.instances.get,compute.zoneOperations.get --stage=GA
fi
gc compute instances add-iam-policy-binding "$VM_NAME" --zone="$ZONE" --format=none \
  --member="user:${EMAIL}" --role="projects/${PROJECT_ID}/roles/${ROLE}" --condition=None

say "done. The friend starts the VM with:"
echo "  gcloud compute instances start ${VM_NAME} --project=${PROJECT_ID} --zone=${ZONE} --async"
say "(--async: compute.zoneOperations.get takes effect at project level only, so waiting for the operation can fail)"
