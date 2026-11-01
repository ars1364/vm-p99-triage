#!/bin/bash
# inject-fault.sh -- LAB ONLY. Run on a KVM/QEMU host YOU OWN to reproduce the
# three faults on one guest, so you can watch triage.sh classify them.
#   usage: sudo ./inject-fault.sh <throttle|steal|numa|clear|show> <libvirt-domain>
# "steal"    pins all vCPUs onto ONE pCPU (self-oversubscribe) -> guest sees %steal
# "throttle" caps the whole VM to 1.0 CPU via the host cgroup -> guest sees %steal too (!),
#            but the HOST cgroup cpu.stat shows nr_throttled (see host-throttle-sample.sh)
# "numa"     pins vCPUs to node0 while memory sits on node1 -> remote memory access
DOM=${2:-${DOM:-}}
[ -z "$DOM" ] && { echo "give a libvirt domain as arg 2"; exit 2; }
V="sudo docker exec nova_libvirt virsh"
UNLIM=17592186044415
case "$1" in
  throttle) $V schedinfo $DOM --live --set global_period=100000 --set global_quota=100000 >/dev/null; echo "THROTTLE: $DOM capped to 1.0 CPU";;
  steal)    for vc in 0 1 2 3; do $V vcpupin $DOM $vc 11 --live >/dev/null; done; echo "STEAL: 4 vCPUs of $DOM pinned onto pCPU 11 (self-oversubscribe)";;
  numa)     for vc in 0 1 2 3; do $V vcpupin $DOM $vc $vc --live >/dev/null; done; $V numatune $DOM --nodeset 1 --mode strict --live >/dev/null; echo "NUMA: vCPUs->node0(0-3), memory->node1 strict (restart workload to realloc)";;
  clear)    $V schedinfo $DOM --live --set global_quota=$UNLIM >/dev/null 2>&1; for vc in 0 1 2 3; do $V vcpupin $DOM $vc 0-47 --live >/dev/null; done; $V numatune $DOM --nodeset 0-1 --mode strict --live >/dev/null 2>&1; echo "CLEARED $DOM";;
  show)     ;;
esac
echo "  quota: $($V schedinfo $DOM 2>/dev/null | awk -F: '/global_quota/{print $2}')  vcpupin:"; $V vcpupin $DOM 2>/dev/null | sed 's/^/    /'
echo "  numatune: $($V numatune $DOM 2>/dev/null | tr '\n' ' ')"
