# shellcheck shell=bash
# ============================================================================
# engine/facts.sh — collect everything the planner needs, ONCE per process.
#
# Every later decision (roles, policy, tuners, reports) reads these ST_F_*
# globals instead of re-probing the system, so a run costs one `ps`, one
# `ip -d link`, one firewall dump and one container listing — no matter how
# many modules consult them.
# ============================================================================

ST_FACTS_DONE=0
ST_F_CPUS=1
ST_F_CPU_LIST='' # space separated online CPU ids
ST_F_RAM_MB=0
ST_F_VIRT='unknown'
ST_F_IFACE='' # default-route interface (the underlay)
ST_F_IFACE_MTU='?'
ST_F_RXQ=0
ST_F_TXQ=0
ST_F_DRIVER=''
ST_F_CH_MAX=0       # combined NIC channels the driver allows (0 = not reported)
ST_F_CH_CUR=0       # combined NIC channels in use
ST_F_GRO=''         # on | off | fixed | "" (no ethtool)
ST_F_UDPGRO=''      # rx-udp-gro-forwarding: on | off | fixed | ""
ST_F_PROCS=''       # basenames of every running argv[0], one per line
ST_F_CONTAINERS=''  # "name image" per running container (docker + podman)
ST_F_UNITS=''       # running systemd service names (template instances included)
ST_F_DNAT_REMOTE='' # DNAT destinations on other machines
ST_F_DOCKER=0       # a reachable Docker daemon
ST_F_CONNTRACK=0    # nf_conntrack is loaded (Docker, UFW, stateful rules, NAT)
ST_F_IRQBALANCE=0   # irqbalance is running (it owns interrupt placement)
ST_F_TUNNELS=()     # "name|kind|mtu|remote|encap" per kernel tunnel device

# _facts_tunnels — parse `ip -d -o link show` into ST_F_TUNNELS. The fallback
# devices the tunnel modules create on load (gre0, tunl0, sit0, …) carry no
# traffic and are skipped.
_facts_tunnels() {
  ST_F_TUNNELS=()
  has_cmd ip || return 0
  local out line name kind mtu remote encap
  out="$(ip -d -o link show 2>/dev/null)" || return 0
  while IFS= read -r line; do
    name="$(awk -F': ' '{print $2; exit}' <<<"$line")"
    name="${name%%@*}"
    case "$name" in
      gre0 | gretap0 | erspan0 | ip6gre0 | ip6tnl0 | sit0 | tunl0 | ip_vti0 | ip6_vti0 | '') continue ;;
    esac
    kind="$(grep -oE ' (gre|gretap|ip6gre|ip6gretap|ipip|sit|ip6tnl|vxlan|geneve|wireguard|amneziawg|erspan) ' <<<"$line" | head -n1 | tr -d ' ')" || kind=''
    if [[ -z $kind ]] && grep -qE ' tun type tun ' <<<"$line"; then
      kind='tun'
    fi
    [[ -n $kind ]] || continue
    mtu="$(grep -oE ' mtu [0-9]+' <<<"$line" | head -n1 | awk '{print $2}')" || mtu=''
    remote="$(grep -oE ' remote [0-9a-fA-F:.]+' <<<"$line" | head -n1 | awk '{print $2}')" || remote=''
    encap="$(grep -oE ' encap (fou|gue) ' <<<"$line" | head -n1 | awk '{print $2}')" || encap=''
    ST_F_TUNNELS+=("${name}|${kind}|${mtu:-?}|${remote}|${encap}")
  done <<<"$out"
  return 0
}

_facts_processes() {
  local out
  out="$(ps -eo args= 2>/dev/null)" || out=''
  ST_F_PROCS="$(awk '{n = $1; sub(/.*\//, "", n); sub(/:$/, "", n); if (n != "") print n}' <<<"$out" | sort -u)"
}

# _facts_containers — bounded: a wedged daemon must not hang the tool.
_facts_containers() {
  local engine out=''
  ST_F_CONTAINERS=''
  ST_F_DOCKER=0
  for engine in docker podman; do
    has_cmd "$engine" || continue
    if out="$(run_bounded 8 "$engine" ps --format '{{.Names}} {{.Image}}' 2>/dev/null)"; then
      # The docker CLI may be podman's shim; only a real dockerd has this socket.
      [[ $engine == docker && -S /var/run/docker.sock ]] && ST_F_DOCKER=1
    else
      out=''
    fi
    [[ -n $out ]] && ST_F_CONTAINERS+="${out}"$'\n'
  done
  return 0
}

