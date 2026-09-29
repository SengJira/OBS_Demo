#!/bin/bash
# setup.sh [--dry-run]
# Idempotent creation of all demo-* resources for the ObjectScale presales demo.
# Requires ~/.config/obs-demo/env (see .env.example). Creates:
#   - object user demo-s3user (+ S3 key, written to the env file)
#   - IAM users demo-reader / demo-writer (+ access keys appended to env file)
#   - buckets: demo-s3compat, demo-nfs-share (fs enabled), demo-lock (object lock),
#              demo-lifecycle, demo-copycloud
#   - NFS export /ns1/demo-nfs-share with root mapped to demo-s3user
#   - scoped deny bucket policy on demo-s3compat
#   - lifecycle rules on demo-lifecycle
set -u
DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DEMO_DIR/bin/env.sh" || { echo "env file missing - see .env.example"; exit 1; }
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
RUN() { if [ $DRY -eq 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }

MGMT="$DEMO_DIR/bin/mgmt.sh"
UI="$DEMO_DIR/bin/uicall.sh"
AWS="aws --endpoint-url $OBS_S3_HTTP"
ENV_FILE=${OBS_DEMO_ENV:-$HOME/.config/obs-demo/env}

VPOOL=$($MGMT GET /object/namespaces/namespace/ns1 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('default_data_services_vpool',''))" 2>/dev/null)
[ -z "$VPOOL" ] && VPOOL="urn:storageos:ReplicationGroupInfo:5434aaca-3b43-4eb0-bf2e-8291058cf6fb:global"

echo "### setup: ObjectScale demo (dry-run=$DRY)"

# --- object user demo-s3user ---------------------------------------------
if $MGMT GET "/object/users/$OBS_S3_NAMESPACE" 2>/dev/null | grep -q "\"$OBS_S3_USER\""; then
  echo "user $OBS_S3_USER exists"
else
  RUN $UI POST /users/object -d "{\"name\":\"$OBS_S3_USER\",\"namespace\":\"$OBS_S3_NAMESPACE\",\"metadata\":[]}"
  KEY=$($MGMT POST "/object/user-secret-keys/$OBS_S3_USER" -d '{}' | python3 -c "import json,sys;print(json.load(sys.stdin)['secret_key'])")
  if [ -n "$KEY" ] && [ $DRY -eq 0 ]; then
    printf 'OBS_S3_ACCESS_KEY=%s\nOBS_S3_SECRET_KEY=%s\n' "$OBS_S3_USER" "$KEY" >> "$ENV_FILE"
    echo "stored S3 credentials for $OBS_S3_USER in $ENV_FILE"
  fi
fi

# --- buckets --------------------------------------------------------------
mk_bucket() { # name, extra_json_props
  local b=$1 extra=${2:-}
  if $AWS s3api head-bucket --bucket "$b" 2>/dev/null; then echo "bucket $b exists"; return; fi
  RUN $MGMT POST /object/bucket -d "{\"name\":\"$b\",\"vpool\":\"$VPOOL\",\"namespace\":\"$OBS_S3_NAMESPACE\",\"head_type\":\"S3\",\"is_stale_allowed\":false$extra}"
}
mk_bucket demo-s3compat
mk_bucket demo-nfs-share ',"filesystem_enabled":"true"'
mk_bucket demo-lifecycle
mk_bucket demo-copycloud ',"search_metadata":[{"type":"System","name":"Size","datatype":"integer"},{"type":"System","name":"CreateTime","datatype":"datetime"},{"type":"System","name":"LastModified","datatype":"datetime"},{"type":"System","name":"ObjectName","datatype":"string"}]'

# demo-lock: object lock bucket must be created via S3 API with IAM credentials.
echo "NOTE: demo-lock requires an IAM user access key - see scenes/scene5_objectlock.sh"

# --- bucket ACL so the demo object user can use the file-enabled bucket ---
RUN $UI POST "/buckets/demo-nfs-share/$OBS_S3_NAMESPACE/userAcl" \
  -d "{\"user\":\"$OBS_S3_USER\",\"permissionList\":[\"full_control\",\"privileged_write\",\"delete\"]}"

# --- NFS export -----------------------------------------------------------
if $MGMT GET "/object/nfs/exports" | grep -q demo-nfs-share; then
  echo "nfs export exists"
else
  RUN $UI POST /file/export -d "{\"bucket\":\"demo-nfs-share\",\"namespace\":\"$OBS_S3_NAMESPACE\",\"exportPath\":\"\",\"path\":\"/ns1/demo-nfs-share\",\"exportHostSecurityList\":[{\"host\":\"192.168.1.0/24\",\"security\":\"authsys,rw,root=$OBS_S3_USER\",\"id\":\"192.168.1.0/24\"}]}"
fi

# --- IAM users + keys ------------------------------------------------------
iam() { # Action + params -> POST /iam form-encoded
  $UI POST /iam -d "$1" -H 'Content-Type: application/x-www-form-urlencoded' -H "x-emc-namespace: $OBS_S3_NAMESPACE"
}
for u in demo-reader demo-writer; do
  iam "Action=GetUser&UserName=$u&Namespace=$OBS_S3_NAMESPACE" | grep -q "$u" \
    && echo "iam user $u exists" \
    || RUN iam "Action=CreateUser&UserName=$u&Namespace=$OBS_S3_NAMESPACE"
  if ! iam "Action=ListAccessKeys&UserName=$u&Namespace=$OBS_S3_NAMESPACE" | grep -q AccessKeyId; then
    if [ $DRY -eq 0 ]; then
      K2=$(iam "Action=CreateAccessKey&UserName=$u&Namespace=$OBS_S3_NAMESPACE")
      AK=$(echo "$K2" | python3 -c "import json,sys;print(json.loads(json.load(sys.stdin)['data'])['CreateAccessKeyResult']['AccessKey']['AccessKeyId'])" 2>/dev/null)
      SK=$(echo "$K2" | python3 -c "import json,sys;print(json.loads(json.load(sys.stdin)['data'])['CreateAccessKeyResult']['AccessKey']['SecretAccessKey'])" 2>/dev/null)
      VAR="$(echo "$u" | tr -d - | tr 'a-z' 'A-Z')"
      [ -n "$AK" ] && [ -n "$SK" ] && printf 'OBS_%s_AK=%s\nOBS_%s_SK=%s\n' "$VAR" "$AK" "$VAR" "$SK" >> "$ENV_FILE" && echo "stored $u access key in $ENV_FILE"
    else
      echo "[dry-run] create access key for $u"
    fi
  fi
done

# --- bucket policy on demo-s3compat ---------------------------------------
RUN $AWS s3api put-bucket-policy --bucket demo-s3compat --policy '{
 "Version":"2012-10-17","Statement":[
  {"Sid":"DemoDenyDeleteProtected","Effect":"Deny","Principal":"*",
   "Action":"s3:DeleteObject","Resource":"demo-s3compat/protected/*"}]}'

# --- lifecycle -------------------------------------------------------------
RUN $AWS s3api put-bucket-lifecycle-configuration --bucket demo-lifecycle \
  --lifecycle-configuration '{"Rules":[{"ID":"demo-expire-tmp-1d","Status":"Enabled","Filter":{"Prefix":"tmp/"},"Expiration":{"Days":1}}]}'

echo "### setup done"
