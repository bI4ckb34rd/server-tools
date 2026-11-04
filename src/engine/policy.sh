# shellcheck shell=bash
# ============================================================================
# engine/policy.sh — turn roles + facts into concrete tuning decisions.
#
# Tuners never look at roles directly: they read the ST_P_* decisions made
# here, and every decision is recorded with the reason behind it
# (ST_P_WHY), which `--dry-run` and the plan screen print. This is the one
# place where "a GRE relay is not a proxy node" is encoded — the lesson of
# the pre-2.4.5 field report (a relay whose CPU rose after optimisation because it
# was tuned like a proxy node).
# ============================================================================

ST_CC='cubic'
ST_QDISC='fq_codel'
ST_P_LOCAL_TCP=1 # TCP sessions terminate on this host (proxy, panel, ...)
ST_P_FORWARD=0   # the host routes/forwards user traffic
ST_P_FWD_HEAVY=0 # forwarding dominates and nothing terminates TCP locally
ST_P_RPS=0
ST_P_RPS_CPUS='' # space separated CPU ids RPS may steer to
ST_P_RFS=0
ST_P_XPS='keep' # keep | partition
ST_P_MSS=0
ST_P_CHANNELS=0 # combined channel count to set (0 = leave alone)
ST_P_RXQ=0      # RX queues after the channel change (what RPS plans for)
ST_P_GRO=0      # enable GRO
ST_P_UDPGRO=0   # enable rx-udp-gro-forwarding
ST_P_UDP_STREAM=60
ST_P_CONNTRACK=0   # size + time out connection tracking
ST_P_CT_EST=3600   # nf_conntrack_tcp_timeout_established
ST_P_OVERCOMMIT='' # vm.overcommit_memory to set ("" = leave)
ST_P_DIRTY=0       # bounded dirty-page write-back (databases)
ST_P_IRQ_SPREAD=0  # spread the uplink's receive interrupts over CPUs
ST_P_DOCKER=0      # Docker engine hygiene (daemon.json)
ST_P_WHY=()        # "area|decision|reason"

_why() { ST_P_WHY+=("$1|$2|$3"); }

# _policy_cc — congestion control. BBR is loaded when the kernel has it; the
# dry-run path inspects the module without loading it so the preview matches
# what a real run delivers (v2.4.2).
_policy_cc() {
  ST_CC='cubic'
  if ver_ge "$(kernel_base)" "4.9"; then
    if ((ST_DRY_RUN == 0)) && has_cmd modprobe; then
      # An absent module is not fatal: built-in BBR has no module, and the
      # sysctl list below is the real availability check.
      modprobe tcp_bbr 2>/dev/null || log_debug "tcp_bbr module not loadable (may be built in)."
    fi
    if [[ " $(sysctl_get net.ipv4.tcp_available_congestion_control) " == *' bbr'* ]]; then
      ST_CC='bbr'
    elif ((ST_DRY_RUN)) && has_cmd modinfo && modinfo -n tcp_bbr >/dev/null 2>&1; then
      ST_CC='bbr'
    fi
  fi
  if [[ $ST_CC == bbr ]]; then
    _why cc bbr "kernel $(kernel_base) provides BBR — best throughput on lossy long-haul paths"
  else
    _why cc cubic "BBR unavailable on kernel $(kernel_base)"
  fi
}

