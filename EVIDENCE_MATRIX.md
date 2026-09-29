# Evidence matrix — ObjectScale 4.3.0.0.142978 (single node `luna`, VDC `vdc1`)

Captured 2026-09-29 live run; sanitized outputs in `evidence/`.
Legend: **LIVE** = ran against the system; **CONFIGURED** = accepted and
verifiable but effect pending; **DOC** = documented walkthrough only;
**UNSUPPORTED** = API exists on paper but rejected by this build.

| # | Assertion | Status | Evidence / notes |
|---|-----------|--------|------------------|
| 1 | S3 PUT/GET/HEAD/LIST, metadata, object tags | **LIVE PASS** | `scene1_s3api.txt`; GET byte-identical |
| 1 | Multipart upload (create/upload/list/complete) | **LIVE PASS** | 2×6MiB parts, md5 round-trip match |
| 1 | Presigned URL GET | **LIVE PASS** | `http=200`, content match |
| 1 | Bucket versioning enable + list versions | **LIVE PASS** | Status Enabled; versions listed |
| 1 | Bucket ACL read | **LIVE PASS** | `get-bucket-acl` returns owner grant |
| 1 | Bucket tagging (put/get) | **UNSUPPORTED** | `NotImplemented` on this build |
| 1 | CORS get / bucket-policy get / public-access-block get | **LIVE (API present)** | return NoSuchX/empty — implemented, unconfigured |
| 1 | Object-lock ops by object user | **UNSUPPORTED** | `Only IAM users are supported with object lock enabled buckets` — IAM creds required |
| 2 | NFS export + mount (v3, sec=sys) | **LIVE PASS** | `scene2_nfs.txt`; export id 5 |
| 2 | NFS write → S3 read | **LIVE PASS** | `nfs-hello.txt` read via S3 GET |
| 2 | S3 write → NFS read | **LIVE PASS** | `s3-dir/s3-written.txt` read via NFS; `s3-dir` materializes as a directory |
| 2 | UID/GID mapping | **LIVE PASS (documented)** | `root=<object-user>` export option maps uid 0; unmapped UIDs surface as `2147483647`; writes need `privileged_write` bucket ACL |
| 3 | TLS S3 endpoint (9021) | **LIVE PASS** | TLS 1.3, `TLS_AES_128_GCM_SHA256`, GET verified; lab cert self-signed CN=DataService |
| 3 | Encryption at rest (platform D@RE) | **LIVE PASS (config)** | VDC `isEncryptionEnabled=true` |
| 3 | SSE-S3 / SSE-C request headers | **UNSUPPORTED** | `D@RE jar/license is unavailable` — external KMS feature not licensed here |
| 4 | IAM users + access keys (per namespace) | **LIVE PASS** | demo-reader/demo-writer created via `POST /iam` |
| 4 | IAM allow (reader GET) | **LIVE PASS** | GET 200 |
| 4 | IAM deny (reader PUT) | **LIVE PASS** | `AccessDenied` |
| 4 | Bucket policy Deny overrides IAM Allow | **LIVE PASS** | writer delete on `protected/*` → `AccessDenied`; policy JSON stored |
| 5 | Object-lock bucket create (IAM creds) | **LIVE PASS** | lock enabled, versioning forced on |
| 5 | Governance-mode retention | **LIVE PASS** | delete-version `AccessDenied`; shorten-retention `AccessDenied`; bypass works only with `s3:BypassGovernanceRetention` |
| 5 | Compliance-mode retention | **LIVE PASS** | delete denied even with `s3:*` + bypass flag |
| 5 | Read under retention / delete marker semantics | **LIVE PASS** | GET by version-id OK; plain DELETE only adds marker (same as AWS) |
| 6 | Lifecycle rule store + retrieve | **CONFIGURED** | rule `demo-expire-tmp-1d` returned; `head-object` reports `Expiration: expiry-date=Thu, 01 Oct 2026` |
| 6 | Actual expiry | **AWAITING OBSERVATION** | scanner runs ~daily; verify 2026-10-01+ |
| 7 | Second site / federation present | **NOT PRESENT** | 1 VDC, rg1 numZones=1 |
| 7 | Active-active write/read across sites | **DOC** | `docs/scene7_multisite_plan.md` — runnable plan, needs authorization |
| 8 | Capacity/health via mgmt APIs | **LIVE PASS** | `monitoring_dashboard.md`: 1.02 TB total, node health=Good, 0 bad disks |
| 8 | Built-in alert policies | **LIVE PASS** | ~30 system policies enabled |
| 8 | Flux metrics (`/flux/query`) | **DOC** | endpoint exists; 503 backend in this build |
| 8 | SNMP/syslog/webhook targets | **DOC** | APIs present (`/snmp`, `/syslog`, `/webhooks`), none configured; syslog API returns a fabric error in this lab |
| 9 | Copy to Cloud (data movement) API | **DOC** | `copypolicy`/`testpolicy` exist; requires MD-search bucket (`demo-copycloud` created accordingly); TransformSvc OFF |
| 9 | Copy execution + checksum verify | **DOC** | no authorized destination/creds — `docs/scene9_copy_to_cloud.md` |

## Management-plane access used

- `https://192.168.1.31:4443` — token-authenticated mgmt REST API
  (`X-SDS-AUTH-TOKEN`, cached — the platform caps tokens per user).
- `https://192.168.1.31` — portal JSON API behind session login
  (`POST /startEncryptSession` + AES-encrypted `Authorization: ECS …`).
- `http(s)://192.168.1.31:9020/9021` — S3 data path.

## Postman path

`postman/` contains an importable collection + environment covering scenes
1,3,4,5,6 and the management/monitoring APIs (folder 50). Verified with
Newman 6.2.2: **61/61 requests executed, 86/87 assertions passed** on a cold
run — the single pending assertion is the lifecycle `Expiration` header
(async engine, ~2 min; passes on re-check, verified). Scene 2 (NFS), scene 7
(multisite) and scene 9 (copy-to-cloud) are inherently outside Postman's
scope — see folder 90 notes and `postman/POSTMAN_GUIDE.md`.

## Credentials handling

All credentials live in `~/.config/obs-demo/env` (0600, outside repo).
IAM access keys created during the run are appended there by
`scenes/scene4_iam.sh`. Nothing secret is committed; presigned-URL signature
material in `evidence/scene1_s3api.txt` is redacted (expired anyway).
