# shellcheck shell=bash
# ============================================================================
# tuners/tunnel.sh — read-only audit of kernel tunnels (GRE, IPIP, SIT,
# ip6tnl, VXLAN, Geneve, WireGuard, AmneziaWG).
#
# ServerTools never rewrites a tunnel's own configuration — the tunnel
# manager owns it, and a changed MTU on one side only breaks the link. The
# audit instead states what is wrong and what to do, and the policy engine
# compensates where it can (RPS for entropy-less encapsulation, MSS clamping
# for oversized MTUs). See docs/TUNNELS.md.
# ============================================================================

# _tunnel_overhead KIND REMOTE ENCAP — bytes the encapsulation adds on top
# of the inner packet (outer IP + tunnel header [+ UDP for FOU/GUE]).
_tunnel_overhead() {
  local kind="$1" remote="$2" encap="$3" outer=20 o
  [[ $remote == *:* ]] && outer=40
  case "$kind" in
    gre | erspan) o=$((outer + 4)) ;;
    gretap) o=$((outer + 4 + 14)) ;;
    ip6gre) o=$((40 + 4)) ;;
    ip6gretap) o=$((40 + 4 + 14)) ;;
    ipip | sit) o=$outer ;;
    ip6tnl) o=40 ;;
    vxlan | geneve) o=$((outer + 8 + 8 + 14)) ;;
    wireguard | amneziawg) o=$((outer + 8 + 32)) ;;
    *) o=0 ;;
  esac
  case "$encap" in
    fou) o=$((o + 8)) ;;
    gue) o=$((o + 12)) ;;
  esac
  printf '%s' "$o"
}

# tunnel_rows — "name|kind|mtu|max_mtu|verdict|advice" per tunnel.
tunnel_rows() {
  facts_collect
  local t name kind mtu remote encap under dev max verdict advice
  for t in "${ST_F_TUNNELS[@]-}"; do
    [[ -n $t ]] || continue
    IFS='|' read -r name kind mtu remote encap <<<"$t"
    [[ $kind == tun ]] && continue
    dev=''
    [[ -n $remote ]] && dev="$(net_route_dev "$remote")"
    under="$(net_iface_mtu "${dev:-$ST_F_IFACE}")"
    if [[ $under =~ ^[0-9]+$ && $mtu =~ ^[0-9]+$ ]]; then
      max=$((under - $(_tunnel_overhead "$kind" "$remote" "$encap")))
      if ((mtu > max)); then
        verdict=err
        advice="MTU ${mtu} > ${max} (underlay ${under}): oversized packets fragment or black-hole — set MTU ${max} on BOTH ends"
      elif ((mtu < max - 80)); then
        verdict=warn
        advice="MTU ${mtu} wastes $((max - mtu)) bytes per packet (could be ${max}) — fine, just less efficient"
      else
        verdict=ok
        advice="MTU fits the underlay (max ${max})"
      fi
    else
      max='?'
      verdict=idle
      advice='MTU of the tunnel or its underlay unknown'
    fi
    case "$kind" in
      gre | gretap | ip6gre | ip6gretap | ipip | sit | ip6tnl | erspan)
        if [[ -z $encap ]]; then
          advice+="; no L4 ports → one RX queue per peer (RPS compensates; FOU/GUE would let the NIC spread it)"
        fi
        ;;
    esac
    printf '%s|%s|%s|%s|%s|%s\n' "$name" "$kind${encap:++${encap}}" "$mtu" "$max" "$verdict" "$advice"
  done
  return 0
}

# tunnel_audit — the report section (diagnose, plan screen).
tunnel_audit() {
  local rows row name kind mtu max verdict advice
  rows="$(tunnel_rows)"
  [[ -n $rows ]] || {
    ui_step_note idle "No kernel tunnels on this host."
    return 0
  }
  while IFS='|' read -r name kind mtu max verdict advice; do
    [[ -n $name ]] || continue
    ui_step_note "$verdict" "${name} (${kind}, mtu ${mtu}) — ${advice}"
  done <<<"$rows"
  if role_any vpn tunnel relay && ! mss_verify >/dev/null 2>&1; then
    ui_step_note warn "MSS clamping is not active — forwarded TCP into these tunnels will fragment (Quick Optimize enables it)."
  fi
  return 0
}
