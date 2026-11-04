# shellcheck shell=bash
# ============================================================================
# state/backup.sh — track-before-touch and manifest-driven rollback.
#
# Contract: call `st_track_file PATH` BEFORE creating or
# modifying PATH, and `st_set_runtime PATH VALUE` for every live /proc or
# /sys write. That yields:
#   - a pristine copy under original/ the first time the tool ever touches a
#     file (never overwritten afterwards); runtime values likewise under
#     original/.runtime/,
#   - a per-run copy under runs/<run-id>/ (runtime values under .runtime/),
#   - a manifest row for rollback.
#
# 2.4.5 closes pre-2.4.5 runtime gap: RPS/XPS masks, governor, THP and the live
# qdisc are now restored by rollback, not only after a reboot.
# ============================================================================

# Paths already captured in this run. Tracking twice would overwrite the run
# backup with our own edit and silently break rollback.
declare -A ST_TRACKED=()
readonly ST_RUNTIME_SUBDIR='.runtime'

st_track_file() {
  local path="$1"
  ((ST_DRY_RUN)) && return 0
  [[ -n ${ST_TRACKED[$path]:-} ]] && return 0
  ST_TRACKED[$path]=1

  mkdir -p "$ST_RUN_BACKUP_DIR"
  if [[ -e $path || -L $path ]]; then
    if [[ ! -e ${ST_ORIGINAL_DIR}${path} && ! -L ${ST_ORIGINAL_DIR}${path} ]]; then
      mkdir -p "${ST_ORIGINAL_DIR}$(dirname "$path")"
      cp -a "$path" "${ST_ORIGINAL_DIR}${path}"
    fi
    mkdir -p "${ST_RUN_BACKUP_DIR}$(dirname "$path")"
    cp -a "$path" "${ST_RUN_BACKUP_DIR}${path}"
    manifest_add modified "$path"
    log_debug "tracked (modified): $path"
  else
    manifest_add created "$path"
    log_debug "tracked (created): $path"
  fi
}

# st_write_file PATH CONTENT — write CONTENT (plus a newline) to PATH only
# when it differs, tracking the file first. 0 = written, 1 = already
# identical (nothing tracked, nothing touched — re-runs stay no-ops).
st_write_file() {
  local path="$1" content="$2"
  if [[ -f $path && "$(cat "$path" 2>/dev/null)" == "$content" ]]; then
    return 1
  fi
  st_track_file "$path"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" >"$path"
}

