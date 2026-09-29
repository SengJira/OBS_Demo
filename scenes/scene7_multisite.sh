#!/bin/bash
# Scene 7 - multisite / active-active inspection. Does NOT create federation.
set -u
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DEMO_DIR/bin/env.sh"
OUT=${1:-$DEMO_DIR/evidence}
mkdir -p "$OUT"
UI="$DEMO_DIR/bin/uicall.sh"
{
echo "=== Scene 7: multisite inspection — $(date -u +%FT%TZ) ==="
echo "## VDCs (sites)"
$UI GET /vdcs
echo; echo "## replication groups"
$UI GET /replicationgroups
echo; echo "## geo connection transport"
$UI GET /rest/v1/geoConnection/status
echo; echo "## replication group detail"
$UI GET "/replicationgroup/get/urn:storageos:ReplicationGroupInfo:5434aaca-3b43-4eb0-bf2e-8291058cf6fb:global"
echo; echo "## VDC dashboard (geo)"
"$DEMO_DIR/bin/mgmt.sh" GET "/dashboard/zones/localzone/replicationgroups?category=geo"
echo
echo "SITES=$( $UI GET /vdcs | python3 -c "import json,sys;print(len(json.load(sys.stdin)['data']))" 2>/dev/null )"
echo "=== end scene7 ==="
} | tee "$OUT/scene7_multisite.txt"
