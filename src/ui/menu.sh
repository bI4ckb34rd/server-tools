# shellcheck shell=bash
# ============================================================================
# ui/menu.sh — interactive main menu and sub-screens.
# The dashboard must render instantly: everything network-bound is cached
# (public IP is fetched at most once per process, in lib/net.sh).
# ============================================================================

# _dash_row LABEL VALUE — one compact dashboard line.
_dash_row() {
  printf '  %s%-9s%s %s\n' "$C_KEY" "$1" "$C_RESET" "$2"
}

menu_dashboard() {
  ui_logo
  local applied status
  applied="$(config_get last_roles '')"
  if [[ -n $applied ]]; then
    status="$(ui_badge ok) optimized ${C_MUTED}· ${applied//,/, } · tier $(config_get last_tier '-')${C_RESET}"
    # Tuning that a reboot or another tool undid must not read as "optimized".
    if ! sysctl_verify >/dev/null 2>&1 && ((${#ST_SYSCTL_DRIFT[@]})); then
      status="$(ui_badge warn) ${#ST_SYSCTL_DRIFT[@]} kernel setting(s) no longer in effect ${C_MUTED}· press 4 (Doctor) or 1 to re-apply${C_RESET}"
    fi
  else
    status="$(ui_badge idle) not optimized yet ${C_MUTED}· run Quick Optimize${C_RESET}"
  fi
  _dash_row "Host" "$(hostname 2>/dev/null || printf 'unknown') · $(os_pretty_name) · $(kernel_release)"
  _dash_row "Machine" "${ST_F_CPUS} vCPU · ${ST_F_RAM_MB} MB RAM · up $(uptime_pretty)"
  _dash_row "Network" "$(net_public_ip4) · cc=$(sysctl_get net.ipv4.tcp_congestion_control) · $(sysctl_get net.core.default_qdisc) · IPv6 $(ipv6_state)"
  _dash_row "Roles" "${ST_DETECTED_ROLES// /, } · $(engines_summary)"
  _dash_row "State" "$status"
}

menu_rollback() {
  ui_logo
  ui_title "Rollback"
  local run choice
  run="$(manifest_latest_run)"
  if [[ -z $run ]]; then
    printf 'No recorded changes left to roll back.\n'
    ui_pause
    return 0
  fi
  printf 'Newest open run: %s%s%s · %s change(s) recorded in total\n' \
    "$C_ACCENT" "$run" "$C_RESET" "$(manifest_entry_count)"
  ui_hr
  ui_menu_item 1 "Undo the newest run" "files, units and live values; again = one run further back"
  ui_menu_item 2 "Restore original state" "back to before ServerTools ever ran"
  ui_menu_item 0 "Back"
  read -rp "$(_ui_prompt)" choice || return 0
  case "${choice:-}" in
    1) if ui_confirm "Revert all changes from run ${run}?"; then rollback_latest || st_escalate_exit 3; fi ;;
    2)
      printf '%sThis undoes every ServerTools change on this host.%s\n' "$C_WARN" "$C_RESET"
      if ui_confirm "Restore the original (factory) state?"; then rollback_original || st_escalate_exit 3; fi
      ;;
    *) return 0 ;;
  esac
  ui_pause
}

# _settings_edit — change one registered config key, validated.
_settings_edit() {
  local key value
  read -rp "Key to change (Enter = cancel): " key || return 0
  [[ -n $key ]] || return 0
  if ! config_known "$key"; then
    printf '%sUnknown key%s %s.\n' "$C_ERR" "$C_RESET" "$key"
    return 0
  fi
  read -rp "New value for ${key} (current: $(config_get "$key"); 'default' resets): " value || return 0
  if [[ $value == default ]]; then
    config_unset "$key"
    printf 'Reset %s to its default (%s).\n' "$key" "$(config_default "$key")"
  elif config_validate "$key" "$value"; then
    config_set "$key" "$value"
    printf '%sSaved.%s It applies on the next optimize run.\n' "$C_OK" "$C_RESET"
  else
    printf '%sInvalid value%s for %s — nothing changed.\n' "$C_ERR" "$C_RESET" "$key"
  fi
  return 0
}

