# shellcheck shell=bash
# ============================================================================
# engine/roles.sh — what this server DOES, as a composable set of roles.
#
# pre-2.4.5 forced one exclusive profile per host; real servers are mixed (an Xray
# node that also relays a GRE tunnel, a WireGuard host with an x-ui panel).
# 2.4.5 detects every role that applies and lets the policy engine combine
# them. Detection is DATA, not code: adding a new engine is one line in
# ST_ENGINE_SIGNATURES (see docs/ROLES.md).
# ============================================================================

# Canonical order (also the display order).
readonly -a ST_ROLE_IDS=(proxy panel vpn tunnel relay utunnel web db general)

# Format: id;title;what it covers
readonly -a ST_ROLE_CATALOG=(
  'proxy;Proxy core / node;Xray, sing-box, Hysteria2, TUIC, Marzban/Pasarguard/Remnawave nodes, x-ui, Hiddify'
  'panel;Panel host;Marzban, Marzneshin, Pasarguard, Remnawave dashboards (database + web, little traffic)'
  'vpn;Routed VPN;WireGuard, AmneziaWG, OpenVPN, OpenConnect, IPsec, SoftEther, L2TP, Tailscale'
  'tunnel;Kernel tunnel endpoint;GRE, IPIP, SIT/6to4, ip6tnl, VXLAN, Geneve, FOU/GUE'
  'relay;NAT relay / forwarder;iptables/nftables DNAT that forwards ports to another server'
  'utunnel;Userspace tunnel;Backhaul, Rathole, gost, frp, Chisel, WaterWall, udp2raw, kcptun, Phantun, realm'
  'web;Web server / reverse proxy;nginx, Angie, OpenResty, Caddy, Apache, HAProxy, Traefik, Envoy (sites, bots behind a proxy, L4 balancers)'
  'db;Database / cache;MySQL, MariaDB, PostgreSQL, Redis, Valkey, MongoDB, ClickHouse'
  'general;General server;nothing VPN-specific detected — complete general-purpose tuning'
)

# Format: role;engine label;source;ERE (case-insensitive)
#   source p = basename of a running process (whole-name match)
#   source c = running container name or image (substring match)
#   source u = running systemd service name (whole-name match)
readonly -a ST_ENGINE_SIGNATURES=(
  'proxy;Xray;p;xray|v2ray'
  'proxy;sing-box;p;sing-box'
  'proxy;Hysteria;p;hysteria2?'
  'proxy;TUIC;p;tuic(-server)?'
  'proxy;Juicity;p;juicity-server'
  'proxy;Trojan;p;trojan(-go)?'
  'proxy;mihomo;p;mihomo|clash-meta'
  'proxy;x-ui;p;x-ui|3x-ui'
  'proxy;s-ui;p;s-ui'
  'proxy;Marzban node;c;marzban[-_]?node|marznode'
  'proxy;Pasarguard node;c;pg[-_]?node|pasarguard[-_]?node'
  'proxy;Remnawave node;c;remnanode|remnawave[-_]?node'
  'proxy;Hiddify;c;hiddify'
  'proxy;x-ui;c;x-ui'
  'proxy;sing-box;c;sing-?box'
  'proxy;Hysteria;c;hysteria'
  'vpn;WireGuard;u;wg-quick@.+'
  'vpn;AmneziaWG;u;awg-quick@.+'
  'vpn;AmneziaWG;p;amneziawg-go'
  'vpn;OpenVPN;u;openvpn(-server|-client)?@.+'
  'vpn;OpenVPN;p;openvpn'
  'vpn;OpenConnect;p;ocserv'
  'vpn;IPsec;p;charon|charon-systemd'
  'vpn;SoftEther;p;vpnserver'
  'vpn;L2TP;p;xl2tpd'
  'vpn;Tailscale;p;tailscaled'
  'vpn;ZeroTier;p;zerotier-one'
  'vpn;tinc;p;tincd'
  'vpn;wg-easy;c;wg-easy'
  'vpn;WGDashboard;c;wgdashboard'
  'vpn;Amnezia;c;amnezia'
  'vpn;OpenVPN;c;openvpn'
  'utunnel;Backhaul;p;backhaul'
  'utunnel;Rathole;p;rathole'
  'utunnel;gost;p;gost'
  'utunnel;frp;p;frps|frpc'
  'utunnel;Chisel;p;chisel'
  'utunnel;WaterWall;p;waterwall'
  'utunnel;udp2raw;p;udp2raw.*'
  'utunnel;kcptun;p;kcptun.*|server_linux_(amd64|arm64)|client_linux_(amd64|arm64)'
  'utunnel;Phantun;p;phantun(_server|_client)?'
  'utunnel;realm;p;realm'
  'utunnel;dnstt;p;dnstt-server'
  'utunnel;Backhaul;c;backhaul'
  'utunnel;Rathole;c;rathole'
  'utunnel;gost;c;gost'
  'utunnel;frp;c;frps|frpc'
  'web;nginx;p;nginx|angie|openresty'
  'web;Caddy;p;caddy'
  'web;Apache;p;apache2|httpd'
  'web;HAProxy;p;haproxy'
  'web;Traefik;p;traefik'
  'web;Envoy;p;envoy'
  'db;MySQL;p;mysqld'
  'db;MariaDB;p;mariadbd'
  'db;PostgreSQL;p;postgres|postmaster'
  'db;Redis;p;redis-server'
  'db;Valkey;p;valkey-server'
  'db;MongoDB;p;mongod'
  'db;ClickHouse;p;clickhouse-server'
)

