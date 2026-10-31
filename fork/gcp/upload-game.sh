#!/usr/bin/env bash
# Upload your game folder's game files to gs://<bucket>/game/, keeping file times (they are part of the ETags).
# Only the files the server serves go up: SPEED2.EXE, server.dll, server.cfg, the data folders, and LANGPACKS if
# present. Never a SAVE folder, an installer's log, mod settings or dot files. Run it again after a change: rsync
# sends only what changed, and the VM syncs the folder again at its next start.
#
#   fork/gcp/upload-game.sh "<your game folder>"
#   DRY_RUN=1 fork/gcp/upload-game.sh "<your game folder>"
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"

DIR="${1:-}"
[ -n "$DIR" ] && [ -d "$DIR" ] || die "usage: upload-game.sh <game folder> (the folder with SPEED2.EXE)"
load_config

SPEED2_SHA256="f9dd86c054878ce6276beb07c1fd61874f7a1e4bf1f241b084c65b73e24168a7"
SPEED2_SIZE=4800512
REQUIRED="SPEED2.EXE server.dll server.cfg CARS CREDITS FRONTEND GLOBAL LANGUAGES memcard MOVIES NIS pfdata SOUND speech SUBTITLES TRACKS"
OPTIONAL="LANGPACKS"

# the name each entry has in this folder, compared without case (a folder may say Sound for SOUND)
actual_name() {
  local want="$1" entry base
  for entry in "$DIR"/*; do
    base="$(basename "$entry")"
    if [ "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')" ]; then
      printf '%s' "$base"
      return 0
    fi
  done
  return 1
}

exe="$(actual_name SPEED2.EXE)" || die "no SPEED2.EXE in $DIR"
size="$(wc -c < "$DIR/$exe" | tr -d ' ')"
[ "$size" = "$SPEED2_SIZE" ] || die "$exe has $size bytes, not $SPEED2_SIZE: this is not v1.2 NA"
[ "$(sha256_of "$DIR/$exe")" = "$SPEED2_SHA256" ] || die "$exe has the wrong SHA-256: this is not v1.2 NA"
say "SPEED2.EXE is v1.2 NA"

names=()
missing=()
for want in $REQUIRED; do
  if n="$(actual_name "$want")"; then names+=("$n"); else missing+=("$want"); fi
done
[ "${#missing[@]}" = 0 ] || die "missing in $DIR: ${missing[*]}"
for want in $OPTIONAL; do
  if n="$(actual_name "$want")"; then names+=("$n"); fi
done

# one regular expression that excludes everything but these names at the top, and every dot file anywhere.
# gcloud matches it from the start of each relative path. (It must not start with ^: gcloud reads a leading ^ as
# a list delimiter.)
alts=""
for n in "${names[@]}"; do
  [[ "$n" =~ ^[A-Za-z0-9._-]+$ ]] || die "unexpected name '$n' in $DIR"
  alts="${alts:+$alts|}${n//./\\.}"
done
exclude="(?:^(?!(?:${alts})(?:/|$)))|(?:(?:.*/)?\\..*)"
say "uploading: ${names[*]}"

# --preserve-posix stores the file times (and modes) as object metadata; the VM restores them on download
run gcloud --project="$PROJECT_ID" storage rsync --recursive --preserve-posix \
  --delete-unmatched-destination-objects --exclude="$exclude" "$DIR" "${GS}/game"

# the marker tells the VM that the folder changed (it lives outside game/, so it is never served)
marker="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if is_dry; then
  run gcloud --project="$PROJECT_ID" storage cp - "${GS}/meta/game-marker"
else
  printf '%s\n' "$marker" | gcloud --project="$PROJECT_ID" storage cp - "${GS}/meta/game-marker"
fi
say "done (marker $marker)"
