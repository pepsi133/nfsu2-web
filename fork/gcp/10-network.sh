#!/usr/bin/env bash
# The network: Cloud NAT (the VMs have no public address but must reach Docker Hub, GitHub and Cloudflare), one
# firewall rule for SSH through IAP only, and, after asking, the default rules that open SSH, RDP and ICMP to
# the internet. Run it again at any time.
#
#   fork/gcp/10-network.sh            DRY_RUN=1 fork/gcp/10-network.sh
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"
load_config

ROUTER="nfsu2-router"
NAT="nfsu2-nat"
RULE="nfsu2-allow-iap-ssh"
IAP_RANGE="35.235.240.0/20"

if gc_probe compute routers describe "$ROUTER" --region="$REGION"; then
  say "router $ROUTER exists"
else
  gc compute routers create "$ROUTER" --network="$NETWORK" --region="$REGION"
fi

if gc_probe compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION"; then
  say "NAT $NAT exists"
else
  gc compute routers nats create "$NAT" --router="$ROUTER" --region="$REGION" \
    --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
fi

if gc_probe compute firewall-rules describe "$RULE"; then
  say "firewall rule $RULE exists"
else
  gc compute firewall-rules create "$RULE" --network="$NETWORK" --direction=INGRESS --action=allow \
    --rules=tcp:22 --source-ranges="$IAP_RANGE" --target-tags=nfsu2,nfsu2-build \
    --description="SSH to the nfsu2 VMs through IAP only"
fi

# The default network's rules let the whole internet try SSH, RDP and ping. The VMs have no public address,
# but these rules would open any VM that gets one later.
for rule in default-allow-ssh default-allow-rdp default-allow-icmp; do
  if is_dry; then
    probe gcloud --project="$PROJECT_ID" compute firewall-rules describe "$rule" || true
    say "would ask: delete firewall rule $rule? [y/N]"
    run gcloud --project="$PROJECT_ID" compute firewall-rules delete "$rule" --quiet
    continue
  fi
  if ! gc_probe compute firewall-rules describe "$rule"; then
    say "firewall rule $rule does not exist: skipped"
    continue
  fi
  read -r -p "Delete firewall rule $rule? [y/N] " answer
  case "$answer" in
    y|Y) gc compute firewall-rules delete "$rule" --quiet ;;
    *) say "kept $rule" ;;
  esac
done

say "done"
