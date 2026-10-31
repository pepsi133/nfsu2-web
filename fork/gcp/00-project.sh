#!/usr/bin/env bash
# Prepare the GCP project: APIs, service accounts, the bucket, the image registry, empty secrets, and the
# least-privilege bindings. Run it again at any time: it creates only what is missing.
#
#   fork/gcp/00-project.sh            DRY_RUN=1 fork/gcp/00-project.sh
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"
load_config

# --- APIs (storage is on by default in a new project; it is listed so that the bucket always works)
say "enabling APIs"
gc services enable compute.googleapis.com iap.googleapis.com secretmanager.googleapis.com \
  artifactregistry.googleapis.com logging.googleapis.com oslogin.googleapis.com storage.googleapis.com

# --- service accounts
make_sa() {
  local name="$1" title="$2"
  if gc_probe iam service-accounts describe "${name}@${PROJECT_ID}.iam.gserviceaccount.com"; then
    say "service account $name exists"
  else
    gc iam service-accounts create "$name" --display-name="$title"
  fi
}
make_sa nfsu2-vm "nfsu2 game VM"
make_sa nfsu2-build "nfsu2 temporary build VM"

# --- bucket: private, uniform access, no public access
if gc_probe storage buckets describe "$GS"; then
  say "bucket $GS exists"
else
  gc storage buckets create "$GS" --location="$REGION" --default-storage-class=STANDARD \
    --uniform-bucket-level-access --public-access-prevention
fi
gc storage buckets update "$GS" --uniform-bucket-level-access --public-access-prevention

# --- Artifact Registry
if gc_probe artifacts repositories describe "$AR_REPO" --location="$REGION"; then
  say "registry $AR_REPO exists"
else
  gc artifacts repositories create "$AR_REPO" --repository-format=docker --location="$REGION" \
    --description="nfsu2 server images, built by the build VM"
fi

# --- secrets: created empty. Add the values with: gcloud secrets versions add NAME --data-file=-
for secret in nfsu2-allowlist nfsu2-tunnel-token nfsu2-cloudflare-api-token; do
  if gc_probe secrets describe "$secret"; then
    say "secret $secret exists"
  else
    gc secrets create "$secret" --replication-policy=user-managed --locations="$REGION"
  fi
done

# --- bindings at resource level where GCP allows them
say "binding roles"
vm="serviceAccount:${VM_SA}"
build="serviceAccount:${BUILD_SA}"
gc secrets add-iam-policy-binding --format=none nfsu2-tunnel-token --member="$vm" \
  --role=roles/secretmanager.secretAccessor --condition=None
gc artifacts repositories add-iam-policy-binding --format=none "$AR_REPO" --location="$REGION" --member="$vm" \
  --role=roles/artifactregistry.reader --condition=None
gc artifacts repositories add-iam-policy-binding --format=none "$AR_REPO" --location="$REGION" --member="$build" \
  --role=roles/artifactregistry.writer --condition=None
gc storage buckets add-iam-policy-binding --format=none "$GS" --member="$vm" --role=roles/storage.objectViewer
gc storage buckets add-iam-policy-binding --format=none "$GS" --member="$build" --role=roles/storage.objectViewer
gc storage buckets add-iam-policy-binding --format=none "$GS" --member="$build" --role=roles/storage.objectCreator
# logging and monitoring have no resource-level bindings: project level
gc projects add-iam-policy-binding --format=none "$PROJECT_ID" --member="$vm" --role=roles/logging.logWriter --condition=None
gc projects add-iam-policy-binding --format=none "$PROJECT_ID" --member="$vm" --role=roles/monitoring.metricWriter --condition=None
gc projects add-iam-policy-binding --format=none "$PROJECT_ID" --member="$build" --role=roles/logging.logWriter --condition=None

say "done. Next: 10-network.sh, then add the secret values (fork/gcp/README.md, Secrets)"
