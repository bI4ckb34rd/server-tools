# shellcheck shell=bash
# ============================================================================
# tuners/qdisc.sh — put the chosen default qdisc live on the uplink, the
# multi-queue-safe way.
#
# net.core.default_qdisc only affects qdiscs created AFTER it is set. pre-2.4.5
# forced it live with `tc qdisc replace dev X root fq`, which on a
# multi-queue NIC replaces `mq` (one child per TX queue) with ONE root qdisc:
# every CPU then serialises on a single qdisc lock. 2.4.5 instead asks the
# kernel to re-attach its defaults, which rebuilds mq with the new child
# kind on multi-queue NICs and a single qdisc on single-queue ones.
#
# Custom root qdiscs (htb, cake, tbf shaping set up by an operator or a
# tunnel manager) are never touched.
# ============================================================================

# Root kinds we consider "default-shaped" and may rebuild.
readonly ST_QDISC_MANAGED='mq fq fq_codel pfifo_fast pfifo'

_qdisc_children_kind() { # _qdisc_children_kind IFACE — kinds under mq, one per line
  local out
  out="$(tc qdisc show dev "$1" 2>/dev/null)" || return 0
  awk '$4 == "parent" {print $2}' <<<"$out" | sort -u
}

# qdisc_reattach_default IFACE — rebuild IFACE's root from the CURRENT
# net.core.default_qdisc. Also used by rollback after sysctl is restored.
qdisc_reattach_default() {
  local iface="$1" kind handle txq def
  has_cmd tc || return 1
  IFS=' ' read -r kind handle <<<"$(net_root_qdisc "$iface")"
  [[ -n $kind ]] || return 1
  [[ " ${ST_QDISC_MANAGED} " == *" ${kind} "* ]] || return 0
  txq="$(net_iface_queues "$iface" tx)"
  def="$(sysctl_get net.core.default_qdisc)"
  if [[ $handle != 0: ]]; then
    # A qdisc we (or pre-2.4.5) created: deleting it makes the kernel attach the
    # defaults again (mq + default children, or the default kind).
    tc qdisc del dev "$iface" root 2>>"$ST_LOG_FILE"
  elif ((txq > 1)); then
    # Kernel-attached mq (handle 0 cannot be deleted): a fresh mq picks up
    # the new default for each child.
    tc qdisc replace dev "$iface" root mq 2>>"$ST_LOG_FILE"
  else
    tc qdisc replace dev "$iface" root "$def" 2>>"$ST_LOG_FILE"
  fi
}

# qdisc_state_ok IFACE WANT — 0 when the live qdisc already matches WANT.
qdisc_state_ok() {
  local iface="$1" wanted_kind="$2" kind handle txq children
  IFS=' ' read -r kind handle <<<"$(net_root_qdisc "$iface")"
  txq="$(net_iface_queues "$iface" tx)"
  if ((txq > 1)); then
    [[ $kind == mq ]] || return 1
    children="$(_qdisc_children_kind "$iface")"
    [[ $children == "$wanted_kind" ]]
  else
    [[ $kind == "$wanted_kind" ]]
  fi
}

# qdisc_apply — runner step. 0 ok, 2 nothing to do, 3 left a custom qdisc.
qdisc_apply() {
  local iface="$ST_F_IFACE" kind handle
  has_cmd tc || return 2
  [[ -n $iface ]] || return 2
  IFS=' ' read -r kind handle <<<"$(net_root_qdisc "$iface")"
  if [[ $kind == noqueue || -z $kind ]]; then
    log_note "${iface} has no queue (virtual device) — nothing to set."
    return 2
  fi
  if qdisc_state_ok "$iface" "$ST_QDISC"; then
    log_note "${iface} already runs ${ST_QDISC}."
    return 0
  fi
  if [[ " ${ST_QDISC_MANAGED} " != *" ${kind} "* ]]; then
    log_note "${iface} has a custom root qdisc (${kind}) — left untouched; ${ST_QDISC} applies to new links."
    return 3
  fi
  if [[ "$(sysctl_get net.core.default_qdisc)" != "$ST_QDISC" ]]; then
    log_warn "net.core.default_qdisc is not ${ST_QDISC} yet — run the sysctl step first."
    return 3
  fi
  st_track_qdisc "$iface"
  if ! qdisc_reattach_default "$iface"; then
    log_warn "Could not rebuild the qdisc on ${iface} live (it applies after reboot)."
    return 3
  fi
  if qdisc_state_ok "$iface" "$ST_QDISC"; then
    local txq
    txq="$(net_iface_queues "$iface" tx)"
    if ((txq > 1)); then
      log_note "${iface}: mq with ${txq} × ${ST_QDISC} (one per TX queue — no shared lock)."
    else
      log_note "${iface}: ${ST_QDISC}."
    fi
    return 0
  fi
  log_warn "${iface} qdisc did not verify as ${ST_QDISC} after the rebuild."
  return 3
}

# qdisc_verify — doctor contract (0 ok / 2 not configured / 3 drift).
qdisc_verify() {
  local want iface file
  file="$(sysctl_file_in_use)"
  [[ -f $file ]] || return 2
  want="$(awk -F'= *' '/^net.core.default_qdisc/ {print $2; exit}' "$file")"
  iface="$(net_default_iface)" || iface=''
  [[ -n $want && -n $iface ]] || return 2
  local kind _h
  IFS=' ' read -r kind _h <<<"$(net_root_qdisc "$iface")"
  [[ " ${ST_QDISC_MANAGED} " == *" ${kind} "* ]] || return 0 # custom: not ours
  qdisc_state_ok "$iface" "$want" && return 0
  return 3
}
