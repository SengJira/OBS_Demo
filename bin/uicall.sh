#!/bin/bash
# uicall.sh <METHOD> <path> [curl args...]
# Calls the ObjectScale portal API on :443 using a cached UI session
# (ECSAuthToken + XSRF-TOKEN). Session cached in $OBS_UI_SESSION.
SESS_FILE=${OBS_UI_SESSION:-$HOME/.config/obs-demo/.ui_session.json}
BIN_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -s "$SESS_FILE" ]; then
  python3 "$BIN_DIR/ui_session.py" "$SESS_FILE" || exit 2
fi
AT=$(python3 -c "import json;print(json.load(open('$SESS_FILE'))['authToken'])")
XS=$(python3 -c "import json;print(json.load(open('$SESS_FILE'))['xsrf'])")
M=$1; shift; P=$1; shift

body=$(curl -sk -w '\n__HTTP__%{http_code}' -X "$M" \
  -H "X-SDS-AUTH-TOKEN: $AT" -H "X-XSRF-TOKEN: $XS" \
  -H "Cookie: XSRF-TOKEN=$XS; ECSAuthToken=$AT" \
  -H 'Accept: application/json' \
  "https://192.168.1.31$P" "$@")
code=$(printf '%s' "$body" | grep -oE '__HTTP__[0-9]+' | grep -oE '[0-9]+$')
if printf '%s' "$body" | grep -q '401' && [ "$code" != "200" ]; then
  # session expired: re-login once and retry
  rm -f "$SESS_FILE"
  python3 "$BIN_DIR/ui_session.py" "$SESS_FILE" || exit 2
  AT=$(python3 -c "import json;print(json.load(open('$SESS_FILE'))['authToken'])")
  XS=$(python3 -c "import json;print(json.load(open('$SESS_FILE'))['xsrf'])")
  body=$(curl -sk -X "$M" \
    -H "X-SDS-AUTH-TOKEN: $AT" -H "X-XSRF-TOKEN: $XS" \
    -H "Cookie: XSRF-TOKEN=$XS; ECSAuthToken=$AT" \
    -H 'Accept: application/json' \
    "https://192.168.1.31$P" "$@")
  printf '%s' "$body"
else
  printf '%s' "$body" | sed 's/__HTTP__[0-9]*$//'
fi
