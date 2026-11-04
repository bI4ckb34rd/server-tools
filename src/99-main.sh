# shellcheck shell=bash
# ============================================================================
# 99-main.sh — CLI argument parsing and the program entrypoint.
# This file MUST be last in the build order (see build.sh SOURCES).
# ============================================================================

usage() {
  cat <<EOF
${ST_NAME} v${ST_VERSION} — Linux server optimization for VPN, proxy, tunnel
and relay servers. ${ST_REPO_URL}

Usage: server-tools.sh [OPTIONS]   (installed: st [OPTIONS])

Actions (no action starts the interactive menu):
  --status              Print the full system status report and exit
  --auto                Non-interactive optimize for the detected roles
  --dry-run             Show the plan, the reasons and the exact diff; apply NOTHING
  --diagnose            Measure the network data path (per-core softirq, drops,
                        queues, conntrack, tunnels) — read-only, ~3 s
  --verify              Check whether everything applied is still in effect
  --report              Print + save a plain-text support report
  --rollback            Revert the newest open run (again = one run further back)
  --rollback-original   Restore the state from before ServerTools ever ran
  --settings            List every tunable with its current value
  --set KEY=VALUE       Save a tunable (validated; repeatable; combines with --auto)
  --install             Install as the 'st' command (/usr/local/bin/st)
  --update              Self-update from the latest GitHub release
  --ipv6 on|off|status  Switch the IPv6 stack on/off (persists across reboots)
  --speedtest           Bandwidth test (Ookla, nearest server) + result history

Options for --auto and --dry-run:
  --role LIST           Roles to tune for, comma separated (default: detected):
                        proxy, panel, vpn, tunnel, relay, utunnel, web, db, general
  --profile NAME        older profile names still work: general | vpn-node | wireguard |
                        panel | relay | full
  --tier T              Capacity tier: S | M | L | XL (default: by RAM)
  --users N             Expected concurrent users — sizes conntrack from the
                        real user count instead of RAM (with a RAM warning)
  --dns VALUE           Provider (cloudflare|google|quad9|opendns|shecan|
                        electro|begzar) or custom "primary,secondary"
  --no-swap             Skip the swap step
  --no-limits           Skip the nofile limits step
  --no-extras           Skip the journald/NTP step
  --no-perf             Skip the CPU/NIC data-path step (RPS/XPS, governor, THP)
  --no-mss              Skip MSS clamping (otherwise on for vpn/tunnel/relay roles)
  --no-docker           Skip the Docker engine step (log rotation, live-restore, nofile)
  --no-install          Never install missing prerequisites this run
                        (default: installed automatically — ethtool, nftables, …)

General options:
  --json                Machine-readable output (--verify)
  --no-color            Disable colored output (NO_COLOR env also honoured)
  --debug               Verbose logging to console and log file
  -v, --version         Print version and exit
  -h, --help            Show this help

Exit codes:
  0  everything succeeded    1  at least one step failed
  2  usage error             3  applied, but with warnings / drift found

Examples:
  st --auto --role relay,tunnel           # a GRE/DNAT relay
  st --auto --profile vpn-node --users 10000 --dns cloudflare
  st --set rps_mode=off --auto            # A/B-test software steering
  st --verify --json                      # drift check from your own automation
EOF
}

_need_value() { # _need_value OPTION VALUE
  if [[ -z ${2:-} ]]; then
    printf 'Missing value for %s\n' "$1" >&2
    exit 2
  fi
}

_usage_error() {
  printf '%s\n' "$1" >&2
  exit 2
}

ST_CLI_IPV6=''

