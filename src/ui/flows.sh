# shellcheck shell=bash
# ============================================================================
# ui/flows.sh — Quick / Custom / Auto / Dry-run optimize flows:
#   resolve (roles → capacity → policy) → show the plan WITH reasons →
#   confirm → apply steps with honest per-step outcomes → summary.
# ============================================================================

# CLI inputs, filled by 99-main.sh.
ST_CLI_ROLES=''
ST_AUTO_DNS=''
ST_AUTO_SWAP=1
ST_AUTO_LIMITS=1
ST_AUTO_EXTRAS=1
ST_AUTO_PERF=1
ST_AUTO_MSS=1
ST_AUTO_DOCKER=1

# The optimize steps, in run order: "id|function|title". Swap runs BEFORE
# sysctl on purpose (vm.swappiness depends on the backend), channels before
# steering. A new tuner is one line here (+ a Doctor row, + build.sh).
readonly -a ST_OPTIMIZE_STEPS=(
  'swap|swap_apply|Swap'
  'sysctl|sysctl_apply|Kernel network tuning (sysctl)'
  'qdisc|qdisc_apply|Queueing discipline'
  'perf|nic_apply|CPU & NIC data path (channels, offloads, IRQs, RPS/XPS)'
  'mss|mss_apply|MSS clamping for forwarded TCP'
  'limits|limits_apply|File-descriptor limits (nofile)'
  'extras|extras_apply|Journald cap & NTP'
  'docker|docker_apply|Docker engine (log rotation, live-restore, nofile)'
  'dns|dns_apply|DNS'
)

# _optimize_title ID TITLE — the step title with this run's specifics.
_optimize_title() {
  case "$1" in
    sysctl) printf '%s, tier %s' "$2" "$ST_TIER" ;;
    qdisc) printf '%s on %s (%s)' "$2" "${ST_F_IFACE:-uplink}" "$ST_QDISC" ;;
    dns) printf '%s (%s / %s)' "$2" "$ST_DNS1" "$ST_DNS2" ;;
    *) printf '%s' "$2" ;;
  esac
}

# _optimize_applicable ID — steps the policy rules out are not even listed.
_optimize_applicable() {
  case "$1" in
    mss) ((ST_P_MSS)) ;;
    docker) ((ST_P_DOCKER)) ;;
    *) return 0 ;;
  esac
}

# plan_resolve [ROLES] — the full decision chain, shared by every flow.
# Prerequisites are installed first (quietly; reported in the plan) so the
# facts the policy reads — channels, offloads, nft support — are complete.
plan_resolve() {
  _plan_prerequisites
  roles_resolve "${1:-$ST_CLI_ROLES}"
  capacity_resolve
  policy_resolve
}

_plan_prerequisites() {
  local missing
  missing="$(deps_missing core | cut -f1 | paste -sd' ' -)"
  [[ -n $missing ]] || return 0
  if ((ST_DRY_RUN)); then
    printf '%sPrerequisites a real run would install:%s %s\n' "$C_MUTED" "$C_RESET" "$missing"
    return 0
  fi
  printf '%sInstalling prerequisites:%s %s …\n' "$C_MUTED" "$C_RESET" "$missing"
  deps_ensure core || log_debug "prerequisites incomplete (fallbacks in use)"
  facts_collect force
  return 0
}