ST_ROLES=''        # space separated, canonical order
ST_ROLES_SOURCE='' # auto-detected | config | cli | manual
ST_DETECTED_ROLES=''
ST_ENGINES=() # "role|label", deduplicated

_roles_add_engine() { # _roles_add_engine ROLE LABEL
  local e
  for e in "${ST_ENGINES[@]-}"; do
    [[ $e == "$1|$2" ]] && return 0
  done
  ST_ENGINES+=("$1|$2")
}

# _roles_panel_containers — panel dashboards are recognised by name, but a
# NODE image name contains the panel name too ("marzban-node"), so node
# lines are excluded before matching.
_roles_panel_containers() {
  [[ -n $ST_F_CONTAINERS ]] || return 1
  grep -viE 'node' <<<"$ST_F_CONTAINERS" | grep -qiE 'marzban|marzneshin|pasarguard|remnawave'
}

_roles_tunnel_label() {
  case "$1" in
    gre | gretap | erspan) printf 'GRE' ;;
    ip6gre | ip6gretap) printf 'GRE over IPv6' ;;
    ipip) printf 'IPIP' ;;
    sit) printf 'SIT/6to4' ;;
    ip6tnl) printf 'ip6tnl' ;;
    vxlan) printf 'VXLAN' ;;
    geneve) printf 'Geneve' ;;
    *) printf '%s' "$1" ;;
  esac
}

# roles_detect — fill ST_ENGINES and ST_DETECTED_ROLES from the facts.
roles_detect() {
  facts_collect
  ST_ENGINES=()
  local entry role label src re t name kind _mtu _remote encap

  for entry in "${ST_ENGINE_SIGNATURES[@]}"; do
    IFS=';' read -r role label src re <<<"$entry"
    case "$src" in
      p) [[ -n $ST_F_PROCS ]] && grep -qiE "^(${re})$" <<<"$ST_F_PROCS" && _roles_add_engine "$role" "$label" ;;
      c) [[ -n $ST_F_CONTAINERS ]] && grep -qiE "$re" <<<"$ST_F_CONTAINERS" && _roles_add_engine "$role" "$label" ;;
      u) [[ -n $ST_F_UNITS ]] && grep -qiE "^(${re})$" <<<"$ST_F_UNITS" && _roles_add_engine "$role" "$label" ;;
    esac
  done
  _roles_panel_containers && _roles_add_engine panel 'Panel'

  for t in "${ST_F_TUNNELS[@]-}"; do
    [[ -n $t ]] || continue
    IFS='|' read -r name kind _mtu _remote encap <<<"$t"
    case "$kind" in
      wireguard) _roles_add_engine vpn 'WireGuard' ;;
      amneziawg) _roles_add_engine vpn 'AmneziaWG' ;;
      tun) : ;; # a tun device belongs to a userspace engine detected above
      *) _roles_add_engine tunnel "$(_roles_tunnel_label "$kind")${encap:+ (+${encap^^})}" ;;
    esac
  done

  if [[ -n $ST_F_DNAT_REMOTE ]]; then
    _roles_add_engine relay "NAT relay ($(wc -l <<<"$ST_F_DNAT_REMOTE" | tr -d ' ') destination(s))"
  fi

  local found='' id e
  for id in "${ST_ROLE_IDS[@]}"; do
    for e in "${ST_ENGINES[@]-}"; do
      [[ ${e%%|*} == "$id" ]] && {
        found+="${found:+ }${id}"
        break
      }
    done
  done
  ST_DETECTED_ROLES="${found:-general}"
  log_debug "roles detected: ${ST_DETECTED_ROLES} (engines: $(join_by ', ' "${ST_ENGINES[@]-}"))"
  return 0
}

