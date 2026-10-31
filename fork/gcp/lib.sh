#!/usr/bin/env bash
# Shared helpers for the fork/gcp scripts. Sourced, never run.
#
#   DRY_RUN=1      print every gcloud, gsutil, ssh and curl command instead of running it
#   NFSU2_CONFIG   another config file than fork/gcp/config.env
#
# Every script sources this file first. It loads config.env and checks its values.

GCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-0}"
NETWORK="default"   # the VPC of a new project; 10-network.sh puts the NAT and the firewall rule on it

die() { echo "$(basename "$0"): $*" >&2; exit 1; }
say() { echo "$(basename "$0"): $*"; }

is_dry() { [ "$DRY_RUN" = 1 ]; }

# run CMD...: run a command, or print it with DRY_RUN=1.
run() {
  if is_dry; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# probe CMD...: a read-only check (describe, ls). Its output goes nowhere.
# With DRY_RUN=1 it prints the command and fails, so the script goes on as if the resource did not exist.
probe() {
  if is_dry; then
    printf '[dry-run] check:'
    printf ' %q' "$@"
    printf '\n'
    return 1
  fi
  "$@" > /dev/null 2>&1
}

# capture CMD...: a read-only command whose output the script needs.
# With DRY_RUN=1 it prints the command to stderr and outputs nothing.
capture() {
  if is_dry; then
    { printf '[dry-run] read:'; printf ' %q' "$@"; printf '\n'; } >&2
    return 0
  fi
  "$@"
}

gc() { run gcloud --project="$PROJECT_ID" "$@"; }
gc_probe() { probe gcloud --project="$PROJECT_ID" "$@"; }
gc_capture() { capture gcloud --project="$PROJECT_ID" "$@"; }

valid_commit() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
valid_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
valid_host() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }

sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

load_config() {
  local config="${NFSU2_CONFIG:-$GCP_DIR/config.env}"
  [ -f "$config" ] || die "no $config: copy config.env.example to config.env and fill it in"
  # shellcheck source=/dev/null
  . "$config"
  local key
  for key in PROJECT_ID REGION ZONE VM_NAME BUILD_VM_NAME MACHINE_TYPE BUCKET AR_REPO NFSU2_HOST IDLE_MINUTES; do
    [ -n "${!key:-}" ] || die "$key is empty in $config"
  done
  [[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "PROJECT_ID '$PROJECT_ID' is not a valid project ID"
  [[ "$REGION" =~ ^[a-z]+-[a-z]+[0-9]+$ ]] || die "REGION '$REGION' is not a region name"
  [[ "$ZONE" == "$REGION"-[a-z] ]] || die "ZONE '$ZONE' is not a zone of $REGION"
  [[ "$VM_NAME" =~ ^[a-z][a-z0-9-]{0,61}$ ]] || die "VM_NAME '$VM_NAME' is not a valid instance name"
  [[ "$BUILD_VM_NAME" =~ ^[a-z][a-z0-9-]{0,61}$ ]] || die "BUILD_VM_NAME '$BUILD_VM_NAME' is not a valid instance name"
  [[ "$MACHINE_TYPE" =~ ^[a-z0-9-]+$ ]] || die "MACHINE_TYPE '$MACHINE_TYPE' is not a machine type"
  [[ "$BUCKET" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] || die "BUCKET '$BUCKET' is not a bucket name (no gs://)"
  [[ "$AR_REPO" =~ ^[a-z][a-z0-9-]{0,62}$ ]] || die "AR_REPO '$AR_REPO' is not a repository name"
  valid_host "$NFSU2_HOST" || die "NFSU2_HOST '$NFSU2_HOST' is not a host name"
  [[ "$IDLE_MINUTES" =~ ^[0-9]+$ ]] && [ "$IDLE_MINUTES" -ge 10 ] && [ "$IDLE_MINUTES" -le 1440 ] \
    || die "IDLE_MINUTES '$IDLE_MINUTES' must be a number from 10 to 1440"

  VM_SA="nfsu2-vm@${PROJECT_ID}.iam.gserviceaccount.com"
  BUILD_SA="nfsu2-build@${PROJECT_ID}.iam.gserviceaccount.com"
  AR_HOST="${REGION}-docker.pkg.dev"
  IMAGE_REPO="${AR_HOST}/${PROJECT_ID}/${AR_REPO}/nfsu2-web-rs"
  GS="gs://${BUCKET}"
  # read by the scripts that source this file
  export VM_SA BUILD_SA AR_HOST IMAGE_REPO GS NETWORK
  if is_dry; then
    echo "[dry-run] nothing runs: commands are printed only" >&2
  fi
}
