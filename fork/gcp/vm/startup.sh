#!/usr/bin/env bash
# The game VM's startup script (metadata startup-script, set by fork/gcp/20-vm.sh). It runs as root at every
# boot, and again when release.sh asks for it (google_metadata_script_runner startup). It is idempotent.
#
# Metadata it reads:
#   nfsu2-bucket         the private bucket (without gs://)
#   nfsu2-host           NFSU2_HOST, the Cloudflare Tunnel's public hostname
#   nfsu2-idle-minutes   minutes without players before the VM powers off
#   nfsu2-release        the commit to run (set by release.sh)
#   nfsu2-image          the image of that commit, pinned: <repo>@sha256:<digest> (set by release.sh)
#
# What it does: Docker (from Docker's signed apt repository) and unattended-upgrades if missing; the idle-shutdown
# timer; the game folder from the bucket when its marker changed (file times kept); the module and the deploy files
# of the release; nfsu2.slice; the tunnel token from Secret Manager in /run/nfsu2/tunnel-token only (tmpfs, 0400,
# cloudflared's uid), mounted into cloudflared and never in a container's environment; /run/nfsu2/.env (no secret);
# then docker compose up -d. NFSU2_TURNSTILE_SITE and NFSU2_TURNSTILE_SECRET are never set: Cloudflare Access is
# the gate.
set -euo pipefail

log() { echo "nfsu2-startup: $*"; logger -t nfsu2-startup -- "$*" || true; }
fail() { log "ERROR: $*"; exit 1; }

md() {
  curl -fsS -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" 2> /dev/null || true
}
project() {
  curl -fsS -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/project/project-id"
}

SPEED2_SHA256="f9dd86c054878ce6276beb07c1fd61874f7a1e4bf1f241b084c65b73e24168a7"
DOCKER_KEY_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
BASE=/srv/nfsu2
RUNDIR=/run/nfsu2
COMPOSE_FILES="compose.yml:compose.tunnel.yml:compose.local.yml"
TOKEN_FILE="$RUNDIR/tunnel-token"
# the user of the cloudflare/cloudflared image (its Dockerfile at 2026.9.3: USER 65532:65532, distroless nonroot)
CLOUDFLARED_UID=65532

export DEBIAN_FRONTEND=noninteractive

