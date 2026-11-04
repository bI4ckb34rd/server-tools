# shellcheck shell=bash
# ============================================================================
# lib/fw.sh — firewall backend abstraction (iptables / ip6tables / nft).
#
# Two jobs:
#   1. Idempotent rule management for the few rules ServerTools owns (MSS
#      clamp, NOTRACK): check-then-add, delete-if-present, both families.
#   2. Read-only discovery of NAT forwarding — which local ports are DNAT'd
#      and where to — from BOTH the iptables view (legacy or iptables-nft)
#      and native nftables tables. pre-2.4.5 parsed only `iptables -S` and only the
#      `--dport N` form, so multiport lists, ranges and rules written with
#      plain `nft` (most tunnel managers) were invisible.
# ============================================================================

# Firewall managers that load (and often FLUSH) a ruleset at boot. Every
# ServerTools rule unit is ordered after them, or iptables-restore /
# `nft -f` (flush ruleset) / firewalld would wipe our rules right after
# they were added — "MSS/NOTRACK gone after reboot". Absent units are
# ignored by systemd, so listing them all is safe.
readonly ST_FW_AFTER='nftables.service netfilter-persistent.service iptables.service ip6tables.service ufw.service firewalld.service'

fw_has_iptables() { has_cmd iptables; }
fw_has_nft() { has_cmd nft; }

# fw_rule_ensure BIN TABLE CHAIN ARGS... — add the rule unless it exists.
fw_rule_ensure() {
  local bin="$1" table="$2" chain="$3"
  shift 3
  has_cmd "$bin" || return 2
  "$bin" -w -t "$table" -C "$chain" "$@" 2>/dev/null && return 0
  "$bin" -w -t "$table" -A "$chain" "$@" 2>>"$ST_LOG_FILE"
}

# fw_rule_remove BIN TABLE CHAIN ARGS... — delete every copy of the rule.
fw_rule_remove() {
  local bin="$1" table="$2" chain="$3" guard=0
  shift 3
  has_cmd "$bin" || return 0
  while "$bin" -w -t "$table" -C "$chain" "$@" 2>/dev/null; do
    "$bin" -w -t "$table" -D "$chain" "$@" 2>>"$ST_LOG_FILE" || return 1
    guard=$((guard + 1))
    ((guard < 16)) || return 1
  done
  return 0
}

# fw_rule_present BIN TABLE CHAIN ARGS...
fw_rule_present() {
  local bin="$1" table="$2" chain="$3"
  shift 3
  has_cmd "$bin" || return 1
  "$bin" -w -t "$table" -C "$chain" "$@" 2>/dev/null
}

# fw_nft_table_present FAMILY NAME
fw_nft_table_present() {
  fw_has_nft || return 1
  nft list table "$1" "$2" >/dev/null 2>&1
}

# _fw_nat_text — every NAT rule this host knows, one per line, in either the
# iptables-save or the nft syntax. iptables-nft rules show up in both views;
# consumers only collect sets, so the duplication is harmless.
_fw_nat_text() {
  local out
  if has_cmd iptables-save; then
    out="$(iptables-save -t nat 2>/dev/null)" && printf '%s\n' "$out"
  fi
  if has_cmd ip6tables-save; then
    out="$(ip6tables-save -t nat 2>/dev/null)" && printf '%s\n' "$out"
  fi
  if fw_has_nft; then
    out="$(nft list ruleset 2>/dev/null)" && grep -E '\b(dnat|redirect)\b' <<<"$out"
  fi
  return 0
}

# fw_dnat_rules — normalised "PORTSPEC<TAB>DEST" per DNAT/REDIRECT rule.
#   PORTSPEC: "443", "1000-2000", "80,443" or "*" (the rule matches every port)
#   DEST:     the target address, "local" for REDIRECT, "" when unknown.
fw_dnat_rules() {
  local text
  text="$(_fw_nat_text)"
  [[ -n $text ]] || return 0
  awk '
    function emit(ports, dest) { print (ports == "" ? "*" : ports) "\t" dest }
    # iptables-save syntax
    /^-A / && / -j (DNAT|REDIRECT)/ {
      ports = ""; dest = ""
      for (i = 1; i <= NF; i++) {
        if ($i == "--dport" || $i == "--dports" || $i == "--destination-ports") { ports = $(i + 1) }
        if ($i == "--to-destination") { dest = $(i + 1) }
      }
      if ($0 ~ / -j REDIRECT/) dest = "local"
      gsub(":", "-", ports)
      sub(/^\[/, "", dest); sub(/\](:.*)?$/, "", dest)
      if (dest !~ /:.*:/) sub(/:.*/, "", dest)   # strip ":port" from IPv4 only
      emit(ports, dest); next
    }
    # nft syntax: ... dport 443 ... dnat ip to 10.0.0.2:443
    /(^|[ \t])(dnat|redirect)([ \t]|$)/ {
      ports = ""; dest = ""
      if (match($0, /dport \{[^}]*\}/)) { ports = substr($0, RSTART + 7, RLENGTH - 8); gsub(/[ ]/, "", ports) }
      else if (match($0, /dport [0-9]+(-[0-9]+)?/)) { ports = substr($0, RSTART + 6, RLENGTH - 6) }
      if (match($0, /dnat (ip6? )?to [^ ;]+/)) {
        dest = substr($0, RSTART, RLENGTH); sub(/.* to /, "", dest)
        sub(/^\[/, "", dest); sub(/\](:.*)?$/, "", dest)
        if (dest !~ /:.*:/) sub(/:.*/, "", dest)
      }
      if ($0 ~ /redirect/) dest = "local"
      emit(ports, dest)
    }' <<<"$text" | sort -u
}

# fw_dnat_ports — local ports some DNAT/REDIRECT rule forwards, one per line.
# A rule without any port match prints "*" (it forwards EVERYTHING).
fw_dnat_ports() {
  local ports _dest
  while IFS=$'\t' read -r ports _dest; do
    [[ -n $ports ]] || continue
    if [[ $ports == '*' ]]; then
      printf '*\n'
    else
      ports_expand "$ports"
    fi
  done < <(fw_dnat_rules)
}

# _fw_dest_is_local_container IP — true when IP is this host or sits behind a
# local bridge (Docker/Podman/libvirt publish ports with DNAT to such IPs).
_fw_dest_is_local_container() {
  local ip="$1" dev
  [[ $ip == local || $ip == 127.* || $ip == ::1 ]] && return 0
  dev="$(net_route_dev "$ip")"
  [[ -z $dev ]] && return 0 # unroutable: not evidence of a relay
  [[ $dev =~ ^(lo|docker[0-9]*|br-.*|veth.*|cni.*|virbr.*|podman.*|kube.*|flannel.*|cali.*)$ ]]
}

# fw_dnat_remote_dests — DNAT destinations on OTHER machines (through the
# uplink or a tunnel), i.e. evidence that this host is a NAT relay. Docker's
# own DNAT to container addresses is excluded.
fw_dnat_remote_dests() {
  local _ports dest
  while IFS=$'\t' read -r _ports dest; do
    [[ -n $dest ]] || continue
    is_valid_ip "$dest" || continue
    _fw_dest_is_local_container "$dest" && continue
    printf '%s\n' "$dest"
  done < <(fw_dnat_rules) | sort -u
}
