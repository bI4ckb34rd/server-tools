# shellcheck shell=bash
# ============================================================================
# features/security.sh — Layer 3 optional hardening: UFW, fail2ban, SSH,
# anti-abuse egress, node API restriction, Docker+UFW audit.
#
# Everything here is consent-based. fail2ban is the only
# resident service in the whole project and its cost is stated before the
# user agrees. The SSH allow rule always lands before any deny rule, and the
# sshd drop-in is validated with `sshd -t` before restart — no lockouts.
# ============================================================================

readonly ST_F2B_JAIL='/etc/fail2ban/jail.d/99-server-tools.local'
# sshd applies the FIRST value it sees for a keyword and reads the drop-in
# directory in lexical order, so a 99- file loses against the cloud-init
# 50-cloud-init.conf that ships with most images. 00- wins.
readonly ST_SSHD_DROPIN='/etc/ssh/sshd_config.d/00-server-tools.conf'
readonly ST_SSHD_DROPIN_LEGACY='/etc/ssh/sshd_config.d/99-server-tools.conf'

# detect_ssh_port — the port sshd really listens on. `sshd -T` is the only
# source that accounts for drop-ins; the config file and `ss` are fallbacks.
# Nothing is parsed through a pipe: an early-exiting awk would SIGPIPE the
# producer and pipefail would then discard a perfectly good answer — and
# guessing 22 here could lock the user out through the firewall rules.
detect_ssh_port() {
  local port='' out=''
  if has_cmd sshd; then
    out="$(sshd -T 2>/dev/null)" || out=''
    [[ -n $out ]] && port="$(awk '$1 == "port" {print $2; exit}' <<<"$out")"
  fi
  if [[ -z $port ]]; then
    port="$(awk '/^[[:space:]]*[Pp]ort[[:space:]]/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)" || port=''
  fi
  if [[ -z $port ]] && has_cmd ss; then
    out="$(ss -tnlp 2>/dev/null)" || out=''
    [[ -n $out ]] && port="$(awk '/sshd/ {sub(/.*:/, "", $4); print $4; exit}' <<<"$out")"
  fi
  [[ $port =~ ^[0-9]+$ ]] || port=22
  printf '%s' "$port"
}

security_ufw() {
  ui_section "UFW firewall"
  if ! has_cmd ufw; then
    ui_confirm "UFW is not installed. Install it now?" || return 0
    if ! pkg_install ufw; then
      log_error "UFW installation failed — see the log."
      return 0
    fi
  fi

  local ssh_port
  ssh_port="$(detect_ssh_port)"
  printf 'Detected SSH port: %s — it is allowed FIRST, so you cannot be locked out.\n' "$ssh_port"
  if ! ufw allow "${ssh_port}/tcp" >/dev/null 2>>"$ST_LOG_FILE"; then
    log_error "Could not add the SSH allow rule — aborting before any deny rule."
    return 0
  fi
  ufw default deny incoming >/dev/null 2>>"$ST_LOG_FILE" || log_warn "Could not set default deny incoming."
  ufw default allow outgoing >/dev/null 2>>"$ST_LOG_FILE" || log_warn "Could not set default allow outgoing."

  # A firewall that is correct for a proxy node silently kills a VPN gateway
  # or tunnel relay: UFW drops forwarded packets by default and knows nothing
  # about GRE/WireGuard. Handle those BEFORE enabling (2.4.5 fix).
  _ufw_forwarding_fixups

  local suggested
  suggested="$(_ufw_suggested_ports)"
  [[ -n $suggested ]] && printf 'Detected public listeners: %s
' "$suggested"

  local ports p
  read -rp "Extra ports to allow (e.g. 443/tcp 80/tcp 51820/udp) [Enter=none]: " ports || ports=''
  if [[ -n $ports ]]; then
    local IFS=' ' # the global IFS has no space — restore word splitting here
    for p in $ports; do
      if [[ $p =~ ^[0-9]+(/(tcp|udp))?$ ]]; then
        ufw allow "$p" >/dev/null 2>>"$ST_LOG_FILE" || log_warn "Rule failed: ${p}"
      else
        log_warn "Skipped invalid port spec: ${p}"
      fi
    done
  fi

  if has_cmd docker && docker ps -q 2>/dev/null | grep -q .; then
    printf '%sWarning:%s Docker publishes container ports directly in iptables and\n' "$C_WARN" "$C_RESET"
    printf 'BYPASSES UFW — published panel/node ports stay reachable regardless of\n'
    printf 'these rules (see Network tools > Docker+UFW audit).\n'
  fi

  if ui_confirm "Enable UFW now?"; then
    if ufw --force enable >/dev/null 2>>"$ST_LOG_FILE"; then
      printf '%sUFW enabled.%s\n' "$C_OK" "$C_RESET"
      ufw status verbose 2>/dev/null || log_warn "Could not print UFW status."
    else
      log_error "Enabling UFW failed — see the log."
      return 0
    fi
  fi
  printf '%sNote:%s firewall state is not covered by manifest rollback — revert with: ufw disable\n' \
    "$C_MUTED" "$C_RESET"
  log_info "UFW configured (SSH ${ssh_port}/tcp allowed)."
}

