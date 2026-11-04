# Changelog

Notable changes, newest first. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases 2.0.0 – 2.4.4: [docs/archive/CHANGELOG-2.0-2.4.4.md](docs/archive/CHANGELOG-2.0-2.4.4.md).

## [2.4.6] — 2026-11-03

### Fixed

- Quick Optimize no longer ends with a burst of `ERROR unhandled failure …
  grep` lines on servers without proxy services (a relay, for example). The
  tuning itself was already applied; the noise came from the restart offer.
  The same "nothing found counts as a failure" pattern was removed from
  the speed-test history, the Ookla result card, the NOTRACK port reader,
  the WireGuard port reader, the flowtable device list and the mirror
  file list.

## [2.4.5] — 2026-11-03

A redesign around **roles**: ServerTools now works out what a server does
and tunes for that, instead of applying one exclusive profile. It started
from a field report — a GRE + nftables-DNAT relay whose CPU rose after
tuning because it was tuned like a proxy node — and grew into broader
coverage (bots, sites, databases, Docker), settings that survive reboots,
and a test suite that runs on a real kernel.

### Highlights

- **Roles** `proxy`, `panel`, `vpn`, `tunnel`, `relay`, `utunnel`, `web`,
  `db`, `general` — detected from processes, containers, systemd units,
  tunnel links and NAT rules, combined freely, overridable with `--role`.
- **A reason for every decision**, in the plan and in `--dry-run`.
- **Settings survive reboots** — and the dashboard and `st --verify` say so
  when something drifted anyway.
- **`st --diagnose`** measures the data path instead of guessing.
- **Live rollback** of files, `/sys` values, NIC settings, qdiscs and rules.

### Added

- **Role detection** with data-driven signatures: Xray, sing-box, Hysteria,
  TUIC, Juicity, Trojan, mihomo, x-ui/3x-ui, s-ui, Marzban / Pasarguard /
  Remnawave nodes and panels, Hiddify, WireGuard, AmneziaWG, OpenVPN,
  OpenConnect, IPsec, SoftEther, L2TP, Tailscale, ZeroTier, tinc,
  GRE/IPIP/SIT/ip6tnl/VXLAN/Geneve (+FOU/GUE), DNAT relays, Backhaul,
  Rathole, gost, frp, Chisel, WaterWall, udp2raw, kcptun, Phantun, realm,
  dnstt, nginx/Angie/OpenResty, Caddy, Apache, HAProxy, Traefik, Envoy,
  MySQL, MariaDB, PostgreSQL, Redis, Valkey, MongoDB, ClickHouse.
- **Policy engine** (`engine/policy.sh`): qdisc, NIC channels and offloads,
  IRQ placement, RPS/RFS/XPS, conntrack, MSS, database memory and Docker —
  each with its reason.
- **NIC tuning via ethtool**: unused virtio queue pairs enabled, GRO and
  UDP GRO forwarding; **receive interrupts spread** one per CPU when they all
  sit on one CPU and irqbalance is absent (`irq_affinity`).
- **Conntrack** sized and timed out wherever it is live — forwarders and
  Docker/UFW hosts (whose 5-day default filled the table); forwarders get a
  table sized from RAM headroom (≤ 10 % of RAM, e.g. 1 M on 4 GB).
- **Databases**: bounded dirty write-back; `vm.overcommit_memory=1` with
  Redis/Valkey; panel/database-only hosts stay at tier M.
- **Docker engine step**: `daemon.json` merged with jq (your keys win) for
  log rotation, live-restore and container nofile; validated, applied by
  reload; audit and huge-log cleanup in Node & Docker. `--no-docker`,
  `docker_tuning`, `docker_log_size`.
- **MSS clamping** as a Quick Optimize step for `vpn`/`tunnel`/`relay`
  (iptables or nftables); **tunnel audit** (MTU per encapsulation);
  **nftables fast path** (opt-in flowtable for relays); the plan lists
  opt-in CPU savers not yet enabled.
