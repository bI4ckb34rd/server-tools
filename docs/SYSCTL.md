# SYSCTL.md — kernel tuning specification

> Status: **implemented** by `src/tuners/sysctl.sh` (2.4.5). This document and
> the tuner must stay in sync — change the spec first, then the code. Which
> sections apply is decided by `src/engine/policy.sh` from the detected roles
> (`docs/ROLES.md`), never by role names inside the tuner.

All values land in `/etc/sysctl.d/99-zz-server-tools.conf` (tracked via
`st_track_file`). The name sorts **after** Debian/Ubuntu's `99-sysctl.conf`
(a symlink to `/etc/sysctl.conf`): systemd-sysctl applies files in name
order, so the old `99-server-tools.conf` lost every key a panel or installer
had put into `/etc/sysctl.conf` at the next boot. A run moves the old file,
comments conflicting keys out of `/etc/sysctl.conf` (tracked; `sysctl -p`
and `sysctl --system` apply that file last), and reports — never edits —
conflicts in other later files. `--dry-run` lists them. `TIER` refers to the capacity tier table in
`docs/ROLES.md`.

## Layer 1 — base (always applied)

### Congestion control & queueing

| Key | Value | Why |
| --- | --- | --- |
| `net.core.default_qdisc` | `fq` when TCP terminates locally and BBR is available; `fq_codel` on a pure forwarder or without BBR (config `qdisc` overrides) | fq paces locally generated TCP (what BBR wants); forwarded packets carry no socket, so on a forwarder fq is only per-packet cost |
| `net.ipv4.tcp_congestion_control` | `bbr` if kernel ≥ 4.9 and module loads, else `cubic` | best throughput/latency on lossy long-haul paths |

BBR persistence: `tcp_bbr` in `/etc/modules-load.d/server-tools.conf`

Under `--dry-run` the module is deliberately **not** loaded, so availability is
inferred from `modinfo tcp_bbr` instead of the live
`tcp_available_congestion_control` list — otherwise the plan would promise
`cubic` on exactly the hosts where a real run applies `bbr`.
(tracked, so rollback removes it — a v1 gap).

### Connection accept path (TIER-scaled)

| Key | S / M / L / XL | Why |
| --- | --- | --- |
| `net.core.somaxconn` | 8192 / 16384 / 32768 / 65535 | accept queue for bursty client reconnects |
| `net.ipv4.tcp_max_syn_backlog` | same as somaxconn | SYN flood headroom |
| `net.core.netdev_max_backlog` | 16384 / 32768 / 65536 / 65536 | per-CPU ingress queue |
| `net.ipv4.tcp_syncookies` | `1` | SYN flood fallback |

### Ports, timers, keepalive

| Key | Value | Why |
| --- | --- | --- |
| `net.ipv4.ip_local_port_range` | `10240 65535` | outbound port capacity; keeps privileged/low ports free |
| `net.ipv4.tcp_fin_timeout` | `30` | faster FIN_WAIT2 reclaim under churn |
| `net.ipv4.tcp_tw_reuse` | `1` | reuse TIME_WAIT for outbound |
| `net.ipv4.tcp_keepalive_time/intvl/probes` | `300 / 60 / 5` | detect dead tunnels in ~10 min instead of hours |
| `net.ipv4.tcp_slow_start_after_idle` | `0` | idle tunnels resume at full cwnd |
| `net.ipv4.tcp_no_metrics_save` | `1` | don't poison future connections with bad-path metrics |
| `net.ipv4.tcp_fastopen` | `3` | harmless enable both directions |
| `net.ipv4.tcp_notsent_lowat` | `16384` | caps unsent-buffer depth — lower proxy latency (Cloudflare-documented) |
| `net.ipv4.tcp_rfc1337` | `1` | protects TIME-WAIT sockets from RST assassination |
| `net.ipv4.tcp_mtu_probing` | `1` | **changed vs legacy (was 0)** — mode 1 activates only after a blackhole is detected, preventing stalls on ICMP-filtered paths; the harmful aggressive mode is `2` |
| `net.ipv4.tcp_min_snd_mss` | `512` | CVE-2019-11479 safe floor — keeps PMTU probing useful without letting a peer force a pathologically small MSS (goodput collapse / remote DoS) |

