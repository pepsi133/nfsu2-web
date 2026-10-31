#!/usr/bin/env bash
# The temporary build VM's startup script (set by fork/gcp/build.sh). It builds the game module and the server's
# image of one commit, uploads them, and powers the VM off. build.sh then deletes the VM.
#
# Metadata it reads:
#   nfsu2-commit       the full 40-character commit of https://github.com/pepsi133/nfsu2-web
#   nfsu2-bucket       the private bucket (without gs://)
#   nfsu2-image-repo   <region>-docker.pkg.dev/<project>/<repo>/nfsu2-web-rs
#
# What goes out: the image (to Artifact Registry), out/web/nfsu2.wasm and out/web/nfsu2.json (module/<commit>/),
# web/deploy/{compose.yml,compose.tunnel.yml,nfsu2.slice} (deploy/<commit>/), the manifest (releases/<commit>.json)
# and this log (releases/<commit>.log). Nothing else: never gen/, the rest of out/, or the game.
#
# Downloads are checked: Node and rustup-init against the SHA-256 their publishers list (pinned below), Docker's apt
# key by its fingerprint, and wasi-sdk (no published checksum) by trust on first use, against gs://<bucket>/pins/.
set -euo pipefail

REPO_URL="https://github.com/pepsi133/nfsu2-web"
SPEED2_SHA256="f9dd86c054878ce6276beb07c1fd61874f7a1e4bf1f241b084c65b73e24168a7"
DOCKER_KEY_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
# https://nodejs.org/dist/v24.22.2/SHASUMS256.txt
NODE_VERSION="v24.22.2"
NODE_SHA256="48cc0e21e048790e54c0cf5749c2725005313d652651c40b7a21feb9697aaf75"
# https://static.rust-lang.org/rustup/archive/1.29.2/x86_64-unknown-linux-gnu/rustup-init.sha256
RUSTUP_VERSION="1.29.2"
RUSTUP_SHA256="5be191e8c70a5007074254cb74d78dbfdd25cd5a61c27de7b8e5410122ec24f4"
# wasi-sdk publishes no checksum file: trust on first use (gs://<bucket>/pins/<name>)
WASI_TAG="wasi-sdk-34"
WASI_FILE="wasi-sdk-34.0-x86_64-linux.tar.gz"

WORK=/build
LOG=/var/log/nfsu2-build.log
DONE=/var/lib/nfsu2-build/done

md() {
  curl -fsS -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" 2> /dev/null || true
}

COMMIT="$(md nfsu2-commit)"
BUCKET="$(md nfsu2-bucket)"
IMAGE_REPO="$(md nfsu2-image-repo)"

# A second boot (someone started the stopped VM) does nothing but power off again.
if [ -f "$DONE" ]; then
  shutdown -h now
  exit 0
fi
mkdir -p "$(dirname "$DONE")"
touch "$DONE"

# Everything goes to the log file, the journal (logger) and stdout, which the metadata script runner sends to
# Cloud Logging (log google_metadata_script_runner) and the serial console.
exec > >(tee -a "$LOG" >(logger -t nfsu2-build)) 2>&1

