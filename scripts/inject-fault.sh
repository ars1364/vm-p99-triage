#!/bin/bash
# inject-fault.sh -- LAB ONLY. Run on a KVM/QEMU host YOU OWN to reproduce the
# three environment faults on ONE guest, so you can watch them from inside that
# guest with ordinary Linux tools (vmstat/mpstat, cpu.stat, numactl/sysbench).
#
#   usage: sudo ./inject-fault.sh <steal|numa|providercap|clear|show> <libvirt-domain>
#
# steal       Pin ALL the guest's vCPUs onto ONE physical CPU (self-oversubscribe).
#             Under load the guest wants N CPUs but gets 1 -> real %steal INSIDE the
#             guest, with almost no impact on neighbour VMs (it only ties up 1 pCPU;
#             the host scheduler steers other guests onto the free cores).
# numa        Pin vCPUs to node1 while forcing memory onto node0 -> every memory
#             access crosses the interconnect. Restart the guest workload afterwards
#             so its pages actually (re)allocate on the remote node.
# providercap Cap the WHOLE VM via the host cgroup (global_quota). This is what a
#             provider-imposed CPU cap looks like. IMPORTANT: from inside the guest
#             this shows up as %steal, NOT as cpu.stat throttling -- the guest cannot
#             see the host cgroup. (Throttling you CAN see from the guest is a cap on
#             a cgroup INSIDE the guest: a container/k8s/systemd CPUQuota -- demo that
#             with scripts/guest-throttle-demo.sh, no host access needed.)
# clear       Undo everything (unpin vCPUs, remove cap, memory back to both nodes).
# show        Print the domain's current pinning / quota / numatune.
#
# pCPU/node numbers below assume a 2-socket host (node1 = 12-23,36-47). Adjust
# STEAL_PCPU / NUMA_CPUS / NUMA_MEMNODE for your host (numactl -H to see layout).
set -u
STEAL_PCPU=${STEAL_PCPU:-23}      # a single pCPU on node1
NUMA_CPUS=${NUMA_CPUS:-12-15}     # vCPUs here (node1) ...
NUMA_MEMNODE=${NUMA_MEMNODE:-0}   # ... memory here (node0) => remote
DOM=${2:-${DOM:-}}
[ -z "$DOM" ] && { echo "give a libvirt domain as arg 2"; exit 2; }
V="sudo docker exec nova_libvirt virsh"
UNLIM=17592186044415
NVCPU=$($V vcpucount "$DOM" --live 2>/dev/null | awk 'NR==1{print $1}'); NVCPU=${NVCPU:-4}
vcpus(){ seq 0 $((NVCPU-1)); }
case "${1:-}" in
  steal)
    for vc in $(vcpus); do $V vcpupin "$DOM" "$vc" "$STEAL_PCPU" --live >/dev/null; done
    echo "STEAL: all $NVCPU vCPUs of $DOM pinned onto pCPU $STEAL_PCPU (self-oversubscribe). Load the guest to see %steal." ;;
  numa)
    for vc in $(vcpus); do $V vcpupin "$DOM" "$vc" "$NUMA_CPUS" --live >/dev/null; done
    $V numatune "$DOM" --nodeset "$NUMA_MEMNODE" --mode strict --live >/dev/null
    echo "NUMA: vCPUs->node1($NUMA_CPUS), memory->node$NUMA_MEMNODE (remote). Restart the guest workload to realloc." ;;
  providercap)
    $V schedinfo "$DOM" --live --set global_period=100000 --set global_quota=100000 >/dev/null
    echo "PROVIDERCAP: $DOM host-capped to 1.0 CPU. NOTE: inside the guest this reads as %steal, not throttling." ;;
  clear)
    $V schedinfo "$DOM" --live --set global_quota=$UNLIM >/dev/null 2>&1
    for vc in $(vcpus); do $V vcpupin "$DOM" "$vc" 0-47 --live >/dev/null; done
    $V numatune "$DOM" --nodeset 0-1 --mode strict --live >/dev/null 2>&1
    echo "CLEARED $DOM (vCPUs unpinned, cap removed, memory both nodes)." ;;
  show) ;;
  *) echo "usage: sudo $0 <steal|numa|providercap|clear|show> <domain>"; exit 2 ;;
esac
echo "  global_quota: $($V schedinfo "$DOM" 2>/dev/null | awk -F: '/global_quota/{print $2}')"
echo "  vcpupin:"; $V vcpupin "$DOM" 2>/dev/null | sed 's/^/    /'
echo "  numatune: $($V numatune "$DOM" 2>/dev/null | tr '\n' ' ')"
