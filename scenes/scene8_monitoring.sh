#!/bin/bash
# Scene 8 - monitoring: capacity/health/traffic via portal + dashboard APIs,
# SNMP target list, alert policies, and a generated metrics snapshot.
set -u
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$DEMO_DIR/bin/env.sh"
OUT=${1:-$DEMO_DIR/evidence}
mkdir -p "$OUT"
UI="$DEMO_DIR/bin/uicall.sh"
MGMT="$DEMO_DIR/bin/mgmt.sh"
{
echo "=== Scene 8: monitoring — $(date -u +%FT%TZ) ==="
echo "## node/process health"
$UI GET "/platformlocking/nodes"
echo; echo "## dashboard - zone capacity summary"
$MGMT GET "/dashboard/zones/localzone" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(json.dumps({k:v for k,v in d.items() if k in ('diskSpaceTotalSummary','diskSpaceAllocatedSummary','allocatedCapacityForecast','apiChange')}, indent=1)[:1500])
" 2>/dev/null
echo; echo "## storage pools"
$MGMT GET "/dashboard/zones/localzone/storagepools" | python3 -m json.tool | head -40
echo; echo "## recent events/alerts"
$UI POST /dashboard/events -d '{"dataType":"current","category":"alerts","severity":"ERROR","pageSize":10}' | head -c 1200
echo; echo "## alert policies (system)"
$UI GET "/alertpolicy/list" | python3 -c "import json,sys;[print(p['policyName'],'|',p['metricName'],'|',p['isEnabled']) for p in json.load(sys.stdin)['data']]" 2>/dev/null | head -15
echo; echo "## SNMP targets"
$UI GET /snmp
echo; echo "## metering sample (billing API)"
$UI POST /metering/list -d '{"namespace":"ns1","interval_in_secs":300,"start_time":0}' | head -c 800
echo; echo "=== end scene8 ==="
} | tee "$OUT/scene8_monitoring.txt"