install_docker() {
  if command -v docker > /dev/null 2>&1 && docker compose version > /dev/null 2>&1; then
    return 0
  fi
  log "installing Docker from Docker's apt repository"
  apt-get update -q
  apt-get install -y -q ca-certificates curl gnupg
  install -d -m 0755 /etc/apt/keyrings
  local key
  key="$(mktemp)"
  curl -fsSL https://download.docker.com/linux/debian/gpg -o "$key"
  # the key must be Docker's release key, whatever the download gave
  gpg --show-keys --with-colons "$key" | awk -F: '$1 == "fpr" { print $10; exit }' | grep -qx "$DOCKER_KEY_FPR" \
    || fail "Docker's apt key has an unexpected fingerprint"
  install -m 0644 "$key" /etc/apt/keyrings/docker.asc
  rm -f "$key"
  local codename
  # shellcheck source=/dev/null
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_unattended_upgrades() {
  if dpkg -s unattended-upgrades > /dev/null 2>&1; then
    return 0
  fi
  log "installing unattended-upgrades"
  apt-get update -q
  apt-get install -y -q unattended-upgrades
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
    > /etc/apt/apt.conf.d/20auto-upgrades
}

# The idle-shutdown timer: every 5 minutes, ask the server who plays (its control socket) and count the connections
# in its network namespace. With nobody for IDLE_MINUTES in a row, and the VM up that long, power off.
install_idle_shutdown() {
  local minutes="$1"
  printf 'IDLE_MINUTES=%s\n' "$minutes" > /etc/default/nfsu2-idle
  cat > /usr/local/sbin/nfsu2-idle-check <<'IDLE'
#!/usr/bin/env bash
# Installed by the nfsu2 startup script. Run by nfsu2-idle.timer every 5 minutes.
#
# Busy when either says so:
#   1. the server's control socket (/state/control.sock, newer servers): `nfsu2-server ctl who`, "N on the switch";
#   2. the server's network namespace (the `net` container's): ESTABLISHED TCP to port 8080, and connected Unix
#      stream sockets on @nfsu2-http (newer compose.tunnel.yml lets cloudflared use that socket).
# Idle only when nothing runs (no release) or both checks that apply say 0. Anything that fails counts as busy:
# an error never shuts the VM down.
set -uo pipefail
IDLE_MINUTES=30
# shellcheck source=/dev/null
[ -f /etc/default/nfsu2-idle ] && . /etc/default/nfsu2-idle
state=/run/nfsu2-idle
mkdir -p "$state"
limit=$(( IDLE_MINUTES * 60 ))
now="$(date +%s)"
up="$(cut -d. -f1 /proc/uptime)"

busy() {
  rm -f "$state/idle-since"
  echo "busy: $*"
  exit 0
}
service_id() {
  docker ps -q --filter label=com.docker.compose.project=nfsu2-web --filter "label=com.docker.compose.service=$1"
}

if ! net="$(service_id net)" || ! srv="$(service_id server)"; then
  busy "cannot determine (docker ps failed)"
fi
net="$(echo "$net" | head -1)"
srv="$(echo "$srv" | head -1)"

if [ -z "$net" ] && [ -z "$srv" ]; then
  echo "no game containers run: counted as idle"
else
  # 1. the control socket, when this server has one
  if [ -n "$srv" ] && timeout 20 docker exec "$srv" test -S /state/control.sock; then
    if ! out="$(timeout 20 docker exec "$srv" /app/nfsu2-server ctl who 2>&1)"; then
      busy "cannot determine (ctl who failed)"
    fi
    players="$(printf '%s\n' "$out" | head -1 | sed -n 's/^\([0-9][0-9]*\) on the switch.*/\1/p')"
    [ -n "$players" ] || busy "cannot determine (ctl who gave no count)"
    [ "$players" -eq 0 ] || busy "$players players on the switch"
    echo "control socket: 0 players on the switch"
  fi
  # 2. the connections in the server's namespace
  [ -n "$net" ] || busy "cannot determine (the net container is not running, the server is)"
  pid="$(timeout 20 docker inspect --format '{{.State.Pid}}' "$net" 2> /dev/null)" || busy "cannot determine (docker inspect failed)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || busy "cannot determine (no PID for the net container)"
  tcp="$(nsenter -t "$pid" -n ss -Htn state established '( sport = :8080 )')" || busy "cannot determine (ss -t failed)"
  unx="$(nsenter -t "$pid" -n ss -Hxn state established)" || busy "cannot determine (ss -x failed)"
  ntcp="$(printf '%s' "$tcp" | grep -c . || true)"
  nunx="$(printf '%s\n' "$unx" | grep -c -- '@nfsu2-http' || true)"
  [ "$ntcp" -eq 0 ] && [ "$nunx" -eq 0 ] || busy "$ntcp TCP connections to port 8080, $nunx on @nfsu2-http"
  echo "namespace: 0 connections to port 8080 or @nfsu2-http"
fi

[ -f "$state/idle-since" ] || echo "$now" > "$state/idle-since"
since="$(cat "$state/idle-since")"
idle=$(( now - since ))
echo "idle for $(( idle / 60 )) of $IDLE_MINUTES minutes, up $(( up / 60 )) minutes"
if [ "$idle" -ge "$limit" ] && [ "$up" -ge "$limit" ]; then
  echo "idle for $IDLE_MINUTES minutes: shutting down"
  shutdown -h now
fi
IDLE
  chmod 0755 /usr/local/sbin/nfsu2-idle-check
  cat > /etc/systemd/system/nfsu2-idle.service <<'UNIT'
[Unit]
Description=nfsu2: power off when nobody plays

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nfsu2-idle-check
UNIT
  cat > /etc/systemd/system/nfsu2-idle.timer <<'UNIT'
[Unit]
Description=nfsu2: check every 5 minutes whether anybody plays

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now nfsu2-idle.timer
}

# A wrapper so that the operator (and status.sh) run compose with the right files and env file.
install_compose_wrapper() {
  cat > /usr/local/bin/nfsu2-compose <<WRAP
#!/usr/bin/env bash
# Installed by the nfsu2 startup script: docker compose for the game, with its files and env file.
set -euo pipefail
cd "$BASE"
exec env COMPOSE_FILE="$COMPOSE_FILES" docker compose --env-file "$RUNDIR/.env" "\$@"
WRAP
  chmod 0755 /usr/local/bin/nfsu2-compose
}

sync_game() {
  local bucket="$1" remote local_marker="$BASE/game.marker"
  remote="$(gcloud storage cat "gs://${bucket}/meta/game-marker" 2> /dev/null || true)"
  [ -n "$remote" ] || fail "gs://${bucket}/meta/game-marker is missing: run upload-game.sh first"
  if [ -f "$BASE/game/SPEED2.EXE" ] && [ "$(cat "$local_marker" 2> /dev/null || true)" = "$remote" ]; then
    log "game folder is current (marker $remote)"
    return 0
  fi
  log "syncing the game folder from the bucket (marker $remote)"
  mkdir -p "$BASE/game"
  # --preserve-posix keeps the file times: they are part of the ETags
  gcloud storage rsync --recursive --preserve-posix --delete-unmatched-destination-objects \
    "gs://${bucket}/game" "$BASE/game"
  # owned by root, readable by everyone (the server runs as uid 1000); this keeps the file times
  chown -R root:root "$BASE/game"
  chmod -R u=rwX,go=rX "$BASE/game"
  [ "$(sha256sum "$BASE/game/SPEED2.EXE" | cut -d' ' -f1)" = "$SPEED2_SHA256" ] \
    || fail "SPEED2.EXE in the bucket has the wrong SHA-256"
  echo "$remote" > "$local_marker"
}

sync_release() {
  local bucket="$1" rel="$2" image="$3" dir="$BASE/releases/$2"
  if [ ! -f "$dir/.complete" ]; then
    log "fetching module and deploy files of $rel"
    rm -rf "$dir"
    mkdir -p "$dir/module" "$dir/deploy"
    gcloud storage cp "gs://${bucket}/releases/${rel}.json" "$dir/manifest.json"
    gcloud storage rsync --recursive --preserve-posix "gs://${bucket}/module/${rel}" "$dir/module"
    gcloud storage rsync --recursive --preserve-posix "gs://${bucket}/deploy/${rel}" "$dir/deploy"
    chown -R root:root "$dir"
    chmod -R u=rwX,go=rX "$dir"
    touch "$dir/.complete"
  fi
  local want_sha have_sha want_image
  want_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["wasm_sha256"])' "$dir/manifest.json")"
  want_image="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["image"])' "$dir/manifest.json")"
  have_sha="$(sha256sum "$dir/module/nfsu2.wasm" | cut -d' ' -f1)"
  [ "$want_sha" = "$have_sha" ] || fail "nfsu2.wasm of $rel does not match its manifest"
  [ "$want_image" = "$image" ] || fail "metadata nfsu2-image is not the image of release $rel's manifest"
  for f in compose.yml compose.tunnel.yml nfsu2.slice; do
    [ -f "$dir/deploy/$f" ] || fail "deploy/$rel/$f is missing in the bucket"
  done
}

