#!/bin/bash
# Scene 4 - IAM least-privilege identities + bucket policy.
# Needs a portal session (bin/uicall.sh) for IAM admin, and IAM access keys
# (created here, appended to ~/.config/obs-demo/env when absent).
set -u
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DEMO_DIR/bin/env.sh"
OUT=${1:-$DEMO_DIR/evidence}
mkdir -p "$OUT"
UI="$DEMO_DIR/bin/uicall.sh"
iam() { $UI POST /iam -d "$1" -H 'Content-Type: application/x-www-form-urlencoded' -H "x-emc-namespace: $OBS_S3_NAMESPACE"; }

{
echo "=== Scene 4: IAM & bucket policies — $(date -u +%FT%TZ) ==="
echo "## ensure IAM users"
for u in demo-reader demo-writer; do
  iam "Action=GetUser&UserName=$u&Namespace=$OBS_S3_NAMESPACE" | head -c 400; echo
done

echo; echo "## create access keys (stored only in env file)"
for u in demo-reader demo-writer; do
  K=$(iam "Action=ListAccessKeys&UserName=$u&Namespace=$OBS_S3_NAMESPACE")
  echo "$K" | head -c 400; echo
  if ! echo "$K" | grep -q AccessKeyId; then
    K2=$(iam "Action=CreateAccessKey&UserName=$u&Namespace=$OBS_S3_NAMESPACE")
    echo "$K2" | sed 's/\"SecretAccessKey\":\"[^\"]*\"/\"SecretAccessKey\":\"<redacted>\"/' | head -c 400; echo
    AK=$(echo "$K2" | python3 -c "import json,sys;print(json.loads(json.load(sys.stdin)['data'])['CreateAccessKeyResult']['AccessKey']['AccessKeyId'])" 2>/dev/null)
    SK=$(echo "$K2" | python3 -c "import json,sys;print(json.loads(json.load(sys.stdin)['data'])['CreateAccessKeyResult']['AccessKey']['SecretAccessKey'])" 2>/dev/null)
    if [ -n "$AK" ] && [ -n "$SK" ]; then
      printf 'OBS_%s_AK=%s\nOBS_%s_SK=%s\n' "$(echo $u|tr -d -|tr a-z A-Z)" "$AK" "$(echo $u|tr -d -|tr a-z A-Z)" "$SK" >> "${OBS_DEMO_ENV:-$HOME/.config/obs-demo/env}"
      echo "stored ${u} key in env file (not committed)"
    fi
  fi
done

echo; echo "## attach least-privilege inline policies"
# demo-reader: read-only on demo-s3compat
iam "Action=PutUserPolicy&UserName=demo-reader&PolicyName=demo-read-demo-s3compat&Namespace=$OBS_S3_NAMESPACE&PolicyDocument=$(python3 -c 'import urllib.parse;print(urllib.parse.quote("""{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::demo-s3compat\",\"arn:aws:s3:::demo-s3compat/*\"]}]}\"\"\"))')" | head -c 400; echo
# demo-writer: write on demo-s3compat
iam "Action=PutUserPolicy&UserName=demo-writer&PolicyName=demo-write-demo-s3compat&Namespace=$OBS_S3_NAMESPACE&PolicyDocument=$(python3 -c 'import urllib.parse;print(urllib.parse.quote("""{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\",\"s3:ListBucket\",\"s3:DeleteObject\"],\"Resource\":[\"arn:aws:s3:::demo-s3compat\",\"arn:aws:s3:::demo-s3compat/*\"]}]}\"\"\"))')" | head -c 400; echo

echo "=== end scene4 part1 ==="
} | tee "$OUT/scene4_iam_admin.txt"
echo "Now run scenes/scene4b_iam_test.sh after env file contains OBS_DEMOREADER_* keys"
