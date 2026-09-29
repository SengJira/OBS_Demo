#!/bin/bash
# Scene 9 - Copy to Cloud: show the bucket copy-policy API and inspect whether
# any authorized external destination/credentials exist. Read-only by default.
set -u
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DEMO_DIR/bin/env.sh"
OUT=${1:-$DEMO_DIR/evidence}
mkdir -p "$OUT"
UI="$DEMO_DIR/bin/uicall.sh"
{
echo "=== Scene 9: copy to cloud — $(date -u +%FT%TZ) ==="
echo "## bucket copy-policy state on demo-s3compat (ObjectScale 'Copy to Cloud')"
$UI GET "/bucket/demo-s3compat/ns1/copypolicy"
echo; echo "## bucket copy-policy on demo-copycloud"
$UI GET "/bucket/demo-copycloud/ns1/copypolicy"
echo; echo "## certificate authorities registered for external TLS endpoints"
$UI GET "/rest/v1/x509-certificates" 2>/dev/null | head -c 600
echo; echo "## external key servers / cloud targets"
$UI GET /externalKeyServers/listClusters
echo; echo "## migration service (TransformSvc)"
$UI GET /migrations/service/status
echo; echo "No authorized cloud destination or credentials are configured in this"
echo "lab, so no copy is performed. See docs/scene9_copy_to_cloud.md for the"
echo "ready-to-run procedure and bill of materials."
echo "=== end scene9 ==="
} | tee "$OUT/scene9_copy2cloud.txt"
