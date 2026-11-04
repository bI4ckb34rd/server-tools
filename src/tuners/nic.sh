# shellcheck shell=bash
# ============================================================================
# tuners/nic.sh — CPU/NIC data-path tuning that lives in /sys and ethtool:
#   - NIC channels (use the queue pairs the NIC offers) and GRO / UDP GRO
#     forwarding, through ethtool,
#   - RPS (+RFS when local sockets exist) as decided by engine/policy.sh,
#   - XPS only to give each CPU its own TX queue when the driver set none,
#   - receive-interrupt affinity, only when every RX vector sits on one CPU
#     and irqbalance is absent,
#   - CPU governor = performance (where cpufreq exists),
#   - Transparent Huge Pages = madvise.
#
# Live writes go through st_set_runtime, so rollback restores the previous
# values immediately. Persistence is ONE oneshot unit running a generated,
# idempotent boot script that exits — no resident process.
# NIC ring/coalesce tuning (ethtool -G/-C) is deliberately excluded: it can
# reset the link and is hypervisor-dependent (docs/SYSCTL.md).
#
# Order matters: channels change first, because the queue directories RPS
# writes to only exist once the new channel count is live.
# ============================================================================

readonly ST_PERF_BOOT='/etc/server-tools/perf-boot.sh'
readonly ST_PERF_UNIT='/etc/systemd/system/server-tools-perf.service'

# _nic_xps_partition_mask Q NTX — CPUs (from the online list, in order) whose
# index modulo NTX equals Q: cpu0→q0, cpu1→q1, … the layout virtio uses.
_nic_xps_partition_mask() {
  local q="$1" ntx="$2" idx=0 cpu sel=''
  local -a cpus=()
  IFS=' ' read -ra cpus <<<"$ST_F_CPU_LIST"
  for cpu in "${cpus[@]}"; do
    ((idx % ntx == q)) && sel+=" ${cpu}"
    idx=$((idx + 1))
  done
  cpu_mask_from_list "$sel"
}

# nic_ethtool_plan — "IFACE<TAB>KEY<TAB>VALUE" for every ethtool change.
nic_ethtool_plan() {
  if [[ -z $ST_F_IFACE ]] || ! has_cmd ethtool; then return 0; fi
  ((ST_P_CHANNELS > 0)) && printf '%s\tchannels\t%s\n' "$ST_F_IFACE" "$ST_P_CHANNELS"
  ((ST_P_GRO)) && printf '%s\tgro\ton\n' "$ST_F_IFACE"
  ((ST_P_UDPGRO)) && printf '%s\trx-udp-gro-forwarding\ton\n' "$ST_F_IFACE"
  return 0
}

