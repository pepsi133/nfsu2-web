#!/usr/bin/env bash
# Point the game VM at a built release: the commit and its image, pinned by digest, from releases/<commit>.json.
# A running VM applies it at once (its startup script runs again over IAP SSH); a stopped one at its next start.
# Rollback: the same with an older commit.
#
#   fork/gcp/release.sh <full 40-character commit>
#   DRY_RUN=1 fork/gcp/release.sh <commit>
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"

COMMIT="${1:-}"
valid_commit "$COMMIT" || die "usage: release.sh <full 40-character commit> (lower-case hex)"
load_config

if is_dry; then
  run gcloud --project="$PROJECT_ID" storage cat "${GS}/releases/${COMMIT}.json"
  manifest="{\"commit\":\"${COMMIT}\",\"image\":\"${IMAGE_REPO}@sha256:$(printf '0%.0s' {1..64})\"}"
  say "using a sample manifest for the dry run"
else
  manifest="$(gcloud --project="$PROJECT_ID" storage cat "${GS}/releases/${COMMIT}.json" 2> /dev/null)" \
    || die "no ${GS}/releases/${COMMIT}.json: build it first (build.sh $COMMIT)"
fi

read_field() {
  printf '%s' "$manifest" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}
m_commit="$(read_field commit)"
image="$(read_field image)"
[ "$m_commit" = "$COMMIT" ] || die "the manifest names commit '$m_commit', not $COMMIT"
case "$image" in
  "${IMAGE_REPO}@sha256:"*) ;;
  *) die "the manifest's image '$image' is not in ${IMAGE_REPO}" ;;
esac
[[ "${image#*@}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "the manifest's image is not pinned by a sha256 digest"

say "release $COMMIT, image $image"
gc compute instances add-metadata "$VM_NAME" --zone="$ZONE" \
  --metadata="nfsu2-release=${COMMIT},nfsu2-image=${image}"

status="$(gc_capture compute instances describe "$VM_NAME" --zone="$ZONE" --format='value(status)' || true)"
if is_dry || [ "$status" = RUNNING ]; then
  if is_dry; then say "if the VM runs, it applies the release now:"; else say "the VM runs: applying the release now"; fi
  gc compute ssh "$VM_NAME" --zone="$ZONE" --tunnel-through-iap -- sudo google_metadata_script_runner startup
  say "done. Check it: fork/gcp/status.sh"
else
  say "the VM is ${status:-not running}: the release applies at its next start (fork/gcp/start.sh)"
fi