_facts_units() {
  ST_F_UNITS=''
  has_cmd systemctl || return 0
  local out
  out="$(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null)" || return 0
  ST_F_UNITS="$(awk '{sub(/\.service$/, "", $1); print $1}' <<<"$out")"
}

# facts_refresh_nic — re-read the uplink's queues, channels and offloads
# (also called after the NIC tuner changed the channel count).
facts_refresh_nic() {
  local max cur
  [[ -n $ST_F_IFACE ]] || return 0
  ST_F_RXQ="$(net_iface_queues "$ST_F_IFACE" rx)"
  ST_F_TXQ="$(net_iface_queues "$ST_F_IFACE" tx)"
  IFS=' ' read -r max cur <<<"$(net_channels "$ST_F_IFACE")"
  ST_F_CH_MAX="${max:-0}"
  ST_F_CH_CUR="${cur:-0}"
  ST_F_GRO="$(net_offload "$ST_F_IFACE" gro)"
  ST_F_UDPGRO="$(net_offload "$ST_F_IFACE" rx-udp-gro-forwarding)"
  return 0
}

# facts_collect [force] — fill every ST_F_* global (cached).
facts_collect() {
  [[ ${1:-} == force ]] && ST_FACTS_DONE=0
  ((ST_FACTS_DONE)) && return 0

  ST_F_CPU_LIST="$(cpu_online_list | paste -sd' ' -)"
  ST_F_CPUS="$(cpu_cores)"
  ST_F_RAM_MB="$(mem_total_mb)"
  ST_F_VIRT="$(detect_virt)"

  ST_F_IFACE="$(net_default_iface)" || ST_F_IFACE=''
  if [[ -n $ST_F_IFACE ]]; then
    ST_F_IFACE_MTU="$(net_iface_mtu "$ST_F_IFACE")"
    ST_F_DRIVER="$(net_iface_driver "$ST_F_IFACE")"
    facts_refresh_nic
  fi

  _facts_processes
  _facts_containers
  _facts_units
  _facts_tunnels
  ST_F_DNAT_REMOTE="$(fw_dnat_remote_dests)" || ST_F_DNAT_REMOTE=''
  ST_F_CONNTRACK=0
  [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]] && ST_F_CONNTRACK=1
  ST_F_IRQBALANCE=0
  grep -qx 'irqbalance' <<<"$ST_F_PROCS" && ST_F_IRQBALANCE=1

  ST_FACTS_DONE=1
  log_debug "facts: cpus=${ST_F_CPUS} iface=${ST_F_IFACE} rxq=${ST_F_RXQ} txq=${ST_F_TXQ} tunnels=${#ST_F_TUNNELS[@]} docker=${ST_F_DOCKER} conntrack=${ST_F_CONNTRACK}"
  return 0
}

# facts_tunnel_kinds — distinct tunnel kinds present, one per line.
facts_tunnel_kinds() {
  local t kind
  for t in "${ST_F_TUNNELS[@]-}"; do
    [[ -n $t ]] || continue
    IFS='|' read -r _ kind _ _ _ <<<"$t"
    printf '%s\n' "$kind"
  done | sort -u
}

# facts_has_entropyless_tunnel — 0 when a GRE/IPIP-style tunnel without
# UDP (FOU/GUE) encapsulation exists. Such packets carry no L4 ports in the
# outer header, so the receiving NIC's RSS hashes every packet of a peer pair
# onto ONE hardware queue — the classic "one core at 100%" on tunnel relays.
facts_has_entropyless_tunnel() {
  local t name kind mtu remote encap
  for t in "${ST_F_TUNNELS[@]-}"; do
    [[ -n $t ]] || continue
    IFS='|' read -r name kind mtu remote encap <<<"$t"
    case "$kind" in
      gre | gretap | ip6gre | ip6gretap | ipip | sit | ip6tnl | erspan)
        [[ -z $encap ]] && return 0
        ;;
    esac
  done
  return 1
}
