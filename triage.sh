#!/usr/bin/env bash
# triage.sh — Is your VM's tail latency caused by the HOST, not your app?
#
# Runs INSIDE a Linux VM and tells you which of three environment faults is
# most likely stealing your P99:
#   1. CPU steal     — the hypervisor isn't scheduling your vCPUs (noisy neighbor / overcommit)
#   2. CPU throttling — a cgroup CPU quota (cpu.max) is capping you before you finish
#   3. NUMA          — your memory is on a different NUMA node than your vCPUs (remote access)
#
# Zero dependencies beyond coreutils. sysstat (mpstat) and numactl are used if
# present but are NOT required. Read-only; no root needed for the guest checks.
#
# Usage:
#   ./triage.sh                 # observe the running system for 20s
#   ./triage.sh --pid 12345     # focus throttling on a specific process's cgroup
#   ./triage.sh --load          # generate CPU load yourself (if you have no live workload)
#   ./triage.sh --window 30     # observation window in seconds (default 20)
#   ./triage.sh --json          # machine-readable output
#
# Heuristic, by design. As the method says: one metric is never a verdict.
# This correlates several over one window and points you at the right layer.
set -u

WINDOW=20; PID=""; SELFLOAD=0; JSON=0
while [ $# -gt 0 ]; do case "$1" in
  --window) WINDOW="$2"; shift 2;;
  --pid) PID="$2"; shift 2;;
  --load) SELFLOAD=1; shift;;
  --json) JSON=1; shift;;
  -h|--help) sed -n '2,30p' "$0"; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

NPROC=$(nproc)
say(){ [ "$JSON" = 0 ] && echo "$@"; }
hr(){ [ "$JSON" = 0 ] && printf '%s\n' "----------------------------------------------------------------"; }

# ---------- cgroup detection ----------
CGV=1; [ -f /sys/fs/cgroup/cgroup.controllers ] && CGV=2
# resolve the cgroup path for PID (or self)
cg_path(){
  local p="${1:-self}" line base
  if [ "$CGV" = 2 ]; then
    base=$(awk -F: '/^0::/{print $3}' /proc/$p/cgroup 2>/dev/null)
    echo "/sys/fs/cgroup${base}"
  else
    base=$(awk -F: '/:cpu,cpuacct:|:cpu:/{print $3; exit}' /proc/$p/cgroup 2>/dev/null)
    echo "/sys/fs/cgroup/cpu${base}"
  fi
}

# ---------- optional self-load ----------
LOAD_PIDS=()
start_load(){
  say "[*] generating CPU load ($((NPROC*2)) workers) for the window..."
  if command -v stress-ng >/dev/null 2>&1; then
    stress-ng --cpu $((NPROC*2)) --timeout "${WINDOW}s" >/dev/null 2>&1 &
    LOAD_PIDS+=($!)
  else
    local end=$(( $(date +%s) + WINDOW ))
    for _ in $(seq 1 $((NPROC*2))); do
      ( while [ "$(date +%s)" -lt "$end" ]; do :; done ) & LOAD_PIDS+=($!)
    done
  fi
}
[ "$SELFLOAD" = 1 ] && start_load

# ---------- resolve throttle cgroup path up front ----------
CGP=$(cg_path "${PID:-self}")
statf="$CGP/cpu.stat"
read_cpu(){ awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $9, $5}' /proc/stat; } # total steal idle
read_thr(){ if [ -r "$statf" ]; then awk '/nr_throttled /{n=$2} /throttled_usec /{u=$2} END{print (n==""?0:n), (u==""?0:u)}' "$statf"; else echo "0 0"; fi; }

# ---------- 1+2: snapshot BEFORE, sleep one window, snapshot AFTER ----------
read T1 S1 I1 < <(read_cpu)
read NRT1 TUS1 < <(read_thr)
sleep "$WINDOW"
read T2 S2 I2 < <(read_cpu)
read NRT2 TUS2 < <(read_thr)
DT=$((T2-T1)); DS=$((S2-S1)); DI=$((I2-I1))
STEAL_PCT=$(awk -v s="$DS" -v t="$DT" 'BEGIN{printf (t>0)? "%.2f":"0", 100*s/t}')
IDLE_PCT=$(awk -v i="$DI" -v t="$DT" 'BEGIN{printf (t>0)? "%.2f":"0", 100*i/t}')

