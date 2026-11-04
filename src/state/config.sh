# shellcheck shell=bash
# ============================================================================
# state/config.sh — persistent user preferences (/etc/server-tools/config,
# plain key=value) plus the REGISTRY of every user-facing key.
#
# The registry is the single place a new tunable is declared: its default,
# its validation pattern and a one-line description. The Settings screen,
# `--set KEY=VALUE` and the docs table are all driven from it, so a key can
# never exist in code without being discoverable (a pre-2.4.5 gap: `rps_mode` and
# `qdisc` were honoured but documented nowhere).
# ============================================================================

declare -A ST_CONFIG=()

# Format: key;default;validation (ERE, anchored);description
readonly -a ST_CONFIG_KEYS=(
  'roles;auto;^(auto|[a-z,]+)$;Server roles to tune for (auto = detect; or e.g. proxy,relay)'
  'capacity_tier;auto;^(auto|S|M|L|XL)$;Capacity tier override (auto = by RAM)'
  'expected_users;0;^[0-9]+$;Expected concurrent users (0 = size by RAM)'
  'qdisc;auto;^(auto|fq|fq_codel|cake|pfifo_fast)$;Queueing discipline (auto = fq for local TCP, fq_codel for pure forwarders)'
  'rps_mode;auto;^(auto|on|off)$;RPS/RFS software packet steering'
  'rps_cpus;auto;^(auto|[0-9,-]+)$;CPUs that RPS may steer to (auto, or a list like 1-3)'
  'mss_clamp;auto;^(auto|on|off)$;MSS clamping in Quick Optimize (auto = on for VPN/tunnel/relay roles)'
  'reserved_ports;;^[0-9,-]*$;Extra ports to reserve from the ephemeral range (UDP-only services)'
  'swap_backend;auto;^(auto|file|zram)$;Swap backend when none exists'
  'swap_size_mb;2048;^[0-9]+$;Swap file size in MB'
  'dns_over_tls;auto;^(auto|opportunistic|no)$;DNS-over-TLS for systemd-resolved (auto = off for Iran-hosted resolvers)'
  'install_deps;auto;^(auto|never)$;Install missing prerequisites (ethtool, nftables, dig, ...) automatically'
  'nic_channels;auto;^(auto|off|[0-9]+)$;NIC RX/TX channel count (auto = raise to min(max, CPUs) on virtio)'
  'nic_offloads;auto;^(auto|off)$;Enable GRO / UDP GRO forwarding where the NIC supports it'
  'irq_affinity;auto;^(auto|off)$;Spread receive interrupts when they all sit on one CPU (no irqbalance)'
  'docker_tuning;auto;^(auto|off)$;Docker engine hygiene in Quick Optimize (log rotation, live-restore, nofile)'
  'docker_log_size;10m;^[0-9]+[kmg]$;Per-file size cap for json-file container logs (3 files kept)'
)

state_init() {
  mkdir -p "$ST_ETC_DIR" "$ST_LIB_DIR" "$ST_BACKUP_DIR"
  if [[ ! -f $ST_MANIFEST_FILE ]]; then
    printf '# timestamp\trun_id\taction\ttarget\n' >"$ST_MANIFEST_FILE"
  fi
}

config_load() {
  ST_CONFIG=()
  [[ -f $ST_CONFIG_FILE ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    [[ -z $key || $key == \#* ]] && continue
    ST_CONFIG[$key]="$value"
  done <"$ST_CONFIG_FILE"
}

# config_default KEY — the registry default ("" for unknown keys).
config_default() {
  local entry key def _re _desc
  for entry in "${ST_CONFIG_KEYS[@]}"; do
    IFS=';' read -r key def _re _desc <<<"$entry"
    [[ $key == "$1" ]] && {
      printf '%s' "$def"
      return 0
    }
  done
  return 0
}

config_get() { # config_get KEY [DEFAULT] — explicit DEFAULT beats the registry.
  local fallback="${2-}"
  if (($# < 2)); then fallback="$(config_default "$1")"; fi
  printf '%s' "${ST_CONFIG[$1]:-$fallback}"
}

config_known() { # config_known KEY — 0 when KEY is in the registry.
  local entry
  for entry in "${ST_CONFIG_KEYS[@]}"; do
    [[ ${entry%%;*} == "$1" ]] && return 0
  done
  return 1
}

# config_validate KEY VALUE — 0 when KEY is registered and VALUE matches it.
config_validate() {
  local entry key _def re _desc
  for entry in "${ST_CONFIG_KEYS[@]}"; do
    IFS=';' read -r key _def re _desc <<<"$entry"
    if [[ $key == "$1" ]]; then
      [[ $2 =~ $re ]] || return 1
      # A role list must name real roles, not just look like one.
      if [[ $key == roles && $2 != auto ]]; then
        roles_normalize "$2" >/dev/null || return 1
      fi
      return 0
    fi
  done
  return 1
}

config_set() { # config_set KEY VALUE — updates memory and persists.
  ST_CONFIG[$1]="$2"
  config_save
}

config_unset() {
  unset 'ST_CONFIG[$1]'
  config_save
}

config_save() {
  ((ST_DRY_RUN)) && return 0
  mkdir -p "$ST_ETC_DIR"
  local tmp="${ST_CONFIG_FILE}.tmp" key
  {
    printf '# %s configuration — generated; editing by hand is fine.\n' "$ST_NAME"
    printf '# Keys and allowed values: st --settings, or docs/GUIDE.md.\n'
    for key in "${!ST_CONFIG[@]}"; do
      printf '%s=%s\n' "$key" "${ST_CONFIG[$key]}"
    done | sort
  } >"$tmp"
  mv -f "$tmp" "$ST_CONFIG_FILE"
}

# config_set_cli "KEY=VALUE" — validated setter behind `--set`.
config_set_cli() {
  local key="${1%%=*}" value="${1#*=}"
  if [[ $1 != *=* ]] || ! config_validate "$key" "$value"; then
    log_error "Invalid setting '${1}' — run 'st --settings' for keys and allowed values."
    exit 2
  fi
  config_set "$key" "$value"
  printf '%s=%s saved.\n' "$key" "$value"
}

# config_print — the registry with current values (Settings / --settings).
config_print() {
  local entry key def re desc cur
  for entry in "${ST_CONFIG_KEYS[@]}"; do
    IFS=';' read -r key def re desc <<<"$entry"
    cur="$(config_get "$key")"
    printf '  %s%-15s%s %-12s %s%s%s\n' "$C_KEY" "$key" "$C_RESET" "${cur:-(empty)}" "$C_MUTED" "$desc" "$C_RESET"
  done
}