# _ufw_suggested_ports — externally-bound TCP listeners (minus SSH) as
# "443/tcp 8443/tcp" hints for the extra-ports prompt.
_ufw_suggested_ports() {
  has_cmd ss || return 0
  local out ssh
  out="$(ss -tln 2>/dev/null)" || return 0
  ssh="$(detect_ssh_port)"
  ss_listen_ports "$out" | ports_subtract "$ssh" | awk '{printf "%s%s/tcp", sep, $1; sep = " "}'
}

# _ufw_forwarding_fixups — forwarding policy, tunnel protocols, VPN ports.
_ufw_forwarding_fixups() {
  roles_detect
  local defaults='/etc/default/ufw' t name kind _mtu remote _encap port
  if [[ " ${ST_DETECTED_ROLES} " =~ \ (vpn|tunnel|relay)\  ]]; then
    if [[ -f $defaults ]] && grep -q '^DEFAULT_FORWARD_POLICY="DROP"' "$defaults"; then
      printf '%sThis host forwards traffic%s (%s) but UFW drops forwarded packets by default.\n' \
        "$C_WARN" "$C_RESET" "$(engines_summary)"
      if ui_confirm_yes "Allow forwarding in UFW (DEFAULT_FORWARD_POLICY=ACCEPT)?"; then
        st_track_file "$defaults"
        sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' "$defaults"
        log_info "UFW forward policy set to ACCEPT (forwarding roles detected)."
      else
        printf '%sForwarded traffic will be blocked once UFW is enabled.%s\n' "$C_ERR" "$C_RESET"
      fi
    fi
  fi
  for t in "${ST_F_TUNNELS[@]-}"; do
    [[ -n $t ]] || continue
    IFS='|' read -r name kind _mtu remote _encap <<<"$t"
    [[ -n $remote ]] || continue
    case "$kind" in
      gre | gretap | ip6gre | ip6gretap | erspan)
        if ufw allow proto gre from "$remote" >/dev/null 2>>"$ST_LOG_FILE"; then
          printf 'Allowed GRE from tunnel peer %s (%s).\n' "$remote" "$name"
        else
          log_warn "Could not allow GRE from ${remote} — tunnel ${name} may break once UFW is enabled."
        fi
        ;;
      ipip | sit | ip6tnl)
        printf '%sNote:%s %s (%s) needs IP protocol %s from %s — UFW cannot express it; add it to /etc/ufw/before.rules.\n' \
          "$C_WARN" "$C_RESET" "$name" "$kind" "$([[ $kind == sit ]] && printf 41 || printf 4)" "$remote"
        ;;
    esac
  done
  while IFS= read -r port; do
    [[ -n $port ]] || continue
    ufw allow "${port}/udp" >/dev/null 2>>"$ST_LOG_FILE" && printf 'Allowed WireGuard port %s/udp.\n' "$port"
  done < <(wg_listen_ports)
  return 0
}

security_fail2ban() {
  ui_section "fail2ban (SSH brute-force protection)"
  printf 'fail2ban runs as a small resident service (~20 MB RAM); everything\n'
  printf 'else ServerTools sets up exits after applying it.\n'
  ui_confirm "Install and enable fail2ban?" || return 0

  if ! has_cmd fail2ban-server && ! pkg_install fail2ban; then
    log_error "fail2ban installation failed — see the log."
    return 0
  fi

  local ssh_port
  ssh_port="$(detect_ssh_port)"
  st_track_file "$ST_F2B_JAIL"
  mkdir -p "$(dirname "$ST_F2B_JAIL")"
  cat >"$ST_F2B_JAIL" <<EOF
# Generated by ${ST_NAME} v${ST_VERSION}
[sshd]
enabled = true
port = ${ssh_port}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

  if has_cmd systemctl &&
    systemctl enable fail2ban >/dev/null 2>>"$ST_LOG_FILE" &&
    systemctl restart fail2ban 2>>"$ST_LOG_FILE"; then
    printf '%sfail2ban active%s (sshd jail on port %s, ban 1h after 5 tries).\n' \
      "$C_OK" "$C_RESET" "$ssh_port"
    log_info "fail2ban enabled (sshd jail, port ${ssh_port})."
  else
    log_error "fail2ban could not be enabled — see the log."
  fi
}