# runqueue pressure
RUNQ=$(awk '{print $1}' /proc/loadavg)
PSI="n/a"; [ -f /proc/pressure/cpu ] && PSI=$(awk -F'[= ]' '/some/{print $3}' /proc/pressure/cpu | head -1)

# ---------- 2. CPU THROTTLING: quota readout + deltas from the snapshots above ----------
THR_SUPP=1; QUOTA="none"
if [ -r "$statf" ]; then
  if [ "$CGV" = 2 ] && [ -r "$CGP/cpu.max" ]; then
    read Q P < "$CGP/cpu.max"; [ "$Q" != max ] && QUOTA="${Q}us / ${P}us  (~$(awk -v q="$Q" -v p="$P" 'BEGIN{printf "%.2f", q/p}') CPUs)"
  elif [ "$CGV" = 1 ] && [ -r "$CGP/cpu.cfs_quota_us" ]; then
    Q=$(cat "$CGP/cpu.cfs_quota_us"); P=$(cat "$CGP/cpu.cfs_period_us")
    [ "$Q" != "-1" ] && QUOTA="${Q}us / ${P}us  (~$(awk -v q="$Q" -v p="$P" 'BEGIN{printf "%.2f", q/p}') CPUs)"
  fi
else
  THR_SUPP=0
fi
DNRT=$((NRT2-NRT1)); DTUS=$((TUS2-TUS1))
THR_MS=$(awk -v u="$DTUS" 'BEGIN{printf "%.1f", u/1000}')

# ---------- 3. NUMA ----------
NUMA_NODES=1; NUMA_NOTE="single node (N/A)"
if command -v numactl >/dev/null 2>&1; then
  NUMA_NODES=$(numactl --hardware 2>/dev/null | awk '/available:/{print $2}')
fi
NUMA_REMOTE="n/a"
if [ "${NUMA_NODES:-1}" -gt 1 ]; then
  NUMA_NOTE="$NUMA_NODES nodes present"
  if [ -n "$PID" ] && [ -r "/proc/$PID/numa_maps" ]; then
    # crude: count bytes mapped per node is hard; report node spread of pages
    NUMA_REMOTE=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^N[0-9]+=/){split($i,a,"=");g[a[1]]+=a[2]}} END{n=0;for(k in g)n++; printf "%d node(s) backing this PID\x27s pages", n}' "/proc/$PID/numa_maps")
  elif command -v numastat >/dev/null 2>&1; then
    NUMA_REMOTE=$(numastat 2>/dev/null | awk '/numa_miss/{m=$2} /numa_hit/{h=$2} END{if(h+m>0) printf "numa_miss ratio %.2f%%", 100*m/(h+m); else print "n/a"}')
  fi
fi

# stop self-load
for p in "${LOAD_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done

# ---------- verdict ----------
# thresholds are heuristics; tune to taste. Documented in README.
steal_hot=$(awk -v s="$STEAL_PCT" 'BEGIN{print (s>=3.0)?1:0}')
thr_hot=$(awk -v n="$DNRT" -v ms="$THR_MS" 'BEGIN{print (n>0 && ms>=50)?1:0}')
# NUMA is only "hot" with real evidence: a high numa_miss ratio, or a PID whose
# pages span >1 node. Merely HAVING >1 node is not a fault.
numa_hot=0
NUMA_MISS=$(printf '%s' "$NUMA_REMOTE" | grep -oE '[0-9.]+%' | tr -d '%' | head -1)
if [ "${NUMA_NODES:-1}" -gt 1 ]; then
  awk -v m="${NUMA_MISS:-0}" 'BEGIN{exit !(m>=5.0)}' && numa_hot=1
  printf '%s' "$NUMA_REMOTE" | grep -qE '[2-9] node' && numa_hot=1
fi

