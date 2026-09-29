#!/bin/bash
# monitor/collect.sh - pull live capacity/health/alert signals and render a
# markdown "dashboard" to evidence/monitoring_dashboard.md
set -u
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DEMO_DIR/bin/env.sh"
OUT=${1:-$DEMO_DIR/evidence}
UI="$DEMO_DIR/bin/uicall.sh"; MGMT="$DEMO_DIR/bin/mgmt.sh"
mkdir -p "$OUT"

export ZONE=$($MGMT GET /dashboard/zones/localzone)
export NODES=$($MGMT GET /dashboard/zones/localzone/nodes)
# per-node detail for healthStatus
ND_FILE=$(mktemp)
python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for i in d.get('_embedded',{}).get('_instances',[]):
    print(i['_links']['self']['href'])
" <<<"$NODES" | while read -r h; do $MGMT GET "$h"; echo; done > "$ND_FILE"
export ND_FILE
export ALERTS=$($UI GET /alertpolicy/list)
export EVENTS=$($UI POST /dashboard/events -d '{"dataType":"current","category":"alerts","severity":"ERROR","pageSize":10}')
export SNMP=$($UI GET /snmp)
export NOW=$(date -u +%FT%TZ) OUTF="$OUT/monitoring_dashboard.md" HOST=$OBS_MGMT_HOST

python3 - <<'PYEOF'
import json, os
zone  = json.loads(os.environ["ZONE"])
nodes = json.loads(os.environ["NODES"])
alerts= json.loads(os.environ["ALERTS"])
events= json.loads(os.environ["EVENTS"])
snmp  = json.loads(os.environ["SNMP"])

tot   = float(zone.get("diskSpaceTotalSummary",{}).get("Avg",0))
alloc = float(zone.get("diskSpaceAllocatedSummary",{}).get("Avg",0))
L = [f"# ObjectScale monitoring snapshot — {os.environ['NOW']}",
     f"\n**Source**: live portal/dashboard APIs on {os.environ['HOST']} (no simulated data)\n",
     "## Capacity",
     f"- Total disk space (cluster): {tot/1e12:.2f} TB",
     f"- Allocated (used + reserved): {alloc/1e9:.1f} GB",
     f"- Free headroom: {(tot-alloc)/1e12:.2f} TB\n",
     "## Node health"]
nd = []
_txt = open(os.environ["ND_FILE"]).read()
_dec = json.JSONDecoder()
_i = 0
while _i < len(_txt):
    while _i < len(_txt) and _txt[_i] not in "{": _i += 1
    if _i >= len(_txt): break
    try:
        _o, _j = _dec.raw_decode(_txt, _i)
        nd.append(_o); _i = _j
    except Exception: _i += 1
if nd:
    for n in nd:
        L.append(f"- node {n.get('_links',{}).get('self',{}).get('href','').split('/')[-1][:8]} "
                 f"health={n.get('healthStatus','?')} badDisks={n.get('numBadDisks','?')} "
                 f"pool={n.get('storagePoolName','?')}")
else:
    for n in nodes.get("data", []):
        L.append(f"- {n.get('nodeName','?')} ({n.get('nodeIp','?')}) version={n.get('version','?')}")
L.append("\n## Alert policies enabled (sample)")
for p in alerts.get("data", [])[:15]:
    L.append(f"- {p['policyName']} ({p['metricName']}) enabled={p['isEnabled']}")
L.append("\n## Recent ERROR events")
d = events.get("data")
L.append(f"```\n{json.dumps(d,indent=1)[:800] if d else 'none returned'}\n```")
L.append(f"\n## SNMP targets configured: {len(snmp.get('data',[]))}")
L.append("(POST /snmp/create or UI → Settings → SNMP to forward alerts)\n")
open(os.environ["OUTF"], "w").write("\n".join(L))
print("wrote", os.environ["OUTF"])
PYEOF
