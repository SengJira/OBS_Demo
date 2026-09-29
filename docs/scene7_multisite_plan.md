# Scene 7 — Multisite active-active: two-site test plan

**Lab state (verified live):** single VDC `vdc1`, one replication group `rg1`
(`...:global`), `numZones=1`. No second site exists, so nothing here was run
live. This plan is runnable once a second ObjectScale site is authorized.

## Prerequisites

- A second ObjectScale site (VDC2) reachable on ports 443/4443/9020-9021 and
  the geo service ports (9080-9096 range per Security Configuration Guide).
- A federated RG spanning both VDCs: create via UI *Manage → Replication Groups
  → New* selecting storage pools from both sites, or
  `POST /replicationgroup/create` with both VDC storage pools.
  **Requires explicit customer authorization — federation changes topology.**
- Namespace spanning both sites; bucket created in the federated RG.

## Test script (once federated)

```bash
EP_A=http://siteA:9020   EP_B=http://siteB:9020
aws --endpoint-url $EP_A s3 mb s3://demo-geo --region us-east-1
# write at A, read at B (eventual consistency; expect convergence in seconds)
aws --endpoint-url $EP_A s3api put-object --bucket demo-geo --key a.txt --body samples/demo-file.txt
sleep 10
aws --endpoint-url $EP_B s3api get-object --bucket demo-geo --key a.txt /tmp/b.txt
diff samples/demo-file.txt /tmp/b.txt            # proves A->B replication
# reverse direction
aws --endpoint-url $EP_B s3api put-object --bucket demo-geo --key b.txt --body samples/demo.csv
sleep 10
aws --endpoint-url $EP_A s3api get-object --bucket demo-geo --key b.txt /tmp/a.csv
# concurrent conflicting write: same key at both sites ~simultaneously
aws --endpoint-url $EP_A s3api put-object --bucket demo-geo --key conflict.txt --body samples/demo-file.txt &
aws --endpoint-url $EP_B s3api put-object --bucket demo-geo --key conflict.txt --body samples/demo.csv &
wait; sleep 10
aws --endpoint-url $EP_A s3api get-object --bucket demo-geo --key conflict.txt /tmp/c1.txt
aws --endpoint-url $EP_B s3api get-object --bucket demo-geo --key conflict.txt /tmp/c2.txt
diff /tmp/c1.txt /tmp/c2.txt && echo "converged - last-writer-wins on conflict"
# replication status via portal API on either site
GET /dashboard/zones/localzone/replicationgroups?category=geo   # rglinks, lag
GET /vdc/{vdc}/dashboards/geoReplication/rpo                    # RPO estimate
```

## Expected results to claim

- Writes at either site are readable at the other after convergence
  (active-active via the shared `global` RG; each object has an authoritative
  owner VDC but both sites accept reads/writes).
- Conflicting writes converge last-writer-wins (mtime-based) — document the
  resolved value on both sites.
- `rglinks` dashboard shows link health; `rpo` shows replication point lag.
- Failover: with `enableFailover`, a namespace can be failed over to the peer
  site during site outage (test only with authorization).

## Do NOT

- Do not create a second VDC or join federation without sign-off — it is a
  topology change that affects the whole cluster.
