# Presenter Runbook — Dell ObjectScale 4.3 demo (~18 min)

Audience-facing sequence. All commands run from this repo after `. bin/env.sh`.
Evidence from the recorded live run is in `evidence/sceneN_*.txt`.

Timing: S3 3m → NFS 3m → Encryption 2m → IAM 2m → WORM 3m → Lifecycle 1.5m →
Multisite 1.5m → Monitoring 1.5m → Copy-to-Cloud 1m → Q&A.

## 0. Intro (30s)

One node, one namespace, one API surface: S3 + NFS + CAS + IAM. Value hook:
*"ObjectScale is S3-native object storage with file multiprotocol, WORM
compliance, and enterprise IAM — all on-prem or edge."*

## 1. S3 API compatibility (3m) — `scenes/scene1_s3_api.sh`

```bash
aws --endpoint-url $OBS_S3_HTTP s3api put-object --bucket demo-s3compat \
  --key doc/demo-file.txt --body samples/demo-file.txt \
  --metadata project=demo --tagging "env=demo&scene=1"
aws --endpoint-url $OBS_S3_HTTP s3api get-object --bucket demo-s3compat \
  --key doc/demo-file.txt /tmp/g.txt && diff samples/demo-file.txt /tmp/g.txt
aws --endpoint-url $OBS_S3_HTTP s3 presign s3://demo-s3compat/doc/demo-file.txt
```

Expected: ETag returned, GET byte-identical, LIST/HEAD work, MPU completes
(`evidence/scene1_s3api.txt` md5 match), presigned URL returns `http=200`.

**Value:** existing S3 apps/sdks connect unchanged (just swap endpoint). Be
honest: bucket tagging returns `NotImplemented` — full API coverage, not 100%
parity. *"S3-compatible where it matters: PUT/GET/LIST/HEAD, metadata, object
tags, MPU, presign, versioning, bucket policy."*

## 2. S3/NFS multiprotocol (3m) — `scenes/scene2_nfs.sh`

```bash
mount -t nfs -o vers=3 192.168.1.31:/ns1/demo-nfs-share /mnt/obs-demo
echo hi > /mnt/obs-demo/nfs-hello.txt
aws --endpoint-url $OBS_S3_HTTP s3api get-object --bucket demo-nfs-share \
  --key nfs-hello.txt /tmp/n.txt && cat /tmp/n.txt   # NFS->S3
aws --endpoint-url $OBS_S3_HTTP s3api put-object --bucket demo-nfs-share \
  --key s3-dir/s3-written.txt --body samples/demo-file.txt
cat /mnt/obs-demo/s3-dir/s3-written.txt              # S3->NFS
```

Expected: both directions read back correctly (verified live).

**Value:** ingest files over NFS, serve them over S3 (or vice versa) without
copying — one copy of data, two access paths. Note the UID mapping model:
export option `root=demo-s3user` maps uid 0 to that object user; unmapped UIDs
present as `2147483647` and obey the bucket's user-ACL file permissions
(`privileged_write` needed for writes). NFSv3, `authsys` (Kerberos optional).

## 3. Encryption (2m) — `scenes/scene3_encryption.sh`

```bash
echo | openssl s_client -connect 192.168.1.31:9021 | grep -E "Protocol|Cipher"
aws --endpoint-url https://192.168.1.31:9021 --no-verify-ssl s3 ls
```

Expected: `TLSv1.3`, GET over HTTPS verified byte-identical.

**Value:** encryption in flight (TLS 1.3 on :9021) and at rest — VDC-level
D@RE is enabled (`isEncryptionEnabled=true` on vdc1). SSE-S3/SSE-C request
headers return an explicit unsupported error on this lab (needs the optional
external-KMS SSE license); don't oversell — say "platform encrypts at rest by
default; SSE with customer keys is a licensed option via external KMS".

## 4. IAM & bucket policy (2m) — `scenes/scene4b_iam_test.sh`

