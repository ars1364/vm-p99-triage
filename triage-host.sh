#!/usr/bin/env bash
# triage-host.sh — the HOST (hypervisor) half of the triage.
#
# Run this on the KVM/QEMU host (not inside the guest) when triage.sh inside a
# VM pointed at the host. It attributes steal / throttling / NUMA to a specific
# guest by its libvirt domain or QEMU PID. Read-only.
#
# Usage:
#   sudo ./triage-host.sh --domain <libvirt-domain>
#   sudo ./triage-host.sh --pid <qemu-pid>
#   sudo ./triage-host.sh --domain instance-00000abc --window 20
set -u
WINDOW=20; DOMAIN=""; QPID=""
while [ $# -gt 0 ]; do case "$1" in
  --domain) DOMAIN="$2"; shift 2;;
  --pid) QPID="$2"; shift 2;;
  --window) WINDOW="$2"; shift 2;;
  -h|--help) sed -n '2,12p' "$0"; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

if [ -n "$DOMAIN" ] && command -v virsh >/dev/null 2>&1; then
  QPID=$(virsh qemu-monitor-command "$DOMAIN" --hmp info status >/dev/null 2>&1; pgrep -f "guest=$DOMAIN," | head -1)
  [ -z "$QPID" ] && QPID=$(pgrep -f -- "-name guest=$DOMAIN" | head -1)
fi
[ -z "$QPID" ] && { echo "could not resolve QEMU PID (give --pid)"; exit 2; }
echo "=== host triage for QEMU pid $QPID ${DOMAIN:+(domain $DOMAIN)} , window ${WINDOW}s ==="

echo "--- 1) host CPU pressure & per-CPU steal/idle (is the NODE oversubscribed?) ---"
command -v mpstat >/dev/null 2>&1 && mpstat -P ALL 1 "$WINDOW" | awk 'END{}1' | tail -n +1 | grep -E "Average|CPU" | head -60 || \
  echo "(install sysstat for mpstat; meanwhile see /proc/pressure/cpu below)"
[ -f /proc/pressure/cpu ] && { echo "host PSI cpu:"; cat /proc/pressure/cpu; }

echo "--- 2) this guest's cgroup CPU quota + throttling on the HOST ---"
# libvirt puts the VM under machine.slice/.../ ; find the cgroup of the qemu pid
CG=$(awk -F: '/^0::/{print $3}' /proc/$QPID/cgroup 2>/dev/null)
if [ -n "$CG" ]; then
  base="/sys/fs/cgroup${CG}"
  echo "cgroup: $CG"
  [ -r "$base/cpu.max" ] && echo "cpu.max: $(cat "$base/cpu.max")"
  if [ -r "$base/cpu.stat" ]; then
    n1=$(awk '/nr_throttled /{print $2}' "$base/cpu.stat"); u1=$(awk '/throttled_usec /{print $2}' "$base/cpu.stat")
    sleep "$WINDOW"
    n2=$(awk '/nr_throttled /{print $2}' "$base/cpu.stat"); u2=$(awk '/throttled_usec /{print $2}' "$base/cpu.stat")
    echo "host-side throttling over ${WINDOW}s: events +$((n2-n1)), throttled +$(( (u2-u1)/1000 ))ms"
  fi
fi

echo "--- 3) NUMA placement of this guest (vCPU node vs memory node) ---"
if command -v numastat >/dev/null 2>&1; then
  echo "numastat -p $QPID (per-node memory of the QEMU process, MB):"
  numastat -p "$QPID" 2>/dev/null | tail -8
fi
if [ -n "$DOMAIN" ] && command -v virsh >/dev/null 2>&1; then
  echo "vCPU pinning (virsh vcpupin):"; virsh vcpupin "$DOMAIN" 2>/dev/null
  echo "emulator pinning:"; virsh emulatorpin "$DOMAIN" 2>/dev/null
  echo "numatune (memory policy):"; virsh numatune "$DOMAIN" 2>/dev/null
fi
echo "=== read the three sections together: high per-CPU steal on the node -> overcommit;"
echo "    host-side throttling -> the VM's quota caps it; memory on a different node"
echo "    than its vCPUs -> NUMA penalty. ==="