main() {
  local action="menu" tuning_opts=''
  local -a sets=()
  while (($# > 0)); do
    case "$1" in
      -v | --version)
        printf '%s %s\n' "$ST_NAME" "$ST_VERSION"
        return 0
        ;;
      -h | --help)
        usage
        return 0
        ;;
      --status) action="status" ;;
      --rollback) action="rollback" ;;
      --rollback-original) action="rollback_original" ;;
      --auto) action="auto" ;;
      --dry-run) action="dryrun" ;;
      --diagnose) action="diagnose" ;;
      --verify | --doctor) action="verify" ;;
      --report) action="report" ;;
      --install) action="install" ;;
      --update) action="update" ;;
      --settings) action="settings" ;;
      --speedtest) action="speedtest" ;;
      --ipv6)
        _need_value "$1" "${2:-}"
        shift
        case "$1" in
          on | off | status) ST_CLI_IPV6="$1" ;;
          *) _usage_error "Invalid --ipv6 '${1}' (on, off or status)." ;;
        esac
        action="ipv6"
        ;;
      --set)
        _need_value "$1" "${2:-}"
        shift
        sets+=("$1")
        [[ $action == menu ]] && action="set"
        ;;
      --role | --roles)
        _need_value "$1" "${2:-}"
        shift
        roles_normalize "$1" >/dev/null ||
          _usage_error "Invalid --role '${1}' (proxy, panel, vpn, tunnel, relay, utunnel, web, db, general)."
        ST_CLI_ROLES="$1"
        tuning_opts='yes'
        ;;
      --profile)
        _need_value "$1" "${2:-}"
        shift
        ST_CLI_ROLES="$(roles_from_profile "$1")" ||
          _usage_error "Invalid --profile '${1}' (general|vpn-node|wireguard|panel|relay|full)."
        ST_CLI_ROLES="${ST_CLI_ROLES// /,}"
        tuning_opts='yes'
        ;;
      --tier)
        _need_value "$1" "${2:-}"
        shift
        ST_CLI_TIER="${1^^}"
        [[ $ST_CLI_TIER =~ ^(S|M|L|XL)$ ]] || _usage_error "Invalid --tier '${1}' (S|M|L|XL)."
        tuning_opts='yes'
        ;;
      --users)
        _need_value "$1" "${2:-}"
        shift
        [[ $1 =~ ^[0-9]+$ ]] || _usage_error "Invalid --users '${1}' (expected a number)."
        ST_CLI_USERS="$1"
        tuning_opts='yes'
        ;;
      --dns)
        _need_value "$1" "${2:-}"
        shift
        ST_AUTO_DNS="$1"
        tuning_opts='yes'
        ;;
      --no-swap) ST_AUTO_SWAP=0 tuning_opts='yes' ;;
      --no-limits) ST_AUTO_LIMITS=0 tuning_opts='yes' ;;
      --no-extras) ST_AUTO_EXTRAS=0 tuning_opts='yes' ;;
      --no-perf) ST_AUTO_PERF=0 tuning_opts='yes' ;;
      --no-mss) ST_AUTO_MSS=0 tuning_opts='yes' ;;
      --no-docker) ST_AUTO_DOCKER=0 tuning_opts='yes' ;;
      --no-install) ST_OPT_NO_INSTALL=1 ;;
      --json) ST_OPT_JSON=1 ;;
      --no-color) ST_OPT_NO_COLOR=1 ;;
      --debug) ST_OPT_DEBUG=1 ;;
      *)
        printf 'Unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done

  # Tuning options only mean something for a planning run; silently ignoring
  # them would hide a typo in a provisioning script.
  if [[ -n $tuning_opts && $action != auto && $action != dryrun ]]; then
    _usage_error 'Options like --role/--tier/--users/--dns require --auto or --dry-run.'
  fi

  ui_detect_terminal
  require_root
  log_init
  state_init
  config_load
  log_info "${ST_NAME} v${ST_VERSION} started (run ${ST_RUN_ID}, action=${action})"

  local kv
  for kv in "${sets[@]-}"; do
    [[ -n $kv ]] && config_set_cli "$kv"
  done

  case "$action" in
    set) : ;;
    settings)
      ST_OPT_BATCH=1
      ui_title "Settings (${ST_CONFIG_FILE})"
      config_print
      ;;
    status)
      ST_OPT_BATCH=1
      facts_collect
      show_status
      ;;
    rollback)
      ST_OPT_BATCH=1
      rollback_latest || st_escalate_exit $?
      ;;
    rollback_original)
      ST_OPT_BATCH=1
      rollback_original || st_escalate_exit $?
      ;;
    auto)
      ST_OPT_BATCH=1
      auto_optimize
      ;;
    dryrun)
      ST_OPT_BATCH=1
      ST_DRY_RUN=1
      dry_run_optimize
      ;;
    diagnose)
      ST_OPT_BATCH=1
      diagnose_network || st_escalate_exit 3
      ;;
    verify)
      ST_OPT_BATCH=1
      facts_collect
      doctor_run || st_escalate_exit $?
      ;;
    report)
      ST_OPT_BATCH=1
      facts_collect
      roles_detect
      tools_report
      ;;
    ipv6)
      ST_OPT_BATCH=1
      ipv6_cli "$ST_CLI_IPV6" || st_escalate_exit $?
      ;;
    speedtest)
      ST_OPT_BATCH=1
      tools_speedtest_cli || st_escalate_exit 1
      ;;
    install)
      ST_OPT_BATCH=1
      st_self_install || st_escalate_exit 1
      ;;
    update)
      ST_OPT_BATCH=1
      st_self_update || st_escalate_exit 1
      ;;
    menu)
      main_menu
      ;;
  esac

  # ST_EXIT_CODE deliberately carries 1 or 3, so the ERR trap is cleared
  # first — otherwise this `return` looks like an unhandled failure.
  trap - ERR
  log_info "${ST_NAME} finished (run ${ST_RUN_ID}, exit=${ST_EXIT_CODE})"
  return "$ST_EXIT_CODE"
}

# Library mode for tests: `ST_SOURCE_ONLY=1 source dist/server-tools.sh`
# loads every function without running anything.
if [[ ${ST_SOURCE_ONLY:-0} != 1 ]]; then
  main "$@"
fi
