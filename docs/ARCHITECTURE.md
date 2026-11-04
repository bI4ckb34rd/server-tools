# Architecture

## Goals

1. **Lightweight** — fast and frugal while it runs (one pass of fact
   collection, no polling), and nothing resident afterwards by default: boot
   persistence uses oneshot units that exit. Prerequisites are installed when
   they make the result better (`lib/deps.sh`).
2. **Right for the role** — a proxy node, a GRE/DNAT relay, a WireGuard
   gateway and a panel need different tuning. Decisions come from detected
   roles and measured facts, and every decision states its reason.
3. **Trustworthy changes** — every touched file AND live value is tracked
   before it changes; rollback restores both.
4. **Single-file delivery, modular development** — users fetch one file;
   developers work in a layered tree with one responsibility per file.

## Layers

```text
            ┌──────────────────────────────────────────────┐
  ui/       │ flows (quick/custom/auto/dry-run) · menu     │  talks to the user
            ├──────────────────────────────────────────────┤
  features/ │ opt-in tools: notrack · flowtable · security │  explicit consent
            │ diagnose · doctor · sysinfo · tools · ...    │
            ├──────────────────────────────────────────────┤
  tuners/   │ sysctl · qdisc · nic · mss · tunnel(audit)   │  apply / verify /
            │ swap · limits · extras · dns                 │  dry-run contract
            ├──────────────────────────────────────────────┤
  engine/   │ facts → roles → capacity → policy · runner   │  decides, never writes
            ├──────────────────────────────────────────────┤
  state/    │ config registry · manifest · backup · migrate │  rollback source of truth
            ├──────────────────────────────────────────────┤
  lib/      │ term · log · ui · sys · net · fw · deps       │  helpers, prerequisites
            └──────────────────────────────────────────────┘
```

Rules between layers:

- **Facts are collected once** (`facts_collect`): one `ps`, one `ip -d link`,
  one NAT dump, one container listing. Everything else reads `ST_F_*`.
- **Tuners read decisions, not roles.** `engine/policy.sh` is the only place
  that maps roles to settings (`ST_P_*`, `ST_QDISC`, `ST_CC`) and records the
  reason for each (`ST_P_WHY`). A new role or a changed rule touches one file.
- **Every tuner follows one contract:** `<name>_apply` returns 0 ok, 1 failed,
  2 skipped, 3 applied with warnings; `<name>_verify` returns 0 in effect,
  2 not configured, 3 drift. The runner and Doctor are generic over it.
- **Every write is tracked first** (`st_track_file`, `st_write_file`,
  `st_set_runtime`, `st_set_ethtool`, `st_track_qdisc`,
  `systemd_enable_oneshot`) — see `docs/ROLLBACK.md`. `st_write_file`
  leaves an identical file alone, so a re-run changes nothing.
- **External commands that can hang are bounded** (`run_bounded`: docker,
  podman) — a wedged daemon must never freeze the tool.
- **Data, not code, for extension points:** engine signatures
  (`ST_ENGINE_SIGNATURES`), role catalog, config registry (`ST_CONFIG_KEYS`),
  prerequisites (`ST_DEPS`), optimize steps (`ST_OPTIMIZE_STEPS`), Doctor
  checks (`ST_DOCTOR_CHECKS`) are tables.

## Extending

| To add | Touch |
| --- | --- |
| a detectable engine | one line in `ST_ENGINE_SIGNATURES` (`engine/roles.sh`) |
| a role | `ST_ROLE_IDS` + `ST_ROLE_CATALOG`, then its rules in `engine/policy.sh` |
| a tuning decision | a `_policy_*` function with `_why`, read by a tuner |
| a tuner | `tuners/<name>.sh` with `<name>_apply` / `<name>_verify`, one line in `ST_OPTIMIZE_STEPS` (`ui/flows.sh`), a row in `ST_DOCTOR_CHECKS`, an entry in `build.sh` |
| a tunable | one line in `ST_CONFIG_KEYS` (`state/config.sh`) |
| a prerequisite | one line in `ST_DEPS` (`lib/deps.sh`) |