# _policy_qdisc — fq paces locally generated TCP (what BBR wants). Forwarded
# packets carry no socket, so on a pure forwarder fq is pure per-packet cost:
# fq_codel there is cheaper and still fights bufferbloat.
_policy_qdisc() {
  local wanted
  wanted="$(config_get qdisc)"
  if [[ $wanted != auto ]]; then
    if qdisc_supported "$wanted"; then
      ST_QDISC="$wanted"
      _why qdisc "$wanted" "set in config (qdisc=${wanted})"
      return 0
    fi
    log_warn "Configured qdisc '${wanted}' is not supported by this kernel — choosing automatically."
  fi
  if ((ST_P_LOCAL_TCP)) && [[ $ST_CC == bbr ]]; then
    ST_QDISC='fq'
    _why qdisc fq "TCP terminates locally — fq gives BBR per-flow pacing"
  else
    ST_QDISC='fq_codel'
    if ((ST_P_FWD_HEAVY)); then
      _why qdisc fq_codel "pure forwarder — forwarded packets have no socket to pace, fq would only add per-packet cost"
    else
      _why qdisc fq_codel "no BBR — fq_codel keeps queues short"
    fi
  fi
  if ! qdisc_supported "$ST_QDISC"; then
    log_warn "Kernel does not support ${ST_QDISC} — falling back to fq_codel."
    ST_QDISC='fq_codel'
  fi
}

# policy_irq_cpus IFACE — CPUs that service the NIC's receive interrupts
# (space separated), "" when they cannot be identified with certainty.
policy_irq_cpus() {
  local _irq list cpus=''
  while IFS=$'\t' read -r _irq list; do
    [[ -n $list ]] && cpus+=" $(cpu_list_expand "$list" | paste -sd' ' -)"
  done < <(net_rx_irqs "$1")
  tr ' ' '\n' <<<"$cpus" | grep -E '^[0-9]+$' | sort -un | paste -sd' ' -
  return 0
}

# _policy_channels — use the hardware queues the NIC already offers. Many
# virtio VPS NICs expose several queue pairs but boot with one: raising the
# count lets the hypervisor spread receive work in hardware, which beats
# software steering (no cross-CPU hop). Applied automatically on virtio_net,
# where the change is live and does not reset the link; on other drivers it
# is recommended only (some re-initialise the device).
_policy_channels() {
  local mode want
  ST_P_CHANNELS=0
  ST_P_RXQ="$ST_F_RXQ"
  mode="$(config_get nic_channels)"
  ((ST_F_CH_MAX > 0)) || return 0
  case "$mode" in
    off)
      _why channels keep "disabled in config (nic_channels=off)"
      return 0
      ;;
    auto)
      want=$((ST_F_CH_MAX < ST_F_CPUS ? ST_F_CH_MAX : ST_F_CPUS))
      if ((want <= ST_F_CH_CUR)); then
        _why channels keep "${ST_F_CH_CUR} of ${ST_F_CH_MAX} channels in use — already the most useful count"
        return 0
      fi
      if [[ $ST_F_DRIVER != virtio_net ]]; then
        _why channels keep "${ST_F_CH_CUR} of ${ST_F_CH_MAX} in use; driver ${ST_F_DRIVER} may reset the link — set nic_channels=${want} to raise"
        return 0
      fi
      ;;
    *) want=$((mode < ST_F_CH_MAX ? mode : ST_F_CH_MAX)) ;;
  esac
  ((want > 0 && want != ST_F_CH_CUR)) || return 0
  ST_P_CHANNELS=$want
  ST_P_RXQ=$want
  _why channels "$want" "NIC offers ${ST_F_CH_MAX} queue pairs but uses ${ST_F_CH_CUR} — hardware spreading beats software steering"
}

# _policy_offloads — GRO coalesces a flow's packets before the stack, so
# routing, netfilter and conntrack run once per batch instead of per packet.
# UDP GRO forwarding (kernel ≥ 5.12) extends that to forwarded UDP
# (WireGuard, QUIC, Hysteria) — off by default in the kernel.
_policy_offloads() {
  ST_P_GRO=0
  ST_P_UDPGRO=0
  [[ "$(config_get nic_offloads)" == off ]] && {
    _why offloads keep "disabled in config (nic_offloads=off)"
    return 0
  }
  if [[ $ST_F_GRO == off ]]; then
    ST_P_GRO=1
    _why gro on "GRO is off — every packet would traverse the stack alone"
  fi
  if ((ST_P_FORWARD)) && [[ $ST_F_UDPGRO == off ]]; then
    ST_P_UDPGRO=1
    _why udp-gro on "forwarded UDP (WireGuard/QUIC/Hysteria) is coalesced like TCP"
  fi
  return 0
}

