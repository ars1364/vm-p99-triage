#!/bin/bash
# steal-under-load.sh -- run INSIDE a guest VM. Saturate every vCPU, then measure
# %steal DURING the load. This is the test the since-boot counter can't do:
# CPU steal only appears when you actually DEMAND the CPU and a neighbour (or a
# host cap) denies it. A cheap passive read of /proc/stat on an idle VM proves
# nothing; this forces contention.
#
#   usage: ./steal-under-load.sh [seconds]     (default 15)
#
# Read it as: if idle -> ~0 (load really landed) AND steal stays ~0, the host
# gave you all the CPU you asked for -> NOT overcommitted. If steal climbs into
# the double digits while idle is 0, the hypervisor is holding your vCPUs back
# (noisy neighbour / overcommit, OR a host cgroup cap on your QEMU -- the guest
# can't tell those two apart; both read as steal). Uses stress-ng if present,
# else a built-in busy-loop; either way idle->0 is what validates the probe.
set -u
N=$(nproc); DUR=${1:-15}
read _ u ni sy id io ir so st _ < /proc/stat
tot=$((u+ni+sy+id+io+ir+so+st)); sb=$(awk -v s="$st" -v t="$tot" 'BEGIN{printf (t>0)?"%.2f":"0",100*s/t}')
GEN="busy-loop"
if command -v stress-ng >/dev/null 2>&1; then
  GEN="stress-ng"; stress-ng --cpu "$N" --timeout "$((DUR+3))s" >/dev/null 2>&1 &
else
  end=$(( $(date +%s) + DUR + 3 ))
  for _ in $(seq 1 "$N"); do ( while [ "$(date +%s)" -lt "$end" ]; do :; done ) & done
fi
sleep 1
if command -v mpstat >/dev/null 2>&1; then
  L=$(mpstat 1 "$DUR" 2>/dev/null | awk '/Average:/{print $(NF-3),$(NF-9),$NF}')
  steal=$(echo "$L" | awk '{print $1}'); usr=$(echo "$L" | awk '{print $2}'); idle=$(echo "$L" | awk '{print $3}')
else
  read _ a1 b1 c1 d1 e1 f1 g1 s1 _ < /proc/stat; T1=$((a1+b1+c1+d1+e1+f1+g1+s1))
  sleep "$DUR"
  read _ a2 b2 c2 d2 e2 f2 g2 s2 _ < /proc/stat; T2=$((a2+b2+c2+d2+e2+f2+g2+s2))
  dt=$((T2-T1)); steal=$(awk -v x="$((s2-s1))" -v t="$dt" 'BEGIN{printf"%.2f",100*x/t}')
  usr=$(awk -v x="$(((a2-a1)+(b2-b1)))" -v t="$dt" 'BEGIN{printf"%.2f",100*x/t}')
  idle=$(awk -v x="$((d2-d1))" -v t="$dt" 'BEGIN{printf"%.2f",100*x/t}')
fi
wait 2>/dev/null
echo "vCPU=$N  load=$GEN  window=${DUR}s"
echo "  %steal under load : ${steal}%   (want ~0; double digits = overcommit/host cap)"
echo "  %usr  under load  : ${usr}%     (stress-ng ~99 = load landed)"
echo "  %idle under load  : ${idle}%    (~0 confirms the vCPU was truly saturated)"
echo "  %steal since boot : ${sb}%      (lifetime average; chronic overcommit shows here)"