security_ssh() {
  ui_section "SSH hardening"
  if [[ ! -d /etc/ssh/sshd_config.d ]]; then
    log_warn "This system has no /etc/ssh/sshd_config.d — skipping (editing sshd_config in place is not safe enough)."
    return 0
  fi

  local lines=('UseDNS no')
  if [[ -s /root/.ssh/authorized_keys ]]; then
    printf 'An SSH key for root exists.\n'
    printf '%sVerify key login works in a second terminal BEFORE confirming.%s\n' "$C_WARN" "$C_RESET"
    if ui_confirm "Disable password authentication?"; then
      lines+=('PasswordAuthentication no')
    fi
  else
    printf '%sNo /root/.ssh/authorized_keys found — password login stays enabled.%s\n' "$C_WARN" "$C_RESET"
  fi

  # A drop-in from an older version sorts after cloud-init and would keep
  # losing; remove it so only the winning file remains.
  if [[ -f $ST_SSHD_DROPIN_LEGACY ]]; then
    st_track_file "$ST_SSHD_DROPIN_LEGACY"
    rm -f "$ST_SSHD_DROPIN_LEGACY"
    log_info "Removed the superseded 99- SSH drop-in."
  fi

  st_track_file "$ST_SSHD_DROPIN"
  {
    printf '# Generated by %s v%s\n' "$ST_NAME" "$ST_VERSION"
    printf '%s\n' "${lines[@]}"
  } >"$ST_SSHD_DROPIN"

  if has_cmd sshd && ! sshd -t 2>>"$ST_LOG_FILE"; then
    rm -f "$ST_SSHD_DROPIN"
    log_error "sshd config validation failed — drop-in removed, nothing changed."
    return 1
  fi
  if has_cmd systemctl; then
    # Service name differs across distros (ssh on Debian/Ubuntu, sshd elsewhere).
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>>"$ST_LOG_FILE" ||
      log_warn "Could not restart sshd — settings apply on its next restart."
  fi

  # Verify against the effective configuration, not the file we wrote.
  local effective
  for effective in "${lines[@]}"; do
    ssh_effective_matches "$effective" || {
      log_warn "SSH setting '${effective}' is NOT in effect — another drop-in overrides it (check: sshd -T)."
      printf '%sWarning:%s "%s" did not take effect — see the log.\n' "$C_WARN" "$C_RESET" "$effective"
      return 3
    }
  done

  # "${lines[*]}" would join with the global IFS's newline and break this into
  # one line per setting; the entries contain spaces, so join with ", ".
  local summary
  summary="$(
    IFS=', '
    printf '%s' "${lines[*]}"
  )"
  printf '%sApplied and verified:%s %s\n' "$C_OK" "$C_RESET" "$summary"
  log_info "SSH hardening drop-in applied and verified: ${summary}"
  return 0
}

# ssh_effective_matches "Keyword value" — is that what sshd really uses?
ssh_effective_matches() {
  has_cmd sshd || return 0 # cannot check; do not claim failure
  local keyword value actual
  keyword="${1%% *}"
  value="${1#* }"
  actual="$(sshd -T 2>/dev/null | awk -v k="${keyword,,}" '$1 == k {print $2; exit}')" || actual=''
  [[ -z $actual ]] && return 0 # keyword unknown to this sshd build
  [[ ${actual,,} == "${value,,}" ]]
}

# ssh_verify — 0 when our drop-in exists and its settings are in effect.
ssh_verify() {
  [[ -f $ST_SSHD_DROPIN ]] || return 2
  local line
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    ssh_effective_matches "$line" || return 3
  done <"$ST_SSHD_DROPIN"
  return 0
}