# _policy_rps — software receive steering. Worth it when hardware cannot
# spread: a single RX queue (or one per two+ CPUs), or entropy-less tunnels (GRE/IPIP carry
# no ports, so RSS sends a whole peer pair to one queue). On a forwarder with
# >= 4 CPUs and a single RX queue the interrupt CPU is left out of the mask:
# it already runs the IRQ, GRO and the steering itself, and handing it a
# share of the netfilter work too recreates the hot spot RPS was meant to
# remove.
_policy_rps() {
  local mode cpus_cfg irq left
  mode="$(config_get rps_mode)"
  ST_P_RPS=0
  ST_P_RFS=0
  ST_P_RPS_CPUS="$ST_F_CPU_LIST"

  local rxq="${ST_P_RXQ:-$ST_F_RXQ}"
  if [[ -z $ST_F_IFACE ]] || ((rxq == 0)); then
    _why rps off "no physical uplink with queues found"
    return 0
  fi
  case "$mode" in
    off)
      _why rps off "disabled in config (rps_mode=off)"
      return 0
      ;;
    on) ST_P_RPS=1 && _why rps on "forced in config (rps_mode=on)" ;;
    *)
      if ((ST_F_CPUS < 2)); then
        _why rps off "single CPU — nothing to spread to"
        return 0
      elif ((rxq == 1 || rxq * 2 <= ST_F_CPUS)); then
        # One queue, or at most half the cores receive: software steering
        # pays for its cross-CPU hop. With more queues than that, RSS already
        # spreads well enough and RPS would only add the hop.
        ST_P_RPS=1
        _why rps on "${ST_F_IFACE} has ${rxq} RX queue(s) for ${ST_F_CPUS} CPUs — most cores would never see receive work"
      elif role_has tunnel && facts_has_entropyless_tunnel; then
        ST_P_RPS=1
        _why rps on "GRE/IPIP without FOU carries no L4 ports — hardware RSS puts each tunnel on one queue"
      else
        _why rps off "${ST_F_IFACE} has ${rxq} RX queues for ${ST_F_CPUS} CPUs — hardware RSS already spreads"
        return 0
      fi
      ;;
  esac

  cpus_cfg="$(config_get rps_cpus)"
  if [[ $cpus_cfg != auto ]]; then
    ST_P_RPS_CPUS="$(cpu_list_expand "$cpus_cfg" | paste -sd' ' -)"
    _why rps-cpus "$cpus_cfg" "set in config (rps_cpus)"
  elif ((ST_P_FWD_HEAVY && ST_F_CPUS >= 4 && rxq == 1)); then
    irq="$(policy_irq_cpus "$ST_F_IFACE")"
    left="$(tr ' ' '\n' <<<"$ST_F_CPU_LIST" | ports_subtract "$(tr ' ' '\n' <<<"$irq")" | paste -sd' ' -)"
    if [[ -n $irq && $(wc -w <<<"$left") -ge 2 && $left != "$ST_F_CPU_LIST" ]]; then
      ST_P_RPS_CPUS="$left"
      _why rps-cpus "$left" "forwarder: CPU ${irq} already runs the NIC interrupt — steer the heavy work elsewhere"
    else
      _why rps-cpus all "interrupt CPU not identifiable — steering to every CPU"
    fi
  else
    _why rps-cpus all "steering to every online CPU"
  fi

  # RFS steers a flow to the CPU where its consuming socket runs. Forwarded
  # traffic has no local socket, so the flow table would be pure overhead.
  if ((ST_P_LOCAL_TCP)); then
    ST_P_RFS=1
    _why rfs on "local sockets exist — keep each flow on its consumer's CPU"
  else
    _why rfs off "forwarded traffic has no local socket to follow"
  fi
}

