# Roles — what a server does, and how that drives tuning

> Status: **implemented** by `src/engine/roles.sh` (detection),
> `src/engine/capacity.sh` (sizing) and `src/engine/policy.sh` (decisions).
> Replaces the single-profile model of 2.4.4 and older.

## Why roles, not profiles

2.4.4 picked ONE exclusive profile per host (`vpn-node`, `wireguard`, `panel`,
`general`). Real servers are mixed: an Xray node that also terminates a GRE
tunnel, a WireGuard gateway with an x-ui panel, an Iran-side relay that
DNATs ports into a tunnel. Worse, a single profile hid the one distinction
that matters most for CPU: **does TCP terminate on this host, or is traffic
only routed through it?** A GRE/DNAT relay tuned like a proxy node gets RPS
on every core, RFS flow tables and `fq` pacing for packets that have no
local socket — measurable extra CPU for nothing (the 2.4.4 field report).

2.4.5 detects every role that applies and combines them. The base layer still
covers the whole server; roles only decide the specialised part.

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Optional (explicit consent): UFW · fail2ban · SSH · NOTRACK ·        │
│   forwarding fast path (nftables flowtable) · IPv6 disable · XanMod  │
├──────────────────────────────────────────────────────────────────────┤
│ Policy (engine/policy.sh): roles + facts → decisions, each with why  │
│   cc · qdisc · channels/offloads/IRQs · RPS/RFS/XPS · conntrack ·    │
│   MSS · packet budget · database memory · Docker engine              │
├──────────────────────────────────────────────────────────────────────┤
│ Base (always): accept queues · buffers · timers · capacity ceilings  │
│   · limits · journald · NTP · swap (if missing) · DNS (if chosen)    │
└──────────────────────────────────────────────────────────────────────┘
```

## The roles

| Role | Detected via | Traffic shape |
| --- | --- | --- |
| `proxy` | xray, v2ray, sing-box, hysteria, tuic, juicity, trojan, mihomo, x-ui/3x-ui, s-ui processes; marzban-node/marznode, pg-node, Remnawave node, Hiddify, x-ui, sing-box, Hysteria containers | client TCP/UDP **terminates here**; the proxy opens its own outbound sockets |
| `panel` | Marzban, Marzneshin, Pasarguard, Remnawave dashboard containers (node images excluded) | web + database, little traffic |
| `vpn` | WireGuard/AmneziaWG links and `wg-quick@`/`awg-quick@` units, openvpn, ocserv, strongSwan, SoftEther, xl2tpd, tailscaled, zerotier, tinc; wg-easy, WGDashboard, Amnezia, OpenVPN containers | routed + NATed client traffic |
| `tunnel` | kernel tunnel links: GRE/gretap/ip6gre, IPIP, SIT, ip6tnl, VXLAN, Geneve, ERSPAN (with FOU/GUE noted) | encapsulated, often between two fixed IPs |
| `relay` | a DNAT/REDIRECT rule (iptables **or** native nftables) forwarding to an address on another machine; Docker's DNAT to container bridges is ignored | pure forwarding through conntrack/NAT |
| `utunnel` | backhaul, rathole, gost, frps/frpc, chisel, waterwall, udp2raw, kcptun, phantun, realm, dnstt processes (and their containers) | userspace tunnel: terminates locally, re-originates |
| `web` | nginx, Angie, OpenResty, Caddy, Apache, HAProxy, Traefik, Envoy processes (also when they run in containers) | sites, bot webhooks, reverse proxies, L4 balancers: many short TCP connections terminating here |
| `db` | mysqld, mariadbd, postgres, redis-server, valkey-server, mongod, clickhouse-server processes | local sockets, memory and disk write-back matter more than packets |
| `general` | nothing above | complete general-purpose tuning — not a reduced set |

Detection reads one snapshot of facts (`engine/facts.sh`): process argv[0]
basenames, container names/images (docker + podman), running systemd
services, `ip -d link`, and the NAT rules. Adding an engine is one line in
`ST_ENGINE_SIGNATURES`:

```text
role;label;source;regex      source: p = process, c = container, u = systemd unit
'utunnel;Backhaul;p;backhaul'
```

Override detection with `--role proxy,relay` (CLI), `st --set roles=...`
(persistent), or the Custom Optimize picker. 2.4.4 profile names still work:
`--profile vpn-node` = `proxy`, `wireguard` = `vpn`, `relay` = `relay,tunnel`,
`full` = every traffic role.

## Scenarios

| Server | Detected roles | What changes beyond the base layer |
| --- | --- | --- |
| x-ui / 3x-ui or a Marzban/Pasarguard node | `proxy` | fq + BBR, RPS/RFS on single-queue NICs, conntrack sized |
| Marzban/Remnawave panel with MySQL/PostgreSQL/Redis | `panel db` | tier capped at M, bounded write-back, `overcommit=1` for Redis, Docker logs bounded |
| Telegram bot or website in Docker (nginx + Redis) | `web db` | conntrack timeouts (Docker NAT), Docker logs bounded, inotify limits; no routing changes |
| Bot running directly with Python/Node, nothing else | `general` | complete base layer (accept queues, buffers, ports, limits, swap, journald) |
| HAProxy / nginx-stream relay to a foreign server | `web` | local-TCP tuning, conntrack when the firewall is stateful, nofile |
| GRE / IPIP + DNAT relay (Iran side) | `tunnel relay` | fq_codel, RPS without the IRQ CPU, no RFS, MSS clamp, optional flowtable |
| WireGuard / AmneziaWG gateway | `vpn` | UDP GRO forwarding, long UDP NAT timeouts, MSS clamp |
| Backhaul / Rathole / gost tunnel | `utunnel` | local-TCP + forwarding tuning, nofile |

## From roles to decisions

Three derived facts drive almost everything:

| Derived | Definition |
| --- | --- |
| local TCP | any of `proxy`, `panel`, `utunnel`, `web`, `db`, `general` |
| forwarding | any of `proxy`, `vpn`, `tunnel`, `relay`, `utunnel` |
| forwarder | forwarding **and not** local TCP (e.g. `tunnel,relay` only) |

| Decision | Rule |
| --- | --- |
| Congestion control | BBR when the kernel has it (harmless for forwarded flows) |
| qdisc | `fq` when TCP terminates locally (pacing for BBR); `fq_codel` on a pure forwarder (forwarded packets have no socket to pace). Config `qdisc` wins. |
| NIC channels | raised to min(offered, CPUs) on virtio NICs that use fewer queue pairs than they offer; recommended only on other drivers. Config `nic_channels` wins. |
| GRO / UDP GRO forwarding | GRO on when off; UDP GRO forwarding on for forwarding roles. Config `nic_offloads=off` disables. |
| RPS | planned for the queue count after the channel change; on with one RX queue or at most one queue per two CPUs; also on for GRE/IPIP-style tunnels without FOU/GUE (no L4 ports → RSS puts each peer pair on one queue); off otherwise. Config `rps_mode` wins. |
| RPS CPUs | every online CPU — except on a forwarder with ≥ 4 CPUs and one RX queue, where the CPU that services the NIC interrupt is left out. Config `rps_cpus` wins. |
| RFS | only with local sockets (forwarded traffic has none to follow) |
| IRQ affinity | receive interrupts spread one per CPU, only when every RX vector runs on one CPU and irqbalance is absent. Config `irq_affinity=off` disables |
| XPS | untouched when the driver already maps CPUs to TX queues; else one CPU → one queue; never "every CPU → every queue" (2.4.4) |
| MSS clamping | on for `vpn`, `tunnel`, `relay` (forwarded TCP into a smaller MTU). Config `mss_clamp` wins. |
| Packet budget | `netdev_budget = 600` (ceiling) for forwarding roles |
| Conntrack | forwarding roles without `--users`: the largest power of two whose worst case stays within 10 % of RAM, never below the tier (4 GB → 1M). Sized (ceiling) and timed out for forwarding roles — **and** on any host where `nf_conntrack` is already loaded (Docker, UFW, stateful rules). Established timeout 1 h on forwarders, 2 h on local-only hosts; UDP stream 180 s with `vpn`, else 60 s |
| Database memory | role `db`: `vm.dirty_*` bounded (5 %/10 %); `vm.overcommit_memory=1` when Redis/Valkey runs |
| Docker engine | a running dockerd: daemon.json merged with log rotation, live-restore and container nofile, then reloaded. Config `docker_tuning=off` disables |

`st --dry-run` prints every decision with its reason before anything changes.

## Capacity tiers

Conntrack tables and buffers consume real kernel RAM; sizing them for 100k
users on a 1 GB VPS would cause the very OOM problems we exist to prevent.
The tier is chosen from RAM (overridable), and the estimated kernel memory
cost is displayed **before** applying.

| Tier | Target concurrent users | Typical RAM | nf_conntrack_max | somaxconn / syn_backlog | rmem/wmem max |
| --- | --- | --- | --- | --- | --- |
| S | up to ~1k | ≤ 1.5 GB | 65,536 | 8,192 | 8 MB |
| M | up to ~10k | ≤ 6 GB | 262,144 | 16,384 | 16 MB |
| L | up to ~100k | ≤ 24 GB | 1,048,576 | 32,768 | 32 MB |
| XL | 100k+ | > 24 GB | 2,097,152 (+ tw_buckets/orphans caps) | 65,535 | 64 MB |

**Forwarders get more conntrack than their tier.** Relays and tunnels are
CPU-bound long before RAM runs out, and a full table drops new connections,
so without `--users` the table is sized from RAM headroom: the largest power
of two whose worst case (table full) stays within 10 % of RAM — 512 MB →
131k, 1 GB → 262k, 2 GB → 524k, 4–6 GB → 1M, 8 GB+ → 2M, at most 4M. Buffers
and queues keep their tier values: they do not lower CPU, and on a
forwarder socket buffers are not even used.

A host whose roles are only `panel` and/or `db` is capped at M — its RAM
belongs to the database. One conntrack entry ≈ 300 bytes, so a 2M table can cost ~600 MB
when full.

## User-based capacity model (`expected_users` / `--users`)

Conntrack demand follows the **active user count**, not RAM:

- `nf_conntrack_max = users × 24 flows × 1.5 headroom` (clamped 65k–4.2M);
- buffers stay RAM-tier sized;
- `net.ipv4.tcp_mem` is bounded explicitly (~16% of RAM max);
- an honest warning fires when conntrack RAM plus ~0.5 MB per user for
  userspace roles (`proxy`, `utunnel`) exceeds 75% of RAM — rule of thumb:
  **~8 GB RAM per 10k concurrent proxy users**.

See `docs/SYSCTL.md` for the per-key values and `docs/TUNNELS.md` for the
tunnel/relay specifics.
