#!/usr/bin/env bash
# The game VM: no public address, Shielded VM, OS Login, its own service account, and vm/startup.sh as its
# startup script. A weekly snapshot schedule keeps 4 snapshots of its disk. Run it again to update the startup
# script and the metadata of an existing VM.
#
#   fork/gcp/20-vm.sh            DRY_RUN=1 fork/gcp/20-vm.sh
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"
load_config

SCHEDULE="nfsu2-weekly"
STARTUP="${GCP_DIR}/vm/startup.sh"
[ -f "$STARTUP" ] || die "missing $STARTUP"
META="enable-oslogin=TRUE,block-project-ssh-keys=TRUE,nfsu2-host=${NFSU2_HOST},nfsu2-bucket=${BUCKET},nfsu2-idle-minutes=${IDLE_MINUTES}"

if gc_probe compute instances describe "$VM_NAME" --zone="$ZONE"; then
  say "VM $VM_NAME exists: updating its metadata and startup script"
  gc compute instances add-metadata "$VM_NAME" --zone="$ZONE" --metadata="$META" \
    --metadata-from-file="startup-script=${STARTUP}"
else
  gc compute instances create "$VM_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-size=20GB --boot-disk-type=pd-balanced \
    --network="$NETWORK" --no-address \
    --tags=nfsu2 \
    --service-account="$VM_SA" --scopes=cloud-platform \
    --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
    --metadata="$META" \
    --metadata-from-file="startup-script=${STARTUP}"
fi

# weekly snapshots, kept 28 days: 4 at a time
if gc_probe compute resource-policies describe "$SCHEDULE" --region="$REGION"; then
  say "snapshot schedule $SCHEDULE exists"
else
  gc compute resource-policies create snapshot-schedule "$SCHEDULE" --region="$REGION" \
    --weekly-schedule=sunday --start-time=03:00 --max-retention-days=28 \
    --on-source-disk-delete=keep-auto-snapshots --storage-location="$REGION"
fi
policies="$(gc_capture compute disks describe "$VM_NAME" --zone="$ZONE" --format='value(resourcePolicies)' || true)"
case "$policies" in
  *"/$SCHEDULE"*) say "the disk has the snapshot schedule" ;;
  *) gc compute disks add-resource-policies "$VM_NAME" --zone="$ZONE" --resource-policies="$SCHEDULE" ;;
esac

say "done. Without a release the VM only installs Docker, then powers off after ${IDLE_MINUTES} idle minutes."
say "next: fork/gcp/release.sh <commit>"