# --- Anti-abuse profile ---------------------------------------------------
# Datacenter abuse reports about VPN nodes are almost always one of: outbound
# spam, scanning of the provider's internal ranges, or worm ports. These are
# egress rules, which only cover traffic the host itself emits — that is
# exactly how userspace proxies (Xray/sing-box) send user traffic. Forwarded
# traffic (WireGuard) needs `ufw route` rules, so that case is stated openly.

# Ports whose outbound use triggers abuse complaints. 465/587 are optional:
# blocking them stops authenticated spam but also breaks real mail clients.
readonly -a ST_ABUSE_PORTS_TCP=(25 23 445 135 139)
readonly -a ST_ABUSE_RANGES=(
  '10.0.0.0/8' '172.16.0.0/12' '192.168.0.0/16' '100.64.0.0/10' '169.254.0.0/16'
)

security_antiabuse() {
  ui_section "Anti-abuse egress profile"
  if ! has_cmd ufw; then
    log_error "UFW is not installed — set it up first (menu option 1)."
    return 2
  fi

  printf 'Blocks the outbound traffic that datacenters complain about:\n'
  printf '  · SMTP (25) and worm ports (23, 135, 139, 445) — spam and scanning\n'
  printf '  · RFC1918/CGNAT ranges — stops users reaching the provider network\n'
  printf 'Your own subnet stays reachable so the server keeps working.\n'
  if has_cmd wg && [[ -n "$(wg show interfaces 2>/dev/null)" ]]; then
    printf '%sNote:%s WireGuard traffic is FORWARDED, not emitted by the host, so\n' "$C_WARN" "$C_RESET"
    printf 'these egress rules do not restrict WireGuard peers.\n'
  fi
  ui_confirm "Apply the anti-abuse rules?" || return 2

  local rc=0 port range gw_net=''
  for port in "${ST_ABUSE_PORTS_TCP[@]}"; do
    ufw deny out to any port "$port" proto tcp >/dev/null 2>>"$ST_LOG_FILE" ||
      {
        log_warn "Could not add the egress deny rule for tcp/${port}."
        rc=3
      }
  done
  ufw deny out to any port 137:139 proto udp >/dev/null 2>>"$ST_LOG_FILE" ||
    {
      log_warn "Could not add the NetBIOS egress deny rule."
      rc=3
    }

  if ui_confirm "Also block submission ports 465/587? (stops authenticated spam, breaks real mail clients)"; then
    for port in 465 587; do
      ufw deny out to any port "$port" proto tcp >/dev/null 2>>"$ST_LOG_FILE" ||
        {
          log_warn "Could not add the egress deny rule for tcp/${port}."
          rc=3
        }
    done
  fi

  # Every directly connected subnet must stay reachable — the provider LAN,
  # but also tunnel point-to-point nets (GRE 10.x/30), WireGuard and Docker
  # bridges. pre-2.4.5 kept only a /24 guess of the uplink, which cut a relay off
  # from its own tunnel peer and the host off from its containers. Allow
  # rules are inserted BEFORE the deny rules so they win.
  while IFS= read -r gw_net; do
    [[ -n $gw_net ]] || continue
    printf 'Keeping the connected subnet %s reachable.\n' "$gw_net"
    ufw insert 1 allow out to "$gw_net" >/dev/null 2>>"$ST_LOG_FILE" ||
      {
        log_warn "Could not allow the connected subnet ${gw_net} — private ranges left untouched."
        return 3
      }
  done < <(_abuse_connected_subnets)
  for range in "${ST_ABUSE_RANGES[@]}"; do
    ufw deny out to "$range" >/dev/null 2>>"$ST_LOG_FILE" ||
      {
        log_warn "Could not add the egress deny rule for ${range}."
        rc=3
      }
  done

  # Brute-force rate limiting costs nothing and replaces a plain allow.
  local ssh_port
  ssh_port="$(detect_ssh_port)"
  ufw limit "${ssh_port}/tcp" >/dev/null 2>>"$ST_LOG_FILE" ||
    log_warn "Could not switch SSH to a rate-limited rule."

  printf '%sAnti-abuse rules applied.%s Review them with: ufw status numbered\n' "$C_OK" "$C_RESET"
  printf '%sProxy-level blocking (private ranges, BitTorrent) still belongs in\n' "$C_MUTED"
  printf 'the Xray/sing-box routing config — see docs/GUIDE.md.%s\n' "$C_RESET"
  log_info "Anti-abuse egress profile applied (rc=${rc})."
  return "$rc"
}

