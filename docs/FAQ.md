# FAQ

ServerTools 2.4.6 · فارسی: [FAQ.fa.md](FAQ.fa.md)

## Is running Quick Optimize (menu 1) enough?

For most servers, yes: it detects the roles and applies everything that is
safe to apply automatically — kernel, qdisc, NIC, MSS where needed, limits,
journald/NTP, swap when missing, Docker when present, and DNS if you pick
one. A few things stay a deliberate choice because they change the firewall
path or depend on the host: UFW / fail2ban / SSH hardening (menu 6), NOTRACK
and the nftables fast path (menu 7 — the plan lists them when they would cut
CPU on your host), IPv6 off (menu `i`), and XanMod. If you know the number of
concurrent users, give it: `st --auto --users 10000`.

Re-run Quick Optimize after installing new software (a panel, Docker, a
tunnel): roles are detected afresh, and a re-run changes nothing that is
already right.

## Why does a 4 GB server get tier M? Would L or XL be faster?

No. A tier sets **ceilings** — table sizes, queue lengths, maximum socket
buffers — not speed. Until a ceiling is reached, M and L behave identically;
CPU usage does not change either way.

- The ceiling that does matter on busy forwarders, the **conntrack table**, is
  already sized from free RAM on relays, tunnels, VPNs and proxies: a 4 GB
  relay gets 1 M entries instead of the tier's 262 k (worst case ≤ 10 % of
  RAM).
- Larger socket buffers only help single flows above ~1 Gbit/s at high RTT,
  and a forwarder does not use socket buffers at all.
- A longer backlog queue only adds latency once the CPU falls behind.

If `st --diagnose` shows real pressure (conntrack drops, backlog drops), give
the user count (`--users N`) or force a tier (`st --set capacity_tier=L`).
What actually lowers CPU: the nftables fast path on relays, NOTRACK on proxy
nodes, and the NIC work Quick Optimize already does.

## My settings were gone after a reboot. Why, and is it fixed?

The common causes, all handled in 2.4.5:

| Cause | Fix |
| --- | --- |
| `/etc/sysctl.conf` (applied after older ServerTools files) overrode our keys | our file now sorts last; conflicting keys in `/etc/sysctl.conf` are commented out (tracked) |
| a firewall manager (nftables, iptables-persistent, firewalld) flushed MSS/NOTRACK rules at boot | rule units now start after them |
| DHCP / router advertisements / NetworkManager put the provider's DNS back | DNS is pinned in networkd, NetworkManager and dhclient |
| networkd turned IPv6 back on per interface | a oneshot unit turns it off again after the network is up |
| the NIC came up before the qdisc default was set | the boot script puts the default qdisc live |

Check with `st --verify` (or look at the dashboard), and re-run Quick
Optimize once after upgrading so the fixes are written.

## How much CPU and RAM does the tool use?

Only while it runs, and little: facts are collected once, a full run takes
seconds, and nothing stays resident — boot persistence uses oneshot units
that apply and exit. Optional services (fail2ban) are installed only on
request, with their cost stated.

## Does it install packages?

Yes, when that makes the result better: `ethtool`, `nftables`, `iproute2`,
`iptables`, `dig`, `jq` and similar, without recommended extras, listed on
screen and in `st --report`. `--no-install` or
`st --set install_deps=never` prevents it; rollback does not remove them.

## After tuning, all cores are balanced but total CPU is higher

On GRE/IPIP tunnel servers all traffic of a tunnel lands in **one NIC queue
and one core** (GRE carries no ports). Spreading it with RPS costs a
cross-CPU hop per packet; and if that first core was at 100 %, part of the
increase is simply more traffic getting through. Versions up to 2.4.4 also
applied proxy-node tuning (RFS, `fq`, an all-to-all XPS map) to pure
forwarders — fixed in 2.4.5. Measure with `st --diagnose`, compare with
`st --set rps_mode=off && st --auto`, and read [TUNNELS.md](TUNNELS.md) for
the structural fixes (FOU encapsulation, the fast path).

## My server only forwards traffic (DNAT or a tunnel). Is that detected?

Yes. DNAT to another machine (iptables or native nft) means `relay`;
GRE/IPIP/SIT/VXLAN links mean `tunnel`; Docker's own DNAT to containers is
ignored. If detection is wrong: `st --auto --role relay,tunnel`.

## My server runs a bot, a website or a panel — is this useful?

Yes. The base layer (BBR, accept queues, buffers, limits, swap, journald,
DNS) helps every server. On top of that, `web` and `db` are detected
(nginx, Caddy, HAProxy, MySQL, PostgreSQL, Redis, …), Docker hosts get
bounded container logs and conntrack timeouts for Docker NAT, and a panel or
database host stays at tier M so its RAM goes to the database.

## How does rollback work?

Every file, live kernel value, NIC setting, qdisc and firewall unit is
recorded before it changes. `st --rollback` undoes the newest run at once;
running it again undoes the run before; `st --rollback-original` returns to
the state before ServerTools ever ran. Details: [ROLLBACK.md](ROLLBACK.md).

## Is `bash <(curl ...)` safe?

The script is open source and can be read first. Releases ship a
`SHA256SUMS` file; `st --update` verifies it and refuses a release without a
matching entry. `-f` makes curl fail on HTTP errors, so nothing partial runs.

## Which distributions are tested?

CI runs on Ubuntu 20.04 / 22.04 / 24.04 and Debian 11 / 12, plus a
real-kernel namespace test. Other distributions with apt, dnf/yum or pacman
generally work; inside LXC/OpenVZ containers, what belongs to the host
(swap, clock, many kernel keys) is skipped and explained.

## My old install link does not work

The version 1 scripts are frozen in `legacy/`:

```bash
bash <(curl -fsSL4 https://raw.githubusercontent.com/Sir-Adnan/server-tools/main/legacy/opt.sh)
```
