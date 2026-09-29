#!/bin/bash
# cleanup.sh [--dry-run]
# Removes ONLY demo-* resources created by this demo. Safe to re-run.
set -u
DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DEMO_DIR/bin/env.sh" || exit 1
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
RUN() { if [ $DRY -eq 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }
MGMT="$DEMO_DIR/bin/mgmt.sh"; UI="$DEMO_DIR/bin/uicall.sh"
AWS="aws --endpoint-url $OBS_S3_HTTP"

echo "### cleanup ObjectScale demo (dry-run=$DRY)"

empty_bucket() { # best-effort object purge incl. versions (non-lock buckets)
  local b=$1
  $AWS s3api list-object-versions --bucket "$b" --output json 2>/dev/null \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
objs=[{'Key':v['Key'],'VersionId':v['VersionId']} for v in d.get('Versions',[])+d.get('DeleteMarkers',[])]
print(json.dumps({'Objects':objs}) if objs else '')" > /tmp/del_$b.json
  [ -s /tmp/del_$b.json ] && $AWS s3api delete-objects --bucket "$b" --delete file:///tmp/del_$b.json 2>/dev/null
  rm -f /tmp/del_$b.json
}

for b in demo-s3compat demo-nfs-share demo-lifecycle demo-copycloud; do
  if $AWS s3api head-bucket --bucket "$b" 2>/dev/null; then
    RUN $AWS s3api delete-bucket-policy --bucket "$b" 2>/dev/null
    RUN $AWS s3api delete-bucket-lifecycle --bucket "$b" 2>/dev/null
    if [ $DRY -eq 0 ]; then empty_bucket "$b"; fi
    RUN $AWS s3api delete-bucket --bucket "$b"
  fi
done

# demo-lock: governance retention may still be active - bypass if permitted
if [ -n "${OBS_DEMOWRITER_AK:-}" ]; then
  if AWS_ACCESS_KEY_ID=$OBS_DEMOWRITER_AK AWS_SECRET_ACCESS_KEY=$OBS_DEMOWRITER_SK \
    $AWS s3api head-bucket --bucket demo-lock 2>/dev/null; then
    if [ $DRY -eq 0 ]; then
      echo "attempting demo-lock purge (governance bypass where permitted)"
      AWS_ACCESS_KEY_ID=$OBS_DEMOWRITER_AK AWS_SECRET_ACCESS_KEY=$OBS_DEMOWRITER_SK \
      $AWS s3 rm "s3://demo-lock" --recursive 2>/dev/null
      $MGMT POST "/object/bucket/ns1.demo-lock/deactivate" -d '{}' \
        || echo "demo-lock: deactivate failed - compliance-retained objects may still exist; retry after their expiry"
    else
      echo "[dry-run] purge + deactivate demo-lock (may fail until retention expiry)"
    fi
  fi
fi

# NFS export
EX=$($MGMT GET /object/nfs/exports 2>/dev/null | python3 -c "import json,sys;print(' '.join(e['id']+':'+e['path'] for e in json.load(sys.stdin).get('exports',[])))" 2>/dev/null)
for e in $EX; do
  case "$e" in *demo-nfs-share*) id=${e%%:*}; RUN $UI DELETE "/file/export/$id/ns1";; esac
done
umount /mnt/obs-demo 2>/dev/null

# IAM users
iam() { $UI POST /iam -d "$1" -H 'Content-Type: application/x-www-form-urlencoded' -H "x-emc-namespace: $OBS_S3_NAMESPACE"; }
for u in demo-reader demo-writer; do
  KEYS=$(iam "Action=ListAccessKeys&UserName=$u&Namespace=$OBS_S3_NAMESPACE" | python3 -c "import json,sys
try:
  d=json.loads(json.load(sys.stdin)['data']); print(' '.join(k['AccessKeyId'] for k in d['ListAccessKeysResult']['AccessKeyMetadata']))
except Exception: pass" 2>/dev/null)
  for k in $KEYS; do RUN iam "Action=DeleteAccessKey&UserName=$u&AccessKeyId=$k&Namespace=$OBS_S3_NAMESPACE" >/dev/null; done
  for p in $(iam "Action=ListUserPolicies&UserName=$u&Namespace=$OBS_S3_NAMESPACE" | python3 -c "import json,sys
try:
  d=json.loads(json.load(sys.stdin)['data']); print(' '.join(d['ListUserPoliciesResult']['PolicyNames']))
except Exception: pass" 2>/dev/null); do
    RUN iam "Action=DeleteUserPolicy&UserName=$u&PolicyName=$p&Namespace=$OBS_S3_NAMESPACE" >/dev/null
  done
  RUN iam "Action=DeleteUser&UserName=$u&Namespace=$OBS_S3_NAMESPACE" >/dev/null
done

# object user + its key
RUN $MGMT POST "/object/users/deactivate" -d "{\"user\":\"$OBS_S3_USER\",\"namespace\":\"$OBS_S3_NAMESPACE\"}" 2>/dev/null
echo "### cleanup done"