Applying the qdisc live (`src/tuners/qdisc.sh`): `default_qdisc` only
affects qdiscs created later. 2.4.4 forced it with `tc qdisc replace dev X root
fq`, which on a **multi-queue** NIC replaces `mq` (one child per TX queue)
with a single root qdisc — every CPU then serialises on one lock. 2.4.5 asks the
kernel to re-attach its defaults instead (delete our own root, or replace a
kernel-attached `mq` with a fresh `mq`), which rebuilds `mq` with the new
child kind on multi-queue NICs and a single qdisc on single-queue ones.
Custom roots (htb, cake, tbf shaping) are never touched. The rebuild is
recorded (`qdisc` manifest row) and undone by rollback.

### Buffers (TIER-scaled)

| Key | S / M / L / XL | Why |
| --- | --- | --- |
| `net.core.rmem_max` / `wmem_max` | 8 / 16 / 32 / 64 MB | BDP headroom for long-haul high-bandwidth paths |
| `net.ipv4.tcp_rmem` | `≥ 4096 87380 <rmem_max>` | autotuning bounds. **Per-field ceiling** — the middle value is the buffer each new socket starts with, and modern kernels default to `131072`; a hardcoded triple would shrink it back to the pre-4.20 `87380` |
| `net.ipv4.tcp_wmem` | `≥ 4096 65536 <wmem_max>` | autotuning bounds. **Per-field ceiling** (same rule; also stops a small tier from lowering a large kernel max) |
| `net.core.rmem_default` / `wmem_default` | `262144` | sane default without autotuning |
| `net.ipv4.udp_rmem_min` / `udp_wmem_min` | `16384` | UDP floor under memory pressure (WireGuard/Hysteria2) |
| `net.core.optmem_max` | `≥ 131072` | per-socket ancillary buffer headroom (**ceiling** — never below the kernel default, which is 131072 on modern kernels) |

### High-churn caps (L / XL only)

| Key | L / XL | Why |
| --- | --- | --- |
| `net.ipv4.tcp_max_tw_buckets` | 524288 / 1048576 | cap TIME-WAIT memory under mass reconnects |
| `net.ipv4.tcp_max_orphans` | 131072 / 262144 | cap orphaned-socket memory under churn |

### Reserved service ports (dynamic)

`net.ipv4.ip_local_reserved_ports` is generated at apply time from the service
ports that fall inside our ephemeral range (10240-65535, up to 64 entries after
collapsing consecutive runs into ranges) — an outgoing connection can then never
grab a panel/node port.

Only **unambiguous** evidence is used, in this order:

1. **TCP sockets in LISTEN state, bound to an address reachable from off the
   box** (wildcard or a real address). Loopback-only listeners are excluded:
   Xray keeps internal plumbing on `127.0.0.1` with a port the kernel assigns
   afresh at every start, so reserving it is meaningless *and* would change the
   generated value on every run — whereas a port that serves clients must be
   externally bound and survives a restart unchanged.
2. **WireGuard's listen port**, asked of `wg` itself rather than inferred from
   sockets.
3. The **`reserved_ports` config key** (comma separated), for anything else.

Generic UDP listeners are deliberately **not** auto-detected. A userspace proxy
opens one UNCONN socket per UDP session and a QUIC/Hysteria session outlives any
affordable sampling window, so by socket inspection alone those ephemeral ports
are indistinguishable from a service. Reserving them spent the list on ports
belonging to nothing and — because this set is rebuilt from the live system on
every render — made the rendered value differ on every run. Sampling twice and
capping the count only reduced how often that happened; it could not fix it,
because the input is genuinely ambiguous. Restricting the sources above makes
the result **deterministic by construction**; a UDP-only service on a fixed port
is pinned with `reserved_ports`.

One more property this key does *not* share with the others:

- **Drift is judged by coverage, not equality.** This is the only key whose
  intent is rebuilt from the live system on every render, so the set legitimately
  differs between runs. Reserving *more* than the current render asks for is
  harmless; only a *missing* port is a hazard, and Doctor reports that
  separately (`_doctor_unreserved_ports`). Comparing for equality made the key
  report drift forever on a busy node.

### System capacity