# nic_plan — "path<TAB>value" for every /sys tweak that applies on THIS host.
# Single source of truth for live apply, the boot script and verify.
nic_plan() {
  local iface="$ST_F_IFACE" g q n=0 mask flow_cnt
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w $g ]] && printf '%s\t%s\n' "$g" performance
  done
  [[ -w /sys/kernel/mm/transparent_hugepage/enabled ]] &&
    printf '%s\t%s\n' /sys/kernel/mm/transparent_hugepage/enabled madvise
  [[ -w /sys/kernel/mm/transparent_hugepage/defrag ]] &&
    printf '%s\t%s\n' /sys/kernel/mm/transparent_hugepage/defrag madvise

  # One receive interrupt per CPU, in queue order (cpu0→irq0, cpu1→irq1, …).
  # IRQ numbers are not stable across reboots: the boot script recomputes
  # the same placement by name (_nic_irq_boot_lines).
  if ((ST_P_IRQ_SPREAD)) && [[ -n $iface ]]; then
    local irq _cpus idx=0
    local -a cpus=()
    IFS=' ' read -ra cpus <<<"$ST_F_CPU_LIST"
    while IFS=$'\t' read -r irq _cpus; do
      [[ -n $irq && -w /proc/irq/$irq/smp_affinity_list ]] || continue
      printf '%s\t%s\n' "/proc/irq/${irq}/smp_affinity_list" "${cpus[idx % ${#cpus[@]}]}"
      idx=$((idx + 1))
    done < <(net_rx_irqs "$iface")
  fi

  if [[ -n $iface && -d /sys/class/net/$iface/queues ]]; then
    if ((ST_P_RPS)); then
      mask="$(cpu_mask_from_list "$ST_P_RPS_CPUS")"
      flow_cnt=0
      ((ST_P_RFS)) && flow_cnt=$((32768 / (ST_F_RXQ > 0 ? ST_F_RXQ : 1)))
      for q in /sys/class/net/"$iface"/queues/rx-*; do
        [[ -w $q/rps_cpus ]] && printf '%s\t%s\n' "$q/rps_cpus" "$mask"
        # Written when RFS runs, or to switch off a flow table a previous
        # (pre-2.4.5) run left behind on a host that no longer benefits from it.
        if [[ -w $q/rps_flow_cnt ]] && { ((ST_P_RFS)) || [[ "$(cat "$q/rps_flow_cnt" 2>/dev/null)" != 0 ]]; }; then
          printf '%s\t%s\n' "$q/rps_flow_cnt" "$flow_cnt"
        fi
      done
    fi
    if [[ $ST_P_XPS == partition ]]; then
      for q in /sys/class/net/"$iface"/queues/tx-*; do
        [[ -w $q/xps_cpus ]] || continue
        n="${q##*tx-}"
        printf '%s\t%s\n' "$q/xps_cpus" "$(_nic_xps_partition_mask "$n" "$ST_F_TXQ")"
      done
    fi
  fi
  # Value-producing helper: never leak a trailing guard's status into the
  # `plan="$(nic_plan)"` capture under errexit. A read-only /sys (LXC)
  # simply yields an empty plan.
  return 0
}

# _nic_irq_boot_lines IFACE — POSIX sh that re-spreads IFACE's receive
# interrupts at boot, found by name with the same selector the live run used.
# shellcheck disable=SC2016 # the $vars belong to the generated script
_nic_irq_boot_lines() {
  local iface="$1" dev n
  dev="$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null)" || dev=''
  dev="${dev##*/}"
  n="$(wc -w <<<"$ST_F_CPU_LIST" | tr -d ' ')"
  printf '#@irq %s\n' "$iface"
  printf "irqs=\$(awk -v i='%s' -v d='%s' '%s' /proc/interrupts 2>/dev/null)\n" \
    "$iface" "$dev" "$(tr '\n' ' ' <<<"$ST_RX_IRQ_AWK")"
  printf 'k=0\nfor irq in $irqs; do\n'
  printf "  c=\$(echo '%s' | cut -d' ' -f\$((k %% %s + 1)))\n" "$ST_F_CPU_LIST" "$n"
  printf '  [ -w /proc/irq/$irq/smp_affinity_list ] && echo "$c" > /proc/irq/$irq/smp_affinity_list\n'
  printf '  k=$((k + 1))\ndone\n'
}

# _nic_qdisc_boot_lines IFACE — POSIX sh that puts the default qdisc live on
# IFACE at boot. net.core.default_qdisc only reaches qdiscs created after it
# is set; a NIC brought up before systemd-sysctl ran (initramfs networking,
# some cloud images) kept the old one until the next manual run. Same rules
# as tuners/qdisc.sh: mq is rebuilt (never collapsed), custom roots
# (htb, cake, tbf …) are never touched.
# shellcheck disable=SC2016 # the $vars belong to the generated script
_nic_qdisc_boot_lines() {
  local iface="$1"
  printf 'if command -v tc >/dev/null; then\n'
  printf '  def=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)\n'
  printf "  kind=\$(tc qdisc show dev %s root 2>/dev/null | awk 'NR == 1 {print \$2}')\n" "$iface"
  printf "  kids=\$(tc qdisc show dev %s 2>/dev/null | awk '\$4 == \"parent\" {print \$2}' | sort -u)\n" "$iface"
  printf '  ntx=$(ls -d /sys/class/net/%s/queues/tx-* 2>/dev/null | wc -l)\n' "$iface"
  printf '  case "$kind" in\n'
  printf '    mq) [ -z "$def" ] || [ "$kids" = "$def" ] || tc qdisc replace dev %s root mq ;;\n' "$iface"
  printf '    fq | fq_codel | pfifo_fast | pfifo) [ -z "$def" ] || [ "$ntx" -gt 1 ] || [ "$kind" = "$def" ] || tc qdisc replace dev %s root "$def" ;;\n' "$iface"
  printf '  esac\nfi\n'
}

