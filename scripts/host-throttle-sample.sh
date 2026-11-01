#!/bin/bash
DOM=${1:-instance-00000d15}; W=${2:-18}
P=$(pgrep -f -- "guest=$DOM," | head -1); [ -z "$P" ] && { echo "no qemu pid"; exit 1; }
REL=$(awk -F: '/^0::/{print $3}' /proc/$P/cgroup)      # .../libvirt-qemu/emulator
PAR=$(dirname "$REL")                                   # .../libvirt-qemu  (quota lives here)
CG="/sys/fs/cgroup${PAR}"
echo "qemu_pid=$P"; echo "vm_cgroup=$PAR"
echo "cpu.max(host)=$(sudo cat $CG/cpu.max 2>/dev/null)"
read n1 u1 < <(sudo awk '/nr_throttled /{n=$2}/throttled_usec /{u=$2}END{print n,u}' $CG/cpu.stat)
sleep "$W"
read n2 u2 < <(sudo awk '/nr_throttled /{n=$2}/throttled_usec /{u=$2}END{print n,u}' $CG/cpu.stat)
echo "HOST VM-cgroup cpu.stat over ${W}s: nr_throttled +$((n2-n1))  throttled +$(( (u2-u1)/1000 ))ms"