VERDICT="HEALTHY — no host-level CPU/NUMA fault stood out this window"
REASON="steal, throttling and NUMA all look benign; if P99 is still high, look at your app: I/O waits, lock contention, GC, downstream calls, or network."
if [ "$steal_hot" = 1 ] && [ "$thr_hot" = 0 ]; then
  VERDICT="HOST CPU SCHEDULING (CPU STEAL)"
  REASON="%steal is elevated while cgroup throttling is low -> the hypervisor is not giving you the CPU you are ready to use. Suspect (a) host overcommit / a noisy neighbor, OR (b) a CPU quota on the QEMU process itself -- a host cgroup cap looks EXACTLY like steal from inside the guest. You cannot tell which from here: check the host (mpstat on the node AND the QEMU cgroup cpu.max / cpu.stat via triage-host.sh)."
elif [ "$thr_hot" = 1 ] && [ "$steal_hot" = 0 ]; then
  VERDICT="CGROUP CPU THROTTLING"
  REASON="throttling events/time are rising while %steal is low -> you are hitting your own CPU quota (cpu.max) before the period ends. Raise the quota, or reduce per-request CPU / concurrency. Remember: a cgroup inside the VM differs from the cgroup capping the QEMU process on the host."
elif [ "$steal_hot" = 1 ] && [ "$thr_hot" = 1 ]; then
  VERDICT="BOTH steal AND throttling present"
  REASON="investigate both the host scheduler and your cgroup quota; separate them by pinning or by relaxing the quota one at a time."
elif [ "$numa_hot" = 1 ]; then
  VERDICT="NUMA PLACEMENT SUSPECT"
  REASON="steal and throttling are benign but memory access looks remote ($NUMA_REMOTE across $NUMA_NODES nodes). Your vCPUs and memory may sit on different NUMA nodes. On the host check numastat -p <qemu-pid> and the vCPU/memory pinning policy."
fi
# If nothing was hot but the host has >1 NUMA node, add a one-line footnote (not a verdict).
if [ "$steal_hot" = 0 ] && [ "$thr_hot" = 0 ] && [ "$numa_hot" = 0 ] && [ "${NUMA_NODES:-1}" -gt 1 ]; then
  REASON="$REASON  (Host has $NUMA_NODES NUMA nodes; re-run with --pid <your server pid> to check memory locality for your process specifically.)"
fi

# ---------- output ----------
if [ "$JSON" = 1 ]; then
  cat <<J
{"window_s":$WINDOW,"nproc":$NPROC,"cgroup_v":$CGV,
 "steal_pct":$STEAL_PCT,"idle_pct":$IDLE_PCT,"loadavg_1m":$RUNQ,"psi_cpu_some_avg10":"$PSI",
 "cpu_quota":"$QUOTA","throttle_supported":$THR_SUPP,"throttled_events_delta":$DNRT,"throttled_ms_delta":$THR_MS,
 "numa_nodes":${NUMA_NODES:-1},"numa_detail":"$NUMA_REMOTE",
 "verdict":"$VERDICT"}
J
  exit 0
fi

hr
say " VM TAIL-LATENCY TRIAGE   (window ${WINDOW}s, ${NPROC} vCPUs, cgroup v${CGV})"
hr
say " 1) CPU STEAL      : ${STEAL_PCT}%   (idle ${IDLE_PCT}%, loadavg1m ${RUNQ}, PSI-cpu ${PSI})"
say "      -> %steal = time you were runnable but the host didn't schedule you."
say " 2) CPU THROTTLING : events +${DNRT}, throttled +${THR_MS}ms   quota: ${QUOTA}"
[ "$THR_SUPP" = 0 ] && say "      (no readable cpu.stat for this cgroup; pass --pid <PID> to target your service)"
say "      -> rising events+time = you hit your cgroup CPU quota before finishing."
say " 3) NUMA           : ${NUMA_NOTE}   ${NUMA_REMOTE}"
say "      -> vCPUs and memory on different nodes = slower memory access."
hr
say " VERDICT: ${VERDICT}"
say " ${REASON}"
hr
