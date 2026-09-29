#!/bin/bash
# Scene 3 - Encryption: TLS transfer + D@RE evidence + SSE header probe.
set -u
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DEMO_DIR/bin/env.sh"
OUT=${1:-$DEMO_DIR/evidence}
mkdir -p "$OUT"
BUCKET="demo-s3compat"
{
echo "=== Scene 3: encryption — $(date -u +%FT%TZ) ==="
echo "## TLS handshake on S3 HTTPS endpoint $OBS_S3_HTTPS"
echo | openssl s_client -connect "$(echo "$OBS_S3_HTTPS" | sed 's|https://||')" -servername 192.168.1.31 2>/dev/null \
  | grep -E "Protocol|Cipher|Verify|subject=|issuer=|notBefore|notAfter" 
echo | openssl s_client -connect "$(echo "$OBS_S3_HTTPS" | sed 's|https://||')" 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -fingerprint -sha256

echo; echo "## TLS S3 transfer (GET over HTTPS)"
aws --endpoint-url "$OBS_S3_HTTPS" --no-verify-ssl s3api get-object \
  --bucket "$BUCKET" --key doc/demo-file.txt /tmp/scene3-tls.txt 2>&1 | head -12
echo "tls_get_exit=$?"
diff "$DEMO_DIR/samples/demo-file.txt" /tmp/scene3-tls.txt && echo "TLS round-trip content verified"

echo; echo "## SSE-S3 header probe (x-amz-server-side-encryption AES256)"
aws --endpoint-url "$OBS_S3_HTTP" s3api put-object --bucket "$BUCKET" \
  --key tmp/sse-probe.txt --body "$DEMO_DIR/samples/demo-file.txt" \
  --server-side-encryption AES256 2>&1 | head -8
echo; echo "## SSE-C (customer key) probe"
aws --endpoint-url "$OBS_S3_HTTP" s3api put-object --bucket "$BUCKET" \
  --key tmp/ssec-probe.txt --body "$DEMO_DIR/samples/demo-file.txt" \
  --sse-customer-algorithm AES256 \
  --sse-customer-key "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MA==" 2>&1 | head -8
echo; echo "## bucket default encryption config"
aws --endpoint-url "$OBS_S3_HTTP" s3api get-bucket-encryption --bucket "$BUCKET" 2>&1 | head -8
echo "=== end scene3 ==="
} | tee "$OUT/scene3_encryption.txt"
