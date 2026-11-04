# shellcheck shell=bash
# ============================================================================
# state/migrate.sh — one-time upgrade of a host tuned by ServerTools pre-2.4.5.
#
# pre-2.4.5 state stays valid for rollback (the manifest format is a superset), but
# pre-2.4.5 left four things live on servers that 2.4.5 now knows to be wrong. They are
# fixed here, once, as tracked changes of the current run — so a rollback of
# this run reverts the migration too:
#   1. the MSS unit had no ExecStop and re-appended a duplicate rule on every
#      restart;
#   2. NOTRACK rules matched forwarded traffic too (breaks NAT/VPN clients
#      on the proxy port);
#   3. `tc qdisc replace root fq` collapsed a multi-queue NIC's mq into one
#      root qdisc (one lock for every CPU);
#   4. the CPU/NIC boot script mapped every CPU to every TX queue and ran RPS
#      regardless of role — re-planned on the next optimize run.
# Never runs under --dry-run, --status or --rollback.
# ============================================================================

ST_MIGRATE_NOTES=()

# migrate_pending — 0 when this host carries pre-2.4.5 state not yet migrated.
migrate_pending() {
  [[ "$(config_get schema '')" == "$ST_SCHEMA" ]] && return 1
  [[ -f $ST_MANIFEST_FILE ]] && (($(manifest_entry_count) > 0))
}

_migrate_mss_unit() {
  [[ -f $ST_MSS_UNIT ]] || return 0
  grep -q '^ExecStop=' "$ST_MSS_UNIT" && return 0
  fw_has_iptables || return 0
  # Collapse the duplicates pre-2.4.5 unit appended into exactly one live rule.
  fw_rule_remove iptables mangle FORWARD "${ST_MSS_RULE[@]}" || log_warn "Could not de-duplicate the IPv4 MSS rule."
  fw_rule_ensure iptables mangle FORWARD "${ST_MSS_RULE[@]}" || log_warn "Could not re-add the IPv4 MSS rule."
  if has_cmd ip6tables; then
    fw_rule_remove ip6tables mangle FORWARD "${ST_MSS_RULE[@]}" || log_debug "no IPv6 MSS duplicates"
    fw_rule_ensure ip6tables mangle FORWARD "${ST_MSS_RULE[@]}" || log_debug "no IPv6 netfilter"
  fi
  st_track_file "$ST_MSS_UNIT"
  _mss_unit_iptables >"$ST_MSS_UNIT"
  ST_MIGRATE_NOTES+=("MSS unit: idempotent start + ExecStop (no duplicate rules; rollback removes it live)")
}

_migrate_notrack() {
  local rc=0
  notrack_migrate_v2 || rc=$?
  case "$rc" in
    0) ST_MIGRATE_NOTES+=("NOTRACK rules now match only traffic addressed to this host (NAT/VPN clients on the same port work again)") ;;
    1) log_warn "Could not migrate the NOTRACK rules of the older version — re-apply them from Network tools → n." ;;
  esac
  return 0
}

_migrate_qdisc() {
  local kind handle txq
  [[ -n $ST_F_IFACE ]] || return 0
  txq="$(net_iface_queues "$ST_F_IFACE" tx)"
  ((txq > 1)) || return 0
  IFS=' ' read -r kind handle <<<"$(net_root_qdisc "$ST_F_IFACE")"
  [[ $kind == fq || $kind == fq_codel ]] || return 0
  [[ $handle != 0: ]] || return 0
  st_track_qdisc "$ST_F_IFACE"
  if qdisc_reattach_default "$ST_F_IFACE"; then
    ST_MIGRATE_NOTES+=("${ST_F_IFACE}: single root ${kind} replaced by mq (${txq} TX queues no longer share one lock)")
  else
    log_warn "Could not rebuild the qdisc on ${ST_F_IFACE} — it is corrected at the next reboot."
  fi
}

_migrate_perf() {
  [[ -f $ST_PERF_BOOT ]] || return 0
  grep -q '^printf %s ' "$ST_PERF_BOOT" || return 0
  ST_MIGRATE_NOTES+=("CPU/NIC tuning is from an older version (RPS/XPS not role-aware) — the next Quick Optimize re-plans it")
}

# migrate_unit_order — rule units written by earlier versions started BEFORE
# the firewall managers, which then flushed their rules at boot. Re-order
# them in place (tracked); runs before every optimize, a no-op once fixed.
migrate_unit_order() {
  ((ST_DRY_RUN)) && return 0
  local unit fixed=0
  for unit in "$ST_MSS_UNIT" "$ST_NOTRACK_UNIT" "$ST_FT_UNIT"; do
    [[ -f $unit ]] || continue
    grep -q '^After=.*firewalld\.service' "$unit" && continue
    st_track_file "$unit"
    sed -i "s|^After=\(.*\)$|After=\1 ${ST_FW_AFTER}|" "$unit"
    fixed=$((fixed + 1))
  done
  ((fixed)) || return 0
  has_cmd systemctl && { systemctl daemon-reload 2>>"$ST_LOG_FILE" || log_warn "daemon-reload failed."; }
  log_info "${fixed} firewall rule unit(s) now start after the firewall managers (rules survive reboots)."
  return 0
}

# migrate_run — perform the migration once; prints what changed.
migrate_run() {
  ((ST_DRY_RUN)) && return 0
  migrate_unit_order
  if ! migrate_pending; then
    [[ "$(config_get schema '')" == "$ST_SCHEMA" ]] || config_set schema "$ST_SCHEMA"
    return 0
  fi
  facts_collect
  ST_MIGRATE_NOTES=()
  log_info "Migrating ServerTools 2.4.4-or-older state to schema ${ST_SCHEMA}."
  _migrate_mss_unit
  _migrate_notrack
  _migrate_qdisc
  _migrate_perf
  has_cmd systemctl && { systemctl daemon-reload 2>>"$ST_LOG_FILE" || log_warn "daemon-reload failed."; }

  local last
  last="$(config_get last_profile '')"
  if [[ -n $last && -z $(config_get last_roles '') ]]; then
    config_set last_roles "$(roles_from_profile "$last" | tr ' ' ',' || printf '%s' "$last")"
  fi
  config_set schema "$ST_SCHEMA"

  if ((${#ST_MIGRATE_NOTES[@]})); then
    printf '%sUpgraded this host from ServerTools 2.4.4 or older:%s\n' "$C_TITLE" "$C_RESET"
    local n
    for n in "${ST_MIGRATE_NOTES[@]}"; do
      printf '  %s %s\n' "$(ui_badge ok)" "$n"
      log_info "migrate: ${n}"
    done
    printf '\n'
  fi
  return 0
}
