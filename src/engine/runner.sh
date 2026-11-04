# shellcheck shell=bash
# ============================================================================
# engine/runner.sh — the step runner, the run summary, and the before/after
# counter snapshot.
#
# NOTE: steps run via `"$fn" || rc=$?`, which suppresses errexit for their
# whole body (bash semantics). Steps therefore signal outcomes with explicit
# return codes: 0=ok, 1=failed, 2=skipped, 3=applied with warnings.
# ============================================================================

ST_STEP_RESULTS=()
ST_STEP_IDX=0
ST_STEP_TOTAL=0

st_run_step() { # st_run_step TITLE FN [ARGS...]
  local title="$1" fn="$2" rc=0 note
  shift 2
  ST_STEP_IDX=$((ST_STEP_IDX + 1))
  printf '%s[%d/%d]%s %s ... ' "$C_KEY" "$ST_STEP_IDX" "$ST_STEP_TOTAL" "$C_RESET" "$title"

  # Keep the status line intact: notes are collected and printed below it.
  ST_LOG_BUFFER=()
  ST_LOG_BUFFERING=1
  "$fn" "$@" || rc=$?
  ST_LOG_BUFFERING=0
  case "$rc" in
    0)
      printf '%sOK%s\n' "$C_OK" "$C_RESET"
      ST_STEP_RESULTS+=("ok|${title}")
      ;;
    2)
      printf '%sSKIPPED%s\n' "$C_MUTED" "$C_RESET"
      ST_STEP_RESULTS+=("skip|${title}")
      ;;
    3)
      printf '%sWARN%s\n' "$C_WARN" "$C_RESET"
      ST_STEP_RESULTS+=("warn|${title}")
      st_escalate_exit 3
      ;;
    *)
      printf '%sFAILED%s\n' "$C_ERR" "$C_RESET"
      ST_STEP_RESULTS+=("fail|${title}")
      st_escalate_exit 1
      ;;
  esac

  for note in "${ST_LOG_BUFFER[@]-}"; do
    [[ -n $note ]] && printf '      %s%s%s\n' "$C_MUTED" "$note" "$C_RESET"
  done
  ST_LOG_BUFFER=()
  return 0
}

st_report_summary() {
  local entry status _title ok=0 warn=0 fail=0 skip=0
  for entry in "${ST_STEP_RESULTS[@]-}"; do
    [[ -n $entry ]] || continue
    IFS='|' read -r status _title <<<"$entry"
    case "$status" in
      ok) ok=$((ok + 1)) ;;
      warn) warn=$((warn + 1)) ;;
      skip) skip=$((skip + 1)) ;;
      fail) fail=$((fail + 1)) ;;
    esac
  done

  ui_hr
  if ((fail > 0)); then
    printf '%sCompleted with failures:%s %d ok, %d warned, %d skipped, %d failed — see the log.\n' \
      "$C_ERR" "$C_RESET" "$ok" "$warn" "$skip" "$fail"
  elif ((warn > 0)); then
    printf '%sCompleted with warnings:%s %d ok, %d warned, %d skipped — details in the log.\n' \
      "$C_WARN" "$C_RESET" "$ok" "$warn" "$skip"
  else
    printf '%sAll steps completed:%s %d applied, %d skipped.\n' "$C_OK" "$C_RESET" "$ok" "$skip"
  fi
  ui_kv "Backups" "$ST_RUN_BACKUP_DIR"
  ui_kv "Log" "$ST_LOG_FILE"
  ui_kv "Rollback" "menu → Rollback, or: st --rollback"
  ui_kv "Measure" "st --diagnose (per-core softirq, drops, queues)"
  printf '%sNo daemons or cron jobs were installed — nothing stays running.%s\n' "$C_MUTED" "$C_RESET"
}

# --- Before/after snapshot -------------------------------------------------
# Kernel counters captured before the first change, so the effect of the
# tuning can be shown later instead of merely claimed.

readonly ST_SNAPSHOT_FILE="${ST_LIB_DIR}/snapshot.tsv"

_snapshot_counters() {
  local retrans='0' insegs='0' outsegs='0' drops='0' ct='0' sn_drop='0'
  if [[ -r /proc/net/snmp ]]; then
    # IFS forced to a space: the global IFS has none, so awk's output would
    # land entirely in $retrans. A missing snmp table keeps the defaults.
    IFS=' ' read -r retrans insegs outsegs < <(awk '
      /^Tcp:/ { if (!h) { for (i = 1; i <= NF; i++) idx[$i] = i; h = 1; next }
                print $idx["RetransSegs"], $idx["InSegs"], $idx["OutSegs"]; exit }' /proc/net/snmp) ||
      retrans=0
  fi
  if [[ -r /proc/net/dev ]]; then
    drops="$(awk 'NR > 2 {rx += $5; tx += $12} END {print rx + tx + 0}' /proc/net/dev)"
  fi
  if [[ -r /proc/net/softnet_stat ]]; then
    # Hex columns; parsed in bash because mawk (Debian's awk) has no strtonum.
    local _p d _r
    while IFS=' ' read -r _p d _r; do
      [[ $d =~ ^[0-9a-fA-F]+$ ]] && sn_drop=$((sn_drop + 16#$d))
    done </proc/net/softnet_stat
  fi
  ct="$(sysctl_get net.netfilter.nf_conntrack_count)"
  [[ $ct =~ ^[0-9]+$ ]] || ct=0
  printf '%s\t%s\t%s\t%s\t%s\t%s' "${retrans:-0}" "${insegs:-0}" "${outsegs:-0}" "${drops:-0}" "$ct" "${sn_drop:-0}"
}

snapshot_save() {
  ((ST_DRY_RUN)) && return 0
  local now
  now="$(_snapshot_counters)" || return 0
  printf 'taken_at\t%s\n' "$(date '+%F %T')" >"$ST_SNAPSHOT_FILE"
  printf 'counters\t%s\n' "$now" >>"$ST_SNAPSHOT_FILE"
  log_debug "baseline snapshot stored"
}

# snapshot_report — deltas since the baseline; 2 when none was taken.
snapshot_report() {
  [[ -f $ST_SNAPSHOT_FILE ]] || return 2
  local taken old new
  taken="$(awk -F'\t' '$1 == "taken_at" {print $2; exit}' "$ST_SNAPSHOT_FILE")"
  old="$(awk -F'\t' '$1 == "counters" {print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" ($7 == "" ? 0 : $7); exit}' "$ST_SNAPSHOT_FILE")"
  new="$(_snapshot_counters)"

  local o_re o_in o_out o_drop _o_ct o_sn n_re n_in n_out n_drop n_ct n_sn
  IFS=$'\t' read -r o_re o_in o_out o_drop _o_ct o_sn <<<"$old"
  IFS=$'\t' read -r n_re n_in n_out n_drop n_ct n_sn <<<"$new"

  local d_re=$((n_re - o_re)) d_seg=$((n_in - o_in + n_out - o_out)) d_drop=$((n_drop - o_drop))
  local d_sn=$((n_sn - ${o_sn:-0}))
  ui_kv "Baseline taken" "$taken"
  if ((d_seg > 0)); then
    ui_kv "TCP retransmits" "${d_re} of ${d_seg} segments ($((d_re * 1000 / d_seg))‰ since baseline)"
  else
    ui_kv "TCP retransmits" "${d_re} since baseline"
  fi
  ui_kv "Interface drops" "${d_drop} since baseline"
  ((d_sn >= 0)) && ui_kv "Backlog drops" "${d_sn} since baseline (softnet)"
  ui_kv "Conntrack now" "$n_ct"
  return 0
}
