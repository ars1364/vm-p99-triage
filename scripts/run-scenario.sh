#!/bin/bash
# run-scenario.sh -- drive load at the two target VMs and run triage.sh on each,
# in the same window. Edit A/B to your target IPs. Runs from the load-gen host.
#   usage: ./run-scenario.sh <label> [rate_rps] [duration_s]
LABEL=$1; RATE=${2:-150}; DUR=${3:-20}
A=10.99.0.129; B=10.99.0.17
OUT=~/results/$LABEL; mkdir -p "$OUT"
ssh -n a "P=\$(pgrep -x cpuwork); ~/triage.sh --pid \$P --window $DUR --json" > "$OUT/triage-a.json" 2>/dev/null &
ssh -n b "P=\$(pgrep -x cpuwork); ~/triage.sh --pid \$P --window $DUR --json" > "$OUT/triage-b.json" 2>/dev/null &
~/loadgen -url http://$A:8080/work -rate $RATE -duration ${DUR}s -label $LABEL-a > "$OUT/load-a.json" 2>/dev/null &
~/loadgen -url http://$B:8080/work -rate $RATE -duration ${DUR}s -label $LABEL-b > "$OUT/load-b.json" 2>/dev/null &
wait
echo "===== $LABEL (rate=$RATE dur=${DUR}s) ====="
for v in a b; do
  printf "  VM-%s load:   " "$v"; python3 -c "import json;d=json.load(open('$OUT/load-$v.json'));print('p50=%.1f p99=%.1f p999=%.1f ok=%d err=%d rps=%.0f'%(d['p50_ms'],d['p99_ms'],d['p999_ms'],d['ok'],d['errors'],d['achieved_rps']))"
  printf "  VM-%s triage: " "$v"; python3 -c "import json;d=json.load(open('$OUT/triage-$v.json'));print('steal=%s%% throttle_ev=%s thr_ms=%s numa_nodes=%s => %s'%(d['steal_pct'],d['throttled_events_delta'],d['throttled_ms_delta'],d['numa_nodes'],d['verdict']))" 2>/dev/null || echo "(parse n/a)"
done