- **IPv6 on/off** as main-menu item `i` and `st --ipv6 on|off|status`.
- **Speed test**: the Ookla client is kept (no re-download), results history,
  "3 nearest servers" mode, `st --speedtest`.
- **Automatic prerequisites** (`ethtool`, `nftables`, `jq`, …) through
  apt / dnf / yum / pacman, reported on screen; `--no-install`.
- **Settings registry**: `st --settings`, `st --set KEY=VALUE` (validated),
  and an editor in the menu.
- **Tests**: ~150 unit checks, a real-kernel GRE + DNAT relay test in a
  network namespace, and CLI smoke tests — all in CI.

### Changed

- **qdisc follows the workload**: `fq` where TCP terminates locally,
  `fq_codel` on pure forwarders.
- **RPS is role- and topology-aware**: on for one RX queue (or one per two
  CPUs) and for GRE/IPIP without FOU; off where RSS already spreads; the
  interrupt CPU is left out on forwarders. RFS only with local sockets.
- `netdev_budget` is a ceiling for forwarding roles only;
  `netdev_budget_usecs` is no longer set.
- inotify ceilings for Docker and Node/PM2 hosts.
- The sysctl file is now `/etc/sysctl.d/99-zz-server-tools.conf`.
- DNS-over-TLS is off by default for Iran-hosted resolvers.
- Source reorganised into `lib/ state/ engine/ tuners/ features/ ui/`;
  optimize steps are one table (`ST_OPTIMIZE_STEPS`).
- Documentation rewritten: English is canonical, with Persian translations
  (`*.fa.md`); older history moved to `docs/archive/`.

### Fixed

- **Settings lost after a reboot**: `/etc/sysctl.conf` overrode the old file
  name (conflicting keys are now commented out, tracked); MSS/NOTRACK/
  flowtable rules were flushed by nftables / iptables-persistent / firewalld
  (units now start after them, and existing units are re-ordered); a NIC up
  before sysctl kept its old qdisc (the boot script fixes it).
- **DNS reverting to the provider's**: the networkd drop-in now resets
  `DNS=` and ignores DHCP and RA servers, on every link; NetworkManager
  profiles get `ignore-auto-dns`; dhclient gets `supersede`.
- **IPv6 coming back after a reboot**: re-applied per interface after the
  network is up; Doctor reports an interface that came back.
- **Multi-queue NICs**: the live qdisc change no longer collapses `mq` into
  one root qdisc (one lock for every CPU); affected hosts are repaired.
- **NOTRACK broke NAT**: rules match only traffic addressed to this host;
  DNAT detection sees native nft rules, `multiport` lists and ranges.
- **XPS** no longer maps every CPU to every TX queue.
- **MSS unit** no longer duplicates its rule on restart and removes it on
  rollback.
- **UFW on forwarding hosts** keeps tunnels working (forward policy, GRE
  peers, WireGuard port); **anti-abuse** keeps every connected subnet.
- Conntrack table and hash size are ceilings — never lowered.
- Kernels without IPv6 get no `net.ipv6.*` keys; keys a kernel lacks are
  "not present", not drift; LXC/OpenVZ containers skip swap and NTP.
- A hung Docker daemon no longer freezes the tool (bounded calls).
- File limits: an unchanged re-run no longer re-executes systemd or prompts
  for restarts; restart candidates come from the engine signatures.
- Custom Optimize no longer saves a tier override without asking.
- Rollback counted failed copies as restored; run ids could collide.
- CPU masks come from `/sys/devices/system/cpu/online`, not `nproc`.
- XanMod: v4-capable CPUs get x64v3; non-x86-64 hosts are refused.
- Self-update refuses a release without a `SHA256SUMS` entry and never
  downgrades.

### Upgrade notes

- Run Quick Optimize once after updating: it migrates state left by 2.4.4
  and older (tracked — rollback undoes it), moves the sysctl file and writes
  the reboot fixes.
- Profile names still work: `--profile vpn-node` = `--role proxy`,
  `wireguard` = `vpn`, `relay` = `relay,tunnel`.