# _plan_cpu_hints — opt-in features that cut CPU on this kind of host and
# are not enabled yet. They change the firewall path, so they stay a choice
# (Network & VPN Tools) instead of a Quick Optimize step.
_plan_cpu_hints() {
  local -a hints=()
  local rc
  if role_has relay; then
    rc=0
    flowtable_verify || rc=$?
    ((rc == 2)) && hints+=("nftables fast path (menu 7 → f): forwarded NAT flows skip most of netfilter — the largest CPU saving on a relay")
  fi
  if role_has proxy; then
    rc=0
    notrack_verify || rc=$?
    ((rc == 2)) && hints+=("NOTRACK for proxy ports (menu 7 → n): no conntrack work for connections to the proxy itself")
  fi
  ((${#hints[@]})) || return 0
  ui_section "Lower CPU further (opt-in)"
  local h
  for h in "${hints[@]}"; do
    ui_step_note idle "$h"
  done
  return 0
}

plan_show() {
  ui_section "What this server does"
  ui_kv "Roles" "$(roles_summary) (${ST_ROLES_SOURCE})"
  ui_kv "Engines" "$(engines_summary)"
  ui_kv "Uplink" "${ST_F_IFACE:-?} · ${ST_F_RXQ} RX / ${ST_F_TXQ} TX queues · ${ST_F_CPUS} CPUs · ${ST_F_VIRT}"

  ui_section "Capacity"
  if ((ST_EXPECTED_USERS > 0)); then
    ui_kv "Sizing" "${ST_EXPECTED_USERS} expected users (conntrack from users, buffers from RAM tier ${ST_TIER})"
  else
    ui_kv "Tier" "${ST_TIER} — up to ${ST_TIER_USERS} concurrent users"
  fi
  ui_kv "Socket buffers" "up to ${ST_BUF_MB} MB per socket"
  ((ST_P_CONNTRACK)) && ui_kv "Conntrack" "${ST_CONNTRACK} entries (~$(capacity_conntrack_ram_mb) MB kernel RAM worst case)"
  local warn
  warn="$(capacity_warning)"
  if [[ -n $warn ]]; then
    printf '    %sCapacity warning:%s %s\n' "$C_WARN" "$C_RESET" "$warn"
    log_info "capacity warning: ${warn}"
  fi

  ui_section "Decisions (and why)"
  policy_print
  _plan_cpu_hints
  if ((${#ST_F_TUNNELS[@]})); then
    ui_section "Tunnels"
    tunnel_audit
  fi
  return 0
}

# _optimize_run STEP_ID... — run the listed steps in table order, skipping
# those the policy rules out, then summarise and offer follow-ups.
_optimize_run() {
  local wanted entry id fn title
  wanted=" $(join_sp "$@") "
  local -a run=()
  for entry in "${ST_OPTIMIZE_STEPS[@]}"; do
    IFS='|' read -r id fn title <<<"$entry"
    [[ $wanted == *" ${id} "* ]] && _optimize_applicable "$id" && run+=("$entry")
  done
  ST_STEP_RESULTS=()
  ST_STEP_IDX=0
  ST_STEP_TOTAL=${#run[@]}
  # Baseline first: counters must be read before anything is changed.
  snapshot_save
  ui_hr
  for entry in "${run[@]}"; do
    IFS='|' read -r id fn title <<<"$entry"
    st_run_step "$(_optimize_title "$id" "$title")" "$fn"
  done
  st_report_summary
  [[ $wanted == *' dns '* ]] && ui_kv "DNS in effect" "$(dns_effective_servers)"
  docker_offer_restart
  _offer_service_restart
  config_set last_roles "${ST_ROLES// /,}"
  config_set last_tier "$ST_TIER"
  config_unset last_profile
  backup_prune 10
  return 0
}

# _optimize_run_list "ID ID ..." — space-separated form (the global IFS has
# no space, so an unquoted list would not split).
_optimize_run_list() {
  local -a ids=()
  IFS=' ' read -ra ids <<<"$1"
  _optimize_run "${ids[@]}"
}

# _restart_candidates — "kind<TAB>name" for running workloads that keep their
# old nofile until restarted, found with the engine signatures (one source
# of truth with role detection). Containers only count when daemon.json
# gives them a limit: otherwise they inherit dockerd's, and restarting the
# container alone changes nothing.
_restart_candidates() {
  local entry role _label src re line unit
  local -A seen=()
  for entry in "${ST_ENGINE_SIGNATURES[@]}"; do
    IFS=';' read -r role _label src re <<<"$entry"
    # Socket-heavy userspace engines only: a kernel WireGuard unit holds no
    # descriptors, and restarting it would only drop the tunnel.
    [[ $role == proxy || $role == utunnel ]] || continue
    case "$src" in
      c)
        grep -q 'default-ulimits' "$ST_DOCKER_DAEMON" 2>/dev/null || continue
        while IFS= read -r line; do
          [[ -n $line && -z ${seen[c${line%% *}]:-} ]] || continue
          seen[c${line%% *}]=1
          printf 'container\t%s\n' "${line%% *}"
        done < <(grep -iE "$re" <<<"$ST_F_CONTAINERS")
        ;;
      p | u)
        while IFS= read -r unit; do
          [[ -n $unit && -z ${seen[u$unit]:-} ]] || continue
          seen[u$unit]=1
          printf 'service\t%s\n' "$unit"
        done < <(grep -iE "^(${re})(-server|-client|@.+)?$" <<<"$ST_F_UNITS")
        ;;
    esac
  done
  return 0
}

# _offer_service_restart — running services keep their old nofile limit until
# restarted; offer to restart detected workloads (interactive), or say so.
_offer_service_restart() {
  ((ST_LIMITS_CHANGED)) || return 0
  local list
  list="$(_restart_candidates)"
  if ((ST_F_DOCKER)) && ! grep -q 'default-ulimits' "$ST_DOCKER_DAEMON" 2>/dev/null; then
    printf '%sNote:%s containers take their file limit from dockerd, not limits.d —\n' "$C_MUTED" "$C_RESET"
    printf 'the Docker engine step (or Node & Docker → 3) sets it for them.\n'
  fi
  [[ -n $list ]] || return 0

  if ((ST_OPT_BATCH)); then
    printf '%sNote:%s restart these so they pick up the new limits: %s\n' \
      "$C_WARN" "$C_RESET" "$(cut -f2 <<<"$list" | paste -sd' ' -)"
    return 0
  fi

  printf '%sA restart briefly disconnects the users served by that service.%s\n' "$C_WARN" "$C_RESET"
  # FD 3: with the list on stdin, ui_confirm's read would consume it.
  local kind name ok
  while IFS=$'\t' read -r kind name <&3; do
    [[ -n $name ]] || continue
    ui_confirm "Restart ${kind} '${name}' now?" || continue
    ok=0
    if [[ $kind == container ]]; then
      run_bounded 60 docker restart "$name" >/dev/null 2>>"$ST_LOG_FILE" && ok=1
    else
      systemctl restart "$name" 2>>"$ST_LOG_FILE" && ok=1
    fi
    if ((ok)); then
      printf '%sRestarted:%s %s\n' "$C_OK" "$C_RESET" "$name"
    else
      log_warn "Could not restart ${name}."
    fi
  done 3<<<"$list"
  return 0
}

quick_optimize() {
  ui_logo
  ui_title "Quick Optimize"
  migrate_run
  plan_resolve
  printf 'The base layer always optimizes the whole server; the detected roles\n'
  printf 'decide the specialised tuning on top of it.\n'
  plan_show
  ui_hr

  local with_dns=0
  dns_select_menu && with_dns=1
  printf '\n'
  if ! ui_confirm "Apply the plan above?"; then
    ui_pause
    return 0
  fi
  local steps='swap sysctl qdisc perf mss limits extras docker'
  ((with_dns)) && steps+=' dns'
  _optimize_run_list "$steps"
  ui_pause
}

# auto_optimize — the non-interactive flow behind --auto. DNS is only touched
# when --dns was given.
auto_optimize() {
  migrate_run
  plan_resolve
  local with_dns=0
  if [[ -n $ST_AUTO_DNS ]]; then
    dns_resolve_cli "$ST_AUTO_DNS" || die "Invalid --dns '${ST_AUTO_DNS}' (provider name or ip1,ip2)."
    with_dns=1
  fi
  ui_title "Auto Optimize (non-interactive)"
  plan_show
  local steps='sysctl qdisc'
  ((ST_AUTO_SWAP)) && steps+=' swap'
  ((ST_AUTO_PERF)) && steps+=' perf'
  ((ST_AUTO_MSS)) && steps+=' mss'
  ((ST_AUTO_LIMITS)) && steps+=' limits'
  ((ST_AUTO_EXTRAS)) && steps+=' extras'
  ((ST_AUTO_DOCKER)) && steps+=' docker'
  ((with_dns)) && steps+=' dns'
  _optimize_run_list "$steps"
}

# dry_run_optimize — --dry-run: the plan, the exact sysctl diff and the /sys
# writes. Applies absolutely nothing.
dry_run_optimize() {
  plan_resolve
  ui_title "Dry Run — nothing will be applied"
  plan_show
  ui_hr
  sysctl_dry_run
  local plan eplan
  eplan="$(nic_ethtool_plan)"
  plan="$(nic_plan)"
  printf '\n%s[CPU/NIC writes]%s\n' "$C_TITLE" "$C_RESET"
  [[ -n $eplan ]] && awk -F'\t' '{printf "  ethtool %-52s %s\n", $1 " " $2, $3}' <<<"$eplan"
  if [[ -n $plan ]]; then
    awk -F'\t' '{printf "  %-60s %s\n", $1, $2}' <<<"$plan"
  elif [[ -z $eplan ]]; then
    printf '  (none on this host)\n'
  fi
  if [[ -n $eplan ]] && grep -q channels <<<"$eplan"; then
    printf '  %s(queue paths above are the current ones; the real run re-reads them after the channel change)%s\n' "$C_MUTED" "$C_RESET"
  fi
  docker_dry_run
  printf '\nA real run would also cover: live qdisc on %s, %snofile limits,\n' \
    "${ST_F_IFACE:-the uplink}" "$( ((ST_P_MSS)) && printf 'MSS clamping, ')"
  printf 'journald cap & NTP, swap%s.\n' "$([[ -n $ST_AUTO_DNS ]] && printf ', DNS')"
  if migrate_pending; then
    printf '%sThis host carries state from ServerTools 2.4.4 or older; a real run migrates it first.%s\n' "$C_WARN" "$C_RESET"
  fi
}

# _custom_pick_roles — multi-select from the catalog; Enter keeps detection.
_custom_pick_roles() {
  local entry id title desc i=1 answer pick out=''
  local -a ids=()
  printf '%s[Roles]%s detected: %s\n' "$C_TITLE" "$C_RESET" "$(roles_summary)"
  for entry in "${ST_ROLE_CATALOG[@]}"; do
    IFS=';' read -r id title desc <<<"$entry"
    ids+=("$id")
    ui_menu_item "$i" "$title" "$desc"
    i=$((i + 1))
  done
  read -rp "Select one or more (e.g. 1,4) [Enter=detected]: " answer || answer=''
  [[ -n $answer ]] || return 0
  while IFS= read -r pick; do
    [[ $pick =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#ids[@]})) && out+="${out:+,}${ids[pick - 1]}"
  done < <(ports_split "$answer")
  if [[ -n $out ]]; then
    roles_resolve "$out"
    ST_ROLES_SOURCE='manual'
    if ui_confirm "Remember these roles for future runs?"; then config_set roles "$out"; fi
  fi
  return 0
}

custom_optimize() {
  ui_logo
  ui_title "Custom Optimize"
  migrate_run
  roles_resolve
  _custom_pick_roles

  local tier_choice users_in
  capacity_resolve
  read -rp "Capacity tier — auto picked ${ST_TIER} (up to ${ST_TIER_USERS} users). Override [S/M/L/XL, Enter=keep]: " tier_choice || tier_choice=''
  case "${tier_choice^^}" in
    S | M | L | XL)
      # This run uses it either way; saving it is a separate choice.
      ST_CLI_TIER="${tier_choice^^}"
      ui_confirm "Remember tier ${ST_CLI_TIER} for future runs?" && config_set capacity_tier "$ST_CLI_TIER"
      ;;
  esac
  read -rp "Expected concurrent users [Enter=size by RAM, 0=reset saved value]: " users_in || users_in=''
  [[ $users_in =~ ^[0-9]+$ ]] && config_set expected_users "$users_in"
  capacity_resolve
  policy_resolve

  plan_show
  ui_hr
  if ! ui_confirm_yes "Apply sysctl + live qdisc tuning? (the core step)"; then
    printf 'Nothing to do without the core step.\n'
    ui_pause
    return 0
  fi
  local steps='sysctl qdisc'
  ui_confirm_yes "Tune the CPU/NIC data path (channels, offloads, IRQs, RPS/XPS as planned)?" && steps+=' perf'
  ((ST_P_MSS)) && ui_confirm_yes "Clamp MSS on forwarded TCP?" && steps+=' mss'
  ui_confirm_yes "Raise file-descriptor limits?" && steps+=' limits'
  ui_confirm_yes "Cap journald disk usage and enable NTP?" && steps+=' extras'
  ((ST_P_DOCKER)) && ui_confirm_yes "Bound Docker container logs, enable live-restore and container nofile?" && steps+=' docker'
  ui_confirm_yes "Create swap if none exists?" && steps+=' swap'
  dns_select_menu && steps+=' dns'

  printf '\n'
  if ! ui_confirm "Apply now?"; then
    ui_pause
    return 0
  fi
  _optimize_run_list "$steps"
  ui_pause
}
