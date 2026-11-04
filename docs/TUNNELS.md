# Tunnel and relay servers

How ServerTools tunes servers that **pass traffic through** rather than serve
it: an Iran-side server forwarding ports with iptables/nftables DNAT, both
ends of a GRE/IPIP/SIT/VXLAN tunnel, WireGuard gateways, and userspace
tunnels (Backhaul, Rathole, gost, frp, Chisel, WaterWall, udp2raw, kcptun).
Persian translation: [TUNNELS.fa.md](TUNNELS.fa.md).

Roles involved: `tunnel`, `relay`, `vpn`, `utunnel` ([ROLES.md](ROLES.md)).
Every decision below is printed with its reason by `st --dry-run`.

## 1. Why a GRE tunnel loads a single core

The outer header of GRE and IPIP packets carries **no ports** — only the two
endpoint addresses. NIC receive-side scaling (RSS) hashes exactly those
fields, and every packet of a tunnel has the same pair, so the whole tunnel
lands in **one hardware queue and one CPU** — regardless of how many queues
the NIC has.

Fixes, best first:

1. **FOU/GUE encapsulation** — GRE inside UDP with a variable source port.
   The NIC spreads the tunnel in hardware, with no software cost. Both ends
   must change, in the tool that builds the tunnel:

   ```bash
   ip fou add port 5555 ipproto 47
   ip link add gre1 type gre remote PEER_IP local LOCAL_IP ttl 255 \
     encap fou encap-sport auto encap-dport 5555
   ```

2. **More NIC channels** — on virtio VPS NICs that offer several queue pairs
   but use one, ServerTools raises the count (`nic_channels`). This helps
   every flow except entropy-less tunnels.
3. **RPS** (software steering) — enabled automatically when a GRE/IPIP tunnel
   without FOU exists, or when the NIC has one RX queue.

## 2. "All cores are balanced now, but total CPU went up"

The field report that led to 2.4.5. Three separate effects:

| Cause | Explanation | Verdict |
| --- | --- | --- |
| Bottleneck removed | If the single core was at 100 %, packets were being dropped. More traffic now gets through, so more CPU is used. | good — if user throughput rose |
| RPS cost | Each packet is handled on two CPUs plus an inter-processor interrupt; on a VM every IPI is a VM exit. | real overhead |
| Proxy tuning on a forwarder | 2.4.4 also enabled RFS, `fq` and an "every CPU → every TX queue" XPS map. Forwarded packets have no local socket, so these were pure cost. | 2.4.4 bug — fixed |

On a pure forwarder 2.4.5 uses `fq_codel`, leaves RFS off and XPS untouched,
enables GRO and UDP GRO forwarding, and — with ≥ 4 CPUs and one RX queue —
keeps the CPU that services the NIC interrupt out of the RPS mask.

A multi-queue NIC can show the same "one hot core" for a different reason:
without irqbalance, every receive interrupt may sit on CPU 0. When
`--diagnose` measures that, Quick Optimize spreads the vectors one per CPU
(hardware spreading, no RPS hop); `irq_affinity=off` disables it.

### Measure, don't guess

```bash
st --diagnose
```

In ~3 s it shows softirq, system and steal per CPU; packets and backlog drops
per CPU; NIC channels, queues, RPS/XPS masks and GRO state; qdisc drops;
conntrack pressure; and tunnel MTUs. Tuning is not changed.

### A/B test at similar traffic

```bash
st --set rps_mode=off && st --auto
```

```bash
st --set rps_mode=auto && st --auto
```

```bash
st --set rps_cpus=1-3 && st --auto
```

Take `st --diagnose` after each. Compare **CPU per Mbit/s**, not CPU percent
alone.

## 3. MTU and MSS — the hidden CPU cost

Every encapsulation adds bytes. A tunnel MTU larger than *underlay MTU −
overhead* fragments or black-holes packets: slower and more CPU.

| Encapsulation | Overhead (IPv4) | Max MTU on a 1500 underlay |
| --- | --- | --- |
| GRE | 24 | 1476 |
| GRE + FOU | 32 | 1468 |
| IPIP / SIT | 20 | 1480 |
| ip6gre | 44 | 1456 |
| VXLAN / Geneve | 50 | 1450 |
| WireGuard | 60 (IPv6: 80) | 1440 (1420) |

`st --diagnose` and Network tools → `t` compute this for your tunnels.
ServerTools never changes a tunnel's MTU itself — the tunnel manager owns it,
and a one-sided change breaks the link — it states the correct value.

**MSS clamping** is a Quick Optimize step for `vpn`, `tunnel` and `relay`
roles: TCP SYNs are clamped to the path MTU, so segments never need
fragmenting in the first place.

## 4. Forwarding fast path (nftables flowtable) — opt-in

The largest CPU saving for relays: after the first packets of a connection,
the rest are forwarded straight from the ingress hook, skipping routing and
the netfilter chains.

- Menu: Network & VPN Tools → `f`.
- Needs `nft` (installed automatically) and kernel ≥ 4.17 with
  `nf_flow_table`; the ruleset is checked with `nft -c` first and nothing
  changes if the kernel refuses it.
- Offloaded packets bypass iptables counters and limits built on them
  (e.g. traffic accounting with iptables). New connections are still fully
  filtered.
- Removed from the same menu or by rollback.

## 5. Firewall on tunnel servers

UFW drops forwarded packets by default and knows nothing about GRE. When a
forwarding role is detected, the UFW setup offers
`DEFAULT_FORWARD_POLICY=ACCEPT`, allows GRE from each tunnel peer, and allows
WireGuard ports. The anti-abuse profile keeps tunnel subnets (`10.x/30`) and
Docker bridges reachable.

**NOTRACK** only matches traffic addressed to this host
(`-m addrtype --dst-type LOCAL`); DNAT-forwarded ports — including nft rules,
multiport lists and ranges — are excluded automatically, and a relay that
forwards every port is refused.

## 6. Recommended commands

```bash
st --auto --role relay,tunnel     # Iran-side DNAT relay + GRE
st --auto --role proxy,tunnel     # foreign end: Xray node + GRE endpoint
st --auto --role utunnel          # Backhaul / Rathole / gost
```

If detection is right, plain `st --auto` is enough; `st --dry-run` shows what
was detected and why.