# roles_normalize LIST — validate a comma/space list against the catalog and
# print it in canonical order. Non-zero (and nothing printed) on an unknown id.
roles_normalize() {
  local -A wanted=()
  local r id out=''
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    case "$r" in
      proxy | panel | vpn | tunnel | relay | utunnel | web | db | general) wanted[$r]=1 ;;
      *) return 1 ;;
    esac
  done < <(ports_split "$1")
  for id in "${ST_ROLE_IDS[@]}"; do
    [[ -n ${wanted[$id]:-} ]] && out+="${out:+ }${id}"
  done
  [[ -n $out ]] || return 1
  # "general" only means something on its own.
  [[ $out == *' '* ]] && out="${out/ general/}"
  printf '%s' "$out"
}

# roles_from_profile NAME — pre-2.4.5 profile names keep working on the CLI.
roles_from_profile() {
  case "$1" in
    general) printf 'general' ;;
    vpn-node | node | proxy) printf 'proxy' ;;
    wireguard | vpn) printf 'vpn' ;;
    panel) printf 'panel' ;;
    relay | forwarder) printf 'relay tunnel' ;;
    tunnel) printf 'tunnel' ;;
    utunnel) printf 'utunnel' ;;
    full) printf 'proxy vpn tunnel relay utunnel' ;;
    *) return 1 ;;
  esac
}

# roles_resolve [CLI_ROLES] — the final role set: CLI > config > detection.
roles_resolve() {
  local cli="${1:-}" cfg norm
  roles_detect
  if [[ -n $cli ]]; then
    norm="$(roles_normalize "$cli")" || die "Invalid role list '${cli}' — valid: $(join_by ', ' "${ST_ROLE_IDS[@]}")."
    ST_ROLES="$norm"
    ST_ROLES_SOURCE='cli'
    return 0
  fi
  cfg="$(config_get roles)"
  if [[ $cfg != auto && -n $cfg ]]; then
    if norm="$(roles_normalize "$cfg")"; then
      ST_ROLES="$norm"
      ST_ROLES_SOURCE='config'
      return 0
    fi
    log_warn "Ignoring invalid 'roles=${cfg}' in ${ST_CONFIG_FILE}."
  fi
  ST_ROLES="$ST_DETECTED_ROLES"
  ST_ROLES_SOURCE='auto-detected'
  return 0
}

role_has() { [[ " ${ST_ROLES} " == *" $1 "* ]]; }

# roles_only ROLE... — 0 when every active role is one of ROLE...
roles_only() {
  local r
  local -a active=()
  IFS=' ' read -ra active <<<"$ST_ROLES"
  for r in "${active[@]-}"; do
    [[ " $(join_sp "$@") " == *" ${r} "* ]] || return 1
  done
  return 0
}

# engine_detected LABEL — 0 when an engine with that label was detected.
engine_detected() {
  local e
  for e in "${ST_ENGINES[@]-}"; do
    [[ ${e#*|} == "$1" ]] && return 0
  done
  return 1
}

# role_any ROLE... — 0 when at least one of the roles is active.
role_any() {
  local r
  for r in "$@"; do role_has "$r" && return 0; done
  return 1
}

roles_summary() {
  local -a r=()
  IFS=' ' read -ra r <<<"$ST_ROLES"
  join_by ', ' "${r[@]-}"
}

# engines_summary [ROLE] — "Xray, GRE" for all engines (or one role's).
# shellcheck disable=SC2120 # the ROLE filter is optional by design
engines_summary() {
  local e out=()
  for e in "${ST_ENGINES[@]-}"; do
    [[ -n $e ]] || continue
    [[ -z ${1:-} || ${e%%|*} == "$1" ]] && out+=("${e#*|}")
  done
  ((${#out[@]})) || {
    printf 'none'
    return 0
  }
  join_by ', ' "${out[@]}"
}

role_title() {
  local entry id title _desc
  for entry in "${ST_ROLE_CATALOG[@]}"; do
    IFS=';' read -r id title _desc <<<"$entry"
    [[ $id == "$1" ]] && printf '%s' "$title"
  done
  return 0
}
