# shellcheck shell=bash
# ============================================================================
# engine/capacity.sh — capacity tiers (by RAM) and the user-based model.
# Conntrack tables and buffers cost real kernel RAM; sizing them for 100k
# users on a 1 GB VPS would cause the very OOMs we exist to prevent.
# See docs/ROLES.md for the tables.
# ============================================================================

ST_TIER=''
ST_TIER_USERS=''
ST_SOMAXCONN=0
ST_NETDEV_BACKLOG=0
ST_BUF_MB=0
ST_CONNTRACK=0
ST_EXPECTED_USERS=0
ST_CLI_USERS=''
ST_CLI_TIER=''

tier_set() {
  ST_TIER="$1"
  case "$1" in
    S) ST_TIER_USERS='~1k' ST_SOMAXCONN=8192 ST_NETDEV_BACKLOG=16384 ST_BUF_MB=8 ST_CONNTRACK=65536 ;;
    M) ST_TIER_USERS='~10k' ST_SOMAXCONN=16384 ST_NETDEV_BACKLOG=32768 ST_BUF_MB=16 ST_CONNTRACK=262144 ;;
    L) ST_TIER_USERS='~100k' ST_SOMAXCONN=32768 ST_NETDEV_BACKLOG=65536 ST_BUF_MB=32 ST_CONNTRACK=1048576 ;;
    XL) ST_TIER_USERS='100k+' ST_SOMAXCONN=65535 ST_NETDEV_BACKLOG=65536 ST_BUF_MB=64 ST_CONNTRACK=2097152 ;;
    *) tier_set S ;;
  esac
}

# capacity_resolve — tier from CLI > config > RAM, then the users model.
capacity_resolve() {
  local override ram_mb
  override="${ST_CLI_TIER:-$(config_get capacity_tier)}"
  case "$override" in
    S | M | L | XL) tier_set "$override" ;;
    *)
      ram_mb="$(mem_total_mb)"
      if ((ram_mb <= 1536)); then
        tier_set S
      elif ((ram_mb <= 6144)); then
        tier_set M
      elif ((ram_mb <= 24576)); then
        tier_set L
      else
        tier_set XL
      fi
      # A panel/database host never needs an L/XL conntrack table — its RAM
      # is better left to the database.
      if roles_only panel db && [[ $ST_TIER == L || $ST_TIER == XL ]]; then
        tier_set M
      fi
      ;;
  esac
  _capacity_apply_users
  return 0
}

# _capacity_apply_users — conntrack demand follows the ACTIVE USER COUNT, not
# RAM: ~24 flows per online user × 1.5 headroom. RAM still sizes buffers.
_capacity_apply_users() {
  local users ct
  users="${ST_CLI_USERS:-$(config_get expected_users)}"
  [[ $users =~ ^[0-9]+$ ]] || users=0
  ST_EXPECTED_USERS="$users"
  ((users > 0)) || return 0
  ct=$((users * 24 * 3 / 2))
  ((ct < 65536)) && ct=65536
  ((ct > 4194304)) && ct=4194304
  ST_CONNTRACK="$ct"
  return 0
}

# capacity_ct_budget RAM_MB — the largest power-of-two conntrack table whose
# worst case (~300 bytes per entry, table full) stays within 10% of RAM,
# capped at 4M. Forwarders are CPU-bound long before RAM runs out, and a
# full table drops new connections — the RAM tier alone was too timid.
capacity_ct_budget() {
  local budget=$((${1:-0} * 1048576 / 10 / 300)) ct=65536
  while ((ct * 2 <= budget && ct < 4194304)); do ct=$((ct * 2)); done
  printf '%d' "$ct"
}

capacity_conntrack_ram_mb() {
  # ~300 bytes per conntrack entry, worst case (table full).
  printf '%d' $((ST_CONNTRACK * 300 / 1048576))
}

# capacity_warning — an honest RAM-math warning when the estimated need
# (conntrack + ~0.5 MB proxy userspace per online user) crowds >75% of RAM.
capacity_warning() {
  ((ST_EXPECTED_USERS > 0)) || return 0
  local ram_mb ct_mb proxy_mb need_mb
  ram_mb="$(mem_total_mb)"
  ct_mb=$((ST_CONNTRACK * 300 / 1048576))
  proxy_mb=0
  role_any proxy utunnel && proxy_mb=$((ST_EXPECTED_USERS / 2))
  need_mb=$((ct_mb + proxy_mb))
  if ((ram_mb > 0 && need_mb > ram_mb * 3 / 4)); then
    printf 'estimated need ~%d MB (conntrack %d + userspace ~%d) vs %d MB RAM — OOM risk at peak. Split users across nodes or add RAM (rule of thumb: ~8 GB per 10k proxy users).' \
      "$need_mb" "$ct_mb" "$proxy_mb" "$ram_mb"
  fi
  return 0
}