```bash
# demo-reader (s3:GetObject+ListBucket on demo-s3compat)
AWS_ACCESS_KEY_ID=$OBS_DEMOREADER_AK AWS_SECRET_ACCESS_KEY=$OBS_DEMOREADER_SK \
  aws --endpoint-url $OBS_S3_HTTP s3api get-object --bucket demo-s3compat \
  --key doc/demo-file.txt /tmp/r.txt                       # allowed
AWS_ACCESS_KEY_ID=$OBS_DEMOREADER_AK AWS_SECRET_ACCESS_KEY=$OBS_DEMOREADER_SK \
  aws --endpoint-url $OBS_S3_HTTP s3api put-object --bucket demo-s3compat \
  --key x --body samples/demo-file.txt                     # AccessDenied
aws --endpoint-url $OBS_S3_HTTP s3api delete-object --bucket demo-s3compat \
  --key protected/important.txt                            # AccessDenied (bucket policy)
```

Expected: allow GET, deny PUT (IAM), deny delete on `protected/*` (bucket
policy — Deny overrides Allow).

**Value:** AWS-style IAM users/policies per namespace + bucket policies —
least privilege without sharing the admin account. Apps never use `root`.

## 5. Object Lock / WORM (3m) — `scenes/scene5_objectlock.sh`

```bash
AWS_ACCESS_KEY_ID=$OBS_DEMOWRITER_AK AWS_SECRET_ACCESS_KEY=$OBS_DEMOWRITER_SK \
  aws --endpoint-url $OBS_S3_HTTP s3api create-bucket --bucket demo-lock \
  --object-lock-enabled-for-bucket
# put with --object-lock-mode COMPLIANCE --object-lock-retain-until-date +75m
# delete-object --version-id -> AccessDenied, even with --bypass-governance-retention
```

Expected (all verified): bucket lock enabled + versioning forced on; delete of
a retained **version** = AccessDenied; reads succeed; retention shortening =
AccessDenied; governance bypass works only when the identity holds
`s3:BypassGovernanceRetention`; compliance mode denies bypass regardless.

**Value:** SEC 17a-4/FINRA-style immutability, ransomware protection. Caveat
to mention: object lock requires IAM credentials (object users rejected), and
a plain DELETE on a versioned bucket only adds a delete marker.

## 6. Lifecycle (1.5m) — `scenes/scene6_lifecycle.sh`

```bash
aws --endpoint-url $OBS_S3_HTTP s3api get-bucket-lifecycle-configuration \
  --bucket demo-lifecycle
aws --endpoint-url $OBS_S3_HTTP s3api head-object --bucket demo-lifecycle \
  --key tmp/scratch.txt   # Expiration: expiry-date="...", rule-id="demo-expire-tmp-1d"
```

Expected: rules stored and returned; `head-object` shows the computed expiry
date. Say plainly: *"the rule is live — the engine expires objects on its
daily scan; we can check the bucket tomorrow."* Do NOT claim deletion happened.

## 7. Multisite (1.5m) — `scenes/scene7_multisite.sh` + `docs/scene7_multisite_plan.md`

Show `/vdcs` (one site) and `/replicationgroups` (`rg1` global, 1 zone).
Say: *"This lab is a single site; in a two-VDC federation the same bucket is
active-active — writes at either site replicate via the RG links. Here's the
test plan we'd run on your two sites."* Conflict = last-writer-wins.
Do not create federation live.

## 8. Monitoring (1.5m) — `monitor/collect.sh` → `evidence/monitoring_dashboard.md`

Show rendered dashboard: 1.02 TB capacity / health=Good / enabled alert
policies. Mention integrations: SNMPv2/v3 targets (`/snmp`), syslog
forwarding, email/webhook alerts, plus portal dashboard + metering APIs for
external collectors. Flux metrics endpoint exists but returns 503 in this
build — label it *not exercised*.

## 9. Copy to Cloud (1m) — `docs/scene9_copy_to_cloud.md`

Show `demo-copycloud` (metadata-search enabled). Explain: policy-driven async
copy of bucket objects to external S3 (AWS or another ObjectScale), hourly
scan, tag filters, detailed log bucket, copies-not-deletes semantics.
No cloud destination authorized in this lab → procedure + BOM only.

## Close

*"Everything you saw ran on a single lab node today — same code path as the
production appliance; scale-out and multisite are configuration, not a
different product."*
