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

## 3. NUMA — your memory is on a remote node

A single-vNUMA guest can't show `numa_miss` (it thinks everything is local), so
the honest guest-side evidence is a **memory-latency/bandwidth probe** compared
against the identical healthy VM:

```
numactl -H                                  # topology the guest sees
sysbench memory --memory-block-size=256M --memory-total-size=20G --memory-oper=read --memory-access-mode=rnd run
```

> Use a block size **larger than your L3 cache** (here 256 MiB). With a tiny
> buffer sysbench measures cache bandwidth and NUMA is invisible.

- **VM A (local memory):** e.g. seq ~6650 MiB/s, rnd ~193 MiB/s.
- **VM B (remote memory):** e.g. seq ~5380 MiB/s, rnd ~169 MiB/s — ~20% lower
  bandwidth for the *same* VM spec, because every access crosses the CPU
  interconnect (QPI/UPI). The bandwidth hit is modest; the real damage is on a
  memory-bound app's **tail latency**, where remote memory can push P99/P999
  several times higher (measure with your own workload, not just sysbench).

If the flavor exposes >=2 vNUMA nodes, you also get it directly:
```
numastat                                    # numa_miss / numa_foreign > 0
numastat -p $(pgrep -n yourapp)             # per-process page placement
```

On the host (for the write-up, not something a customer can run) the proof is
`numastat -p <qemu-pid>` showing the VM's pages sitting on the remote node.

---

## The one-shot community script

`triage.sh` (in this repo) runs read-only inside any VM and reports all three
signals plus a heuristic verdict — paste-and-run, zero dependencies. It is the
convenience wrapper; the commands above are the ground truth it is built on.
