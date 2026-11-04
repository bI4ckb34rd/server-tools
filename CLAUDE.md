# CLAUDE.md — ServerTools

Contributor guide for humans and AI assistants. Keep it short: this file says
*what matters and where to look*; the details live in `docs/`.

## Purpose

ServerTools tunes Linux servers for the job they actually do. It detects
composable **roles** — `proxy`, `panel`, `vpn`, `tunnel`, `relay`, `utunnel`,
`web`, `db`, `general` — and tunes the kernel, NIC, firewall and container
engine for them, with a
reason for every decision. It ships as one bash file (`dist/server-tools.sh`)
built from a modular `src/` tree, and runs as root (interactive menu or CLI).

Target environments: VPS and bare-metal hosts running Xray/sing-box/Hysteria
nodes and panels, WireGuard/AmneziaWG/OpenVPN, GRE/IPIP/VXLAN tunnels,
iptables/nftables DNAT relays, userspace tunnels and HAProxy relays — often
under tens of thousands of concurrent users — and plain servers running bots,
sites and databases, with or without Docker.

## Rules

1. **Best tuning for the role, decided from evidence.** Decisions come from
   detected roles plus measured facts, never guesses. Every decision is made
   in `src/engine/policy.sh` and records its reason (`_why`); tuners read
   decisions, never roles.
2. **Light while running, nothing resident by default.** Collect facts once
   (`facts_collect`), avoid polling and repeated subprocesses, finish in
   seconds. Persistence uses oneshot units that exit. Tuning must not raise
   the server's steady-state CPU — check with `st --diagnose` before/after.
3. **Dependencies are welcome when they make the result better.** Declare them
   in `ST_DEPS` (`src/lib/deps.sh`); they are installed automatically and
   reported to the user. Callers still check `has_cmd` and fall back cleanly
   when a tool is absent (offline host, `--no-install`).
4. **Resident services only for measurable benefit**, opt-in, with their cost
   stated in the UI (fail2ban, irqbalance, …).
5. **Never break the server.** No change may cut SSH, forwarding or a tunnel.
   Every change is recorded before it happens (`st_track_file`,
   `st_write_file`, `st_set_runtime`, `st_set_ethtool`, `st_track_qdisc`,
   `systemd_enable_oneshot`) so rollback restores it; `--dry-run` must show
   exactly what a real run would do and change nothing.
6. **Idempotent.** Running anything twice converges to the same state — no
   duplicated rules or lines.
7. **Honest output.** Never report OK for something that failed. Steps return
   0 ok / 1 failed / 2 skipped / 3 warning; verifiers 0 ok / 2 not configured /
   3 drift.
8. **Edit `src/`, never `dist/`.** Build with `./build.sh`; new files go into
   `SOURCES` in `build.sh` (the build fails otherwise). Lint and tests stay
   green; every new behaviour gets a test.
9. **Docs in English**, Persian translations in `*.fa.md`. Update
   `CHANGELOG.md` with every user-visible change and the matching spec in
   `docs/` before or with the code.
10. **Git:** do not commit or push unless the user asks; suggest a commit
    message instead.

## Bash pitfalls in this codebase

- The global `IFS=$'\n\t'` has **no space**: `"${arr[*]}"` and `" $* "` join
  with newlines, and neither an unquoted `$list` nor `read -ra` splits on
  spaces. Use `join_sp`, `join_by`, `ports_split` (`src/lib/net.sh`) or
  `IFS=' ' read -ra …`.
- Debian ships **mawk**: no `strtonum`/`gensub`; parse hex in bash
  (`$((16#$x))`).
- Value-producing helpers captured with `x="$(fn)"` end in `return 0`, so a
  trailing false test never trips errexit.
- Parse command output from a here-string, not a pipe into an early-exiting
  `awk` (SIGPIPE + pipefail).
- Commands that can hang (docker, podman) go through `run_bounded`.

## Map

| Need | Look at |
| --- | --- |
| layers, source map, how to extend (engine, role, decision, tuner, tunable, prerequisite) | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| roles, detection signatures, role → decision rules, capacity tiers | [docs/ROLES.md](docs/ROLES.md) |
| every kernel / NIC setting and its rationale (spec for `tuners/`) | [docs/SYSCTL.md](docs/SYSCTL.md) |
| tunnel and relay behaviour: RSS, RPS, MTU/MSS, flowtable | [docs/TUNNELS.md](docs/TUNNELS.md) |
| manifest, live rollback, upgrading from 2.4.4 | [docs/ROLLBACK.md](docs/ROLLBACK.md) |
| user-facing behaviour, menus, CLI | [docs/GUIDE.md](docs/GUIDE.md), [README.md](README.md) |
| history and plans | [CHANGELOG.md](CHANGELOG.md), [ROADMAP.md](ROADMAP.md); releases ≤ 2.4.4 in [docs/archive/](docs/archive/) |

Source layout: `src/lib` (helpers, prerequisites) → `src/state` (config
registry, manifest, backup, migration) → `src/engine` (facts, roles,
capacity, policy, runner) → `src/tuners` (apply/verify) → `src/features`
(opt-in tools, diagnose, doctor) → `src/ui` (flows, menu) → `src/99-main.sh`.
`legacy/` holds the frozen v1 scripts and is not part of the build.

## Commands

```bash
./build.sh               # src/ → dist/server-tools.sh (+ bash -n)
make lint                # shellcheck -x on dist + tests, shfmt -i 2 -ci
make test                # tests/smoke.sh (CLI contract) + tests/unit.sh
sudo make test-netns     # real kernel: GRE + DNAT relay in a private namespace
```

Unit tests load the program with `ST_SOURCE_ONLY=1` and sandbox its state
with `ST_STATE_ROOT`. CI (`.github/workflows/ci.yml`) runs lint, unit,
namespace and smoke tests, plus a root `--status` boot on Ubuntu
20.04/22.04/24.04 and Debian 11/12.

## Style

- shfmt `-i 2 -ci`; ShellCheck clean.
- Functions `snake_case` with a module prefix (`net_`, `fw_`, `deps_`,
  `config_`, `manifest_`, `facts_`, `roles_`, `policy_`, `sysctl_`, `nic_`,
  …); private helpers start with `_`. Globals `ST_*` (facts `ST_F_*`,
  decisions `ST_P_*`); locals always `local`.
- Colours only through the `C_*` palette and only on labels; Unicode only
  behind `ST_UTF8` with an ASCII fallback.
- Code, comments and commit messages in English.

## Releases

`VERSION` is the single source of truth (injected as `@VERSION@`). SemVer.
Pushing a `v*` tag runs `release.yml`: build, tests, SHA-256, GitHub Release
asset.
