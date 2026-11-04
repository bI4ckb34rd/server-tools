# User guide

ServerTools 2.4.5 · فارسی: [GUIDE.fa.md](GUIDE.fa.md)

## 1. What it is

ServerTools detects what a server does — its **roles** — and applies the
tuning that fits them. Roles combine; with nothing specific detected the
`general` role applies, which is the complete general-purpose tuning, not a
reduced one.

| Role | Typical software |
| --- | --- |
| `proxy` | Xray/Reality, sing-box, Hysteria2, TUIC, Marzban/Pasarguard/Remnawave nodes, x-ui, Hiddify |
| `panel` | Marzban, Marzneshin, Pasarguard, Remnawave dashboards |
| `vpn` | WireGuard, AmneziaWG, OpenVPN, OpenConnect, IPsec, SoftEther, Tailscale |
| `tunnel` | GRE, IPIP, SIT, ip6tnl, VXLAN, Geneve, FOU/GUE |
| `relay` | iptables / nftables DNAT forwarding ports to another server |
| `utunnel` | Backhaul, Rathole, gost, frp, Chisel, WaterWall, udp2raw, kcptun |
| `web` | nginx, Caddy, Apache, HAProxy, Traefik, Envoy — sites, bot webhooks, L4 relays |
| `db` | MySQL, MariaDB, PostgreSQL, Redis, Valkey, MongoDB, ClickHouse |
| `general` | anything else |

Hosts running Docker additionally get a Docker engine step. Tunnel and
relay servers have their own guide: [TUNNELS.md](TUNNELS.md).

The tool runs, tunes and exits. What must survive a reboot is re-applied by
small oneshot boot units that also exit.

## 2. Requirements and install

- root (`sudo -i`); Ubuntu 20.04+ or Debian 11+ (tested in CI) — other
  distributions with apt, dnf/yum or pacman generally work;
- internet access for the download and for prerequisites.

```bash
bash <(curl -fsSL4 https://raw.githubusercontent.com/Sir-Adnan/server-tools/main/dist/server-tools.sh) --install
```