prune_releases() {
  local keep="$1"
  # keep the current release and the two before it, by time
  local old
  old="$(find "$BASE/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' | sort -rn | awk 'NR > 3 { print $2 }')"
  local d
  for d in $old; do
    [ "$d" = "$keep" ] && continue
    log "removing old release $d"
    rm -rf "${BASE:?}/releases/$d"
  done
}

main() {
  local bucket host minutes rel image proj
  bucket="$(md nfsu2-bucket)"
  host="$(md nfsu2-host)"
  minutes="$(md nfsu2-idle-minutes)"
  rel="$(md nfsu2-release)"
  image="$(md nfsu2-image)"
  proj="$(project)"

  [[ "$minutes" =~ ^[0-9]+$ ]] || minutes=30
  install_unattended_upgrades
  install_docker
  # the timer goes in first: a VM without a release powers off too
  install_idle_shutdown "$minutes"
  install_compose_wrapper
  command -v gcloud > /dev/null 2>&1 || fail "gcloud is missing (the Debian image of GCE ships it)"

  if [ -z "$rel" ] || [ -z "$image" ]; then
    log "no release set (metadata nfsu2-release, nfsu2-image): nothing to start. Run fork/gcp/release.sh"
    exit 0
  fi
  [[ "$rel" =~ ^[0-9a-f]{40}$ ]] || fail "nfsu2-release is not a 40-character commit"
  [[ "$image" =~ ^[a-z0-9-]+-docker\.pkg\.dev/[a-z0-9-]+/[a-z0-9-]+/[a-z0-9-]+@sha256:[0-9a-f]{64}$ ]] \
    || fail "nfsu2-image is not an Artifact Registry image pinned by digest"
  [[ "$bucket" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] || fail "nfsu2-bucket is missing or invalid"
  [[ "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || fail "nfsu2-host is missing or invalid"

  mkdir -p "$BASE/releases"
  sync_game "$bucket"
  sync_release "$bucket" "$rel" "$image"
  local dir="$BASE/releases/$rel"

  install -m 0644 "$dir/deploy/compose.yml" "$BASE/compose.yml"
  install -m 0644 "$dir/deploy/compose.tunnel.yml" "$BASE/compose.tunnel.yml"
  if ! cmp -s "$dir/deploy/nfsu2.slice" /etc/systemd/system/nfsu2.slice; then
    install -m 0644 "$dir/deploy/nfsu2.slice" /etc/systemd/system/nfsu2.slice
    systemctl daemon-reload
  fi
  # one cloudflared, not the four of compose.tunnel.yml, reading its token from a file on tmpfs (never from its
  # environment: Docker keeps a container's environment on the disk, and so in the snapshots). An empty TUNNEL_TOKEN
  # replaces the placeholder of .env, and cloudflared then reads --token-file (cloudflared 2026.9.3,
  # cmd/cloudflared/tunnel/subcommands.go: the file only when the token flag or TUNNEL_TOKEN is empty). The bind
  # mount does not create a missing source: after a reboot cloudflared waits for this script to write the file.
  # The server in a cgroup namespace of its own (newer compose.yml says cgroup: host). NFSU2_COMPRESS_THREADS from
  # .env reaches the server (compose.yml does not pass it): 0 keeps no compressed copies of the game in the state
  # volume, and so none in the snapshots.
  cat > "$BASE/compose.local.yml" <<LOCAL
# Written by the nfsu2 startup script at every start. Do not edit: the next start replaces it.
services:
  cloudflared:
    scale: 1
    command: ["tunnel", "--no-autoupdate", "run", "--token-file", "/run/secrets/tunnel-token"]
    environment:
      TUNNEL_TOKEN: ""
    volumes:
      - type: bind
        source: $TOKEN_FILE
        target: /run/secrets/tunnel-token
        read_only: true
        bind:
          create_host_path: false
  server:
    cgroup: private
    environment:
      NFSU2_COMPRESS_THREADS: \${NFSU2_COMPRESS_THREADS:-0}
LOCAL

  # docker pulls from Artifact Registry with the VM's service account
  gcloud auth configure-docker "${image%%/*}" --quiet > /dev/null 2>&1

  install -d -m 0700 "$RUNDIR"
  # the tunnel token: only in this file on tmpfs, readable by cloudflared's user alone; never printed
  local token rotated=0
  token="$(gcloud secrets versions access latest --secret=nfsu2-tunnel-token --project="$proj" 2> /dev/null || true)"
  [ -n "$token" ] || fail "secret nfsu2-tunnel-token has no value (or the VM may not read it)"
  [[ "$token" =~ ^[A-Za-z0-9+/=_-]+$ ]] || fail "secret nfsu2-tunnel-token does not look like a tunnel token"
  # a directory in its place (Docker makes one for a missing bind source) goes first
  [ -d "$TOKEN_FILE" ] && rm -rf "$TOKEN_FILE"
  (
    umask 077
    printf '%s' "$token" > "$TOKEN_FILE.new"
  )
  unset token
  chown "$CLOUDFLARED_UID:$CLOUDFLARED_UID" "$TOKEN_FILE.new"
  chmod 0400 "$TOKEN_FILE.new"
  if [ -f "$TOKEN_FILE" ] && ! cmp -s "$TOKEN_FILE.new" "$TOKEN_FILE"; then
    rotated=1
  fi
  mv -f "$TOKEN_FILE.new" "$TOKEN_FILE"

  # the env file, on tmpfs, root only; it holds no secret (TUNNEL_TOKEN is a placeholder for compose.tunnel.yml's check)
  (
    umask 077
    {
      printf 'NFSU2_HOST=%s\n' "$host"
      printf 'NFSU2_DATA=%s\n' "$BASE/game"
      printf 'NFSU2_MODULE=%s\n' "$dir/module"
      printf 'NFSU2_IMAGE=%s\n' "$image"
      printf 'NFSU2_VAULT_GB=5\n'
      printf 'NFSU2_COMPRESS_THREADS=0\n'
      printf 'TUNNEL_TOKEN=unused-token-file\n'
      printf 'COMPOSE_FILE=%s\n' "$COMPOSE_FILES"
    } > "$RUNDIR/.env.new"
    mv -f "$RUNDIR/.env.new" "$RUNDIR/.env"
  )
  chmod 0600 "$RUNDIR/.env"

  log "starting release $rel"
  /usr/local/bin/nfsu2-compose up -d --remove-orphans
  # a new token: the running cloudflared still holds the old file (a bind mount keeps the inode)
  if [ "$rotated" = 1 ]; then
    log "the tunnel token changed: recreating cloudflared"
    /usr/local/bin/nfsu2-compose up -d --force-recreate cloudflared
  fi
  docker image prune -f > /dev/null 2>&1 || true
  prune_releases "$rel"
  log "release $rel is up"
}

main "$@"