# _nic_write_boot ETHTOOL_PLAN PLAN — idempotent boot script + oneshot unit.
_nic_write_boot() {
  local eplan="$1" plan="$2" path value iface key
  st_track_file "$ST_PERF_BOOT"
  mkdir -p "$(dirname "$ST_PERF_BOOT")"
  {
    printf '#!/bin/sh\n'
    printf '# Generated by %s v%s — reapplies non-persistent /sys tuning at boot.\n' "$ST_NAME" "$ST_VERSION"
    printf '# roles=%s rps=%s rfs=%s xps=%s. Each write is best-effort: a NIC that\n' \
      "${ST_ROLES// /,}" "$ST_P_RPS" "$ST_P_RFS" "$ST_P_XPS"
    printf '# was renamed or removed must not fail the whole boot step.\n'
    while IFS=$'\t' read -r iface key value; do
      [[ -n $iface ]] || continue
      # "#@ethtool" marker lines are what nic_verify reads back.
      printf '#@ethtool %s %s %s\n' "$iface" "$key" "$value"
      if [[ $key == channels ]]; then
        printf 'command -v ethtool >/dev/null && ethtool -L %s combined %s >/dev/null 2>&1\n' "$iface" "$value"
      else
        printf 'command -v ethtool >/dev/null && ethtool -K %s %s %s >/dev/null 2>&1\n' "$iface" "$key" "$value"
      fi
    done <<<"$eplan"
    [[ -n $ST_F_IFACE ]] && _nic_qdisc_boot_lines "$ST_F_IFACE"
    ((ST_P_IRQ_SPREAD)) && _nic_irq_boot_lines "$ST_F_IFACE"
    while IFS=$'\t' read -r path value; do
      [[ -n $path && $path != /proc/irq/* ]] || continue
      printf '[ -w %s ] && printf "%%s\\n" %s > %s\n' "$path" "$value" "$path"
    done <<<"$plan"
    printf 'exit 0\n'
  } >"$ST_PERF_BOOT"
  chmod 0755 "$ST_PERF_BOOT"

  st_track_file "$ST_PERF_UNIT"
  mkdir -p "$(dirname "$ST_PERF_UNIT")"
  {
    printf '# Generated by %s v%s\n' "$ST_NAME" "$ST_VERSION"
    printf '[Unit]\nDescription=ServerTools CPU/NIC performance tuning (oneshot, exits after boot)\n'
    printf 'After=network-online.target\nWants=network-online.target\n\n'
    printf '[Service]\nType=oneshot\nRemainAfterExit=yes\n'
    printf 'ExecStart=%s\n' "$ST_PERF_BOOT"
    printf '\n[Install]\nWantedBy=multi-user.target\n'
  } >"$ST_PERF_UNIT"
}

# _nic_undo_stale — a previous run may have enabled RPS that the current
# policy turns off (e.g. a pre-2.4.5 run on a relay). Return those queues to the
# kernel default (0 = no steering) so the new plan is really in effect.
_nic_undo_stale() {
  local q cur
  ((ST_P_RPS)) && return 0
  [[ -n $ST_F_IFACE ]] || return 0
  for q in /sys/class/net/"$ST_F_IFACE"/queues/rx-*/rps_cpus; do
    [[ -r $q ]] || continue
    cur="$(cat "$q" 2>/dev/null)" || continue
    if [[ $(cpu_mask_norm "$cur") != 0 && -f $ST_PERF_BOOT ]] && grep -qF "$q" "$ST_PERF_BOOT"; then
      st_set_runtime "$q" 0 && log_note "RPS turned off on ${q%/rps_cpus} (no longer beneficial for these roles)."
    fi
  done
  return 0
}

# nic_apply — runner step. 0 applied, 2 nothing applicable, 3 partial.
nic_apply() {
  local plan eplan iface key value applied=0 unavail=0
  _nic_undo_stale
  eplan="$(nic_ethtool_plan)"
  while IFS=$'\t' read -r iface key value; do
    [[ -n $iface ]] || continue
    if st_set_ethtool "$iface" "$key" "$value"; then
      applied=$((applied + 1))
      log_note "${iface}: ${key} → ${value}."
    else
      unavail=$((unavail + 1))
      log_note "${iface}: could not set ${key} (driver refused) — left as-is."
    fi
  done <<<"$eplan"
  # New channel count → new queue directories for the steering writes below.
  [[ -n $eplan ]] && facts_refresh_nic

  plan="$(nic_plan)"
  if [[ -z $plan && -z $eplan ]]; then
    log_note "Nothing applicable here (no cpufreq, THP, channels or steering needed)."
    return 2
  fi

  local path
  while IFS=$'\t' read -r path value; do
    [[ -n $path ]] || continue
    if st_set_runtime "$path" "$value"; then
      applied=$((applied + 1))
    else
      unavail=$((unavail + 1))
    fi
  done <<<"$plan"

  local rc=0
  if systemd_usable; then
    _nic_write_boot "$eplan" "$plan"
    systemd_enable_oneshot server-tools-perf.service || rc=3
  else
    log_warn "No systemd — performance tuning is active now but will not survive a reboot."
    rc=3
  fi

  if ((ST_P_RPS)); then
    log_note "RPS on ${ST_F_IFACE} → CPUs ${ST_P_RPS_CPUS// /,}$( ((ST_P_RFS)) && printf ' (+RFS)')."
  elif [[ -n $ST_F_IFACE ]]; then
    log_note "RPS not used on ${ST_F_IFACE} — see the plan for why."
  fi
  [[ $ST_P_XPS == partition ]] && log_note "XPS: each CPU mapped to its own TX queue."
  ((ST_P_IRQ_SPREAD)) && log_note "Receive interrupts of ${ST_F_IFACE} spread one per CPU."
  if ((unavail > 0)); then
    log_note "${unavail} target(s) were read-only and left as-is."
    ((rc == 0)) && rc=3
  fi
  log_info "nic applied: applied=${applied} unavail=${unavail} rps=${ST_P_RPS} rfs=${ST_P_RFS} xps=${ST_P_XPS} iface=${ST_F_IFACE:-none}."
  return "$rc"
}

# nic_verify — 0 when every value the boot script manages is still live,
# 3 on drift, 2 when never configured here.
nic_verify() {
  [[ -f $ST_PERF_BOOT ]] || return 2
  # A pre-2.4.5-format script is not role-aware: report it until re-planned.
  grep -q '^printf %s ' "$ST_PERF_BOOT" && return 3
  local line path value cur drift=0 _m iface key
  while IFS= read -r line; do
    if [[ $line == '#@ethtool '* ]]; then
      IFS=' ' read -r _m iface key value <<<"$line"
      [[ -d /sys/class/net/$iface ]] || continue
      cur="$(ethtool_read "$iface" "$key")"
      [[ -z $cur || $cur == "$value" ]] || drift=1
      continue
    fi
    if [[ $line == '#@irq '* ]]; then
      # Spread means: more than one distinct CPU serves the receive vectors.
      iface="${line#'#@irq '}"
      cur="$(net_rx_irqs "$iface" | cut -f2 | sort -u | grep -c .)" || cur=0
      ((cur > 1)) || [[ ! -d /sys/class/net/$iface ]] || drift=1
      continue
    fi
    [[ $line == '[ -w '* ]] || continue
    # [ -w PATH ] && printf "%s\n" VALUE > PATH
    path="$(awk '{print $3}' <<<"$line")"
    value="$(awk '{print $(NF - 2)}' <<<"$line")"
    [[ -n $path && -r $path ]] || continue
    cur="$(runtime_read "$path")" || continue
    case "$path" in
      *rps_cpus | *xps_cpus) [[ $(cpu_mask_norm "$cur") == "$(cpu_mask_norm "$value")" ]] || drift=1 ;;
      *rps_flow_cnt) [[ $cur -ge $value ]] 2>/dev/null || drift=1 ;;
      *) [[ $cur == "$value" ]] || drift=1 ;;
    esac
  done <"$ST_PERF_BOOT"
  ((drift)) && return 3
  return 0
}