| Key | Value | Why |
| --- | --- | --- |
| `fs.file-max` | `≥ 2097152` | sockets are files; 100k users × several fds. **Ceiling** — a kernel/distro that already set it higher (often unlimited) is left as-is |
| `fs.nr_open` | `≥ 2097152` | per-process fd ceiling — raising the nofile limit is silently capped by this. **Ceiling** |
| `vm.max_map_count` | `≥ 262144` | Xray/sing-box map many buffers per connection. **Ceiling** — kernels ≥ 6.7 default to 1048576, which is never lowered |
| `fs.inotify.max_user_instances` | `≥ 8192` | Docker, Node/PM2, systemd and log followers each hold inotify instances; the default 128 ends in "too many open files" from `docker logs -f` or a file watcher. **Ceiling**; costs memory only when used |
| `fs.inotify.max_user_watches` | `≥ 524288` | same, for watched paths (Node bundlers, PM2 watch). **Ceiling** |
| `vm.swappiness` | `10` | swap is an OOM safety net, not working memory (100 on zram — see swap module) |
| `net.ipv4.icmp_echo_ignore_broadcasts` | `1` | drop broadcast pings (smurf hardening) |
| `net.ipv4.icmp_ignore_bogus_error_responses` | `1` | ignore malformed ICMP error replies |

### RFS flow table (policy: RFS on)

| Key | Value | Why |
| --- | --- | --- |
| `net.core.rps_sock_flow_entries` | `32768` when RFS is on; `0` when a previous run enabled it but the roles no longer benefit | RFS keeps each flow on the CPU of its consuming socket — only meaningful when sockets terminate locally |

### Connection tracking (policy: conntrack — forwarding roles, or nf_conntrack already loaded)

Docker's published ports, UFW and any stateful rule load `nf_conntrack` on
hosts that forward nothing — a bot or website behind Docker NAT tracks every
connection too. Its defaults (a small table, a **5-day** established
timeout) are what end in `nf_conntrack: table full, dropping packet`, so the
table is sized and timed out wherever it is live. A host where the module is
not loaded and nothing forwards is left alone (it is never loaded just to be
tuned).

| Key | Value | Why |
| --- | --- | --- |
| `net.netfilter.nf_conntrack_max` | per TIER / users; forwarders without `--users` get the RAM budget (largest power of two ≤ 10 % of RAM at 300 B/entry, never below the tier); **ceiling** | NAT/firewall state table; entries cost RAM only when used, so a larger running value is never lowered |
| hash size (`nf_conntrack hashsize`, modprobe.d + live) | `max / 4`, **ceiling** | hash table sized with the table (kernel default lags); never shrunk |
| `net.netfilter.nf_conntrack_tcp_timeout_established` | `3600` on forwarders, `7200` on local-only hosts | kernel default is **5 days**; local-only hosts keep 2 h so idle pooled connections through Docker NAT survive |
| `net.netfilter.nf_conntrack_tcp_timeout_time_wait` / `close_wait` | `60` / `30` | reclaim closing flows quickly |
| `net.netfilter.nf_conntrack_udp_timeout` / `udp_timeout_stream` | `30` / `180` with role `vpn`, else `60` | WireGuard benefits from long-lived NAT mappings; QUIC/Hysteria entries otherwise dominate the table |
| `net.netfilter.nf_conntrack_generic_timeout` | `300` | GRE and other non-TCP/UDP flows |

`nf_conntrack` is listed in `/etc/modules-load.d/server-tools.conf`, so the
keys exist when systemd-sysctl applies the file at boot (Docker and UFW load
the module later).

### Memory behaviour (policy: role `db`)

