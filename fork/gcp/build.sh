#!/usr/bin/env bash
# Build the game module and the server's image of one commit, on a temporary Spot VM (vm/build-startup.sh).
# It waits until the VM has powered off, prints the manifest, and deletes the VM: also on failure, on Ctrl-C and
# after 3 hours.
#
#   fork/gcp/build.sh <full 40-character commit>
#   DRY_RUN=1 fork/gcp/build.sh <commit>
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"

COMMIT="${1:-}"
valid_commit "$COMMIT" || die "usage: build.sh <full 40-character commit> (lower-case hex)"
load_config

TIMEOUT_SECONDS=$(( 3 * 60 * 60 ))
POLL_SECONDS=30
LOG_GS="${GS}/releases/${COMMIT}.log"
LOG_FILTER="resource.type=\"gce_instance\" AND logName=\"projects/${PROJECT_ID}/logs/google_metadata_script_runner\""

# --- nothing of this commit may be in the bucket yet (the build account cannot replace objects)
if gc_probe storage objects describe "${GS}/releases/${COMMIT}.json"; then
  say "release $COMMIT is built already:"
  gc storage cat "${GS}/releases/${COMMIT}.json"
  exit 0
fi
if ! is_dry; then
  leftovers="$(gcloud --project="$PROJECT_ID" storage ls "${GS}/module/${COMMIT}/**" "${GS}/deploy/${COMMIT}/**" \
    "$LOG_GS" 2> /dev/null || true)"
  if [ -n "$leftovers" ]; then
    echo "$leftovers" >&2
    die "an earlier build of $COMMIT left these objects. Read its log ($LOG_GS), then delete them:
  gcloud storage rm -r ${GS}/module/${COMMIT} ${GS}/deploy/${COMMIT} $LOG_GS"
  fi
else
  probe gcloud --project="$PROJECT_ID" storage ls "${GS}/module/${COMMIT}/**" "${GS}/deploy/${COMMIT}/**" "$LOG_GS" || true
fi

if gc_probe compute instances describe "$BUILD_VM_NAME" --zone="$ZONE"; then
  die "a VM $BUILD_VM_NAME exists already (another build?). Delete it first:
  gcloud --project=$PROJECT_ID compute instances delete $BUILD_VM_NAME --zone=$ZONE"
fi

created=0
cleanup() {
  local code=$?
  trap - EXIT INT TERM
  if [ "$created" = 1 ]; then
    say "deleting the build VM $BUILD_VM_NAME"
    gc compute instances delete "$BUILD_VM_NAME" --zone="$ZONE" --quiet || say "delete failed: delete $BUILD_VM_NAME by hand"
  fi
  if [ "$code" != 0 ]; then
    say "the build failed. Its log: gcloud storage cat $LOG_GS"
    say "or Cloud Logging: gcloud --project=$PROJECT_ID logging read '$LOG_FILTER' --freshness=1d"
  fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

say "creating the build VM $BUILD_VM_NAME for $COMMIT"
# --max-run-duration stops the VM even if this script dies; a Spot VM that is preempted stops too (STOP, not DELETE,
# so that the log stays readable)
created=1
gc compute instances create "$BUILD_VM_NAME" \
  --zone="$ZONE" \
  --machine-type=e2-standard-8 \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --max-run-duration=3h10m \
  --image-family=debian-12 --image-project=debian-cloud \
  --boot-disk-size=50GB --boot-disk-type=pd-balanced \
  --network="$NETWORK" --no-address \
  --tags=nfsu2-build \
  --service-account="$BUILD_SA" --scopes=cloud-platform \
  --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
  --metadata="enable-oslogin=TRUE,block-project-ssh-keys=TRUE,nfsu2-commit=${COMMIT},nfsu2-bucket=${BUCKET},nfsu2-image-repo=${IMAGE_REPO}" \
  --metadata-from-file="startup-script=${GCP_DIR}/vm/build-startup.sh"

say "waiting for the build VM to power off (at most 3 hours; the first build takes longest)"
start="$(date +%s)"
while :; do
  status="$(gc_capture compute instances describe "$BUILD_VM_NAME" --zone="$ZONE" --format='value(status)' || true)"
  if is_dry; then
    say "would poll every ${POLL_SECONDS}s until the status is TERMINATED"
    break
  fi
  [ "$status" = TERMINATED ] && break
  if [ $(( $(date +%s) - start )) -ge "$TIMEOUT_SECONDS" ]; then
    die "timeout after 3 hours (status $status)"
  fi
  sleep "$POLL_SECONDS"
done

if is_dry; then
  run gcloud --project="$PROJECT_ID" storage cat "${GS}/releases/${COMMIT}.json"
  exit 0
fi
if ! manifest="$(gcloud --project="$PROJECT_ID" storage cat "${GS}/releases/${COMMIT}.json" 2> /dev/null)"; then
  die "the build VM stopped without a manifest (failed or preempted)"
fi
say "built:"
echo "$manifest"
say "build log: $LOG_GS"
say "next: fork/gcp/release.sh $COMMIT"
