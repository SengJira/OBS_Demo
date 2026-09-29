#!/bin/bash
# mgmt.sh <METHOD> <path> [curl args...]
# Calls the ObjectScale management REST API on :4443 with a CACHED X-SDS-AUTH-TOKEN.
# IMPORTANT: do not mint a token per call — the system caps tokens per user and
# exhausted tokens take hours to expire. Token cached in $TOKEN_FILE.
source "${OBS_DEMO_ENV:-$HOME/.config/obs-demo/env}"
TOKEN_FILE=${OBS_TOKEN_FILE:-$HOME/.config/obs-demo/.token}
touch "$TOKEN_FILE" 2>/dev/null || TOKEN_FILE=/tmp/.obs_token
chmod 600 "$TOKEN_FILE" 2>/dev/null

get_token() {
  if [ -s "$TOKEN_FILE" ]; then cat "$TOKEN_FILE"; return; fi
  local t
  t=$(curl -sk -D - -o /dev/null -u "$OBS_MGMT_USER:$OBS_MGMT_PASS" \
      "https://$OBS_MGMT_HOST:$OBS_MGMT_PORT/login" \
      | awk '/X-SDS-AUTH-TOKEN/{print $2}' | tr -d '\r')
  [ -n "$t" ] && printf '%s' "$t" > "$TOKEN_FILE"
  printf '%s' "$t"
}

TOKEN=$(get_token)
if [ -z "$TOKEN" ]; then echo "ERROR: could not obtain mgmt token (limit reached?)" >&2; exit 2; fi

METHOD=$1; shift; P=$1; shift
out=$(curl -sk -w '\n__HTTP__%{http_code}' -X "$METHOD" \
  -H "X-SDS-AUTH-TOKEN: $TOKEN" -H 'Accept: application/json' -H 'Content-Type: application/json' \
  "https://$OBS_MGMT_HOST:$OBS_MGMT_PORT$P" "$@")
code=$(printf '%s' "$out" | grep -oE '__HTTP__[0-9]+' | grep -oE '[0-9]+')
if [ "$code" = "401" ] || [ "$code" = "302" ]; then
  rm -f "$TOKEN_FILE"
  TOKEN=$(get_token)
  [ -z "$TOKEN" ] && { echo "ERROR: token refresh failed" >&2; exit 2; }
  out=$(curl -sk -X "$METHOD" -H "X-SDS-AUTH-TOKEN: $TOKEN" \
    -H 'Accept: application/json' -H 'Content-Type: application/json' \
    "https://$OBS_MGMT_HOST:$OBS_MGMT_PORT$P" "$@")
else
  printf '%s' "$out" | sed 's/__HTTP__[0-9]*$//'
fi