| Key | Value | Why |
| --- | --- | --- |
| `vm.overcommit_memory` | `1` when Redis or Valkey runs | they fork for snapshots and AOF rewrites; with `0` the fork can be refused on a busy host (Redis' own startup warning) |
| `vm.dirty_background_ratio` / `vm.dirty_ratio` | `5` / `10` | turns multi-gigabyte write-back bursts into a steady trickle — flat fsync latency for MySQL/PostgreSQL |

## Forwarding sections (policy: forwarding — roles `proxy`, `vpn`, `tunnel`, `relay`, `utunnel`)

### Packet path

| Key | Value | Why |
| --- | --- | --- |
| `net.core.netdev_budget` | `≥ 600` (ceiling) | packets drained per softirq poll before yielding; high packet-rate roles otherwise hit `time_squeeze` |

`net.core.netdev_budget_usecs` is deliberately **not** set: its default is
two jiffies — already 8 ms on the `HZ=250` kernels Debian and Ubuntu ship —
and 2.4.4's fixed 8000 only made a difference on `HZ=1000` kernels, where it
let softirq hold a CPU four times longer than the kernel intends.

### Routing, router hardening

| Key | Value | Why |
| --- | --- | --- |
| `net.ipv4.ip_forward` | `1` | routing user traffic |
| `net.ipv6.conf.all.forwarding` | `1` (only when the kernel has IPv6) | **v1 gap** — without it WireGuard/tunnelled IPv6 silently fails. A kernel booted with `ipv6.disable=1` has no `net.ipv6` tree; the keys are then not written at all |
| `net.ipv4.conf.all.rp_filter` | `2` | loose mode — strict breaks multi-homed/tunnel routing |
| `net.ipv4.conf.all.accept_redirects` / `send_redirects` | `0` | a router must not accept/emit ICMP redirects |
| `net.ipv4.conf.all.accept_source_route` | `0` | classic hardening |
| `net.ipv4.tcp_fastopen` | `1` (client only) instead of `3` | server-side TFO adds a fingerprinting surface on DPI-exposed hosts |

Prerequisite handled by the module: `modprobe nf_conntrack` + persistence,
otherwise the `net.netfilter.*` keys silently fail to apply (a v1 bug).

Non-sysctl companion (`src/tuners/mss.sh`): MSS clamping
(`-j TCPMSS --clamp-mss-to-pmtu` on FORWARD, or the nftables equivalent) — a
Quick Optimize step for roles `vpn`, `tunnel` and `relay`. It fixes
"connects but pages don't load" and avoids per-packet fragmentation into
smaller-MTU tunnels. The oneshot unit checks before adding and removes the
rule on stop, so it never duplicates and rollback clears it live.

### Roles `panel` / `db` only

Base layer only, with tier capped at M — a dashboard or database host
doesn't need a 1M conntrack table; RAM is better left to the database.

### Keys the kernel does not have

`sysctl_verify` lists a key whose `/proc/sys` entry does not exist (module
absent, IPv6 disabled at boot, a container kernel) as *not present in this
kernel* — shown once, never reported as drift, because nothing on the host
could make it match. Inside LXC/OpenVZ containers, keys that belong to the
host kernel do show as drift, with a note saying why.

## Companion — data-path tuning that isn't sysctl (`src/tuners/nic.sh`)

Channels are changed first: the queue directories RPS writes to only exist
once the new count is live.

Some wins live in `/sys`, not `/etc/sysctl.d`. The perf module applies them
live (recording each previous value, so rollback restores it immediately) and
persists them through ONE oneshot systemd unit (`server-tools-perf.service`)
that runs a generated, idempotent boot script and exits — no resident
process. `nic_verify` reports drift in Doctor.

| Setting | Value | Why / guard |
| --- | --- | --- |
| NIC channels | `ethtool -L <if> combined N`, N = min(offered, CPUs) | many virtio NICs offer several queue pairs but boot with one; using them lets the hypervisor spread receive work in hardware. Automatic on `virtio_net` (live, no link reset); recommended only on other drivers. Override: `nic_channels` = `auto`\|`off`\|N |
| GRO | `ethtool -K <if> gro on` when off | coalesces a flow's packets so routing/netfilter/conntrack run once per batch. Override: `nic_offloads=off` |
| UDP GRO forwarding | `ethtool -K <if> rx-udp-gro-forwarding on` for forwarding roles | extends GRO to forwarded UDP (WireGuard, QUIC, Hysteria); kernel ≥ 5.12, off by default |
| RPS | `rps_cpus` = mask of the policy's RPS CPUs | on with one RX queue or ≤ one queue per two CPUs, or for GRE/IPIP-style tunnels without FOU/GUE (RSS cannot spread them). A forwarder with ≥ 4 CPUs and one queue leaves the NIC's interrupt CPU out. Overrides: `rps_mode` = `auto`\|`on`\|`off`, `rps_cpus` = a CPU list |
| RFS | `rps_flow_cnt` = 32768 / RX queues (+ the sysctl above) | only when sockets terminate locally; forwarded traffic has none to follow |
| Receive-interrupt affinity | `/proc/irq/N/smp_affinity_list`: RX vector *k* → CPU *k mod n* | only when **every** receive vector of the uplink runs on one CPU and irqbalance is not running (many drivers only publish affinity *hints*, which irqbalance turns into real placement). Never when channels change in the same run (the driver re-places them). IRQ numbers change across reboots, so the boot script finds the vectors by name again. Override: `irq_affinity=off` |
| XPS | one CPU → one TX queue (`cpu i → queue i mod n`) | only when the NIC has several TX queues and the driver set no map. Never "every CPU → every queue" (2.4.4): that defeats the driver's queue affinity and adds lock contention |
| CPU governor | `performance` | no ramp-up latency on bursty proxy traffic. Skipped silently where `cpufreq` is absent (typical VPS) |
| Transparent Huge Pages | `madvise` (enabled + defrag) | stops khugepaged compaction stalls from adding tail latency, without denying THP to code that explicitly asks for it (`never` would) |

Non-disruptive by design: every write above takes effect for new packets/pages
without resetting the link, so it is safe to apply on a node already carrying
users. That is also why `ethtool -G` ring resizing is excluded (below).

## Surviving reboots

Every setting is persisted, and the ways each one used to get lost are closed:

| Setting | Persisted by | Guarded against |
| --- | --- | --- |
| kernel keys | `/etc/sysctl.d/99-zz-server-tools.conf` | `/etc/sysctl.conf` (via `99-sysctl.conf`) and later drop-ins: ours sorts last; conflicting keys in `/etc/sysctl.conf` are commented out, others reported |
| BBR, conntrack | `/etc/modules-load.d/server-tools.conf`, `modprobe.d` hash size | keys missing at boot because the module loaded later |
| qdisc, RPS/XPS, IRQs, channels, offloads, governor, THP | `server-tools-perf.service` (oneshot) | a NIC brought up before the qdisc default was set; IRQ numbers that change across boots (vectors are found by name) |
| MSS, NOTRACK, fast path | `server-tools-mss` / `-notrack` / `-flowtable` units | nftables, iptables-persistent, UFW and firewalld loading (and flushing) their ruleset afterwards: the units start after them |
| DNS | resolved drop-in + networkd drop-in / NetworkManager profile / dhclient `supersede` | DHCP, router advertisements and netplan/cloud-init servers outranking the global setting |
| IPv6 off | `99-zz-server-tools-ipv6.conf` + `server-tools-ipv6.service` | networkd / NetworkManager turning IPv6 back on per interface |

`st --verify` (Doctor) and the dashboard report anything that drifted
anyway.

## Optional — full IPv6 disable (`src/features/ipv6.sh`)

Opt-in only — main menu `i` or `st --ipv6 off|on|status`; **never** part of
Quick Optimize. Two layers:

1. a separate, tracked drop-in, `/etc/sysctl.d/99-zz-server-tools-ipv6.conf`:

   ```ini
   net.ipv6.conf.all.disable_ipv6 = 1
   net.ipv6.conf.default.disable_ipv6 = 1
   net.ipv6.conf.lo.disable_ipv6 = 1
   ```

2. `server-tools-ipv6.service`, a oneshot that runs after the network is up
   and writes `disable_ipv6 = 1` on every interface — networkd and
   NetworkManager switch IPv6 back on per link while bringing it up, which a
   sysctl file alone cannot prevent.

The knob is used instead of GRUB's `ipv6.disable=1`: no reboot, and the base
layer's IPv6 keys still apply cleanly. Guards: refused on a host whose only
default route is IPv6; an IPv6 SSH session is asked about in the menu and
refused on the CLI. `ipv6_verify` reports drift when any interface has IPv6
on again; Enable removes both layers and resets the keys live.

## Deliberately NOT set

| What | Why not |
| --- | --- |
| Interface MTU / netplan MTU persistence | provider defaults differ (GCP 1460, Hetzner private 1450); forcing 1500 breaks networking — the v1 "cleanup" hazard |
| NIC ring buffers / coalescing (`ethtool -G` / `-C`) | can reset the link and frequently harms VPS latency; hypervisor-dependent |
| `net.core.netdev_budget_usecs` | the kernel default (2 jiffies) is already right on HZ=250 kernels; see Packet path |
| Tunnel MTUs | owned by the tunnel manager; a one-sided change breaks the link. `tuners/tunnel.sh` audits and recommends instead (`docs/TUNNELS.md`) |
| `Domains=~.` DNS routing | global DNS hijack; breaks cloud-internal resolution |
| `tcp_mtu_probing=2` | aggressive probing shrinks MSS pathologically |
| Disabling SACK/timestamps | outdated cargo-cult tuning; hurts modern stacks |
| `net.ipv4.udp_mem` | the kernel already sizes the UDP pool from RAM; a fixed formula only ever caps it lower on a busy QUIC/Hysteria node |
| Per-interface `accept_ra=2` on static links | only added where the link already accepts RAs — on a statically-addressed link networkd holds it at 0 and would revert us forever (a false "drift") |
