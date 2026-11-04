# Roadmap

What is next. What already shipped lives in [CHANGELOG.md](CHANGELOG.md);
the plans of earlier releases are in [docs/archive/](docs/archive/).

## 2.4.5 — field validation

Shipped in code and tests; to confirm on real servers:

1. **GRE/DNAT relay** — `st --diagnose` before and after Quick Optimize at
   similar traffic shows no higher CPU per Mbit; `st --rollback` restores
   RPS and the qdisc live.
2. **Reboot** — on a relay, a proxy node and a Docker host: Quick Optimize,
   reboot, then `st --verify` is green (sysctl, MSS/NOTRACK, DNS, IPv6 off).
3. **Upgrade** — a host tuned by 2.4.4 upgrades cleanly: migration notes
   shown, Doctor green after Quick Optimize, the migration run rolls back.
4. **Docker** — log rotation and live-restore merged into an existing
   `daemon.json`, Docker restart keeps containers running.
5. **Fast path** — flowtable on a kernel that supports it: traffic flows,
   removal clears the table.

## Next

- `--diagnose --json` for fleet dashboards and before/after archives.
- Per-role Doctor checks: relay without MSS, tunnel MTU drift, conntrack
  close to full.
- Guided `iperf3` test between two of your own servers (tunnel throughput
  without a public speed-test server in the path).
- ufw-docker integration: close the Docker firewall bypass instead of only
  reporting it.

## Ideas

- FOU/GUE encapsulation for GRE peers (needs both ends — likely a shared spec
  with GRE-Tunnel-Manager).
- Suggest UFW ports from detected panel and node containers.
- Switch README install links from `main` to `releases/latest` once the
  release channel has a few tagged versions.
