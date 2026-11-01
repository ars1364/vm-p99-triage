#!/bin/bash
sudo systemctl stop cpuwork-capped.service 2>/dev/null; sudo systemctl reset-failed cpuwork-capped.service 2>/dev/null
pkill cpuwork 2>/dev/null; sleep 1
sudo systemd-run --unit=cpuwork-capped -p CPUQuota=100% -p Environment=GOMAXPROCS=4 \
   /home/ubuntu/cpuwork -addr :8080 -work 800 -mem-mb 256 -reads 60000 >/dev/null 2>&1
sleep 2
echo "health: $(curl -s localhost:8080/healthz)"
PID=$(pgrep -x cpuwork); echo "pid=$PID"
CG=$(awk -F: '/^0::/{print $3}' /proc/$PID/cgroup); echo "cg=$CG  cpu.max=$(cat /sys/fs/cgroup$CG/cpu.max 2>/dev/null)"
