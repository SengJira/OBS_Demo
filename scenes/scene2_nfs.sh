#!/bin/bash
# Scene 2 - S3/NFS multiprotocol. Requires export /ns1/demo-nfs-share with
# root=<s3-object-user> mapping (see setup.sh). Live-tested when the mount works;
# otherwise prints a labeled walkthrough.
set -u
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DEMO_DIR/bin/env.sh"
OUT=${1:-$DEMO_DIR/evidence}
mkdir -p "$OUT"
MNT=/mnt/obs-demo
{
echo "=== Scene 2: S3/NFS multiprotocol — $(date -u +%FT%TZ) ==="
echo "## export table"
"$DEMO_DIR/bin/mgmt.sh" GET /object/nfs/exports
echo; echo "## mount"
mkdir -p "$MNT"
umount "$MNT" 2>/dev/null
if mount -t nfs -o vers=3,nolock,proto=tcp "192.168.1.31:/ns1/demo-nfs-share" "$MNT"; then
  echo "mounted 192.168.1.31:/ns1/demo-nfs-share on $MNT (nfs v3, sec=sys)"
  mount | grep "$MNT"

  echo; echo "## NFS -> S3: write file over NFS, read over S3"
  echo "written-via-nfs $(date -u +%FT%TZ)" | tee "$MNT/nfs-hello.txt"
  ls -la "$MNT"
  aws --endpoint-url "$OBS_S3_HTTP" s3api get-object --bucket demo-nfs-share \
    --key nfs-hello.txt /tmp/scene2-from-nfs.txt && cat /tmp/scene2-from-nfs.txt

  echo; echo "## S3 -> NFS: write object over S3, read over NFS"
  aws --endpoint-url "$OBS_S3_HTTP" s3api put-object --bucket demo-nfs-share \
    --key s3-dir/s3-written.txt --body "$DEMO_DIR/samples/demo-file.txt"
  find "$MNT" -type f
  cat "$MNT/s3-dir/s3-written.txt" && echo "(read back over NFS - content matches S3 PUT)"
  stat "$MNT/s3-dir/s3-written.txt" | grep -E "Uid|Gid|Access|Size"
  echo "SCENE2_RESULT=LIVE_TESTED"
else
  echo "mount failed - NFS export not reachable from this host."
  echo "SCENE2_RESULT=NOT_LIVE (see docs/scene2_walkthrough.md)"
fi
echo "=== end scene2 ==="
} | tee "$OUT/scene2_nfs.txt"
umount "$MNT" 2>/dev/null || true
