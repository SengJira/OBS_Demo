# Final summary — prerequisites, limitations, blocked features

## System under test

- **Product:** Dell ObjectScale, node build `4.3.0.0.142978` (single node `luna`)
- **Topology:** 1 node, 1 VDC (`vdc1`), 1 storage pool (`sp1`, EC 12+4),
  1 namespace (`ns1`), 1 replication group (`rg1`, `:global`, single zone)
- **License:** ViPR_CAS/HDFS/Unstructured/Object/ECS — all permanent
- **Endpoints:** portal `https://192.168.1.31`, mgmt API `:4443`,
  S3 `:9020` (HTTP) / `:9021` (HTTPS, TLS 1.3), NFS `2049`/`111`,
  CAS `9024/9025`, Atmos-side `9022/9023`, node UI `9101`

## Prerequisites the demo assumes

- Management `root` credentials and a network path to 443/4443/9020-9021/2049
- Client host with `aws` CLI, `curl`, `openssl`, `mount.nfs`, `python3`
- `~/.config/obs-demo/env` populated (see `.env.example`); IAM access keys
  are created during setup and appended there
- For NFS: client on the exported CIDR (`192.168.1.0/24` as configured) —
  adjust the export host list for other labs

## Limitations discovered (do not overclaim)

1. **No full S3 parity.** Bucket tagging returns `NotImplemented`. Core data
   path APIs are solid (PUT/GET/LIST/HEAD/tags/metadata/MPU/presign/
   versioning/ACL/policy).
2. **Object Lock requires IAM credentials** and an object-lock-enabled bucket
   created via API — object users are rejected. Plain DELETE on a locked
   object only creates a delete marker; protection applies per version.
3. **SSE-S3/SSE-C not usable here**: `D@RE jar/license is unavailable`.
   Platform-level encryption at rest *is* enabled (VDC `isEncryptionEnabled=
   true`); per-request SSE needs the external-KMS-licensed feature.
4. **TLS cert is self-signed** (CN=DataService) — replace with a customer CA
   cert in production (`/rest/v1/x509-certificates`).
5. **Auth token cap**: management tokens are limited per user and live ~8h —
   always cache and reuse (`bin/mgmt.sh` does). Hammering `/login` causes a
   lockout that self-heals in minutes-to-hours.
6. **Metrics**: `/flux/query` returns 503 in this build (metrics store
   unavailable); `/metering/list` returns empty for the queried window;
   `/syslog` errors on a fabric client. Capacity/health/alert-policy APIs all
   work. SNMP/webhook/smtp targets are unconfigured.

## Blocked by lab configuration

| Feature | Blocker |
|---|---|
| Multisite active-active | single VDC; no second site federated — see `docs/scene7_multisite_plan.md` |
| Copy to Cloud execution | no authorized external S3 destination/credentials; TransformSvc OFF — see `docs/scene9_copy_to_cloud.md` |
| SSE with customer keys | external KMS not licensed/configured |
| Lifecycle expiry proof | rule is live; deletion awaits the ~daily scanner (observable ≥2026-10-01) |
| SNMP/syslog forwarding | no trap/syslog receiver provisioned in lab |

## What was created (all `demo-` prefixed)

- Users: object user `demo-s3user`; IAM users `demo-reader`, `demo-writer`
  (each with one access key + inline policy)
- Buckets: `demo-s3compat`, `demo-nfs-share` (file-enabled),
  `demo-lifecycle`, `demo-lock` (object lock), `demo-copycloud` (MD-search)
- NFS export id on `/ns1/demo-nfs-share` → `192.168.1.0/24` `authsys,rw,root=demo-s3user`
- Bucket policy on `demo-s3compat`: deny `s3:DeleteObject` on `protected/*`
- Lifecycle rules on `demo-lifecycle` (expire `tmp/` in 1d, noncurrent `logs/` in 1d)

`cleanup.sh` removes all of the above (except demo-lock objects still under
compliance retention — they expire ~75 min after the demo run; rerun cleanup
after expiry or use governance-mode objects if you must tear down sooner).
