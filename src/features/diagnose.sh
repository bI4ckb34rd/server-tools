# shellcheck shell=bash
# ============================================================================
# features/diagnose.sh — read-only data-path diagnostics (`st --diagnose`).
#
# Answers the question tuning reports keep raising — "why is this core hot /
# why did CPU go up?" — with measurements instead of claims: per-CPU
# softirq/system/steal over a short sample, softnet backlog drops and budget
# squeezes, NIC queues and steering, qdisc drops, conntrack pressure, and the
# tunnel audit. No tuning is changed (missing prerequisites such as ethtool
# are installed first, per install_deps); the sample takes ~3 seconds.
# ============================================================================

readonly ST_DIAG_SAMPLE_SECS=3

# _diag_cpu_stat — "cpuN total softirq system steal" per CPU from /proc/stat.
_diag_cpu_stat() {
  awk '/^cpu[0-9]+ / {
    t = 0; for (i = 2; i <= NF; i++) t += $i
    print $1, t, $8, $4, ($9 == "" ? 0 : $9)
  }' /proc/stat
}

# _diag_softnet — "cpu processed dropped squeezed" (hex columns → decimal).
# The row index is the CPU id on modern kernels (column 13 when present).
_diag_softnet() {
  [[ -r /proc/net/softnet_stat ]] || return 0
  local -a f=()
  local idx=0 cpu
  while IFS=' ' read -ra f; do
    cpu=$idx
    ((${#f[@]} >= 13)) && [[ ${f[12]} =~ ^[0-9a-fA-F]+$ ]] && cpu=$((16#${f[12]}))
    printf '%s %s %s %s\n' "$cpu" "$((16#${f[0]}))" "$((16#${f[1]}))" "$((16#${f[2]}))"
    idx=$((idx + 1))
  done </proc/net/softnet_stat
}

# _diag_conntrack_stats — "drop early_drop insert_failed" summed over CPUs.
_diag_conntrack_stats() {
  local file=/proc/net/stat/nf_conntrack
  [[ -r $file ]] || return 0
  local -a hdr=() row=()
  local i drop=0 early=0 ins=0 first=1
  while IFS=' ' read -ra row; do
    if ((first)); then
      hdr=("${row[@]}")
      first=0
      continue
    fi
    for ((i = 0; i < ${#hdr[@]}; i++)); do
      case "${hdr[i]}" in
        drop) drop=$((drop + 16#${row[i]})) ;;
        early_drop) early=$((early + 16#${row[i]})) ;;
        insert_failed) ins=$((ins + 16#${row[i]})) ;;
      esac
    done
  done <"$file"
  printf '%s %s %s\n' "$drop" "$early" "$ins"
}

_diag_cpu_section() {
  local before after sn_before sn_after
  before="$(_diag_cpu_stat)"
  sn_before="$(_diag_softnet)"
  printf '  %sSampling %d s…%s' "$C_MUTED" "$ST_DIAG_SAMPLE_SECS" "$C_RESET"
  sleep "$ST_DIAG_SAMPLE_SECS"
  after="$(_diag_cpu_stat)"
  sn_after="$(_diag_softnet)"
  printf '\r%*s\r' 30 ''

  ui_section "CPU — where the time goes (last ${ST_DIAG_SAMPLE_SECS} s)"
  printf '    %s%-6s %8s %8s %8s %10s %8s%s\n' "$C_KEY" "CPU" "softirq" "system" "steal" "packets/s" "drops" "$C_RESET"
  local rows
  rows="$(awk -v secs="$ST_DIAG_SAMPLE_SECS" '
    FNR == 1 { file++ }
    file == 1 { t0[$1] = $2; si0[$1] = $3; sy0[$1] = $4; st0[$1] = $5; next }
    file == 2 { dt = $2 - t0[$1]; if (dt <= 0) dt = 1
                id = $1; sub(/^cpu/, "", id)
                si[id] = 100 * ($3 - si0[$1]) / dt; sy[id] = 100 * ($4 - sy0[$1]) / dt; st[id] = 100 * ($5 - st0[$1]) / dt
                cpus[id] = 1; next }
    file == 3 { p0[$1] = $2; d0[$1] = $3; next }
    file == 4 { pk[$1] = ($2 - p0[$1]) / secs; dr[$1] = $3 - d0[$1]; next }
    END { for (c in cpus) printf "%d %.1f %.1f %.1f %d %d\n", c, si[c], sy[c], st[c], pk[c], dr[c] }' \
    <(printf '%s\n' "$before") <(printf '%s\n' "$after") \
    <(printf '%s\n' "${sn_before:-x 0 0 0}") <(printf '%s\n' "${sn_after:-x 0 0 0}") | sort -n)"

  local cpu si sy st pk dr max_si=0 sum_si=0 n=0 max_st=0 hot='' drops=0
  while IFS=' ' read -r cpu si sy st pk dr; do
    [[ -n $cpu ]] || continue
    printf '    %-6s %7s%% %7s%% %7s%% %10s %8s\n' "cpu${cpu}" "$si" "$sy" "$st" "$pk" "$dr"
    n=$((n + 1))
    sum_si=$((sum_si + ${si%.*}))
    ((${si%.*} > max_si)) && {
      max_si=${si%.*}
      hot=$cpu
    }
    ((${st%.*} > max_st)) && max_st=${st%.*}
    drops=$((drops + dr))
  done <<<"$rows"

  ui_section "Verdict"
  local avg_si=0
  ((n > 0)) && avg_si=$((sum_si / n))
  if ((n > 1 && max_si >= 40 && max_si > avg_si * 2)); then
    ui_step_note err "cpu${hot} runs ${max_si}% softirq while the average is ${avg_si}% — single-core packet hot spot."
    if ((ST_P_RPS == 0)); then
      ui_step_note warn "RPS is off: enable it with  st --set rps_mode=on  then re-run Quick Optimize."
    fi
  elif ((max_si >= 20)); then
    ui_step_note ok "softirq load is spread (max ${max_si}%, average ${avg_si}%)."
  else
    ui_step_note ok "packet processing is light (max ${max_si}% softirq)."
  fi
  if ((max_st >= 10)); then
    ui_step_note warn "up to ${max_st}% steal — the hypervisor is withholding CPU; tuning cannot fix a noisy host."
  fi
  if ((drops > 0)); then
    ui_step_note err "${drops} packet(s) dropped from per-CPU backlogs during the sample — a core is saturated."
  fi
  if ((ST_P_RPS && ST_P_FWD_HEAVY && avg_si >= 25)); then
    ui_step_note warn "This forwarder spends ${avg_si}% per core in softirq with RPS on. RPS adds a cross-CPU hop per packet; compare at equal traffic:"
    printf '        st --set rps_mode=off && st --auto      (then re-check: st --diagnose)\n'
    printf '        st --set rps_cpus=1-%d && st --auto    (keep cpu0 for the NIC interrupt)\n' "$((ST_F_CPUS - 1))"
    ui_step_note idle "The biggest structural saving for a NAT relay is the nftables fast path: Network tools → f."
  fi
  return 0
}

_diag_nic_section() {
  local iface="$ST_F_IFACE" q mask rps='' xps=''
  ui_section "Uplink ${iface:-?}"
  [[ -n $iface ]] || {
    ui_step_note idle "No default route."
    return 0
  }
  ui_kv "Driver · MTU" "${ST_F_DRIVER} · ${ST_F_IFACE_MTU}"
  ui_kv "Queues" "${ST_F_RXQ} RX · ${ST_F_TXQ} TX for ${ST_F_CPUS} CPUs"
  if ((ST_F_CH_MAX > 0)); then
    ui_kv "Channels" "${ST_F_CH_CUR} in use of ${ST_F_CH_MAX} offered"
    ((ST_F_CH_CUR < ST_F_CH_MAX && ST_F_CH_CUR < ST_F_CPUS)) &&
      ui_step_note warn "the NIC offers more queue pairs than it uses — Quick Optimize raises them on virtio (nic_channels)."
  fi
  ui_kv "GRO / UDP-GRO fwd" "${ST_F_GRO:-n/a} · ${ST_F_UDPGRO:-n/a}"
  for q in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
    [[ -r $q ]] || continue
    mask="$(cpu_mask_norm "$(cat "$q" 2>/dev/null)")"
    rps+="${rps:+ }${mask}"
  done
  for q in /sys/class/net/"$iface"/queues/tx-*/xps_cpus; do
    [[ -r $q ]] || continue
    mask="$(cpu_mask_norm "$(cat "$q" 2>/dev/null)")"
    xps+="${xps:+ }${mask}"
  done
  ui_kv "RPS masks" "${rps:-n/a} (0 = off)"
  ui_kv "XPS masks" "${xps:-n/a}"
  local irq nvec
  irq="$(policy_irq_cpus "$iface")"
  nvec="$(net_rx_irqs "$iface" | grep -c .)" || nvec=0
  ui_kv "IRQ CPUs" "${irq:-not identifiable (driver naming)} · ${nvec} RX vector(s) · irqbalance $( ((ST_F_IRQBALANCE)) && printf 'on' || printf 'off')"
  if ((nvec > 1 && ST_F_CPUS > 1)) && [[ $irq =~ ^[0-9]+$ ]]; then
    ui_step_note warn "all ${nvec} receive interrupts run on CPU ${irq} — Quick Optimize spreads them one per CPU (irq_affinity)."
  fi
  ui_kv "RFS table" "$(sysctl_get net.core.rps_sock_flow_entries)"
  if has_cmd tc; then
    local out
    out="$(tc -s qdisc show dev "$iface" 2>/dev/null)" || out=''
    ui_kv "Root qdisc" "$(net_root_qdisc "$iface")"
    ui_kv "Qdisc drops" "$(awk '/dropped/ {gsub(/,/, "", $7); print $7 + 0; exit}' <<<"$out")"
  fi
}

_diag_conntrack_section() {
  ui_section "Conntrack"
  local count max drop early ins
  count="$(sysctl_get net.netfilter.nf_conntrack_count)"
  max="$(sysctl_get net.netfilter.nf_conntrack_max)"
  if [[ ! $count =~ ^[0-9]+$ || ! $max =~ ^[0-9]+$ || $max -eq 0 ]]; then
    ui_step_note idle "conntrack not loaded."
    return 0
  fi
  ui_kv "Entries" "${count} / ${max} ($((count * 100 / max))%)"
  IFS=' ' read -r drop early ins <<<"$(_diag_conntrack_stats)"
  ui_kv "Drops (boot)" "drop ${drop:-0} · early_drop ${early:-0} · insert_failed ${ins:-0}"
  if ((count * 100 / max >= 80)); then
    ui_step_note err "table is $((count * 100 / max))% full — new flows will be dropped; raise the tier or --users."
  fi
  if ((${early:-0} > 0 || ${drop:-0} > 0)); then
    ui_step_note warn "conntrack has dropped flows since boot (table pressure at some point)."
  fi
  return 0
}

# diagnose_network — the whole report. Read-only.
diagnose_network() {
  _plan_prerequisites
  facts_collect
  roles_resolve
  capacity_resolve
  local saved_dry=$ST_DRY_RUN
  ST_DRY_RUN=1 # policy must not load modules from a read-only report
  policy_resolve
  ST_DRY_RUN=$saved_dry

  ui_title "Diagnose — network data path"
  ui_kv "Roles" "$(roles_summary) (${ST_ROLES_SOURCE}) · engines: $(engines_summary)"
  ui_kv "Virtualization" "$ST_F_VIRT"
  _diag_cpu_section
  _diag_nic_section
  _diag_conntrack_section
  if ((ST_F_DOCKER)); then
    ui_section "Docker"
    if docker_verify; then
      ui_step_note ok "Container logs are bounded."
    else
      ui_step_note warn "json-file container logs are unbounded — Quick Optimize or Node & Docker → 3."
    fi
  fi
  ui_section "Tunnels"
  tunnel_audit
  printf '\n'
  ui_hint "No tuning was changed. Run this before and after a change, at similar traffic, to compare."
  return 0
}
