#!/bin/bash
# Scene 6 - lifecycle rules: configure on disposable bucket, show rule, document
# realistic observation window (do NOT claim expiration happened).
set -u
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DEMO_DIR/bin/env.sh"
OUT=${1:-$DEMO_DIR/evidence}
mkdir -p "$OUT"
BUCKET="demo-lifecycle"
EP="$OBS_S3_HTTP"
{
echo "=== Scene 6: lifecycle — $(date -u +%FT%TZ) ==="
aws --endpoint-url "$EP" s3api head-bucket --bucket "$BUCKET" 2>/dev/null \
  || aws --endpoint-url "$EP" s3 mb "s3://$BUCKET"

aws --endpoint-url "$EP" s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration '{
    "Rules": [
      {"ID":"demo-expire-tmp-1d","Status":"Enabled",
       "Filter":{"Prefix":"tmp/"},"Expiration":{"Days":1}},
      {"ID":"demo-expire-versioned","Status":"Enabled",
       "Filter":{"Prefix":"logs/"},
       "NoncurrentVersionExpiration":{"NoncurrentDays":1}}
    ]}'

echo "## rule as stored:"
aws --endpoint-url "$EP" s3api get-bucket-lifecycle-configuration --bucket "$BUCKET"

aws --endpoint-url "$EP" s3api put-object --bucket "$BUCKET" --key tmp/scratch.txt \
  --body "$DEMO_DIR/samples/demo-file.txt" >/dev/null
echo "## object written to tmp/ - expiration requires the bucket lifecycle scanner"
echo "## to run; Dell ObjectScale evaluates rules periodically (typically daily)."
echo "## Expected earliest effect: ~24h after rule creation."
aws --endpoint-url "$EP" s3api head-object --bucket "$BUCKET" --key tmp/scratch.txt | head -12
echo "=== end scene6 ==="
} | tee "$OUT/scene6_lifecycle.txt"
