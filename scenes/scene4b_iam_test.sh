#!/bin/bash
# Scene 4b - exercise least-privilege access with IAM user keys.
set -u
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DEMO_DIR/bin/env.sh"
OUT=${1:-$DEMO_DIR/evidence}
mkdir -p "$OUT"
{
echo "=== Scene 4b: IAM allow/deny tests — $(date -u +%FT%TZ) ==="
if [ -z "${OBS_DEMOREADER_AK:-}" ]; then echo "OBS_DEMOREADER_AK not in env - run scene4_iam.sh first"; exit 1; fi

R_AK="$OBS_DEMOREADER_AK"; R_SK="$OBS_DEMOREADER_SK"
W_AK="${OBS_DEMOWRITER_AK:-}"; W_SK="${OBS_DEMOWRITER_SK:-}"

echo "## demo-reader GET (expect allow)"
AWS_ACCESS_KEY_ID=$R_AK AWS_SECRET_ACCESS_KEY=$R_SK aws --endpoint-url "$OBS_S3_HTTP" \
  s3api get-object --bucket demo-s3compat --key doc/demo-file.txt /tmp/s4.txt 2>&1 | head -8
echo "## demo-reader PUT (expect AccessDenied)"
AWS_ACCESS_KEY_ID=$R_AK AWS_SECRET_ACCESS_KEY=$R_SK aws --endpoint-url "$OBS_S3_HTTP" \
  s3api put-object --bucket demo-s3compat --key data/nope.txt --body "$DEMO_DIR/samples/demo-file.txt" 2>&1 | head -6
if [ -n "$W_AK" ]; then
  echo "## demo-writer PUT (expect allow)"
  AWS_ACCESS_KEY_ID=$W_AK AWS_SECRET_ACCESS_KEY=$W_SK aws --endpoint-url "$OBS_S3_HTTP" \
    s3api put-object --bucket demo-s3compat --key data/writer.txt --body "$DEMO_DIR/samples/demo-file.txt" 2>&1 | head -6
  echo "## demo-writer DELETE on protected/ (expect AccessDenied via bucket policy)"
  AWS_ACCESS_KEY_ID=$W_AK AWS_SECRET_ACCESS_KEY=$W_SK aws --endpoint-url "$OBS_S3_HTTP" \
    s3api delete-object --bucket demo-s3compat --key protected/important.txt 2>&1 | head -6
fi
echo "## current bucket policy (scoped deny)"
aws --endpoint-url "$OBS_S3_HTTP" s3api get-bucket-policy --bucket demo-s3compat | head -14
echo "=== end scene4b ==="
} | tee "$OUT/scene4_iam_test.txt"
