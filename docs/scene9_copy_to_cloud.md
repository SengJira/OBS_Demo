# Scene 9 — Copy to Cloud (Data Movement): procedure + BOM

**Lab state (verified):** the bucket copy-policy API exists
(`POST /bucket/{b}/{ns}/copypolicy`, `policyType=COPY_ONLY`,
`targetLocationStatus=COPY_TO_S3`). Source buckets **must be created with
Metadata Search enabled including a `LastModified` index** — verified by API
error: `bucket must have Metadata Search enabled to be eligible to apply copy
policy`. `demo-copycloud` was created accordingly. No external/cloud
credentials or destination are authorized in this lab, so **no copy was run**.

Reference: Dell "ECS Data Movement (Copy to Cloud)" white paper (ECS 3.8.0+;
same feature in ObjectScale 4.x). Built on the ECS Sync engine; targets AWS S3
or a non-federated ECS/ObjectScale. IAM accounts only; deletes are NOT
propagated; scan interval ~1h (configurable via support).

## Bill of materials

| Item | Needed |
|---|---|
| Destination | AWS S3 bucket (e.g. `demo-obs-c2c-target`) in a chosen region, or a second ObjectScale bucket |
| Destination creds | IAM access key/secret on the target (AWS IAM user) with `s3:PutObject` on the target bucket — customer supplies |
| Source bucket | `demo-copycloud` (metadata search enabled at creation — cannot be enabled retroactively) |
| TLS trust | target CA cert uploaded via `POST /rest/v1/x509-certificates?type=CA` if non-public CA |
| Network | egress 443 from ObjectScale nodes to the S3 endpoint |

## Procedure

1. Create source bucket with metadata search (done for `demo-copycloud`;
   recreate pattern in `setup.sh` under `search_metadata`).
2. Upload a tagged dataset:
   `aws s3api put-object --bucket demo-copycloud --key docs/x.txt --tagging "copyme=yes" ...`
3. Configure the policy (UI → bucket → *Copy to Cloud*, or API):
   `PUT /bucket/demo-copycloud/ns1/copypolicy` with
   `{"policyType":"COPY_ONLY","targetLocationStatus":"COPY_TO_S3",
     "targetBucket":"demo-obs-c2c-target","targetRegion":"us-east-1",
     "externalEndpoint":"https://s3.us-east-1.amazonaws.com",
     "targetAccessKey":"<key>","targetSecretKey":"<secret>",
     "sseS3Enabled":true,"daysAfterLastWrite":0,"minimumSize":0,
     "tagFilterEnabled":true,"tagFilter":"copyme=yes",
     "detailedLogEnabled":true,"detailedLogBucket":"<log-bucket>"}`
   Use `POST .../testpolicy` to validate first.
4. Wait one scan interval (~1h default); verify object count + ETags/MD5
   between source listing and destination listing.
5. Demonstrate semantics: delete at source → object REMAINS at target
   (copy-only, deletes not synced).

## Verification checklist

- [ ] object count source(prefix) == object count target
- [ ] checksums/ETag match for each object
- [ ] log bucket contains per-object copy records
- [ ] deletes not propagated (by design)
- [ ] policy can be disabled/deleted and source bucket unaffected