## Build pipeline

```text
src/ (layered, ShellCheck-directive headers)
  └── build.sh  — checks SOURCES == files on disk, concatenates in order,
                  strips per-file shebangs, injects VERSION (@VERSION@), bash -n
        └── dist/server-tools.sh  — the only artifact users run
```

- Build order lives in `SOURCES` in `build.sh`; the header is first (strict
  mode, constants, ERR trap) and `99-main.sh` last. The build fails if a file
  in `src/` is missing from `SOURCES` (or vice versa).
- `ST_SOURCE_ONLY=1 source dist/server-tools.sh` loads every function without
  running `main` — the basis of `tests/unit.sh` and `tests/netns.sh`.

## Source map

| Path | Responsibility |
| --- | --- |
| `src/00-header.sh` | strict mode, constants (`ST_*`), exit-code contract, ERR trap |
| `src/lib/term.sh` | terminal capability detection, palette (`C_*`) |
| `src/lib/log.sh` | leveled logging, rotation, buffered step notes, `die` |
| `src/lib/ui.sh` | rules/titles/kv/menu/confirm/pause/badges, logo |
| `src/lib/sys.sh` | OS/kernel/CPU/memory facts, container detection, `run_bounded`, CPU lists and masks, `pkg_install`, systemd helpers |
| `src/lib/net.sh` | address validation, port-list arithmetic, listeners, interfaces/queues/qdisc, receive IRQs, ethtool channels/offloads, public IP |
| `src/lib/fw.sh` | iptables/ip6tables/nft rule helpers, DNAT discovery (iptables + native nft) |
| `src/lib/deps.sh` | prerequisite registry, package names per manager, automatic install |
| `src/state/config.sh` | config registry, validated get/set, `--set` / `--settings` |
| `src/state/manifest.sh` | append-only change log, open runs, rollback markers |
| `src/state/backup.sh` | `st_track_file`, `st_write_file`, `st_set_runtime`, `st_set_ethtool`, `st_track_qdisc`, both rollbacks |
| `src/state/migrate.sh` | one-time repair of live state left by 2.4.4 and older |
| `src/engine/facts.sh` | one-pass fact collection (CPU, uplink queues, tunnels, processes, containers, Docker, conntrack, irqbalance, units, NAT) |
| `src/engine/roles.sh` | role catalog, engine signatures, detection, CLI/config resolution |
| `src/engine/capacity.sh` | capacity tiers, user-based conntrack sizing, RAM warning |
| `src/engine/policy.sh` | roles + facts → decisions with reasons |
| `src/engine/runner.sh` | step runner, summary, before/after counter snapshot |
| `src/tuners/sysctl.sh` | `/etc/sysctl.d` render (docs/SYSCTL.md), conntrack module, verify, dry-run diff |
| `src/tuners/qdisc.sh` | multi-queue-safe live qdisc rebuild |
| `src/tuners/nic.sh` | NIC channels and offloads, receive-IRQ affinity, RPS/RFS/XPS, governor, THP + oneshot boot unit |
| `src/tuners/mss.sh` | MSS clamping (iptables or nft), idempotent unit with ExecStop |
| `src/tuners/tunnel.sh` | tunnel MTU / encapsulation audit (read-only) |
| `src/tuners/swap.sh` · `limits.sh` · `extras.sh` · `dns.sh` | swap, nofile, journald/NTP, DNS that sticks |
| `src/features/notrack.sh` | host-scoped conntrack exemption for proxy ports |
| `src/features/flowtable.sh` | opt-in nftables fast path for forwarders |
| `src/features/docker.sh` | Docker engine hygiene (daemon.json merge with jq: log rotation, live-restore, nofile), audit, log truncation |
| `src/features/security.sh` | UFW (forwarding-aware), fail2ban, SSH, anti-abuse, node API, Docker audit |
| `src/features/diagnose.sh` | measured data-path report (`--diagnose`) |
| `src/features/doctor.sh` | drift check over every tuner's `_verify` (`--verify`) |
| `src/features/sysinfo.sh` · `tools.sh` | status report; ping/speed/benchmark/live view/report |
| `src/features/ipv6.sh` · `kernel.sh` · `mirror.sh` · `installer.sh` · `selfupdate.sh` | IPv6 toggle, XanMod, APT mirror, node installers, `st` install/update |
| `src/ui/flows.sh` | optimize step table, plan → confirm → apply flows, restart offers |
| `src/ui/menu.sh` | interactive menu, settings editor |
| `src/99-main.sh` | CLI parsing, entrypoint, library mode |

