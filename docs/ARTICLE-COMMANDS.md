# Diagnosing VM tail latency from inside the guest — the commands

Two identical VMs, same flavor, same host, same network. One is healthy; the
other is the victim of an environment fault. Everything below is run **inside
the guest** with ordinary Linux tools — no hypervisor access. Each section is a
clean A/B: run the same commands on the good VM (A) and the bad VM (B).

The honest scope, up front:

| Cause | Guest-visible? | Command that shows it |
|-------|----------------|-----------------------|
| CPU steal (overcommit / noisy neighbor) | **Yes, directly** | `vmstat`, `mpstat` — `%steal` |
| cgroup CPU throttling (your container / k8s / systemd CPUQuota) | **Yes, directly** | `cat .../cpu.stat` — `nr_throttled` |
| NUMA (memory on a remote node) | **Indirectly** (single-vNUMA guest) | `sysbench memory`, `numactl -H`, `numastat` |
| A **provider-imposed** cap on your whole VM | **No — it looks like steal** | needs host `cpu.stat`; from the guest it is indistinguishable from overcommit |

The last row is the key caveat: a CPU cap the *provider* puts on your QEMU
process shows up inside the guest as `%steal`, not as throttling, because the
guest cannot read the host's cgroup. Throttling you *can* see from the guest is
a cap on a cgroup **inside** the guest (a container/k8s/systemd limit).

---

## 1. CPU steal — the host isn't scheduling your vCPUs

Generate a little load, then look at `st`:

```
stress-ng --cpu "$(nproc)" --timeout 30s &
vmstat 1 5                 # column 'st' = steal
mpstat -P ALL 1 3          # '%steal' per CPU
```

- **VM A (healthy):** `st` ~= 0, `%steal` ~= 0.
- **VM B (victim):** `st` is large (e.g. 60-75%). You are runnable but the host
  won't give you a physical CPU — overcommit, a noisy neighbor, or a
  provider-side cap. You cannot tell which of those from inside the guest.

Raw source of the number (no tools): field 9 of `/proc/stat`:
```
awk '/^cpu /{print "steal_ticks="$9}' /proc/stat
```

## 2. cgroup CPU throttling — you hit your own quota

This is the throttling the guest *can* see directly: a `cpu.max` quota on a
cgroup inside the VM (exactly how Docker `--cpus`, k8s CPU limits and systemd
`CPUQuota` enforce a cap). Unlike steal, this is self-inflicted — it reproduces
on ANY VM regardless of which host it lands on.

**Timing trap:** a `--scope` unit's cgroup only exists *while the job runs*;
systemd deletes it the instant the command exits. So read `cpu.stat` DURING the
window, not after. Give the burn a long timeout and sample twice:

```
# start a 60s burn capped at HALF a core, then sample the counters while it runs
sudo systemctl stop demo.scope 2>/dev/null; sudo systemctl reset-failed demo.scope 2>/dev/null
sudo systemd-run --unit=demo --scope -p CPUQuota=50% stress-ng --cpu 2 --timeout 60s &
sleep 2
cat /sys/fs/cgroup/system.slice/demo.scope/cpu.max       # "50000 100000" = 0.5 CPU / 100ms
grep -E 'nr_throttled|throttled_usec' /sys/fs/cgroup/system.slice/demo.scope/cpu.stat   # BEFORE
mpstat 1 10 | awk '/Average:/{print "%steal="$(NF-3)}'                                   # host?
grep -E 'nr_throttled|throttled_usec' /sys/fs/cgroup/system.slice/demo.scope/cpu.stat   # AFTER
sudo systemctl stop demo.scope                                                           # cleanup
```

Validated A/B result:

- **VM A (uncapped):** same burn with no quota -> `nr_throttled` stays 0.
- **VM B (capped, or any VM with the cap above):** in a 10s window,
  `nr_throttled` climbs ~**+101** (18 -> 119) and `throttled_usec` ~**+15.1s**
  (2.69 -> 17.83s) while **`%steal` stays 0.00**. You are stopped at your own
  quota before the 100ms period ends — the CPU is idle, you just aren't allowed
  to use it.

The clean discriminator from steal:
**throttle -> `nr_throttled` up, `%steal` ~0; steal -> `%steal` up, `nr_throttled` 0.**

For an already-running service, point at its real cgroup instead of a demo unit:
```
cat /sys/fs/cgroup/$(awk -F: '/^0::/{print $3}' /proc/$(pgrep -n yourapp)/cgroup)/cpu.stat
```

## 3. NUMA — memory on a remote node  *(this one is for the infra owner, not the VM user)*

