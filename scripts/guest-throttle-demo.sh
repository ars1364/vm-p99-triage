#!/bin/bash
# guest-throttle-demo.sh -- run ENTIRELY inside a guest VM, no host access.
# Demonstrates cgroup CPU throttling (cpu.max) the way a container / k8s / systemd
# CPUQuota limit does it -- the one kind of throttling the guest CAN see directly
# in cpu.stat (nr_throttled). Contrast with %steal, which stays ~0 here.
#
#   usage: sudo ./guest-throttle-demo.sh [quota_pct] [seconds]
#   e.g.   sudo ./guest-throttle-demo.sh 200 30     # cap at 2.0 CPUs for 30s
set -u
PCT=${1:-200}; SECS=${2:-30}; N=$(nproc)
echo "Capping a $N-thread CPU burn to CPUQuota=${PCT}% for ${SECS}s (host idle-safe; only limits this unit)."
sudo systemctl stop thr-demo.scope 2>/dev/null; sudo systemctl reset-failed thr-demo.scope 2>/dev/null
sudo systemd-run --unit=thr-demo --scope -p CPUQuota=${PCT}% \
     stress-ng --cpu "$N" --timeout "${SECS}s" >/dev/null 2>&1 &
sleep 2
CG=$(find /sys/fs/cgroup -maxdepth 3 -name thr-demo.scope -type d 2>/dev/null | head -1)
echo "cpu.max = $(cat $CG/cpu.max 2>/dev/null)   (quota us / period us)"
echo "watching cpu.stat (nr_throttled should climb; %steal stays ~0):"
for i in $(seq 1 $((SECS/3))); do
  sleep 3
  echo "  t+$((i*3))s  $(awk '/nr_throttled|throttled_usec/{printf "%s=%s ",$1,$2}' $CG/cpu.stat 2>/dev/null)  st(vmstat)=$(vmstat 1 2 | tail -1 | awk '{print $(NF-2)}')%"
done
wait 2>/dev/null
echo "done. (nr_throttled rising + steal~0  =>  cgroup cpu.max throttling, NOT host steal)"
