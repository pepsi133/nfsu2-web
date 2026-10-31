#!/usr/bin/env bash
# Stop the game VM now. Everyone in the game is cut off. The disk, its snapshots and the bucket stay.
#
#   fork/gcp/stop.sh            DRY_RUN=1 fork/gcp/stop.sh
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"
load_config

gc compute instances stop "$VM_NAME" --zone="$ZONE"
say "stopped"