# _abuse_connected_subnets — private IPv4 networks routed directly on a
# local link (kernel "proto kernel scope link" routes), exact CIDRs.
_abuse_connected_subnets() {
  local out
  has_cmd ip || return 0
  out="$(ip -4 route show proto kernel scope link 2>/dev/null)" || return 0
  awk '$1 ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|169\.254\.)/ {print $1}' <<<"$out" | sort -u
}

# security_node_ports — a node's API port only ever talks to its panel.
security_node_api() {
  ui_section "Restrict node API ports to the panel"
  if ! has_cmd ufw; then
    log_error "UFW is not installed — set it up first (menu option 1)."
    return 2
  fi
  printf 'Marzban-node uses 62050/62051, pg-node 62050 by default. Leaving them\n'
  printf 'open to the internet exposes the service to every scanner.\n'
  local panel_ip ports port
  read -rp "Panel IP address (empty = cancel): " panel_ip || return 2
  [[ -n $panel_ip ]] || return 2
  if ! is_valid_ip "$panel_ip"; then
    log_error "'${panel_ip}' is not a valid IP address."
    return 1
  fi
  read -rp "API ports [62050,62051]: " ports || ports=''
  ports="${ports:-62050,62051}"

  local rc=0
  while IFS= read -r port; do
    [[ $port =~ ^[0-9]+$ ]] || {
      log_warn "Skipped invalid port '${port}'."
      continue
    }
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true # rule may simply not exist
    if ufw allow from "$panel_ip" to any port "$port" proto tcp >/dev/null 2>>"$ST_LOG_FILE"; then
      printf '  %s/tcp: only %s\n' "$port" "$panel_ip"
    else
      log_warn "Could not restrict port ${port}."
      rc=3
    fi
  done < <(ports_split "$ports")
  log_info "Node API ports restricted to ${panel_ip} (rc=${rc})."
  return "$rc"
}

security_menu() {
  local choice
  while true; do
    ui_logo
    ui_title "Security (Layer 3 — optional, consent-based)"
    ui_menu_item 1 "UFW firewall" "SSH-safe setup, extra ports, Docker warning"
    ui_menu_item 2 "fail2ban" "SSH brute-force bans (resident service ~20 MB)"
    ui_menu_item 3 "SSH hardening" "UseDNS off, optional key-only login (validated)"
    ui_menu_item 4 "Anti-abuse egress" "block SMTP/worm ports and provider networks"
    ui_menu_item 5 "Restrict node API" "panel-only access to 62050/62051"
    ui_menu_item 6 "Docker + UFW audit" "check the firewall bypass"
    ui_menu_item 0 "Back"
    read -rp "$(_ui_prompt)" choice || return 0
    case "${choice:-}" in
      1)
        security_ufw
        ui_pause
        ;;
      2)
        security_fail2ban
        ui_pause
        ;;
      3)
        security_ssh || true # outcome already reported to the user
        ui_pause
        ;;
      4)
        security_antiabuse || true # outcome already reported
        ui_pause
        ;;
      5)
        security_node_api || true # outcome already reported
        ui_pause
        ;;
      6)
        security_docker_ufw_audit
        ui_pause
        ;;
      0) return 0 ;;
      *)
        ui_invalid
        ;;
    esac
  done
}

security_docker_ufw_audit() {
  ui_section "Docker + UFW audit"
  local docker_on=0 ufw_on=0
  if has_cmd docker && docker ps -q 2>/dev/null | grep -q .; then
    docker_on=1
  fi
  if has_cmd ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw_on=1
  fi
  if ((docker_on == 0)); then
    printf 'No running Docker containers — no bypass risk.\n'
    return 0
  fi
  if ((ufw_on == 0)); then
    printf 'Docker is running but UFW is inactive — nothing to bypass (no firewall).\n'
    return 0
  fi
  printf '%sBoth Docker and UFW are active.%s Docker inserts its own iptables rules,\n' "$C_WARN" "$C_RESET"
  printf 'so ports published with -p/ports: are reachable EVEN IF UFW blocks them.\n'
  printf '\n%sPublished ports right now:%s\n' "$C_KEY" "$C_RESET"
  docker ps --format '  {{.Names}}: {{.Ports}}' 2>/dev/null || log_warn "Could not list container ports."
  printf '\nMitigations: bind sensitive ports to 127.0.0.1 in compose, or use the\n'
  printf 'ufw-docker approach (DOCKER-USER chain rules).\n'
}
