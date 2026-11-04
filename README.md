# ServerTools

**Role-aware Linux server tuning — for VPN nodes, tunnels and relays, and
for the everyday servers next to them.**

One command works out what a server *does* — proxy node, panel, WireGuard
gateway, GRE relay, Docker host running a bot, database — and tunes the
kernel, NIC, firewall path and container engine for exactly that. Every
decision comes with its reason, every change can be rolled back, and the
result survives reboots.

> **2.4.6** · one bash file · runs as root · Ubuntu 20.04+ / Debian 11+
> (other distributions with apt, dnf/yum or pacman generally work) ·
> فارسی: [README.fa.md](README.fa.md)

## Install

```bash
bash <(curl -fsSL4 https://raw.githubusercontent.com/Sir-Adnan/server-tools/main/dist/server-tools.sh) --install
```

Then run `st` and press **1 (Quick Optimize)**. Update with `st --update`.
Missing tools (`ethtool`, `nftables`, `jq`, …) are installed automatically
and listed on screen; `--no-install` turns that off. A host tuned by an older
version is upgraded on the first run, tracked like every other change.

## Quick start

```bash
st                      # menu → 1 Quick Optimize
st --dry-run            # the plan, each decision with its reason, the exact diff
st --auto               # non-interactive: detect and apply
st --diagnose           # measure: per-core softirq, drops, queues, conntrack
st --verify             # still in effect? (run it after a reboot)
st --rollback           # undo the newest run (again = one run further back)
```

## One tool, every kind of server

| Server | Detected as | What it gets beyond the base layer |
| --- | --- | --- |
| x-ui / 3x-ui, Marzban / Pasarguard / Remnawave node | `proxy` | fq + BBR, RPS/RFS on single-queue NICs, conntrack sized from RAM |
| Panel with MySQL / PostgreSQL / Redis | `panel db` | tier capped at M, bounded write-back, `overcommit=1` for Redis |
| Telegram bot or website in Docker | `web db` + Docker | bounded container logs, live-restore, conntrack timeouts for Docker NAT |
| GRE / IPIP + DNAT relay | `tunnel relay` | fq_codel, RPS without the IRQ CPU, no RFS, MSS clamp, fast-path hint |
| WireGuard / AmneziaWG / OpenVPN | `vpn` | UDP GRO forwarding, long UDP NAT timeouts, MSS clamp |
| Backhaul / Rathole / gost / frp | `utunnel` | local + forwarding tuning, nofile |
| HAProxy / nginx relay, plain bot | `web` / `general` | the complete base layer |

Roles combine (an Xray node that is also a GRE endpoint gets both), and
detection can be overridden: `st --auto --role relay,tunnel`.
Details: [docs/ROLES.md](docs/ROLES.md).

## What it tunes

| Area | What happens |
| --- | --- |
| Congestion & queueing | BBR; `fq` where TCP terminates locally, `fq_codel` on pure forwarders — applied live without collapsing multi-queue `mq` |
| NIC | unused virtio queue pairs enabled, GRO and UDP GRO forwarding, receive interrupts spread when stuck on one CPU, RPS/RFS only where hardware cannot spread |
| Kernel network stack | accept queues, buffers, timers, keepalive, reserved service ports — ceilings that never lower a modern kernel's values |
| Conntrack | sized and timed out wherever it is live (forwarders, Docker, UFW); forwarders get a table sized from RAM headroom |
| Forwarding | IP forwarding, router hardening, MSS clamping into tunnels |
| Databases & Docker | bounded write-back, Redis overcommit; daemon.json merged (your keys win) |
| System | swap (file or zram), nofile, inotify, journald cap, NTP, DNS that stays set after reboots and DHCP renewals |
| Opt-in | UFW (forwarding-aware), fail2ban, SSH hardening, NOTRACK, nftables fast path, IPv6 off, XanMod/BBRv3, APT mirror |

Every key and its rationale: [docs/SYSCTL.md](docs/SYSCTL.md).

## Built to be trusted

| | |
| --- | --- |
| **Survives reboots** | sysctl file ordered after `/etc/sysctl.conf`, firewall rule units after the firewall managers, DNS pinned in the network manager, IPv6-off re-applied per interface — and `st --verify` / the dashboard say so when something drifted anyway |
| **Reversible** | files, live `/sys` values, NIC settings, qdiscs, firewall rules and `/etc/sysctl.conf` edits are recorded before they change |
| **Honest** | each step reports OK / WARN / FAILED / SKIPPED and is checked against the live system |
| **Light** | runs in seconds; nothing stays resident — boot persistence uses oneshot units that exit |
| **Tested** | ShellCheck + shfmt, 150 unit checks, and a real-kernel GRE + DNAT relay test in a network namespace |

## CLI

```text
Actions   --status | --auto | --dry-run | --diagnose | --verify [--json] | --report
          --rollback | --rollback-original | --settings | --set KEY=VALUE
          --ipv6 on|off|status | --speedtest | --install | --update
Planning  --role proxy,panel,vpn,tunnel,relay,utunnel,web,db,general
(--auto,  --tier S|M|L|XL   --users N   --dns cloudflare|shecan|ip1,ip2
--dry-run) --no-swap --no-limits --no-extras --no-perf --no-mss --no-docker
General   --no-install --no-color --debug -v -h
```

Exit codes: `0` ok · `1` a step failed · `2` usage error · `3` applied with
warnings, or drift found. All tunables: `st --settings`.

## Documentation

| | |
| --- | --- |
| [User guide](docs/GUIDE.md) | every menu and command |
| [FAQ](docs/FAQ.md) | Is Quick enough? Why tier M? Settings after reboot? |
| [Tunnels & relays](docs/TUNNELS.md) | RSS, RPS, MTU/MSS, fast path, A/B testing |
| [Roles](docs/ROLES.md) | detection, decision rules, capacity |
| [Kernel settings](docs/SYSCTL.md) | every setting with its rationale |
| [Rollback](docs/ROLLBACK.md) | what is recorded and how it is undone |
| [Architecture](docs/ARCHITECTURE.md) | source layout, extending, tests |
| [Changelog](CHANGELOG.md) · [Roadmap](ROADMAP.md) | history and plans |

Persian: [README.fa.md](README.fa.md) · [GUIDE.fa.md](docs/GUIDE.fa.md) ·
[FAQ.fa.md](docs/FAQ.fa.md) · [TUNNELS.fa.md](docs/TUNNELS.fa.md).
Contributor rules: [CLAUDE.md](CLAUDE.md).

## Author

**UnknownZero** — Telegram **@UnknownZero** · License: [MIT](LICENSE)
