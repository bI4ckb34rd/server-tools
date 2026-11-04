# shellcheck shell=bash
# ============================================================================
# state/manifest.sh — the append-only change log rollback replays.
#
# One TSV row per change: timestamp, run_id, action, target. Actions:
#   created     a file that did not exist (rollback deletes it)
#   modified    a file that existed (rollback restores the run backup)
#   unit        a systemd unit the run enabled (rollback disables it)
#   runtime     a live /proc or /sys value (rollback writes the old value back)
#   qdisc       an interface whose root qdisc was rebuilt (rollback re-attaches
#               the kernel default after sysctl files are restored)
#   ethtool     "IFACE/KEY": NIC channels or an offload (rollback re-applies
#               the saved value with ethtool)
#   package     informational: a prerequisite installed (never removed)
#   rolledback  marker: run <target> has been rolled back (never replayed)
#
# pre-2.4.5 manifests only contain created/modified/unit and remain valid as-is.
# File order IS time order, so "latest run" never depends on sorting ids.
# ============================================================================

readonly ST_MANIFEST_CHANGE_ACTIONS='created|modified|unit|runtime|qdisc|ethtool'

manifest_add() { # manifest_add ACTION TARGET
  ((ST_DRY_RUN)) && return 0
  printf '%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$ST_RUN_ID" "$1" "$2" >>"$ST_MANIFEST_FILE"
}

manifest_entry_count() {
  [[ -f $ST_MANIFEST_FILE ]] || {
    printf '0'
    return 0
  }
  awk -F'\t' -v re="^(${ST_MANIFEST_CHANGE_ACTIONS})$" 'NR > 1 && $3 ~ re' "$ST_MANIFEST_FILE" |
    wc -l | tr -d '[:space:]'
}

# manifest_open_runs — run ids that recorded changes and were not rolled
# back yet, oldest first.
manifest_open_runs() {
  [[ -f $ST_MANIFEST_FILE ]] || return 0
  awk -F'\t' -v re="^(${ST_MANIFEST_CHANGE_ACTIONS})$" '
    NR > 1 && $3 == "rolledback" { done[$4] = 1; next }
    NR > 1 && $3 ~ re && !($2 in seen) { seen[$2] = 1; order[++n] = $2 }
    END { for (i = 1; i <= n; i++) if (!(order[i] in done)) print order[i] }' "$ST_MANIFEST_FILE"
}

# manifest_latest_run — the newest open run ("" if none). Because rolled-back
# runs are skipped, rolling back twice walks one run further into the past
# instead of re-applying the same backup (a pre-2.4.5 limitation).
manifest_latest_run() {
  manifest_open_runs | tail -n1
}

# manifest_rows RUN — "action<TAB>target" rows of RUN, oldest first.
manifest_rows() {
  [[ -f $ST_MANIFEST_FILE ]] || return 0
  awk -F'\t' -v run="$1" 'NR > 1 && $2 == run {print $3 "\t" $4}' "$ST_MANIFEST_FILE"
}

# manifest_targets ACTION — every target ever recorded with ACTION.
manifest_targets() {
  [[ -f $ST_MANIFEST_FILE ]] || return 0
  awk -F'\t' -v a="$1" 'NR > 1 && $3 == a {print $4}' "$ST_MANIFEST_FILE" | sort -u
}

manifest_mark_rolled_back() { # manifest_mark_rolled_back RUN
  manifest_add rolledback "$1"
}