## Runtime filesystem layout (FHS)

| Path | Purpose |
| --- | --- |
| `/etc/server-tools/config` | user preferences (key=value; keys in the registry) |
| `/etc/server-tools/perf-boot.sh`, `mss.nft`, `flowtable.sh` | generated oneshot payloads |
| `/etc/sysctl.d/99-zz-server-tools.conf` (+ `-ipv6.conf`) | kernel keys; the name sorts after `99-sysctl.conf` |
| `/etc/systemd/system/server-tools-*.service` | oneshot units: perf, mss, notrack, flowtable, dns, ipv6, zram |
| `/var/lib/server-tools/bin/speedtest`, `speedtest-history.tsv` | kept Ookla client, speed test results |
| `/var/lib/server-tools/installed-packages` | prerequisites installed by ServerTools |
| `/var/lib/server-tools/manifest.tsv` | change manifest (rollback source of truth) |
| `/var/lib/server-tools/backups/original/` | pristine first-touch copies (+ `.runtime/` values) |
| `/var/lib/server-tools/backups/runs/<run-id>/` | per-run copies (+ `.runtime/` values) |
| `/var/log/server-tools.log` | log (fallback: `/var/lib/server-tools/`) |

Nothing is written to `/tmp` — predictable filenames in world-writable
directories are a symlink-attack risk for a root tool. (`ST_STATE_ROOT`
relocates only the tool's own state, for the test suites.)

## Error handling policy

- `set -Eeuo pipefail` plus a global ERR trap that reports the failing line
  and command; nothing dies silently.
- Steps signal outcomes with explicit return codes (errexit is suspended
  inside `"$fn" || rc=$?`).
- Tolerable failures carry a comment explaining why (bare `|| true` is
  banned); value-producing helpers end in an explicit `return 0` so a
  trailing false guard never trips errexit through `x="$(helper)"`.
- Prerequisites are declared in `ST_DEPS` and installed by `deps_ensure`
  (policy `install_deps`); every caller still checks `has_cmd` and falls back
  when a tool is absent (offline host, `--no-install`).

## Testing

| Suite | Needs | Covers |
| --- | --- | --- |
| `tests/smoke.sh` | nothing | build, parse, CLI contract and usage-error exits |
| `tests/unit.sh` | nothing (jq for the Docker merge cases) | masks/lists, role detection (incl. web/db), capacity caps, NAT parsing, tunnel overheads, config registry, policy decisions (GRE-relay field case, conntrack, IRQ, database, Docker), IRQ selector, sysctl render (ceilings, IPv6-less kernels, unsupported keys), daemon.json merge, idempotent writes, rollback in a sandbox |
| `tests/netns.sh` | root | a real GRE + DNAT relay in a private namespace: facts, policy, RPS/THP writes, idempotent MSS, scoped NOTRACK, 2.4.4 qdisc repair, live rollback |

CI runs all three, plus a `--status` boot on Ubuntu 20.04/22.04/24.04 and
Debian 11/12.

## UI policy

- Color only labels/titles via the `C_*` palette — never values.
- `NO_COLOR`, non-tty stdout, `TERM=dumb`, and `--no-color` disable color.
- Unicode only when the locale is UTF-8; ASCII fallback otherwise.
- The dashboard renders instantly: network lookups are cached per process.
