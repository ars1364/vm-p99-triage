# vm-p99-triage

**Two VMs, identical vCPU and RAM, the same incoming workload — yet one has much
higher P99 latency. Where do you start?**

This repo answers that question with a script you can paste into any Linux VM.
It distinguishes the three environment-level causes of tail latency that look
similar from the outside:

1. **CPU steal** — the hypervisor isn't scheduling your vCPUs (host overcommit / noisy neighbor)
2. **CPU throttling** — a cgroup CPU quota (`cpu.max`) caps you before the period ends
3. **NUMA** — your memory sits on a different NUMA node than your vCPUs (remote access)

> The point is **measurement-driven triage**: one metric is never a verdict.
> `triage.sh` correlates several over one window and points you at the right layer
> *before* you reach for a bigger flavor.

---

## Quick start (inside the VM you're suspicious of)

```bash
curl -fsSL https://raw.githubusercontent.com/ars1364/vm-p99-triage/main/triage.sh -o triage.sh
chmod +x triage.sh
./triage.sh                 # observe the running system for 20s
./triage.sh --pid $(pgrep -xo your-service)   # focus throttling on your process's cgroup
./triage.sh --load          # no live traffic? generate CPU load yourself
./triage.sh --json          # machine-readable
```

Zero dependencies beyond coreutils. `sysstat`/`numactl` are used if present but
not required. Read-only; no root needed for the guest-side checks.

---

## The decision tree

```
                 %steal high?
                /            \
             yes              no
              |                |
       throttling high?   throttling high?
        /         \         /        \
      no          yes     yes         no
       |           |       |           |
  HOST CPU     BOTH -     CGROUP      look at NUMA,
  SCHEDULING   split      CPU         then your app
  (steal):     them       THROTTLING  (I/O, locks,
  overcommit   one at     : quota     GC, network)
  or a host    a time     too low
  cgroup cap
```

**Before changing the VM flavor, find out where requests are actually waiting.**
Adding vCPUs is defensible only once measurement shows processing capacity is the
real bottleneck.

---

## It's validated — here's it catching all three (real runs)

Two 4-vCPU / 4 GB VMs (`vm-a` = control, `vm-b` = victim) on the same host,
identical Ubuntu image and workload (a fixed-cost HTTP endpoint, see `cmd/cpuwork`),
driven at a constant request rate by `cmd/loadgen`. We injected one fault into
`vm-b` at a time and ran `triage.sh` on both.

| Scenario | vm-b P99 | guest %steal | guest throttle | host throttle | `triage.sh` verdict |
|---|---|---|---|---|---|
| **S0** baseline | 19 ms | 0.0% | 0 | 0 | HEALTHY ✅ |
| **S1** guest cgroup quota | **8523 ms** | 0.04% | **+200 ev / +59.8 s** | 0 | **CGROUP CPU THROTTLING** ✅ |
| **S2** host contention | **147 ms** | **40%** | 0 | 0 | **HOST CPU SCHEDULING (STEAL)** ✅ |
| **S3** host caps the QEMU proc | **~9000 ms** | **73%** | 0 | **+176 ev / +55 s** | guest says **STEAL** ⚠️ (see below) |
| **S4** NUMA, CPU-bound work | 20.7 ms | 1.6% | 0 | 0 | HEALTHY — *no measurable effect* |
| **S4'** NUMA, memory-bound work | p99 **24.6** / p999 **73.9 ms** (remote) vs p99 21.4 / p999 **24.4 ms** (local) | — | — | — | NUMA bites the **tail** |

`vm-a` stayed HEALTHY at ~19 ms P99 through every run — the control held.

### The one that matters most: S2 vs S3

**S2 (a noisy neighbor) and S3 (a CPU quota on the QEMU process) look *identical*
from inside the guest** — both show as high `%steal`, both leave the guest's own
`cpu.stat` clean. In S3 we capped `vm-b`'s QEMU cgroup to 1.0 CPU on the host; the
guest reported **73% steal** and *zero* throttling, because the quota is on the
*host's* cgroup, not the guest's.

> A cgroup **inside** the VM is a different thing from the cgroup controlling the
> **QEMU process on the host**. You cannot rule out a host-side CPU cap by reading
> `cpu.stat` inside the guest. When `triage.sh` says STEAL, the next step is the
> **host**: `triage-host.sh` reads the QEMU cgroup's `cpu.max` and `nr_throttled`
> and tells contention apart from a quota.

And **S4** is the other lesson: remote NUMA placement did **nothing** to a
CPU-bound workload, and only moved the *tail* once the workload was memory-bound.
Observing remote memory does not, by itself, prove NUMA is your P99 problem — you
have to measure it with *your* access pattern.

---

## The host side: `triage-host.sh`

Run on the hypervisor when a guest's `triage.sh` pointed you there:

```bash
sudo ./triage-host.sh --domain <libvirt-domain>   # or --pid <qemu-pid>
```

It attributes steal / throttling / NUMA to a specific guest: per-CPU steal on the
node (overcommit), the guest's QEMU cgroup `cpu.max` + `nr_throttled` (a host cap),
and `numastat -p <qemu-pid>` + vCPU/memory pinning (remote memory).

---

## Reproduce the whole lab yourself

On a KVM/QEMU host **you own**, with two identical guests:

```bash
# 1. build the fixed-cost workload + load generator (pure Go stdlib, no deps)
go build -o cpuwork ./cmd/cpuwork
go build -o loadgen ./cmd/loadgen

# 2. run cpuwork on both guests
GOMAXPROCS=4 ./cpuwork -work 800 -mem-mb 256 -reads 60000   # on each target

# 3. inject a fault into ONE guest (on the host), then compare
sudo ./scripts/inject-fault.sh steal     <victim-domain>
sudo ./scripts/inject-fault.sh throttle  <victim-domain>
sudo ./scripts/inject-fault.sh numa      <victim-domain>
sudo ./scripts/inject-fault.sh clear     <victim-domain>

# 4. drive load + triage both guests in the same window (from the load host)
./scripts/run-scenario.sh my-test 150 20

# guest-internal cgroup throttle (the container case): scripts/guest-cgroup-cap.sh
# host-side throttle counter sampler:                   scripts/host-throttle-sample.sh
```

---

## Fleet mode (optional): Ansible

For checking many VMs at once. **For a single VM, don't bother — just run
`triage.sh`.** The playbook ships the same script, runs it, and collects one JSON
report per host:

```bash
ansible-playbook -i inventory.ini ansible/site.yml
```

---

## Thresholds (heuristics — tune them)

| signal | "hot" when | why |
|---|---|---|
| `%steal` | ≥ 3% over the window | runnable-but-not-scheduled time is real loss |
| throttling | any events **and** ≥ 50 ms throttled | events alone don't tell you severity; pair with time |
| NUMA | >1 node **and** remote evidence (high `numa_miss`, or a PID spanning nodes) | merely *having* >1 node is not a fault |

These are starting points, not laws. The script prints the raw numbers so you can
judge for yourself.

## What the guest can and can't see

- `%steal`, run-queue, PSI, **its own** cgroup throttling: yes.
- Whether high steal is a noisy neighbor **or** a host CPU cap: **no** — that needs the host.
- NUMA: a guest usually sees one flat node; NUMA placement is a **host** property. `triage.sh` says so and sends you to `triage-host.sh`.

## License

MIT — see [LICENSE](LICENSE).
