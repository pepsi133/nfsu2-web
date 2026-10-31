#!/usr/bin/env bash
# The game VM's state, the release it is set to, and (when it runs) its containers, over IAP SSH.
#
#   fork/gcp/status.sh            DRY_RUN=1 fork/gcp/status.sh
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"
load_config

info="$(gc_capture compute instances describe "$VM_NAME" --zone="$ZONE" --format=json || true)"
field() {
  [ -n "$info" ] || return 0
  printf '%s' "$info" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if sys.argv[1] == "status":
    print(d.get("status", ""))
else:
    print(next((i.get("value", "") for i in d.get("metadata", {}).get("items", []) if i.get("key") == sys.argv[1]), ""))
' "$1"
}
status="$(field status)"
release="$(field nfsu2-release)"
image="$(field nfsu2-image)"
echo "VM:      $VM_NAME ${status:-unknown}"
echo "release: ${release:-none}"
echo "image:   ${image:-none}"
if is_dry || [ "$status" = RUNNING ]; then
  gc compute ssh "$VM_NAME" --zone="$ZONE" --tunnel-through-iap -- sudo nfsu2-compose ps
fi
