# shellcheck shell=bash
# ============================================================================
# lib/net.sh — network facts and list helpers: address validation, port-list
# arithmetic, interface/queue/qdisc inspection, cached public IP.
#
# The tool runs with a hardened global IFS ($'\n\t' — deliberately no space).
# That makes two everyday bash idioms silently WRONG on space-separated data:
#   for x in ${list//,/ }  -> no split at all; the whole list arrives as one word
#   "${array[*]}"          -> joined with a NEWLINE instead of a space
# Both failed silently in shipped pre-2.4.5 features (a port list became one bogus
# "port"; a generated systemd ExecStart line was split across nine lines).
# ports_split and join_sp are the supported way to do each.
# ============================================================================

is_valid_ipv4() {
  local ip="$1" octet
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  for octet in $ip; do
    ((10#$octet <= 255)) || return 1
  done
  return 0
}

# is_valid_ipv6 — hex groups separated by colons, at most one "::"
# compression, 2..8 groups. Rejects the "anything with a colon" trap.
is_valid_ipv6() {
  local ip="$1"
  [[ $ip == *:* && $ip != *:::* ]] || return 1
  local rest="${ip//::/}"
  ((${#ip} - ${#rest} <= 2)) || return 1
  [[ $ip =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]] || return 1
  if [[ $ip != *::* ]]; then
    local IFS=':' groups
    read -ra groups <<<"$ip"
    ((${#groups[@]} == 8)) || return 1
  fi
  return 0
}

is_valid_ip() { is_valid_ipv4 "$1" || is_valid_ipv6 "$1"; }

# --- Lists ------------------------------------------------------------------

# ports_split LIST — one token per line from a "80,443 1000-1002" list.
ports_split() {
  local -a items=()
  [[ -n ${1:-} ]] || return 0
  IFS=$', \t' read -ra items <<<"$1"
  ((${#items[@]} > 0)) && printf '%s\n' "${items[@]}"
  return 0
}

# join_sp WORD... — the words joined by single spaces (argv-shaped strings).
join_sp() {
  local IFS=' '
  printf '%s' "$*"
}

# join_by SEP WORD... — the words joined by SEP.
join_by() {
  local sep="$1" out='' w
  shift
  for w in "$@"; do out+="${out:+$sep}${w}"; done
  printf '%s' "$out"
}

# ports_expand LIST — "80,1000-1002,2000:2001" -> one port per line, sorted.
# Accepts both "a-b" (sysctl) and "a:b" (iptables) range syntax.
ports_expand() {
  local item low high
  {
    while IFS= read -r item; do
      item="${item//:/-}"
      if [[ $item =~ ^([0-9]+)-([0-9]+)$ ]]; then
        low="${BASH_REMATCH[1]}"
        high="${BASH_REMATCH[2]}"
        ((high > 65535)) && high=65535
        while ((low <= high)); do
          printf '%s\n' "$low"
          low=$((low + 1))
        done
      elif [[ $item =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$item"
      fi
    done < <(ports_split "$1")
  } | sort -un
}

# ports_collapse — read ports (one per line) on stdin, print "a,b-c" ranges.
ports_collapse() {
  grep -E '^[0-9]+$' | sort -un | awk '
    NR == 1 { start = last = $1; next }
    $1 == last + 1 { last = $1; next }
    { printf "%s%s", sep, (start == last ? start : start "-" last); sep = ","; start = last = $1 }
    END { if (NR) printf "%s%s", sep, (start == last ? start : start "-" last) }'
}

# ports_subtract SET — read candidate ports (one per line) from stdin and
# print those NOT in SET (newline-separated). Replaces `comm`, which needs
# BYTE order while ports are in NUMERIC order ("8443" sorts before "51820"
# numerically but after it bytewise) — comm silently returned wrong results.
ports_subtract() {
  awk -v set="$1" '
    BEGIN { n = split(set, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") m[a[i]] = 1 }
    !($1 in m)'
}

# ports_covered WANTED HAVE — 0 when every port in WANTED is also in HAVE.
ports_covered() {
  local wanted have missing
  wanted="$(ports_expand "$1")"
  have="$(ports_expand "$2")"
  [[ -n $wanted ]] || return 0
  missing="$(ports_subtract "$have" <<<"$wanted")"
  [[ -z $missing ]]
}

# port_in_list PORT LIST — LIST holds numbers and "a-b" ranges.
port_in_list() {
  local port="$1" item
  while IFS= read -r item; do
    if [[ $item =~ ^([0-9]+)-([0-9]+)$ ]]; then
      ((port >= BASH_REMATCH[1] && port <= BASH_REMATCH[2])) && return 0
    elif [[ $item == "$port" ]]; then
      return 0
    fi
  done < <(ports_split "$2")
  return 1
}

# --- Listeners --------------------------------------------------------------

# ss_listen_ports SS_OUTPUT — ports of listeners reachable from OFF the box.
# Loopback-bound listeners are excluded, and that single rule is what
# separates a configured service port from a random internal one: Xray keeps
# internal plumbing on 127.0.0.1 with a port the kernel picks afresh on every
# start, while every port that serves clients is bound to a wildcard or a
# real address and comes back unchanged (v2.4.4).
ss_listen_ports() {
  awk 'NR > 1 {
        addr = $4
        port = addr
        sub(/.*:/, "", port)
        sub(/:[^:]*$/, "", addr)
        gsub(/[][]/, "", addr)
        if (addr ~ /^127\./ || addr == "::1" || addr ~ /^::ffff:127\./ || addr ~ /%lo$/) next
        if (port ~ /^[0-9]+$/) print port
      }' <<<"$1" | sort -un
}

# wg_listen_ports — ports WireGuard/AmneziaWG listen on, asked of the tools
# themselves (authoritative, unlike inspecting sockets).
wg_listen_ports() {
  local bin out
  for bin in wg awg; do
    has_cmd "$bin" || continue
    out="$("$bin" show all listen-port 2>/dev/null)" || continue
    awk '$NF ~ /^[0-9]+$/ {print $NF}' <<<"$out"
  done | sort -un
  return 0
}

# listening_service_ports — REAL service ports inside the ephemeral range
# (10240-65535). Only unambiguous evidence counts: externally-bound TCP
# listeners and the WireGuard listen port. Generic UDP listeners are NOT
# auto-detected: a userspace proxy opens one UNCONN socket per UDP session,
# indistinguishable from a service and different on every run (v2.4.3). A
# UDP-only service is pinned with the `reserved_ports` config key instead.
listening_service_ports() {
  local tcp
  {
    if has_cmd ss; then
      tcp="$(ss -tln 2>/dev/null)" || tcp=''
      ss_listen_ports "$tcp"
    fi
    wg_listen_ports
  } | awk '$1 + 0 >= 10240 && $1 + 0 <= 65535' | sort -un
}

# --- Interfaces -------------------------------------------------------------

# net_default_iface / net_default_gw — read from the default route. Captured
# first, parsed from a here-string: piping into an awk that exits early would
# SIGPIPE `ip`, and pipefail would turn a good answer into a failure.
net_default_iface() {
  has_cmd ip || return 0
  local route
  route="$(ip route show default 2>/dev/null)" || return 0
  awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}' <<<"$route"
}

net_default_gw() {
  has_cmd ip || return 0
  local route
  route="$(ip route show default 2>/dev/null)" || return 0
  awk '{for (i = 1; i < NF; i++) if ($i == "via") {print $(i + 1); exit}}' <<<"$route"
}

# net_route_dev IP — the device the kernel would use to reach IP.
net_route_dev() {
  has_cmd ip || return 0
  local out
  out="$(ip route get "$1" 2>/dev/null)" || return 0
  awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}' <<<"$out"
}

# net_dns_capable_links — links worth carrying a DNS override: everything
# that is up, minus loopback, containers, bridges and tunnels.
net_dns_capable_links() {
  has_cmd ip || return 0
  local out
  out="$(ip -o link show up 2>/dev/null)" || return 0
  awk -F': ' '{print $2}' <<<"$out" | sed 's/@.*//' |
    grep -vE '^(lo|docker[0-9]*|br-|veth|cni|virbr|kube|podman|gre|ipip|sit|tun|wg|awg|vxlan)' || return 0
}

net_iface_mtu() {
  local mtu=''
  [[ -r /sys/class/net/$1/mtu ]] && mtu="$(cat "/sys/class/net/$1/mtu" 2>/dev/null)"
  printf '%s' "${mtu:-?}"
}

# net_iface_queues IFACE rx|tx — number of hardware queues the kernel exposes.
net_iface_queues() {
  local dir="/sys/class/net/$1/queues" n
  [[ -d $dir ]] || {
    printf '0'
    return 0
  }
  n="$(find "$dir" -maxdepth 1 -name "${2}-*" -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
  printf '%s' "${n:-0}"
}

net_iface_driver() {
  local link=''
  link="$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null)" || link=''
  if [[ -n $link ]]; then
    printf '%s' "${link##*/}"
  else
    printf 'virtual'
  fi
}

# ST_RX_IRQ_AWK — selects the receive interrupt vectors of interface i
# (device d) from /proc/interrupts and prints their IRQ numbers in order.
# Receive vectors only: virtio "virtio0-input.0", most others "<if>-TxRx-0",
# "<if>-rx-0" or "<driver>-<if>-TxRx-0"; a pure TX vector does not run the
# receive path. Shared by net_rx_irqs and the generated boot script, so the
# boot-time spread finds exactly the vectors the live run planned for.
# shellcheck disable=SC2016 # awk program, expanded by awk
readonly ST_RX_IRQ_AWK='{ n = $NF; irq = $1; sub(/:$/, "", irq) }
irq ~ /^[0-9]+$/ && tolower(n) ~ /(input|rx)/ &&
  (index(n, i "-") == 1 || index(n, i "_") == 1 || index(n, i ".") == 1 || index(n, "-" i "-") > 0 ||
   (d != "" && (index(n, d "-") == 1 || index(n, d "_") == 1 || index(n, d ".") == 1))) { print irq }'

# net_rx_irqs IFACE — "IRQ<TAB>effective CPU list" for every receive vector
# of IFACE, in queue order ("" when the driver's naming is not recognised).
net_rx_irqs() {
  local iface="$1" dev='' text irq list
  [[ -r /proc/interrupts ]] || return 0
  dev="$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null)" || dev=''
  dev="${dev##*/}"
  text="$(cat /proc/interrupts 2>/dev/null)" || return 0
  while IFS= read -r irq; do
    [[ -n $irq ]] || continue
    list="$(cat "/proc/irq/${irq}/effective_affinity_list" 2>/dev/null)" || list=''
    [[ -n $list ]] || list="$(cat "/proc/irq/${irq}/smp_affinity_list" 2>/dev/null)" || list=''
    printf '%s\t%s\n' "$irq" "$list"
  done < <(awk -v i="$iface" -v d="$dev" "$ST_RX_IRQ_AWK" <<<"$text")
  return 0
}

# net_root_qdisc IFACE — "kind handle" of the root qdisc ("mq 0:", "fq 8001:").
net_root_qdisc() {
  has_cmd tc || return 0
  local out
  out="$(tc qdisc show dev "$1" root 2>/dev/null)" || return 0
  awk 'NR == 1 {print $2, $3; exit}' <<<"$out"
}

# qdisc_supported NAME — real probe: attach the qdisc to loopback and remove
# it again (loopback traffic is unaffected, the default is restored at once).
# Dry-run must not touch anything, so it falls back to module inspection.
qdisc_supported() {
  local name="$1"
  has_cmd tc || return 1
  if ((ST_DRY_RUN)); then
    case "$name" in
      fq | fq_codel | pfifo_fast) return 0 ;;
      *) has_cmd modinfo && modinfo -n "sch_${name}" >/dev/null 2>&1 ;;
    esac
    return
  fi
  tc qdisc add dev lo root "$name" 2>/dev/null || return 1
  tc qdisc del dev lo root 2>/dev/null ||
    log_warn "Could not detach the probe qdisc from loopback."
  return 0
}

# --- Public IP (fetched once per process, then cached — menu redraws must
# --- never block on network calls).
ST_CACHE_IP4=''
ST_CACHE_IP6=''

_net_fetch() { # _net_fetch 4|6 URL
  has_cmd curl || return 1
  curl "-$1" -fsS --max-time 2 "$2" 2>/dev/null | tr -d '[:space:]'
}

net_public_ip4() {
  if [[ -z $ST_CACHE_IP4 ]]; then
    local ip='' url
    for url in 'https://api.ipify.org' 'https://ifconfig.me/ip'; do
      ip="$(_net_fetch 4 "$url")" || ip=''
      is_valid_ipv4 "$ip" && break
      ip=''
    done
    if [[ -z $ip ]] && has_cmd ip; then
      ip="$(ip -4 addr show scope global 2>/dev/null |
        awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')" || ip=''
    fi
    ST_CACHE_IP4="${ip:-N/A}"
  fi
  printf '%s' "$ST_CACHE_IP4"
}

net_public_ip6() {
  if [[ -z $ST_CACHE_IP6 ]]; then
    local ip='' url
    for url in 'https://api64.ipify.org' 'https://ifconfig.me/ip'; do
      ip="$(_net_fetch 6 "$url")" || ip=''
      is_valid_ipv6 "$ip" && break
      ip=''
    done
    if [[ -z $ip ]] && has_cmd ip; then
      ip="$(ip -6 addr show scope global 2>/dev/null |
        awk '/inet6 / {sub(/\/.*/, "", $2); print $2; exit}')" || ip=''
    fi
    ST_CACHE_IP6="${ip:-N/A}"
  fi
  printf '%s' "$ST_CACHE_IP6"
}

# --- ethtool (installed as a prerequisite; every reader degrades to "") ------

# net_channels IFACE — "MAX CUR" combined channels ("" when not reported).
net_channels() {
  has_cmd ethtool || return 0
  local out
  out="$(ethtool -l "$1" 2>/dev/null)" || return 0
  awk '/^Pre-set/ {s = 1} /^Current/ {s = 2}
       /^Combined:/ { if (s == 1) max = $2; else if (s == 2) cur = $2 }
       END { if (max ~ /^[0-9]+$/ && cur ~ /^[0-9]+$/) print max, cur }' <<<"$out"
}

# _net_offload_name KEY — ethtool -K short name to its -k display name.
_net_offload_name() {
  case "$1" in
    gro) printf 'generic-receive-offload' ;;
    *) printf '%s' "$1" ;;
  esac
}

# net_offload IFACE KEY — "on", "off", "fixed" (cannot change) or "".
net_offload() {
  has_cmd ethtool || return 0
  local out name
  out="$(ethtool -k "$1" 2>/dev/null)" || return 0
  name="$(_net_offload_name "$2")"
  awk -v n="${name}:" '$1 == n { print ($3 == "[fixed]" ? "fixed" : $2); exit }' <<<"$out"
}

# ethtool_read IFACE KEY / ethtool_write IFACE KEY VALUE — the two ethtool
# knobs ServerTools manages: "channels" (combined count) and offloads.
ethtool_read() {
  local max cur
  if [[ $2 == channels ]]; then
    IFS=' ' read -r max cur <<<"$(net_channels "$1")"
    printf '%s' "${cur:-}"
  else
    net_offload "$1" "$2"
  fi
}

ethtool_write() {
  has_cmd ethtool || return 1
  if [[ $2 == channels ]]; then
    ethtool -L "$1" combined "$3" 2>>"$ST_LOG_FILE"
  else
    ethtool -K "$1" "$2" "$3" 2>>"$ST_LOG_FILE"
  fi
}
