# ObjectScale Presales Demo (repeatable)

Repeatable demo against a single-node Dell **ObjectScale 4.3.0** lab
(`192.168.1.31`, VDC `vdc1`, namespace `ns1`, storage pool `sp1` EC 12+4).

## Layout

```
bin/            helpers: env.sh, mgmt.sh (4443 token API), uicall.sh + ui_session.py (portal API)
setup.sh        idempotent resource creation, --dry-run supported
cleanup.sh      removes only demo-* resources, --dry-run supported
scenes/         one script per demo scene (write evidence to evidence/)
monitor/        monitoring collector -> renders evidence/monitoring_dashboard.md
postman/        importable Postman collection + environment (second demo path)
samples/        demo payload files
evidence/       sanitized captured output from live runs
docs/           runbook support docs (walkthroughs, plans, BOM)
RUNBOOK.md      15-20 min presenter guide
EVIDENCE_MATRIX.md  per-scene pass/fail status
```

## Prerequisites

- `python3` (+ `cryptography` pkg), `aws` CLI v1, `curl`, `jq` optional, `mount.nfs`.
- Credentials file `~/.config/obs-demo/env` (see `.env.example`, `chmod 600`).
  Never commit credentials — `.gitignore` already excludes env/session files.

## Quick start

```bash
. bin/env.sh
./setup.sh --dry-run        # preview
./setup.sh                  # create demo-* resources (idempotent)
scenes/scene1_s3_api.sh     # run each scene; output tee'd to evidence/
monitor/collect.sh          # render monitoring dashboard
./cleanup.sh --dry-run      # preview teardown
./cleanup.sh                # remove demo-* resources
```

## Postman path

Import `postman/ObjectScale-Demo.postman_collection.json` +
`postman/ObjectScale-Lab.postman_environment.json`, fill the secret variables,
run folders top→down. SigV4 is pre-configured (`us-east-1`/`s3`/path-style);
portal auth is automated (0.1–0.3). See `postman/POSTMAN_GUIDE.md` —
61 requests, verified against this lab (`evidence/postman_run.txt`).

## Important quirks discovered on this build (4.3.0.0.142978)

- Management tokens are capped per user — helpers cache tokens aggressively.
  Do **not** mint a token per call.
- Object Lock ops require **IAM** credentials (`Only IAM users are supported
  with object lock enabled buckets`); object users are rejected.
- `put-bucket-tagging` / `get-bucket-tagging` → `NotImplemented`.
- SSE-S3 / SSE-C request headers rejected (`D@RE jar/license is unavailable`):
  platform-level encryption-at-rest is on (VDC `isEncryptionEnabled=true`),
  but per-request SSE needs an external KMS + license that this lab lacks.
- Portal `/iam` is AWS-style query API via POST only; needs `x-emc-namespace`.
- NFS export options: `authsys,rw,root=<object-user>` maps uid 0 to an object
  user. File writes need `privileged_write` on the bucket user ACL.
- Copy-policy (Copy to Cloud) requires the bucket to be created with
  **Metadata Search enabled** (incl. LastModified index).
- `/flux/query` metrics backend returns 503 in this build; use
  `/dashboard/...` APIs for capacity/health.