# _policy_xps — never map every CPU to every TX queue (pre-2.4.5 did, defeating the
# driver's per-CPU queue affinity and adding queue-lock contention).
_policy_xps() {
  ST_P_XPS='keep'
  if ((ST_P_CHANNELS > 0)); then
    _why xps keep "the driver re-maps CPUs to TX queues when channels change"
    return 0
  fi
  if ((ST_F_TXQ <= 1)); then
    _why xps keep "single TX queue — XPS has nothing to choose from"
    return 0
  fi
  local q any=0 cur
  for q in /sys/class/net/"$ST_F_IFACE"/queues/tx-*/xps_cpus; do
    [[ -r $q ]] || continue
    cur="$(cat "$q" 2>/dev/null)" || cur=''
    [[ $(cpu_mask_norm "$cur") != 0 ]] && any=1
  done
  if ((any)); then
    _why xps keep "the driver already maps CPUs to TX queues"
  else
    ST_P_XPS='partition'
    _why xps partition "no CPU→queue map set — giving each CPU its own TX queue"
  fi
}

# _policy_irq — spread the uplink's receive interrupts when they all land on
# ONE CPU. Many drivers only publish affinity *hints*, which irqbalance turns
# into real placement; without it every RX queue's interrupt can sit on
# CPU 0 — multi-queue hardware with a single hot core. Applied only when the
# collapse is measured and irqbalance is absent (never fight it). Managed
# interrupts are spread by the kernel already and never qualify.
_policy_irq() {
  ST_P_IRQ_SPREAD=0
  [[ -n $ST_F_IFACE ]] && ((ST_F_CPUS > 1)) || return 0
  if [[ "$(config_get irq_affinity)" == off ]]; then
    _why irq keep "disabled in config (irq_affinity=off)"
    return 0
  fi
  if ((ST_P_CHANNELS > 0)); then
    _why irq keep "the driver re-places its interrupts when channels change"
    return 0
  fi
  local irqs n cpus
  irqs="$(net_rx_irqs "$ST_F_IFACE")"
  n="$(grep -c . <<<"$irqs")" || n=0
  ((n > 1)) || return 0
  cpus="$(cut -f2 <<<"$irqs" | sort -u | paste -sd' ' -)"
  if ((ST_F_IRQBALANCE)); then
    _why irq keep "irqbalance is running and owns interrupt placement"
  elif [[ $cpus =~ ^[0-9]+$ ]]; then
    ST_P_IRQ_SPREAD=1
    _why irq spread "all ${n} receive interrupts of ${ST_F_IFACE} run on CPU ${cpus} — one per CPU instead"
  else
    _why irq keep "${n} receive interrupts already spread (CPUs ${cpus// /,})"
  fi
  return 0
}

# _policy_conntrack — connection tracking is sized and timed out wherever it
# is LIVE, not only on forwarders: Docker's published ports, UFW and any
# stateful rule load nf_conntrack too, and its defaults (a small table, a
# 5-day established timeout) are what fill it ("table full, dropping
# packet"). Hosts that only track their own connections get a 2 h timeout:
# idle pooled connections through Docker NAT must survive.
_policy_conntrack() {
  ST_P_CONNTRACK=0
  ST_P_CT_EST=3600
  if ((ST_P_FORWARD)); then
    ST_P_CONNTRACK=1
    # Without a user count, size from RAM headroom (never below the tier):
    # an explicit --users value is the operator's sizing and stays as is.
    local budget
    if ((ST_EXPECTED_USERS == 0)); then
      budget="$(capacity_ct_budget "$(mem_total_mb)")"
      if ((budget > ST_CONNTRACK)); then
        _why conntrack "$budget" "forwarder: raised from tier ${ST_TIER}'s ${ST_CONNTRACK} — a full table drops new connections; worst case ~$((budget * 300 / 1048576)) MB (≤ 10% of RAM)"
        ST_CONNTRACK="$budget"
        return 0
      fi
    fi
    _why conntrack "$ST_CONNTRACK" "forwarding roles — every forwarded flow is a conntrack entry; idle ones expire after 1 h"
  elif ((ST_F_CONNTRACK)); then
    ST_P_CONNTRACK=1
    ST_P_CT_EST=7200
    _why conntrack "$ST_CONNTRACK" "loaded ($( ((ST_F_DOCKER)) && printf 'Docker' || printf 'firewall')) — sized, idle flows expire after 2 h instead of 5 days"
  else
    _why conntrack off "not loaded and nothing forwards — left alone"
  fi
}

