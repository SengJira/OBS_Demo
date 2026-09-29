#!/bin/bash
# Scene 1 - S3 API compatibility sweep against bucket demo-s3compat.
# Usage: scenes/scene1_s3_api.sh [evidence_dir]
set -u
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DEMO_DIR/bin/env.sh"
OUT=${1:-$DEMO_DIR/evidence}
mkdir -p "$OUT"
BUCKET="demo-s3compat"
EP="$OBS_S3_HTTP"
AWS="aws --endpoint-url $EP"

run() {
  echo; echo "##### $*"
  "$@" 2>&1
  echo "   [exit=$?]"
}

{
echo "=== Scene 1: S3 API compatibility — $(date -u +%FT%TZ) ==="
echo "endpoint=$EP bucket=$BUCKET user=$OBS_S3_USER"

# ensure bucket exists (idempotent)
$AWS s3api head-bucket --bucket "$BUCKET" 2>/dev/null || $AWS s3 mb "s3://$BUCKET"

run $AWS s3api put-object --bucket "$BUCKET" --key doc/demo-file.txt \
    --body "$DEMO_DIR/samples/demo-file.txt" \
    --metadata "project=demo,owner=presales" \
    --tagging "env=demo&scene=1" \
    --content-type "text/plain"

run $AWS s3api put-object --bucket "$BUCKET" --key data/demo.csv \
    --body "$DEMO_DIR/samples/demo.csv" --tagging "env=demo"

run $AWS s3api head-object --bucket "$BUCKET" --key doc/demo-file.txt
run $AWS s3api get-object --bucket "$BUCKET" --key doc/demo-file.txt /tmp/scene1-get.txt
run diff "$DEMO_DIR/samples/demo-file.txt" /tmp/scene1-get.txt
run $AWS s3api list-objects-v2 --bucket "$BUCKET" --prefix doc/
run $AWS s3api list-objects-v2 --bucket "$BUCKET"
run $AWS s3api get-object-tagging --bucket "$BUCKET" --key doc/demo-file.txt
run $AWS s3api get-object-attributes --bucket "$BUCKET" --key doc/demo-file.txt \
    --object-attributes ETag ObjectSize Checksum 2>/dev/null || true

echo; echo "##### multipart upload (create/upload-parts/complete/verify)"
MPU_KEY="mp/big-file.bin"
MPU_JSON=$($AWS s3api create-multipart-upload --bucket "$BUCKET" --key "$MPU_KEY" 2>&1)
echo "$MPU_JSON"
UPLOAD_ID=$(printf '%s' "$MPU_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['UploadId'])" 2>/dev/null)
if [ -n "$UPLOAD_ID" ]; then
  split -b 6M "$DEMO_DIR/samples/big-file.bin" /tmp/mp-part-
  i=0; ETAGS=""
  for p in /tmp/mp-part-*; do
    i=$((i+1))
    ETAG=$($AWS s3api upload-part --bucket "$BUCKET" --key "$MPU_KEY" \
        --part-number $i --upload-id "$UPLOAD_ID" --body "$p" 2>/dev/null \
        | python3 -c "import json,sys;print(json.load(sys.stdin)['ETag'])")
    echo "part $i etag=$ETAG"
    ETAGS="$ETAGS{\"ETag\":$ETAG,\"PartNumber\":$i},"
  done
  run $AWS s3api list-parts --bucket "$BUCKET" --key "$MPU_KEY" --upload-id "$UPLOAD_ID"
  run $AWS s3api complete-multipart-upload --bucket "$BUCKET" --key "$MPU_KEY" \
      --upload-id "$UPLOAD_ID" --multipart-upload "{\"Parts\":[${ETAGS%,}]}"
  run $AWS s3api head-object --bucket "$BUCKET" --key "$MPU_KEY"
  $AWS s3api get-object --bucket "$BUCKET" --key "$MPU_KEY" /tmp/scene1-mpu.bin >/dev/null 2>&1
  run md5sum "$DEMO_DIR/samples/big-file.bin" /tmp/scene1-mpu.bin
fi

echo; echo "##### presigned URL"
URL=$($AWS s3 presign "s3://$BUCKET/doc/demo-file.txt" --expires-in 300)
echo "presigned=$URL"
run curl -s "$URL" -o /tmp/scene1-presign.txt -w 'http=%{http_code}\n'
run diff "$DEMO_DIR/samples/demo-file.txt" /tmp/scene1-presign.txt

echo; echo "##### bucket-level ops"
run $AWS s3api put-bucket-tagging --bucket "$BUCKET" --tagging 'TagSet=[{Key=env,Value=demo},{Key=demo,Value=objectscale}]'
run $AWS s3api get-bucket-tagging --bucket "$BUCKET"
run $AWS s3api get-bucket-acl --bucket "$BUCKET"
run $AWS s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
run $AWS s3api get-bucket-versioning --bucket "$BUCKET"
run $AWS s3api get-bucket-location --bucket "$BUCKET"
run $AWS s3api get-bucket-cors --bucket "$BUCKET"
run $AWS s3api get-bucket-encryption --bucket "$BUCKET"
run $AWS s3api get-bucket-policy --bucket "$BUCKET"
run $AWS s3api get-public-access-block --bucket "$BUCKET"
run $AWS s3api get-object-lock-configuration --bucket "$BUCKET"
run $AWS s3api list-object-versions --bucket "$BUCKET" --prefix doc/ --max-items 5
echo "=== end scene1 ==="
} | tee "$OUT/scene1_s3api.txt"