menu_settings() {
  local choice
  while true; do
    ui_logo
    ui_title "Settings & Maintenance"
    ui_kv "Version" "$ST_VERSION"
    ui_kv "Config file" "$ST_CONFIG_FILE"
    ui_kv "Log file" "$ST_LOG_FILE"
    ui_kv "Backups" "$ST_BACKUP_DIR"
    ui_kv "Recorded changes" "$(manifest_entry_count)"
    ui_section "Tunables"
    config_print
    ui_hr
    ui_menu_item 1 "Change a setting" "validated; applies on the next optimize"
    ui_menu_item 2 "Install 'st' command" "run 'st' instead of the one-liner"
    ui_menu_item 3 "Check for updates" "self-update from the latest release"
    ui_menu_item 0 "Back"
    read -rp "$(_ui_prompt)" choice || return 0
    case "${choice:-}" in
      1)
        _settings_edit
        ui_pause
        ;;
      2)
        st_self_install || log_warn "Install did not complete."
        ui_pause
        ;;
      3)
        st_self_update || log_warn "Update did not complete."
        ui_pause
        ;;
      0) return 0 ;;
      *) ui_invalid ;;
    esac
  done
}

main_menu() {
  facts_collect
  roles_detect
  if migrate_pending; then
    ui_logo
    printf '%sThis host was tuned by ServerTools 2.4.4 or older.%s This version fixes a few things it left live\n' "$C_WARN" "$C_RESET"
    printf '(MSS/NOTRACK rules, a single-lock qdisc on multi-queue NICs). The changes are\n'
    printf 'tracked, so a rollback undoes them.\n'
    if ui_confirm_yes "Apply these fixes now?"; then migrate_run; fi
    ui_pause
  fi
  local choice
  while true; do
    menu_dashboard
    ui_hr
    ui_menu_group "Optimize"
    ui_menu_item 1 "Quick Optimize" "detect roles and tune safely · recommended"
    ui_menu_item 2 "Custom Optimize" "choose roles, capacity and steps"
    ui_menu_group "Inspect"
    ui_menu_item 3 "System Status" "full live report"
    ui_menu_item 4 "Doctor" "drift check — still in effect?"
    ui_menu_item d "Diagnose data path" "why is a core hot? measured, read-only"
    ui_menu_group "Manage"
    ui_menu_item 5 "Rollback" "undo changes safely"
    ui_menu_item 6 "Security" "UFW · fail2ban · SSH"
    ui_menu_item 7 "Network & VPN Tools" "MSS · NOTRACK · fast path · speed"
    ui_menu_item 8 "Node & Docker" "backups · installers · Docker engine"
    ui_menu_item i "IPv6 on / off" "now: $(ipv6_state) · stays that way after reboot"
    ui_menu_group "System"
    ui_menu_item 9 "Settings" "tunables · install · update"
    ui_menu_item 0 "Exit"
    printf '\n'
    ui_hint "New here? Press 1 — it detects what this server does and tunes it safely."
    read -rp "$(_ui_prompt)" choice || {
      printf '\n'
      return 0
    }
    case "${choice:-}" in
      1) quick_optimize ;;
      2) custom_optimize ;;
      3) show_status ;;
      4)
        doctor_run || st_escalate_exit 3 # drift is reported on screen
        ui_pause
        ;;
      d | D)
        diagnose_network || st_escalate_exit 3
        ui_pause
        ;;
      5) menu_rollback ;;
      6) security_menu ;;
      7) tools_menu ;;
      8) node_menu ;;
      i | I)
        ui_logo
        ipv6_control
        ui_pause
        ;;
      9) menu_settings ;;
      0) return 0 ;;
      *) ui_invalid ;;
    esac
  done
}
