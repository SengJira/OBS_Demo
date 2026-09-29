# Postman Run Guide — ObjectScale 4.3 Demo

This collection is a **second presentation path** for the same verified demo.
Feature status and limitations match `EVIDENCE_MATRIX.md` and `RUNBOOK.md`.

## Files

| File | Contents |
|---|---|
| `ObjectScale-Demo.postman_collection.json` | 8 folders, 61 requests, ~87 assertions |
| `ObjectScale-Lab.postman_environment.json` | Endpoints + variable slots. **No credentials.** |
| `build_collection.py` | Regenerates both files (edit here, don't hand-edit JSON) |

## Import

1. Postman → **Import** → select both JSON files.
2. Select environment **"ObjectScale Lab"** (top-right).
3. Fill the **secret** variables (marked `secret`, currently empty):

| Variable | Value |
|---|---|
| `mgmt_password` | management password for `{{mgmt_user}}` |
| `access_key` / `secret_key` | S3 key of object user (e.g. `demo-s3user`) |
| `reader_access_key` / `reader_secret_key` | IAM `demo-reader` key |
| `writer_access_key` / `writer_secret_key` | IAM `demo-writer` key |

`mgmt_token`, `ui_token`, `xsrf_token`, `upload_id`, `*_vid`, etc. are filled
automatically by test scripts — leave them empty.

Create the identities with `./setup.sh` first (or run scenes 4/5), or supply
your own.

## Signing details (verified against this install)

- **AWS Signature V4**, region `us-east-1`, service `s3`, **path-style** URLs
  (`endpoint/bucket/key`). SigV4 region is not validated by ObjectScale.
- Postman/Newman computes `x-amz-content-sha256` automatically for `s3`.
- Presigned URL (1.10) uses **SigV2 query auth** (same format AWS CLI emits),
  generated in the pre-request script via `crypto-js` HMAC-SHA1.
- **Object Lock requests require IAM credentials** (`writer_*`), not object
  users — a verified ObjectScale 4.3 quirk (request 1.14 demonstrates the
  object-user denial).
- Management REST (`:4443`) uses `X-SDS-AUTH-TOKEN` (request 0.1 caches it).
- Portal APIs use `X-SDS-AUTH-TOKEN` = `data.authToken` from the AES-credential
  `/login` flow (0.2/0.3) plus the `XSRF-TOKEN` cookie.

## Presenter order

Run folders top→down (or the whole collection — it's ordered):

| Folder | Shows |
|---|---|
| 00 Setup | tokens, create `demo-pm-*` buckets, grant reader policy |
| 10 S3 API | PUT/GET/HEAD/LIST/tagging/MPU/presign/versioning + expected failures |
| 20 IAM & policy | least-privilege allow, AccessDenied, bucket-policy deny |
| 30 Object Lock | governance + compliance WORM, all deny paths |
| 40 Lifecycle | rule on `tmp/`, computed `Expiration` header |
| 50 Mgmt/monitoring | namespaces, license, capacity, node health, VDCs, RGs, alerts, SNMP, IAM list |
| 80 Cleanup | removes `demo-pm-s3`, `demo-pm-lifecycle` |
| 90 Docs | scenes that can't run in Postman |

## Expected-failure requests — they are supposed to "fail"

| Request | Correct result |
|---|---|
| 1.13 GET missing object | 404 NoSuchKey |
| 1.14 lock read as object user | 403 "Only IAM users…" |
| 1.15 bucket tagging | 501 NotImplemented (documented gap) |
| 2.4 reader PUT | 403 AccessDenied |
| 2.6 delete protected/ | 403 AccessDenied (policy beats IAM) |
| 3.5 delete retained version | 403 AccessDenied |
| 3.7 shorten retention | 403 AccessDenied |
| 3.9 compliance delete + bypass | 403 AccessDenied |
| 8.8 delete lock bucket | 409 BucketNotEmpty until retention expires |

## Known timing notes

- **4.4 `Expiration` header**: the lifecycle engine evaluates rules
  asynchronously (~1–2 min). On a cold run 4.4 may fail; wait and re-send the
  request (or re-run folder 40). Verified: header appears as
  `expiry-date="…", rule-id="demo-pm-expire-tmp"`.
- **8.8 lock-bucket delete**: flagged ⚠ — impossible until the governance
  (+2h) and compliance (+75m) retentions from folder 30 expire. 409 is the
  pass condition.

## Run headless (Newman)

```bash
newman run postman/ObjectScale-Demo.postman_collection.json \
  -e postman/ObjectScale-Lab.postman_environment.json -k \
  --env-var "mgmt_password=$OBS_MGMT_PASS" \
  --env-var "access_key=$OBS_S3_ACCESS_KEY" --env-var "secret_key=$OBS_S3_SECRET_KEY" \
  --env-var "reader_access_key=$OBS_DEMOREADER_AK" --env-var "reader_secret_key=$OBS_DEMOREADER_SK" \
  --env-var "writer_access_key=$OBS_DEMOWRITER_AK" --env-var "writer_secret_key=$OBS_DEMOWRITER_SK"
```

(`-k` = accept the lab's self-signed certs. Secrets stay on the command line,
never in files.)

## Scenes not covered by Postman

Folder 90 lists them — they need a shell/second site/cloud account:

- **Scene 2 NFS** — requires an NFS client mount → `scenes/scene2_nfs.sh`
- **Scene 7 multisite** — lab is single-VDC → `docs/scene7_multisite_plan.md`
- **Scene 9 copy-to-cloud** — needs authorized external S3 target →
  `docs/scene9_copy_to_cloud.md`
- **SSE / Flux metrics** — unsupported/unavailable in this build (matrix)

## Verified run (lab)

61/61 requests, 86/87 assertions green on a cold run; the only pending
assertion is 4.4 which passes on re-check once the lifecycle engine evaluates
(~2 min). Full log: `evidence/postman_run.txt`.
