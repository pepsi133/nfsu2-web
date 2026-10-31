#!/usr/bin/env bash
# Make Cloudflare Access match Secret Manager: the Access application allows Google login only (no one-time PIN),
# redirects to it at once and keeps a session 168 hours; its Allow policy includes exactly the emails of the
# secret nfsu2-allowlist (one per line). The Cloudflare API token comes from the secret nfsu2-cloudflare-api-token.
# Neither value is printed, passed on a command line or written anywhere but a 0600 temporary folder.
# It prints counts and HTTP status codes only.
#
#   fork/gcp/access-sync.sh            DRY_RUN=1 fork/gcp/access-sync.sh
#
# The API token needs: Account, Access: Apps and Policies, Edit.
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$0")/lib.sh"
load_config

[[ "${CF_ACCOUNT_ID:-}" =~ ^[0-9a-f]{32}$ ]] || die "CF_ACCOUNT_ID in config.env must be 32 hex characters"
uuid='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
[[ "${CF_ACCESS_APP_ID:-}" =~ $uuid ]] || die "CF_ACCESS_APP_ID in config.env must be a UUID"
[[ "${CF_ACCESS_POLICY_ID:-}" =~ $uuid ]] || die "CF_ACCESS_POLICY_ID in config.env must be a UUID"
[[ "${CF_GOOGLE_IDP_ID:-}" =~ $uuid ]] || die "CF_GOOGLE_IDP_ID in config.env must be a UUID"
command -v python3 > /dev/null 2>&1 || die "python3 is needed"
command -v curl > /dev/null 2>&1 || die "curl is needed"

API="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/access"
APP_PATH="${API}/apps/${CF_ACCESS_APP_ID}"
POLICY_PATH="${API}/policies/${CF_ACCESS_POLICY_ID}"

umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- the two secrets, into variables only
if is_dry; then
  capture gcloud --project="$PROJECT_ID" secrets versions access latest --secret=nfsu2-cloudflare-api-token
  capture gcloud --project="$PROJECT_ID" secrets versions access latest --secret=nfsu2-allowlist
  token=""
  allowlist="friend@example.com"
else
  token="$(gcloud --project="$PROJECT_ID" secrets versions access latest --secret=nfsu2-cloudflare-api-token 2> /dev/null)" \
    || die "cannot read secret nfsu2-cloudflare-api-token (no version yet?)"
  allowlist="$(gcloud --project="$PROJECT_ID" secrets versions access latest --secret=nfsu2-allowlist 2> /dev/null)" \
    || die "cannot read secret nfsu2-allowlist (no version yet?)"
  [[ "$token" =~ ^[A-Za-z0-9_-]+$ ]] || die "secret nfsu2-cloudflare-api-token does not look like an API token"
fi

# --- the allowlist: one email per line; blank lines and lines starting with # are skipped
emails="$tmp/emails"
: > "$emails"
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$(( lineno + 1 ))
  line="$(printf '%s' "$line" | tr -d '[:space:]')"
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  valid_email "$line" || die "line $lineno of nfsu2-allowlist is not an email address"
  printf '%s\n' "$line" | tr '[:upper:]' '[:lower:]' >> "$emails"
done <<< "$allowlist"
unset allowlist
sort -u -o "$emails" "$emails"
count="$(grep -c . "$emails" || true)"
[ "$count" -gt 0 ] || die "nfsu2-allowlist has no email: refusing to set a policy that lets nobody in"
say "allowlist: $count emails"

# cf METHOD URL OUT [BODY]: one API call; the token goes to curl as a config on stdin. Prints the HTTP status.
cf() {
  local method="$1" url="$2" out="$3" body="${4:-}"
  local args=(--silent --show-error --output "$out" --write-out '%{http_code}' --request "$method"
    --header 'Content-Type: application/json' "$url")
  [ -n "$body" ] && args+=(--data-binary "@$body")
  if is_dry; then
    { printf '[dry-run] curl --config - (Authorization header from stdin)'
      printf ' %q' "${args[@]}"
      printf '\n'; } >&2
    echo "{}" > "$out"
    printf '200'
    return 0
  fi
  printf 'header = "Authorization: Bearer %s"\n' "$token" | curl --config - "${args[@]}"
}

check() {
  local what="$1" code="$2"
  say "$what: HTTP $code"
  [ "$code" = 200 ] || die "$what failed"
}

# --- the application: Google only, straight to it, 168 h
code="$(cf GET "$APP_PATH" "$tmp/app.json")"
check "read application" "$code"
if ! is_dry; then
  python3 - "$tmp/app.json" "$CF_GOOGLE_IDP_ID" > "$tmp/app-put.json" <<'PY'
import json, sys
app = json.load(open(sys.argv[1]))["result"]
for k in ("id", "uid", "aud", "created_at", "updated_at"):
    app.pop(k, None)
if isinstance(app.get("policies"), list):
    app["policies"] = [{"id": p["id"], "precedence": p.get("precedence")} if isinstance(p, dict) else p
                       for p in app["policies"]]
app["allowed_idps"] = [sys.argv[2]]
app["auto_redirect_to_identity"] = True
app["session_duration"] = "168h"
json.dump(app, sys.stdout)
PY
else
  echo "{}" > "$tmp/app-put.json"
fi
code="$(cf PUT "$APP_PATH" "$tmp/app.out" "$tmp/app-put.json")"
check "update application (allowed_idps 1, auto redirect, 168h)" "$code"

# --- the policy: include = the allowlist
code="$(cf GET "$POLICY_PATH" "$tmp/policy.json")"
check "read policy" "$code"
if ! is_dry; then
  python3 - "$tmp/policy.json" "$emails" > "$tmp/policy-put.json" <<'PY'
import json, sys
pol = json.load(open(sys.argv[1]))["result"]
if pol.get("decision") != "allow":
    sys.exit("access-sync: the policy is not an Allow policy")
keep = ("name", "decision", "exclude", "require", "session_duration", "approval_required", "approval_groups",
        "isolation_required", "purpose_justification_required", "purpose_justification_prompt")
out = {k: pol[k] for k in keep if k in pol}
out["include"] = [{"email": {"email": e.strip()}} for e in open(sys.argv[2]) if e.strip()]
json.dump(out, sys.stdout)
PY
else
  echo "{}" > "$tmp/policy-put.json"
fi
code="$(cf PUT "$POLICY_PATH" "$tmp/policy.out" "$tmp/policy-put.json")"
check "update policy (include $count emails)" "$code"
say "done"
