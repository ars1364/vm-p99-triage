#!/usr/bin/env bash
# vm-facts.sh — one-shot inventory of a VM's compute + network, for comparing
# two VMs side by side. Zero required deps (uses lscpu/free/ip/lsblk if present).
set -u
line(){ printf '%s\n' "========================================================"; }
kv(){ printf "  %-22s %s\n" "$1" "$2"; }
get(){ command -v "$1" >/dev/null 2>&1; }

line; printf "  VM FACTS  —  %s   (%s)\n" "$(hostname)" "$(date -u '+%Y-%m-%d %H:%M:%SZ')"; line

echo "[ COMPUTE ]"
if get lscpu; then
  MODEL=$(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2;exit}')
  VCPU=$(lscpu | awk -F: '/^CPU\(s\):/{gsub(/ /,"",$2);print $2;exit}')
  SOCK=$(lscpu | awk -F: '/Socket\(s\)/{gsub(/ /,"",$2);print $2}')
  TPC=$(lscpu | awk -F: '/Thread\(s\) per core/{gsub(/ /,"",$2);print $2}')
  MHZ=$(lscpu | awk -F: '/CPU max MHz|CPU MHz/{gsub(/ /,"",$2);print $2;exit}')
  NUMA=$(lscpu | awk -F: '/NUMA node\(s\)/{gsub(/ /,"",$2);print $2}')
  HV=$(lscpu | awk -F: '/Hypervisor vendor/{gsub(/^ +/,"",$2);print $2}')
  VT=$(lscpu | awk -F: '/Virtualization type/{gsub(/^ +/,"",$2);print $2}')
  kv "CPU model" "$MODEL"
  kv "vCPUs" "$VCPU   (sockets=$SOCK, threads/core=$TPC)"
  kv "CPU max MHz" "${MHZ:-n/a}"
  kv "NUMA nodes (guest)" "${NUMA:-1}"
  kv "Hypervisor / virt" "${HV:-?} / ${VT:-?}"
else
  kv "vCPUs" "$(nproc)"
fi
kv "Memory total" "$(get free && free -h | awk '/Mem:/{print $2}')"
kv "Load avg (1/5/15)" "$(awk '{print $1", "$2", "$3}' /proc/loadavg)"
read sA tA < <(awk '/^cpu /{print $9, $2+$3+$4+$5+$6+$7+$8+$9+$10}' /proc/stat); sleep 1; read sB tB < <(awk '/^cpu /{print $9, $2+$3+$4+$5+$6+$7+$8+$9+$10}' /proc/stat)
kv "%steal (now, 1s)" "$(awk -v s=$((sB-sA)) -v t=$((tB-tA)) 'BEGIN{printf "%.2f%%", (t>0)?100*s/t:0}')"

echo "[ DISK ]"
if get lsblk; then lsblk -d -o NAME,SIZE,ROTA,MODEL 2>/dev/null | sed 's/^/  /'; fi
kv "Root fs" "$(df -h / | awk 'NR==2{print $2" total, "$4" free ("$5" used) on "$1}')"

echo "[ OS / KERNEL ]"
kv "OS" "$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")"
kv "Kernel" "$(uname -r)"
kv "Uptime" "$(uptime -p 2>/dev/null)"

echo "[ NETWORK ]"
IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
kv "Primary iface" "${IFACE:-?}"
kv "IPv4 / CIDR" "$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4; exit}')"
kv "MAC" "$(cat /sys/class/net/$IFACE/address 2>/dev/null)"
kv "MTU" "$(cat /sys/class/net/$IFACE/mtu 2>/dev/null)"
kv "Default gateway" "$(ip -o -4 route show default 2>/dev/null | awk '{print $3; exit}')"
kv "DNS" "$(resolvectl dns 2>/dev/null | awk '{ $1="";$2="";print}' | tr -s ' ' | head -1 || grep -h nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd' ')"
GW=$(ip -o -4 route show default 2>/dev/null | awk '{print $3; exit}')
if [ -n "$GW" ]; then
  P=$(ping -c2 -W1 "$GW" 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5" ms avg"}')
  kv "Gateway ping" "${P:-unreachable}"
fi
kv "Internet (1.1.1.1)" "$(ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && echo reachable || echo 'no / blocked')"

echo "[ OPENSTACK PLACEMENT (metadata service) ]"
MD=$(curl -s -m3 http://169.254.169.254/openstack/latest/meta_data.json 2>/dev/null)
if [ -n "$MD" ] && get python3; then
  echo "$MD" | python3 -c 'import sys,json;d=json.load(sys.stdin);
print("  %-22s %s"%("instance name",d.get("name","?")));
print("  %-22s %s"%("availability_zone",d.get("availability_zone","?")));
print("  %-22s %s"%("instance uuid",d.get("uuid","?")[:18]+"..."))' 2>/dev/null
else
  kv "metadata" "unavailable"
fi
line
