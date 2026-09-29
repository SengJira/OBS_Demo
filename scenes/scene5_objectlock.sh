#!/bin/bash
# Scene 5 - Object Lock / WORM. Requires IAM user creds (demo-writer) -
# object lock ops reject object users on this build.
set -u
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DEMO_DIR/bin/env.sh"
OUT=${1:-$DEMO_DIR/evidence}
mkdir -p "$OUT"
{
echo "=== Scene 5: Object Lock / WORM — $(date -u +%FT%TZ) ==="
: "${OBS_DEMOWRITER_AK:?run scene4_iam.sh first - needs IAM access keys}"
export AWS_ACCESS_KEY_ID=$OBS_DEMOWRITER_AK AWS_SECRET_ACCESS_KEY=$OBS_DEMOWRITER_SK
EP="$OBS_S3_HTTP"

echo "## create demo-lock bucket with object lock (auto-enables versioning)"
aws --endpoint-url "$EP" s3api create-bucket --bucket demo-lock \
  --object-lock-enabled-for-bucket 2>&1 | head -6
aws --endpoint-url "$EP" s3api get-object-lock-configuration --bucket demo-lock | head -10
aws --endpoint-url "$EP" s3api get-bucket-versioning --bucket demo-lock | head -6

echo; echo "## GOVERNANCE mode: put object retained until +2h"
RETAIN=$(date -u -d "+2 hours" +%FT%TZ)
aws --endpoint-url "$EP" s3api put-object --bucket demo-lock --key worm/record.txt \
  --body "$DEMO_DIR/samples/demo-file.txt" \
  --object-lock-mode GOVERNANCE --object-lock-retain-until-date "$RETAIN" | head -6
VID=$(aws --endpoint-url "$EP" s3api list-object-versions --bucket demo-lock \
  --prefix worm/record.txt --query 'Versions[0].VersionId' --output text)
aws --endpoint-url "$EP" s3api get-object-retention --bucket demo-lock \
  --key worm/record.txt --version-id "$VID" | head -8
echo "version=$VID"

echo; echo "## plain delete only adds a delete marker (versioned bucket) - version intact"
aws --endpoint-url "$EP" s3api delete-object --bucket demo-lock --key worm/record.txt | head -5
echo "## delete the RETAINED VERSION (expect AccessDenied)"
aws --endpoint-url "$EP" s3api delete-object --bucket demo-lock --key worm/record.txt \
  --version-id "$VID" 2>&1 | head -5
echo "## read the retained version (expect success)"
aws --endpoint-url "$EP" s3api get-object --bucket demo-lock --key worm/record.txt \
  --version-id "$VID" /tmp/s5.txt >/dev/null 2>&1 && diff "$DEMO_DIR/samples/demo-file.txt" /tmp/s5.txt && echo "read-back verified"
echo "## shorten retention (expect AccessDenied)"
aws --endpoint-url "$EP" s3api put-object-retention --bucket demo-lock \
  --key worm/record.txt --version-id "$VID" \
  --retention "{\"Mode\":\"GOVERNANCE\",\"RetainUntilDate\":\"$(date -u -d '+10 minutes' +%FT%TZ)\"}" 2>&1 | head -5
echo "## governance bypass works ONLY because demo-writer has s3:BypassGovernanceRetention"
aws --endpoint-url "$EP" s3api delete-object --bucket demo-lock --key worm/record.txt \
  --version-id "$VID" --bypass-governance-retention 2>&1 | head -5

echo; echo "## COMPLIANCE mode: cannot be bypassed even with s3:*"
RETAIN2=$(date -u -d "+75 minutes" +%FT%TZ)
aws --endpoint-url "$EP" s3api put-object --bucket demo-lock --key worm/compliance-record.txt \
  --body "$DEMO_DIR/samples/demo-file.txt" \
  --object-lock-mode COMPLIANCE --object-lock-retain-until-date "$RETAIN2" | head -6
VID2=$(aws --endpoint-url "$EP" s3api list-object-versions --bucket demo-lock \
  --prefix worm/compliance-record.txt --query 'Versions[0].VersionId' --output text)
echo "## bypass attempt on compliance object (expect AccessDenied despite s3:*)"
aws --endpoint-url "$EP" s3api delete-object --bucket demo-lock \
  --key worm/compliance-record.txt --version-id "$VID2" --bypass-governance-retention 2>&1 | head -5
aws --endpoint-url "$EP" s3api get-object --bucket demo-lock --key worm/compliance-record.txt \
  --version-id "$VID2" /tmp/s5b.txt >/dev/null 2>&1 && diff "$DEMO_DIR/samples/demo-file.txt" /tmp/s5b.txt && echo "read-back verified"
echo "NOTE: both retentions expire within ~2h; objects become deletable afterward."
echo "=== end scene5 ==="
} | tee "$OUT/scene5_objectlock.txt"