# _policy_memory — VM behaviour for database hosts. Redis/Valkey fork for
# snapshots and AOF rewrites; with overcommit_memory=0 the fork can be
# refused on a busy host (Redis warns about it at startup). Lower dirty
# ratios turn multi-gigabyte write-back bursts into a steady trickle, which
# keeps fsync latency flat for MySQL/PostgreSQL.
_policy_memory() {
  ST_P_OVERCOMMIT=''
  ST_P_DIRTY=0
  role_has db || return 0
  if engine_detected Redis || engine_detected Valkey; then
    ST_P_OVERCOMMIT=1
    _why overcommit 1 "Redis/Valkey forks for snapshots — the fork must never be refused (Redis' own advice)"
  fi
  ST_P_DIRTY=1
  _why dirty '5%/10%' "database host — smaller write-back bursts keep fsync latency flat"
}

# _policy_docker — Docker engine hygiene whenever a Docker daemon runs.
_policy_docker() {
  ST_P_DOCKER=0
  ((ST_F_DOCKER)) || return 0
  if [[ "$(config_get docker_tuning)" == off ]]; then
    _why docker keep "disabled in config (docker_tuning=off)"
    return 0
  fi
  ST_P_DOCKER=1
  _why docker tune "Docker engine found — bounded container logs, live-restore, container nofile"
}

# policy_resolve — compute every decision. Requires roles + capacity.
policy_resolve() {
  facts_collect
  ST_P_WHY=()
  ST_P_LOCAL_TCP=0
  role_any proxy panel utunnel web db general && ST_P_LOCAL_TCP=1
  ST_P_FORWARD=0
  role_any proxy vpn tunnel relay utunnel && ST_P_FORWARD=1
  ST_P_FWD_HEAVY=0
  ((ST_P_FORWARD && !ST_P_LOCAL_TCP)) && ST_P_FWD_HEAVY=1

  if ((ST_P_FWD_HEAVY)); then
    _why workload forwarder "roles $(roles_summary): traffic is routed through, not terminated here"
  elif ((ST_P_FORWARD)); then
    _why workload mixed "roles $(roles_summary): terminates TCP locally and forwards traffic"
  else
    _why workload local "roles $(roles_summary): traffic terminates on this host"
  fi

  _policy_cc
  _policy_qdisc
  _policy_channels
  _policy_offloads
  _policy_irq
  _policy_rps
  _policy_xps
  _policy_conntrack
  _policy_memory
  _policy_docker

  ST_P_UDP_STREAM=60
  role_has vpn && ST_P_UDP_STREAM=180

  local mss
  mss="$(config_get mss_clamp)"
  case "$mss" in
    on) ST_P_MSS=1 && _why mss on "forced in config (mss_clamp=on)" ;;
    off) ST_P_MSS=0 && _why mss off "disabled in config (mss_clamp=off)" ;;
    *)
      if role_any vpn tunnel relay; then
        ST_P_MSS=1
        _why mss on "forwarded TCP crosses a tunnel/VPN with a smaller MTU — clamp SYN MSS to the path MTU"
      else
        ST_P_MSS=0
        _why mss off "nothing forwards TCP into a smaller-MTU path"
      fi
      ;;
  esac
  return 0
}

# policy_print — the decisions table for the plan / dry-run screens.
policy_print() {
  local entry area decision reason
  for entry in "${ST_P_WHY[@]-}"; do
    [[ -n $entry ]] || continue
    IFS='|' read -r area decision reason <<<"$entry"
    printf '    %s%-9s%s %-12s %s%s%s\n' "$C_KEY" "$area" "$C_RESET" "$decision" "$C_MUTED" "$reason" "$C_RESET"
  done
}