# runtime_read PATH — the effective value of a /proc or /sys knob. Selector
# files ("always [madvise] never") are reduced to the bracketed choice, so
# the saved value can be written back verbatim.
runtime_read() {
  local raw
  raw="$(cat "$1" 2>/dev/null)" || return 1
  if [[ $raw =~ \[([^]]+)\] ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$raw"
  fi
}

# st_set_runtime PATH VALUE — record the current value, then write VALUE.
# Returns the write's status (a read-only knob is a normal outcome on
# containers; the caller counts it).
st_set_runtime() {
  local path="$1" value="$2" cur
  [[ -w $path ]] || return 1
  if ((ST_DRY_RUN)); then
    return 0
  fi
  if [[ -z ${ST_TRACKED[$path]:-} ]] && cur="$(runtime_read "$path")"; then
    ST_TRACKED[$path]=1
    local orig="${ST_ORIGINAL_DIR}/${ST_RUNTIME_SUBDIR}${path}"
    local run="${ST_RUN_BACKUP_DIR}/${ST_RUNTIME_SUBDIR}${path}"
    if [[ ! -e $orig ]]; then
      mkdir -p "$(dirname "$orig")"
      printf '%s' "$cur" >"$orig"
    fi
    mkdir -p "$(dirname "$run")"
    printf '%s' "$cur" >"$run"
    manifest_add runtime "$path"
  fi
  printf '%s\n' "$value" >"$path" 2>>"$ST_LOG_FILE"
}

# st_set_ethtool IFACE KEY VALUE — record the current NIC setting (channel
# count or an offload), then change it with ethtool.
st_set_ethtool() {
  local iface="$1" key="$2" value="$3" cur rel="ethtool/$1/$2"
  ((ST_DRY_RUN)) && return 0
  cur="$(ethtool_read "$iface" "$key")"
  [[ -n $cur && $cur != fixed ]] || return 1
  [[ $cur == "$value" ]] && return 0
  if [[ -z ${ST_TRACKED[$rel]:-} ]]; then
    ST_TRACKED[$rel]=1
    local orig="${ST_ORIGINAL_DIR}/${ST_RUNTIME_SUBDIR}/${rel}"
    local run="${ST_RUN_BACKUP_DIR}/${ST_RUNTIME_SUBDIR}/${rel}"
    if [[ ! -e $orig ]]; then
      mkdir -p "$(dirname "$orig")"
      printf '%s' "$cur" >"$orig"
    fi
    mkdir -p "$(dirname "$run")"
    printf '%s' "$cur" >"$run"
    manifest_add ethtool "${iface}/${key}"
  fi
  ethtool_write "$iface" "$key" "$value"
}

# _restore_ethtool SAVED IFACE/KEY — re-apply a saved NIC setting.
_restore_ethtool() {
  local saved="$1" iface="${2%%/*}" key="${2#*/}"
  [[ -r $saved && -d /sys/class/net/$iface ]] || return 1
  ethtool_write "$iface" "$key" "$(cat "$saved")"
}

# st_track_qdisc IFACE — note that the live root qdisc of IFACE is rebuilt.
st_track_qdisc() {
  local key="qdisc@$1"
  ((ST_DRY_RUN)) && return 0
  [[ -n ${ST_TRACKED[$key]:-} ]] && return 0
  ST_TRACKED[$key]=1
  manifest_add qdisc "$1"
}

# _restore_runtime SAVED TARGET — write a saved runtime value back.
_restore_runtime() {
  local saved="$1" target="$2" value
  [[ -r $saved && -w $target ]] || return 1
  value="$(cat "$saved")"
  printf '%s\n' "$value" >"$target" 2>>"$ST_LOG_FILE"
}

# backup_prune [KEEP] — keep the newest KEEP run directories (default 10).
# original/ is never touched: it is the only way back to the factory state.
backup_prune() {
  local keep="${1:-10}" runs="${ST_BACKUP_DIR}/runs" dir
  ((ST_DRY_RUN)) && return 0
  [[ -d $runs ]] || return 0
  while IFS= read -r dir; do
    [[ -n $dir ]] || continue
    rm -rf "${runs:?}/${dir}" || log_warn "Could not prune the old backup ${dir}."
    log_debug "pruned old run backup: ${dir}"
  done < <(find "$runs" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null |
    sort -rn | awk -v k="$keep" 'NR > k {print $2}')
}

# _swapoff_if_active FILE — never delete an active swap file under the kernel.
_swapoff_if_active() {
  [[ -r /proc/swaps ]] || return 0
  awk -v f="$1" 'NR > 1 && $1 == f {found = 1} END {exit !found}' /proc/swaps || return 0
  swapoff "$1" 2>>"$ST_LOG_FILE"
}

# _rollback_reload_runtime SYSCTL UNITS IFACES — post-restore reloads shared by
# both rollback flavours: units, sysctl, then qdisc re-attachment (which must
# come AFTER sysctl so the restored default_qdisc is the one re-attached).
_rollback_reload_runtime() {
  local sysctl_touched="$1" units_touched="$2" ifaces="$3" iface
  if ((units_touched)) && has_cmd systemctl; then
    systemctl daemon-reload 2>>"$ST_LOG_FILE" || log_warn "daemon-reload after rollback failed."
  fi
  if ((sysctl_touched)) && has_cmd sysctl; then
    sysctl --system >/dev/null 2>>"$ST_LOG_FILE" ||
      log_warn "sysctl reload after rollback reported errors (see log)."
  fi
  while IFS= read -r iface; do
    [[ -n $iface && -d /sys/class/net/$iface ]] || continue
    qdisc_reattach_default "$iface" ||
      log_warn "Could not re-attach the default qdisc on ${iface} (it is restored at reboot)."
  done <<<"$ifaces"
  return 0
}

# rollback_latest — revert the newest open run, newest change first.
rollback_latest() {
  local run
  run="$(manifest_latest_run)"
  if [[ -z $run ]]; then
    log_warn "No recorded changes left to roll back."
    return 0
  fi

  local src="${ST_BACKUP_DIR}/runs/${run}"
  local action target restored=0 removed=0 missing=0 failed=0
  local sysctl_touched=0 units_touched=0 qdisc_ifaces=''
  while IFS=$'\t' read -r action target; do
    case "$action" in
      unit)
        # Disable (and stop) before the unit file is removed below, so no
        # dangling .wants symlink survives. ExecStop= lines undo live rules.
        if has_cmd systemctl; then
          systemctl disable --now "$target" >/dev/null 2>>"$ST_LOG_FILE" ||
            log_warn "Could not disable unit ${target}."
          units_touched=1
        fi
        ;;
      modified)
        if [[ -e ${src}${target} || -L ${src}${target} ]]; then
          if cp -a "${src}${target}" "$target" 2>>"$ST_LOG_FILE"; then
            restored=$((restored + 1))
          else
            failed=$((failed + 1))
            log_warn "Could not restore ${target}."
          fi
          [[ $target == /etc/sysctl.d/* || $target == /etc/sysctl.conf ]] && sysctl_touched=1
        else
          log_warn "Backup missing for ${target} — skipped."
          missing=$((missing + 1))
        fi
        ;;
      created)
        if ! _swapoff_if_active "$target"; then
          log_warn "Cannot swapoff ${target} — left in place."
          failed=$((failed + 1))
          continue
        fi
        if rm -f "$target" 2>>"$ST_LOG_FILE"; then
          removed=$((removed + 1))
        else
          failed=$((failed + 1))
        fi
        [[ $target == /etc/sysctl.d/* ]] && sysctl_touched=1
        ;;
      runtime)
        if _restore_runtime "${src}/${ST_RUNTIME_SUBDIR}${target}" "$target"; then
          restored=$((restored + 1))
        else
          log_warn "Could not restore the live value of ${target} (reboot restores it)."
          missing=$((missing + 1))
        fi
        ;;
      ethtool)
        if _restore_ethtool "${src}/${ST_RUNTIME_SUBDIR}/ethtool/${target}" "$target"; then
          restored=$((restored + 1))
        else
          log_warn "Could not restore NIC setting ${target} (reboot restores it)."
          missing=$((missing + 1))
        fi
        ;;
      qdisc) qdisc_ifaces+="${target}"$'\n' ;;
    esac
  done < <(manifest_rows "$run" | tac)

  _rollback_reload_runtime "$sysctl_touched" "$units_touched" "$qdisc_ifaces"
  manifest_mark_rolled_back "$run"

  log_info "Rollback of run ${run}: ${restored} restored, ${removed} removed, ${missing} missing, ${failed} failed."
  printf '%sRollback of run %s:%s %d restored, %d removed' "$C_OK" "$run" "$C_RESET" "$restored" "$removed"
  ((missing > 0)) && printf ', %s%d missing%s' "$C_WARN" "$missing" "$C_RESET"
  ((failed > 0)) && printf ', %s%d failed%s' "$C_ERR" "$failed" "$C_RESET"
  printf '\n'
  local next
  next="$(manifest_latest_run)"
  [[ -n $next ]] && printf '%sRolling back again would undo the earlier run %s.%s\n' "$C_MUTED" "$next" "$C_RESET"
  ((failed == 0)) || return 3
  return 0
}

# rollback_original — restore everything to how it was before ServerTools
# first touched it, across all runs, and remove everything it created.
rollback_original() {
  if [[ ! -d $ST_ORIGINAL_DIR ]] && [[ -z "$(manifest_open_runs)" ]]; then
    log_warn "No recorded changes — nothing to restore."
    return 0
  fi

  local file target restored=0 removed=0 failed=0 rt="${ST_ORIGINAL_DIR}/${ST_RUNTIME_SUBDIR}"
  # Restore first, then remove created files: a path can be "created" in one
  # run and "modified" later, and the original must win.
  if [[ -d $ST_ORIGINAL_DIR ]]; then
    while IFS= read -r file; do
      target="${file#"$ST_ORIGINAL_DIR"}"
      [[ -n $target ]] || continue
      mkdir -p "$(dirname "$target")"
      if cp -a "$file" "$target" 2>>"$ST_LOG_FILE"; then
        restored=$((restored + 1))
      else
        failed=$((failed + 1))
      fi
    done < <(find "$ST_ORIGINAL_DIR" -path "$rt" -prune -o \( -type f -o -type l \) -print 2>/dev/null)
  fi

  while IFS= read -r target; do
    [[ -n $target ]] || continue
    [[ -e ${ST_ORIGINAL_DIR}${target} ]] && continue # pre-existing: restored above
    if ! _swapoff_if_active "$target"; then
      log_warn "Cannot swapoff ${target} — left in place."
      failed=$((failed + 1))
      continue
    fi
    rm -f "$target" && removed=$((removed + 1))
  done < <(manifest_targets created)

  local unit
  while IFS= read -r unit; do
    [[ -n $unit ]] || continue
    has_cmd systemctl || break
    systemctl disable --now "$unit" >/dev/null 2>>"$ST_LOG_FILE" || log_warn "Could not disable unit ${unit}."
  done < <(manifest_targets unit)

  if [[ -d $rt ]]; then
    while IFS= read -r file; do
      target="${file#"$rt"}"
      if [[ $target == /ethtool/* ]]; then
        _restore_ethtool "$file" "${target#/ethtool/}" && restored=$((restored + 1))
      else
        _restore_runtime "$file" "$target" && restored=$((restored + 1))
      fi
    done < <(find "$rt" -type f 2>/dev/null)
  fi

  _rollback_reload_runtime 1 1 "$(manifest_targets qdisc)"

  local run
  while IFS= read -r run; do
    [[ -n $run ]] && manifest_mark_rolled_back "$run"
  done < <(manifest_open_runs)

  log_info "Factory restore: ${restored} restored, ${removed} removed, ${failed} failed."
  printf '%sRestored to the state before ServerTools ever ran:%s %d restored, %d removed.\n' \
    "$C_OK" "$C_RESET" "$restored" "$removed"
  ((failed > 0)) && printf '%s%d item(s) could not be restored — see the log.%s\n' "$C_ERR" "$failed" "$C_RESET"
  printf '%sA reboot guarantees every runtime setting is back as well.%s\n' "$C_MUTED" "$C_RESET"
  ((failed == 0)) || return 3
  return 0
}
