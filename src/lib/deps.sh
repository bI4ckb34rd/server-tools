# shellcheck shell=bash
# ============================================================================
# lib/deps.sh — prerequisites: detect what is missing and install it with the
# host's package manager, so every feature runs at full strength (ethtool for
# NIC channels/offloads, nftables for the fast path, dig for DNS tests, …).
#
# Policy (config `install_deps`, CLI `--no-install`):
#   auto   install missing packages, then say exactly what was installed
#   never  never install; features degrade to their built-in fallbacks
# Installs use --no-install-recommends (apt) to stay lean. Installed packages
# are recorded in ST_DEPS_RECORD for transparency; rollback does not remove
# them (other software may depend on them by then).
# ============================================================================

readonly ST_DEPS_RECORD="${ST_LIB_DIR}/installed-packages"
ST_OPT_NO_INSTALL=0
ST_DEPS_INSTALLED=() # packages installed by this run

# Format: command;group;apt;dnf/yum;pacman;what it enables
readonly -a ST_DEPS=(
  'ip;core;iproute2;iproute;iproute2;interfaces, routes, tunnels'
  'tc;core;iproute2;iproute-tc;iproute2;queueing disciplines'
  'ss;core;iproute2;iproute;iproute2;socket listing'
  'sysctl;core;procps;procps-ng;procps-ng;kernel tuning'
  'modprobe;core;kmod;kmod;kmod;kernel modules (BBR, conntrack)'
  'ethtool;core;ethtool;ethtool;ethtool;NIC channels and offloads'
  'iptables;core;iptables;iptables-nft;iptables;MSS clamping, NOTRACK'
  'nft;core;nftables;nftables;nftables;forwarding fast path, nft rules'
  'curl;core;curl;curl;curl;downloads, public IP, self-update'
  'dig;dns;bind9-dnsutils;bind-utils;bind;real DNS latency tests'
  'jq;docker;jq;jq;jq;safe daemon.json merges (Docker hygiene)'
)

deps_pkg_manager() {
  local pm
  for pm in apt-get dnf yum pacman; do
    has_cmd "$pm" && {
      printf '%s' "$pm"
      return 0
    }
  done
  return 0
}

# _deps_pkg_for ENTRY PM — the package name for this package manager.
_deps_pkg_for() {
  local _cmd _group apt dnf pacman _what
  IFS=';' read -r _cmd _group apt dnf pacman _what <<<"$1"
  case "$2" in
    apt-get) printf '%s' "$apt" ;;
    dnf | yum) printf '%s' "$dnf" ;;
    pacman) printf '%s' "$pacman" ;;
  esac
}

# deps_missing GROUP... — "command<TAB>package<TAB>purpose" per missing command.
deps_missing() {
  local entry cmd group _a _d _p what pm want
  want=" $(join_sp "$@") "
  pm="$(deps_pkg_manager)"
  for entry in "${ST_DEPS[@]}"; do
    IFS=';' read -r cmd group _a _d _p what <<<"$entry"
    [[ $want == *" ${group} "* ]] || continue
    has_cmd "$cmd" && continue
    printf '%s\t%s\t%s\n' "$cmd" "$(_deps_pkg_for "$entry" "$pm")" "$what"
  done
}

# deps_ensure GROUP... — install what is missing. 0 nothing missing or all
# installed, 2 skipped by policy / no package manager, 3 some still missing.
deps_ensure() {
  local missing pm
  missing="$(deps_missing "$@")"
  [[ -n $missing ]] || return 0

  local -a pkgs=()
  mapfile -t pkgs < <(awk -F'\t' 'NF && $2 != "" {print $2}' <<<"$missing" | sort -u)
  local cmds
  cmds="$(awk -F'\t' '{printf "%s%s", sep, $1; sep = ", "}' <<<"$missing")"

  if ((ST_DRY_RUN)); then
    log_note "Would install: $(join_sp "${pkgs[@]}") (for ${cmds})."
    return 0
  fi
  if ((ST_OPT_NO_INSTALL)) || [[ "$(config_get install_deps)" == never ]]; then
    log_note "Missing ${cmds} — not installed (install_deps=never); related features use fallbacks."
    return 2
  fi
  pm="$(deps_pkg_manager)"
  if [[ -z $pm || ${#pkgs[@]} -eq 0 ]]; then
    log_note "Missing ${cmds} and no supported package manager — related features use fallbacks."
    return 2
  fi

  log_info "Installing prerequisites via ${pm}: ${pkgs[*]}"
  if ! pkg_install "${pkgs[@]}"; then
    # One bad name (an old release without bind9-dnsutils, say) must not
    # block the rest: retry package by package.
    local p
    for p in "${pkgs[@]}"; do
      pkg_install "$p" || log_warn "Could not install ${p} — see the log."
    done
  fi
  hash -r

  # Record only what actually arrived (its command now exists).
  local cmd pkg _what now_missing
  mkdir -p "$(dirname "$ST_DEPS_RECORD")"
  while IFS=$'\t' read -r cmd pkg _what; do
    if [[ -z $pkg ]] || ! has_cmd "$cmd"; then continue; fi
    [[ " ${ST_DEPS_INSTALLED[*]-} " == *" ${pkg} "* ]] && continue
    ST_DEPS_INSTALLED+=("$pkg")
    grep -qxF "$pkg" "$ST_DEPS_RECORD" 2>/dev/null || printf '%s\n' "$pkg" >>"$ST_DEPS_RECORD"
  done <<<"$missing"
  ((${#ST_DEPS_INSTALLED[@]})) && log_note "Installed: $(join_sp "${ST_DEPS_INSTALLED[@]}")."
  now_missing="$(deps_missing "$@" | cut -f1 | paste -sd, -)"
  if [[ -n $now_missing ]]; then
    log_warn "Still missing after install: ${now_missing} — related features use fallbacks."
    return 3
  fi
  return 0
}