Unlike steal and throttling, **a VM user usually cannot prove NUMA from inside the
guest.** A single-vNUMA flavor reports `available: 1 nodes` no matter where its
RAM physically sits, there is no guest-readable counter, and the bandwidth hit
(~15-25%) hides inside normal shared-host noise. The most a tenant can do is:

```
numactl -H                     # 1 node? then you are blind to placement
# infer from YOUR app's tail latency on memory-heavy work (remote compounds per-access),
# then ASK YOUR PROVIDER to check the host, or pick a NUMA-pinned instance type.
```

> **Verdict (guest side):** NUMA is the sneakiest of the three. Steal has
> `%steal`, throttling has `nr_throttled` — both readable in the VM. NUMA on a
> single-vNUMA guest has **no counter and only a weak, deniable bandwidth
> signal**. The reliable in-guest tell is the *app's own P99/P999*, not a metric.
> **The real diagnosis and the fix live on the host — so the rest of this section
> is for the cloud/OpenStack operator.**

### Host-side detection (operator / OpenStack engineer)

```
numactl -H                                   # node count, per-node CPUs/size, distances
                                             #   distances 10 (local) vs 21 (remote) = ~2.1x cost
# For a specific guest, find its QEMU pid and see where its RAM actually is:
PID=$(cat /var/run/libvirt/qemu/<instance-xxxx>.pid)      # or: pgrep -f guest=<instance-xxxx>
numastat -p "$PID"                           # MB per node for that VM  <-- the smoking gun
virsh vcpupin  <instance-xxxx>               # which pCPUs the vCPUs are on
virsh numatune <instance-xxxx>               # memory nodeset + mode
```

If `numastat -p` shows the VM's pages on node 0 while `vcpupin` has its vCPUs on
node 1's CPUs, every memory access is crossing the interconnect. That is the
unambiguous proof the guest can never see.

### Real numbers (measured on a live 2-socket compute host, load ~7)

```
                           seq bandwidth     random (latency-bound)
LOCAL   (cpu0 -> mem0)       6508 MiB/s         257 MiB/s
REMOTE  (cpu0 -> mem1)       5319 MiB/s  -18%   190 MiB/s  -26%
REMOTE, node1 bus saturated  3834 MiB/s  -41%   129 MiB/s  -50%   <-- worst case
LOCAL while node1 saturated  6854 MiB/s   ~0            -        <-- a LOCAL VM is immune
```

Two lessons: (1) the latency-bound (random) penalty is bigger than the streaming
one, which is why memory-bound **app tail latency** suffers most; (2) a
remote-memory VM is hostage to the *other* node's contention — up to ~2x slower —
while a correctly-placed (local) VM on the same host sails through untouched.

### The fix (OpenStack / libvirt)

The goal is **co-location**: a VM's vCPUs and its RAM on the same node, and a VM
that fits in one node should never be split across two.

- **Flavor:** pin topology and CPUs so the scheduler keeps the guest on one node:
  ```
  openstack flavor set <flavor>     --property hw:numa_nodes=1     --property hw:cpu_policy=dedicated     --property hw:cpu_thread_policy=prefer
  ```
  (A large guest that must span sockets: set `hw:numa_nodes=2` so the guest gets
  a *correct* 2-node topology it can optimize for, rather than a silent split.)
- **Scheduler:** enable `NUMATopologyFilter` in `nova.conf`
  (`[filter_scheduler] enabled_filters`) so placement honours the topology.
- **Host:** reserve memory per node (`reserved_huge_pages` / `reserved_host_memory_mb`)
  and prefer **hugepages** (`hw:mem_page_size=large`) — hugepages are allocated
  per-node and make placement explicit. Avoid overcommit on pinned hosts
  (`cpu_allocation_ratio=1.0` for the pinned aggregate).
- **Live, already-running guest (triage only):** `virsh numatune <dom> --mode
  restrictive --nodeset <n> --live` nudges future allocations; a clean fix needs
  a cold migrate/resize onto a correctly-pinned flavor so the pages re-home.

> **Verdict (host side):** NUMA misplacement is invisible to the tenant and
> costs 15-50% of memory performance, worst on a busy host. It is 100% the
> operator's to prevent — via flavor topology + CPU pinning + NUMATopologyFilter
> — and the VM user's only recourse is to pick a NUMA-aware instance type or ask.

---

## The one-shot community script

`triage.sh` (in this repo) runs read-only inside any VM and reports all three
signals plus a heuristic verdict — paste-and-run, zero dependencies. It is the
convenience wrapper; the commands above are the ground truth it is built on.