Then `st` opens the menu; `st --update` updates (verified against the
release's `SHA256SUMS`). Without `curl`: `bash <(wget -qO- URL)`.

Prerequisites (`ethtool`, `nftables`, `iproute2`, `iptables`, `procps`,
`kmod`, `curl`; `dig` for DNS tests; `jq` for the Docker step) are installed
when missing, lean (`--no-install-recommends`), and listed on screen and in
`st --report`. Turn it off with `--no-install` or
`st --set install_deps=never`; features then fall back to built-in methods.

## 3. The dashboard

The top of the menu shows host, OS and kernel; CPU and RAM; public IP,
congestion control, qdisc and **IPv6** state; the detected **roles** and
engines; and the **state**: tuned (roles, tier), not tuned yet, or — after a
reboot or another tool undid something — how many kernel settings are no
longer in effect, with the fix.

A host tuned by ServerTools 2.4.4 or older is offered a one-time upgrade
that fixes what those versions left live; it is tracked, so rollback undoes
it.

## 4. Quick Optimize (menu 1) — the recommended path

1. Missing prerequisites are installed.
2. The plan: roles and engines, capacity tier, conntrack size and its
   worst-case RAM, the **Decisions (and why)** table, opt-in **CPU savers**
   not yet enabled, and a tunnel audit when tunnels exist.
3. Choose a DNS provider (`t` measures all of them; `0` keeps the current DNS).
4. Confirm. The steps run one by one:

```text
[1/9] Swap ... SKIPPED
[2/9] Kernel network tuning (sysctl), tier M ... OK
[3/9] Queueing discipline on eth0 (fq_codel) ... OK
[4/9] CPU & NIC data path (channels, offloads, IRQs, RPS/XPS) ... OK
[5/9] MSS clamping for forwarded TCP ... OK
[6/9] File-descriptor limits (nofile) ... OK
[7/9] Journald cap & NTP ... OK
[8/9] Docker engine (log rotation, live-restore, nofile) ... OK
[9/9] DNS (1.1.1.1 / 1.0.0.1) ... OK
```

OK = applied and verified · SKIPPED = not needed (swap already exists; inside
an LXC/OpenVZ container swap and the clock belong to the host) · WARN =
applied with a note · FAILED = not applied. MSS runs for `vpn`, `tunnel` and
`relay`; Docker only when a Docker daemon runs.

**What Quick does not do** — it changes the firewall path or the system in
ways that depend on the host, so these stay a choice: UFW, fail2ban, SSH
hardening (menu 6); NOTRACK, the nftables fast path, IPv6 off, XanMod, APT
mirror (menu 7 and `i`). Quick also does not ask for the user count — see
Custom Optimize.

**Docker step.** `/etc/docker/daemon.json` is *merged* with `jq`; your own
keys always win. json-file logs get `max-size=10m` and `max-file=3`
(`docker_log_size`), `live-restore` is enabled (not in Swarm mode), and
containers get `nofile=1048576`. dockerd is reloaded, which stops nothing.
Log limits and nofile reach containers created after a Docker restart —
offered at the end (with live-restore on, containers keep running); recreate
them with `docker compose up -d --force-recreate`.

**Restarts.** If file limits really changed, you are offered a restart of
detected proxy and tunnel services (and of their containers once Docker gives
containers a limit) so they pick up the new limit.

## 5. Custom Optimize (menu 2)

- **Roles**: pick one or more (e.g. `1,4`); Enter keeps detection; the choice
  can be saved.
- **Capacity tier** (S/M/L/XL): chosen from RAM; an override applies to this
  run, saving it is asked separately.
- **Expected users**: sizes conntrack from the real concurrent user count, with
  an honest RAM warning when it does not fit (rule of thumb: ~8 GB RAM per
  10k proxy users).
- Then each step: CPU/NIC data path, MSS, limits, journald/NTP, Docker, swap,
  DNS.

Why a 4 GB server gets tier M and why L would not make it faster:
[FAQ](FAQ.md#why-does-a-4-gb-server-get-tier-m-would-l-or-xl-be-faster).

## 6. Non-interactive use

```bash
st --auto                                   # detect and apply
st --auto --role proxy --dns cloudflare     # pin roles, set DNS
st --auto --role relay,tunnel --no-swap     # a GRE/DNAT relay
st --auto --users 10000                     # size conntrack for 10k users
```

Without `--dns`, DNS is not touched. `--no-swap`, `--no-limits`,
`--no-extras`, `--no-perf`, `--no-mss` and `--no-docker` skip steps. Profile
names from 2.4.4 and older (`--profile vpn-node|wireguard|panel|relay|full`)
still work.

## 7. Dry run

```bash
st --dry-run
st --dry-run --role relay,tunnel --users 10000
```

The decisions with reasons, the full sysctl file, a key-by-key diff against
the live kernel, keys another file would override at boot, every `/sys`,
IRQ and ethtool change, and the Docker merge — then
`N of M keys would change. Nothing was applied.`

## 8. After a reboot

Everything ServerTools sets is built to survive a reboot (details:
[SYSCTL.md](SYSCTL.md#surviving-reboots)). To check:

```bash
st --verify            # or menu 4 — Doctor
```

The dashboard also warns when kernel settings are no longer in effect. If
something drifted (another tool rewrote it), re-run Quick Optimize: it is
idempotent and fixes the cause where it can — for example, keys in
`/etc/sysctl.conf` that overrode ours are commented out (tracked).

## 9. Diagnose the data path (menu d)

```bash
st --diagnose
```

A ~3 s measurement: softirq / system / steal and packets / drops per CPU,
NIC channels, queues, RPS/XPS masks, receive-interrupt placement and
irqbalance, GRO, qdisc drops, conntrack usage and drops, Docker log
rotation, and the tunnel MTU audit — with verdicts and the exact commands for
an A/B comparison. Nothing is changed. How to read it:
[TUNNELS.md](TUNNELS.md).

## 10. Doctor, status and report

- `st --verify` (menu 4) — every area: OK, not configured, or DRIFT with the
  fix; plus retransmit and drop counters since the last run.
  `--verify --json` for monitoring.
- `st --status` (menu 3) — system, CPU/RAM/disk, network, DNS in effect,
  tuning state, limits, security, roles.
- `st --report` — a plain-text support bundle, printed and saved under
  `/var/lib/server-tools/`.

## 11. IPv6 on / off (menu i)

```bash
st --ipv6 off          # or: on, status
```

Switches the whole IPv6 stack off (IPv4 keeps working) or back on, without a
reboot — and it stays off after reboots: a oneshot unit turns it off again
on every interface once the network manager has brought them up. Refused on
an IPv6-only host; over an IPv6 SSH session the menu asks, the CLI refuses.
The menu shows interfaces that came back on and fixes them.

## 12. Bandwidth test (menu 7 → 9)

```bash
st --speedtest
```

Uses the official Ookla client — downloaded once (~1 MB) and **kept** in
`/var/lib/server-tools/bin` — with an automatic, nearby, by-ID or
"3 nearest servers" choice, and falls back to a parallel HTTP test. Every
result is saved; the latest five are shown after each test, `h` shows more.
Test before and after tuning at a similar time of day to compare. Option 9
on the same screen removes the saved client.

## 13. Security (menu 6, all opt-in)

- **UFW** — the SSH port is allowed before any deny rule; on forwarding hosts
  it offers `DEFAULT_FORWARD_POLICY=ACCEPT` and allows GRE from tunnel peers
  and the WireGuard port, so enabling the firewall does not cut a tunnel.
- **fail2ban** — SSH brute-force bans; a resident service (~20 MB RAM).
- **SSH hardening** — key-only login only when a key exists; validated with
  `sshd -t` before restart.
- **Anti-abuse egress** — blocks SMTP/worm ports and private ranges, keeping
  every directly connected subnet (provider LAN, tunnels, Docker, WireGuard)
  reachable.
- **Restrict node API** — 62050/62051 only from the panel IP.
- **Docker + UFW audit** — ports Docker publishes past the firewall.

## 14. Network & VPN tools (menu 7)

| Key | Tool |
| --- | --- |
| d · t | diagnose data path · tunnel audit (MTU, encapsulation, MSS) |
| 5 | MSS clamping |
| n | NOTRACK for proxy ports (only traffic addressed to this host) |
| f | nftables flowtable fast path for relays and VPN gateways |
| i | IPv6 on / off |
| 1 · 2 · 3 · 4 | ping matrix · DNS latency · TCP/conntrack · listening ports |
| 9 · b · w | bandwidth test · quick benchmark · live view |
| 8 · m · 7 | XanMod/BBRv3 kernel · APT mirror · support report |

## 15. Node & Docker (menu 8)

- **Back up node configuration** (`/opt/marzban-node`, `/opt/pg-node`,
  `/etc/wireguard`, …) — the archive contains keys; keep it private.
- **Install a node** with its official installer — the command is shown in
  full first.
- **Docker engine** — audit (live-restore, log rotation, largest container
  logs, docker-proxy count, `docker system df`), the same hygiene merge as the
  Quick step, and emptying container logs above 100 MB (asks first; the log
  text cannot be recovered).

## 16. Rollback (menu 5)

```bash
st --rollback            # undo the newest run; again = one run further back
st --rollback-original   # everything back to before ServerTools ever ran
```

Changed files are restored, created files removed, units disabled (their
rules removed), live values (RPS/XPS, IRQ affinity, THP, governor, NIC
channels and offloads) and the uplink qdisc restored, sysctl reloaded.
Installed prerequisite packages are kept. Details: [ROLLBACK.md](ROLLBACK.md).

## 17. Settings (menu 9)

```bash
st --settings                  # every tunable with its value and meaning
st --set rps_mode=off          # turn software steering off
st --set roles=relay,tunnel    # pin roles instead of detecting them
st --set capacity_tier=L       # force a tier
st --set irq_affinity=off      # never move NIC interrupts
st --set docker_tuning=off     # leave daemon.json alone
```

Values are validated; changes apply on the next optimize run.

## 18. Troubleshooting

| Problem | Fix |
| --- | --- |
| "must be run as root" | `sudo -i`, then run again |
| settings gone after a reboot | `st --verify`, then Quick Optimize again — see section 8 |
| DNS back to the provider's | re-run Quick Optimize with your DNS: it now pins networkd, NetworkManager and dhclient |
| CPU went up after tuning | `st --diagnose`; read [TUNNELS.md](TUNNELS.md); A/B with `st --set rps_mode=off && st --auto` |
| tunnel broke after enabling UFW | re-run UFW setup from menu 6 — it allows forwarding and GRE |
| disk filled up on a Docker host | menu 8 → Docker engine: audit, apply log rotation, empty huge logs |
| `nf_conntrack: table full` in `dmesg` | re-run Quick Optimize; with many users add `--users N` |
| a prerequisite failed to install | see `/var/log/server-tools.log`; the feature uses its fallback |
| broken colours | `st --no-color` or `NO_COLOR=1` |

More in the [FAQ](FAQ.md). Bug reports:
[GitHub Issues](https://github.com/Sir-Adnan/server-tools/issues) — please
attach `st --report`.