finish() {
  local code=$?
  if [ "$code" = 0 ]; then
    echo "nfsu2-build: SUCCESS for $COMMIT"
  else
    echo "nfsu2-build: FAILED for $COMMIT (exit $code)"
  fi
  if [[ "$BUCKET" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] && [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    sleep 2
    gcloud storage cp "$LOG" "gs://${BUCKET}/releases/${COMMIT}.log" || echo "nfsu2-build: log upload failed"
  fi
  shutdown -h now
}
trap finish EXIT

step() { echo "nfsu2-build: === $* ($(date -u +%H:%M:%S))"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
check_sha() {
  local file="$1" want="$2" have
  have="$(sha "$file")"
  [ "$have" = "$want" ] || { echo "nfsu2-build: $file has SHA-256 $have, expected $want"; exit 1; }
}

# trust on first use: the first build stores the hash in pins/<name>, every later build must match it.
# The build account may create objects but not replace them, so a later build cannot change a pin.
pin_check() {
  local file="$1" name="$2" have pinned
  have="$(sha "$file")"
  if pinned="$(gcloud storage cat "gs://${BUCKET}/pins/${name}" 2> /dev/null)"; then
    [ "$pinned" = "$have" ] || { echo "nfsu2-build: $name has SHA-256 $have, pinned $pinned"; exit 1; }
    echo "nfsu2-build: $name matches its pin $have"
  else
    printf '%s' "$have" | gcloud storage cp --if-generation-match=0 - "gs://${BUCKET}/pins/${name}"
    echo "nfsu2-build: $name pinned on first use: $have"
  fi
}

[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "nfsu2-build: metadata nfsu2-commit is not a 40-character commit"; exit 1; }
[[ "$BUCKET" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] || { echo "nfsu2-build: metadata nfsu2-bucket is invalid"; exit 1; }
[[ "$IMAGE_REPO" =~ ^[a-z0-9-]+-docker\.pkg\.dev/[a-z0-9-]+/[a-z0-9-]+/nfsu2-web-rs$ ]] \
  || { echo "nfsu2-build: metadata nfsu2-image-repo is invalid"; exit 1; }
echo "nfsu2-build: commit $COMMIT, bucket $BUCKET, image $IMAGE_REPO"

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$WORK/dl" "$WORK/game"

step "Debian packages"
apt-get update -q
apt-get install -y -q ca-certificates curl git gnupg python3 python3-venv python3-pip xz-utils perl build-essential

step "Docker from Docker's apt repository"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o "$WORK/dl/docker.asc"
gpg --show-keys --with-colons "$WORK/dl/docker.asc" | awk -F: '$1 == "fpr" { print $10; exit }' | grep -qx "$DOCKER_KEY_FPR" \
  || { echo "nfsu2-build: Docker's apt key has an unexpected fingerprint"; exit 1; }
install -m 0644 "$WORK/dl/docker.asc" /etc/apt/keyrings/docker.asc
# shellcheck source=/dev/null
codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

step "Node $NODE_VERSION"
curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz" -o "$WORK/dl/node.tar.xz"
check_sha "$WORK/dl/node.tar.xz" "$NODE_SHA256"
mkdir -p /opt/node
tar -xJf "$WORK/dl/node.tar.xz" -C /opt/node --strip-components=1
export PATH="/opt/node/bin:$PATH"
node --version

step "Rust via rustup $RUSTUP_VERSION"
curl -fsSL "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/x86_64-unknown-linux-gnu/rustup-init" \
  -o "$WORK/dl/rustup-init"
check_sha "$WORK/dl/rustup-init" "$RUSTUP_SHA256"
chmod 0755 "$WORK/dl/rustup-init"
export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
"$WORK/dl/rustup-init" -y --no-modify-path --profile minimal --default-toolchain stable
export PATH="/opt/cargo/bin:$PATH"
rustc --version

step "the source at $COMMIT"
git clone --quiet "$REPO_URL" "$WORK/src"
cd "$WORK/src"
git -c advice.detachedHead=false checkout --quiet "$COMMIT"
head="$(git rev-parse HEAD)"
[ "$head" = "$COMMIT" ] || { echo "nfsu2-build: HEAD is $head, not $COMMIT"; exit 1; }
echo "nfsu2-build: HEAD is $head"

step "wasi-sdk ($WASI_FILE)"
curl -fsSL "https://github.com/WebAssembly/wasi-sdk/releases/download/${WASI_TAG}/${WASI_FILE}" -o "$WORK/dl/$WASI_FILE"
pin_check "$WORK/dl/$WASI_FILE" "$WASI_FILE"
mkdir -p deps
tar -xzf "$WORK/dl/$WASI_FILE" -C deps

step "SPEED2.EXE and server.dll (outside the clone)"
gcloud storage cp "gs://${BUCKET}/game/SPEED2.EXE" "gs://${BUCKET}/game/server.dll" "$WORK/game/"
check_sha "$WORK/game/SPEED2.EXE" "$SPEED2_SHA256"

step "Python packages (README)"
python3 -m venv .venv
.venv/bin/pip install --quiet -r requirements.txt

step "web/gen.sh"
web/gen.sh "$WORK/game/SPEED2.EXE"

step "web/build.sh"
web/build.sh
rev="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rev"])' out/web/nfsu2.json)"
case "$rev" in
  *+*) echo "nfsu2-build: the module says rev $rev: the checkout had changes"; exit 1 ;;
esac
[ "${COMMIT#"$rev"}" != "$COMMIT" ] || { echo "nfsu2-build: the module says rev $rev, not $COMMIT"; exit 1; }
# the game files are needed no more
rm -rf "$WORK/game"

step "the image (linux/amd64)"
gcloud auth configure-docker "${IMAGE_REPO%%/*}" --quiet
docker build --platform linux/amd64 -f web/server-rs/Dockerfile \
  --label "org.opencontainers.image.revision=${COMMIT}" -t "${IMAGE_REPO}:${COMMIT}" .
docker push "${IMAGE_REPO}:${COMMIT}"
ref="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${IMAGE_REPO}:${COMMIT}" \
  | grep -m1 "^${IMAGE_REPO}@sha256:")"
digest="${ref#*@}"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "nfsu2-build: no digest for the pushed image"; exit 1; }
echo "nfsu2-build: image ${IMAGE_REPO}@${digest}"

step "uploads"
wasm_sha="$(sha out/web/nfsu2.wasm)"
gcloud storage cp --preserve-posix out/web/nfsu2.wasm out/web/nfsu2.json "gs://${BUCKET}/module/${COMMIT}/"
gcloud storage cp --preserve-posix web/deploy/compose.yml web/deploy/compose.tunnel.yml web/deploy/nfsu2.slice \
  "gs://${BUCKET}/deploy/${COMMIT}/"
python3 - "$COMMIT" "${IMAGE_REPO}@${digest}" "$digest" "$wasm_sha" "$rev" > "$WORK/manifest.json" <<'PY'
import json, sys, datetime
commit, image, digest, wasm, rev = sys.argv[1:6]
print(json.dumps({
    "commit": commit,
    "image": image,
    "image_digest": digest,
    "wasm_sha256": wasm,
    "module_rev": rev,
    "build_date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, indent=2))
PY
cat "$WORK/manifest.json"
# the manifest goes last: build.sh takes it as the sign of a complete build
gcloud storage cp "$WORK/manifest.json" "gs://${BUCKET}/releases/${COMMIT}.json"
