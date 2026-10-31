#!/usr/bin/env bash
# Start the game VM. Its startup script brings up the current release. It powers itself off after IDLE_MINUTES
# without players.
#
#   fork/gcp/start.sh            DRY_RUN=1 fork/gcp/start.sh
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"
load_config

gc compute instances start "$VM_NAME" --zone="$ZONE"
say "started. The game is up in about 2 minutes at https://${NFSU2_HOST}/ (fork/gcp/status.sh shows it)"
