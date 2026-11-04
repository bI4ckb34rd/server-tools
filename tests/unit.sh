#!/usr/bin/env bash
# ============================================================================
# tests/unit.sh — unit tests for the pure logic of the built program: list
# and mask arithmetic, role resolution, firewall parsing, tunnel overheads,
# config validation, the policy engine (including the pre-2.4.5 field-report case:
# a GRE relay on a single-queue NIC), sysctl rendering, and manifest-driven
# rollback in a sandbox. No root, no network, no changes to the host.
# ============================================================================
# The sourced program consumes the globals set below; ShellCheck cannot see that.
# shellcheck disable=SC2034,SC2153,SC2154,SC2317,SC2329
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${ROOT_DIR}/dist/server-tools.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

bash "${ROOT_DIR}/build.sh" >/dev/null

# Library mode: load every function, run nothing. State goes to the sandbox.
export ST_STATE_ROOT="$SANDBOX"
ST_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "$DIST"
trap 'rm -rf "$SANDBOX"' EXIT
trap - ERR
set +e

PASS=0
FAIL=0
eq() { # eq NAME EXPECTED ACTUAL
  if [[ $2 == "$3" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"
  fi
}
ok() { # ok NAME CMD... — the command must succeed
  local name="$1"
  shift
  if "$@"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s (command failed)\n' "$name"
  fi
}
nok() { # nok NAME CMD... — the command must fail
  local name="$1"
  shift
  if "$@"; then
    FAIL=$((FAIL + 1))
    printf 'FAIL %s (command unexpectedly succeeded)\n' "$name"
  else PASS=$((PASS + 1)); fi
}
lines() { paste -sd' ' -; }

# --- CPU lists and masks -----------------------------------------------------
eq cpu_list_expand "0 1 2 5" "$(cpu_list_expand '0-2,5' | lines)"
eq mask_all4 "0000000f" "$(cpu_mask_from_list '0 1 2 3')"
eq mask_skip0 "0000000e" "$(cpu_mask_from_list '1 2 3')"
eq mask_wide "00000002,00000001" "$(cpu_mask_from_list '0 33')"
eq mask_norm "f" "$(cpu_mask_norm '00000000,0000000f')"
eq mask_norm_zero "0" "$(cpu_mask_norm '00000000')"

# --- Port lists ----------------------------------------------------------------
eq ports_expand "80 1000 1001 1002 2000 2001" "$(ports_expand '80,1000-1002 2000:2001' | lines)"
eq ports_collapse "1-3,5,7-8" "$(printf '%s\n' 5 2 1 3 8 7 | ports_collapse)"
ok ports_covered ports_covered '80,443' '1-1000'
nok ports_not_covered ports_covered '80,2000' '1-1000'
ok port_in_range port_in_list 1001 '80,1000-1002'
nok port_not_in_list port_in_list 999 '80,1000-1002'
eq ports_subtract "8443 51820" "$(printf '%s\n' 22 8443 51820 | ports_subtract $'22\n443' | lines)"
eq join_sp "a b c" "$(join_sp a b c)"

# --- Roles -----------------------------------------------------------------------
eq roles_order "proxy relay" "$(roles_normalize 'relay,proxy')"
eq roles_general_dropped "proxy" "$(roles_normalize 'general proxy')"
nok roles_bogus roles_normalize 'proxy,bogus'
eq profile_vpn_node "proxy" "$(roles_from_profile vpn-node)"
eq profile_wireguard "vpn" "$(roles_from_profile wireguard)"
eq profile_relay "relay tunnel" "$(roles_from_profile relay)"
nok profile_bogus roles_from_profile bogus

# Detection from stubbed facts: an Xray node that also terminates a GRE tunnel
# and relays a port to another server through it.
facts_collect() { ST_FACTS_DONE=1; }
ST_F_PROCS=$'sshd\nxray\nsystemd'
ST_F_CONTAINERS=$'pg-node pasarguard/node:latest\nmarzban gozargah/marzban:latest'
ST_F_UNITS=$'ssh\nwg-quick@wg0'
ST_F_TUNNELS=("gre1|gre|1430|5.6.7.8|")
ST_F_DNAT_REMOTE='10.0.0.2'
roles_detect
eq roles_detect_mixed "proxy panel vpn tunnel relay" "$ST_DETECTED_ROLES"

# A bot/site host: nginx in front, Redis + PostgreSQL behind, nothing VPN.
ST_F_PROCS=$'sshd\nnginx\nredis-server\npostgres\npython3'
ST_F_CONTAINERS='' ST_F_UNITS='' ST_F_TUNNELS=() ST_F_DNAT_REMOTE=''
roles_detect
eq roles_detect_web_db "web db" "$ST_DETECTED_ROLES"
ST_ROLES='web db'
ok engine_redis engine_detected Redis
nok engine_absent engine_detected Xray
ok roles_only_yes roles_only web db panel
nok roles_only_no roles_only db
eq roles_web_db_order "web db" "$(roles_normalize 'db,web')"
ST_F_TUNNELS=("gre1|gre|1430|5.6.7.8|") # the policy cases below use the tunnel

# Capacity: a panel + its database never gets an L/XL conntrack table.
mem_total_mb() { printf '16384'; }
ST_ROLES='panel db' ST_CLI_TIER='' ST_CLI_USERS=''
capacity_resolve
eq panel_db_tier_cap M "$ST_TIER"
ST_ROLES='proxy'
capacity_resolve
eq proxy_tier_l L "$ST_TIER"

# --- Firewall NAT parsing ------------------------------------------------------
_fw_nat_text() {
  cat <<'EOF'
-A PREROUTING -p tcp -m tcp --dport 8443 -j DNAT --to-destination 10.0.0.2:443
-A PREROUTING -p udp -m multiport --dports 2000:2002,3000 -j DNAT --to-destination 10.0.0.2
-A DOCKER ! -i docker0 -p tcp -m tcp --dport 8080 -j DNAT --to-destination 172.17.0.2:80
-A PREROUTING -p tcp -j REDIRECT --to-ports 1080
		tcp dport { 80, 443 } dnat ip to 192.0.2.10:443
		udp dport 5000-5002 dnat ip to 192.0.2.11
EOF
}
eq dnat_ports "* 80 443 2000 2001 2002 3000 5000 5001 5002 8080 8443" "$(fw_dnat_ports | sort -u | sort -n | lines)"
net_route_dev() { case "$1" in 172.17.*) printf 'docker0' ;; *) printf 'eth0' ;; esac }
eq dnat_remote "10.0.0.2 192.0.2.10 192.0.2.11" "$(fw_dnat_remote_dests | lines)"

# --- Tunnel overheads ------------------------------------------------------------
eq gre_v4 24 "$(_tunnel_overhead gre 1.2.3.4 '')"
eq gre_fou 32 "$(_tunnel_overhead gre 1.2.3.4 fou)"
eq ipip 20 "$(_tunnel_overhead ipip 1.2.3.4 '')"
eq wg_v6 80 "$(_tunnel_overhead wireguard 2001:db8::1 '')"
eq vxlan_v4 50 "$(_tunnel_overhead vxlan 1.2.3.4 '')"

# --- Config registry -------------------------------------------------------------
ok cfg_rps_on config_validate rps_mode on
nok cfg_rps_bad config_validate rps_mode maybe
ok cfg_rps_cpus config_validate rps_cpus 1-3
ok cfg_roles config_validate roles relay,tunnel
nok cfg_roles_bogus config_validate roles relay,nonsense
nok cfg_unknown config_validate no_such_key 1
eq cfg_default "auto" "$(config_get rps_mode)"
eq cfg_explicit_default "x" "$(config_get unset_key x)"

# --- Policy engine -----------------------------------------------------------------
kernel_base() { printf '6.1'; }
sysctl_get() {
  case "$1" in
    net.ipv4.tcp_available_congestion_control) printf 'reno cubic bbr' ;;
    *) printf '?' ;;
  esac
}
qdisc_supported() { return 0; }
policy_irq_cpus() { printf '0'; }
net_rx_irqs() { :; }
_policy_xps() { ST_P_XPS='keep'; }
ST_DRY_RUN=1

# The field report: a GRE + DNAT relay, 4 vCPUs, one RX queue. pre-2.4.5 tuned it like
# a proxy node (RPS on every CPU incl. the IRQ CPU, RFS, fq).
ST_F_IFACE=eth0 ST_F_CPUS=4 ST_F_CPU_LIST='0 1 2 3' ST_F_RXQ=1 ST_F_TXQ=1
ST_ROLES='tunnel relay'
policy_resolve
eq relay_fwd_heavy 1 "$ST_P_FWD_HEAVY"
eq relay_qdisc fq_codel "$ST_QDISC"
eq relay_rps 1 "$ST_P_RPS"
eq relay_rps_cpus "1 2 3" "$ST_P_RPS_CPUS"
eq relay_rfs 0 "$ST_P_RFS"
eq relay_mss 1 "$ST_P_MSS"

# Proxy node on a multi-queue NIC: hardware RSS already spreads.
ST_F_RXQ=4 ST_F_TXQ=4 ST_ROLES='proxy'
policy_resolve
eq proxy_mq_rps 0 "$ST_P_RPS"
eq proxy_qdisc fq "$ST_QDISC"
eq proxy_mss 0 "$ST_P_MSS"
eq proxy_forward 1 "$ST_P_FORWARD"

# Many queues but fewer than CPUs (16 RX, 24 CPUs): RSS is enough.
ST_F_CPUS=24 ST_F_CPU_LIST="$(seq -s' ' 0 23)" ST_F_RXQ=16
policy_resolve
eq proxy_16q_rps 0 "$ST_P_RPS"
ST_F_CPUS=4 ST_F_CPU_LIST='0 1 2 3'

# Proxy node on a single-queue virtio NIC: RPS on every CPU, plus RFS.
ST_F_RXQ=1 ST_F_TXQ=1
policy_resolve
eq proxy_sq_rps 1 "$ST_P_RPS"
eq proxy_sq_cpus "0 1 2 3" "$ST_P_RPS_CPUS"
eq proxy_sq_rfs 1 "$ST_P_RFS"

# Multi-queue NIC but a GRE tunnel: RSS cannot spread it, RPS steps in.
ST_F_RXQ=4 ST_ROLES='tunnel'
policy_resolve
eq gre_mq_rps 1 "$ST_P_RPS"
ST_F_TUNNELS=("gre1|gre|1430|5.6.7.8|fou")
policy_resolve
eq gre_fou_rps 0 "$ST_P_RPS"

# Config overrides win.
ST_CONFIG[rps_mode]=off ST_F_RXQ=1 ST_ROLES='proxy'
policy_resolve
eq cfg_rps_off 0 "$ST_P_RPS"
unset 'ST_CONFIG[rps_mode]'
ST_CONFIG[qdisc]=cake
policy_resolve
eq cfg_qdisc cake "$ST_QDISC"
unset 'ST_CONFIG[qdisc]'

# NIC channels: a virtio NIC offering 4 queue pairs but using 1 is raised,
# and RPS is then planned for the new queue count.
ST_ROLES='proxy' ST_F_CPUS=4 ST_F_CPU_LIST='0 1 2 3' ST_F_RXQ=1 ST_F_TXQ=1
ST_F_DRIVER=virtio_net ST_F_CH_MAX=4 ST_F_CH_CUR=1
policy_resolve
eq channels_raised 4 "$ST_P_CHANNELS"
eq channels_rxq 4 "$ST_P_RXQ"
eq channels_rps_off 0 "$ST_P_RPS"
ST_F_DRIVER=ena
policy_resolve
eq channels_non_virtio 0 "$ST_P_CHANNELS"
ST_CONFIG[nic_channels]=2
policy_resolve
eq channels_config 2 "$ST_P_CHANNELS"
unset 'ST_CONFIG[nic_channels]'
ST_F_CH_MAX=0 ST_F_CH_CUR=0 ST_F_DRIVER=virtio_net

# Offloads: GRO and UDP GRO forwarding are enabled when off.
ST_F_GRO=off ST_F_UDPGRO=off ST_ROLES='tunnel relay'
policy_resolve
eq gro_on 1 "$ST_P_GRO"
eq udpgro_on 1 "$ST_P_UDPGRO"
ST_F_GRO=fixed ST_F_UDPGRO=''
policy_resolve
eq gro_fixed 0 "$ST_P_GRO"
eq udpgro_absent 0 "$ST_P_UDPGRO"
ST_F_GRO='' ST_F_UDPGRO=''

# Conntrack budget: the largest power of two within 10% of RAM (300 B/entry).
eq ct_budget_512m 131072 "$(capacity_ct_budget 480)"
eq ct_budget_1g 262144 "$(capacity_ct_budget 960)"
eq ct_budget_2g 524288 "$(capacity_ct_budget 1950)"
eq ct_budget_4g 1048576 "$(capacity_ct_budget 3900)"
eq ct_budget_8g 2097152 "$(capacity_ct_budget 7800)"
eq ct_budget_cap 4194304 "$(capacity_ct_budget 262144)"

# A 4 GB forwarder (tier M) gets the budget; an explicit user count wins;
# a local-only host keeps its tier value.
mem_total_mb() { printf '3900'; }
ST_ROLES='tunnel relay' ST_EXPECTED_USERS=0
tier_set M
policy_resolve
eq ct_forwarder_raised 1048576 "$ST_CONNTRACK"
tier_set M
ST_EXPECTED_USERS=2000 ST_CONNTRACK=72000
policy_resolve
eq ct_users_kept 72000 "$ST_CONNTRACK"
ST_EXPECTED_USERS=0
tier_set M
ST_ROLES='web' ST_F_CONNTRACK=1
policy_resolve
eq ct_local_tier 262144 "$ST_CONNTRACK"
ST_F_CONNTRACK=0

# Conntrack: forwarders always; local-only hosts only when the module is
# live (Docker/UFW), with a longer idle timeout; otherwise left alone.
ST_ROLES='tunnel relay' ST_F_CONNTRACK=0
policy_resolve
eq ct_forwarder "1 3600" "$ST_P_CONNTRACK $ST_P_CT_EST"
ST_ROLES='web' ST_F_CONNTRACK=1 ST_F_DOCKER=1
policy_resolve
eq ct_docker_host "1 7200" "$ST_P_CONNTRACK $ST_P_CT_EST"
eq docker_tune 1 "$ST_P_DOCKER"
ST_CONFIG[docker_tuning]=off
policy_resolve
eq docker_cfg_off 0 "$ST_P_DOCKER"
unset 'ST_CONFIG[docker_tuning]'
ST_F_CONNTRACK=0 ST_F_DOCKER=0
policy_resolve
eq ct_untouched 0 "$ST_P_CONNTRACK"
eq web_local_tcp 1 "$ST_P_LOCAL_TCP"

# Databases: Redis gets overcommit=1, every database bounded write-back.
ST_ENGINES=('db|Redis') ST_ROLES='db'
policy_resolve
eq redis_overcommit 1 "$ST_P_OVERCOMMIT"
eq db_dirty 1 "$ST_P_DIRTY"
ST_ENGINES=('db|PostgreSQL')
policy_resolve
eq pg_no_overcommit '' "$ST_P_OVERCOMMIT"

# IRQ affinity: four receive vectors all on CPU 0, no irqbalance → spread;
# never with irqbalance running or when already spread.
ST_ROLES='proxy' ST_F_RXQ=4 ST_F_TXQ=4 ST_F_CPUS=4 ST_F_CPU_LIST='0 1 2 3'
net_rx_irqs() { printf '%s\t0\n' 40 41 42 43; }
ST_F_IRQBALANCE=0
policy_resolve
eq irq_spread 1 "$ST_P_IRQ_SPREAD"
ST_F_IRQBALANCE=1
policy_resolve
eq irq_irqbalance 0 "$ST_P_IRQ_SPREAD"
ST_F_IRQBALANCE=0
net_rx_irqs() { printf '40\t0\n41\t1\n42\t2\n43\t3\n'; }
policy_resolve
eq irq_already 0 "$ST_P_IRQ_SPREAD"
ST_CONFIG[irq_affinity]=off
net_rx_irqs() { printf '%s\t0\n' 40 41 42 43; }
policy_resolve
eq irq_cfg_off 0 "$ST_P_IRQ_SPREAD"
unset 'ST_CONFIG[irq_affinity]'
net_rx_irqs() { :; }
ST_F_RXQ=1 ST_F_TXQ=1

# The boot-time IRQ selector picks the same vectors as the live run.
irqtxt=$'  40:  1  2 PCI-MSI 1-edge virtio0-input.0\n  41:  1  2 PCI-MSI 2-edge virtio0-output.0\n  42:  1  2 PCI-MSI 3-edge eth1-TxRx-0\n  43:  1  2 PCI-MSI 4-edge ice-eth1-TxRx-1\n  44:  1  2 PCI-MSI 5-edge eth10-rx-0'
eq irq_select_virtio "40" "$(awk -v i=eth0 -v d=virtio0 "$ST_RX_IRQ_AWK" <<<"$irqtxt" | lines)"
eq irq_select_named "42 43" "$(awk -v i=eth1 -v d='' "$ST_RX_IRQ_AWK" <<<"$irqtxt" | lines)"

# Prerequisites: package names per package manager (has_cmd is stubbed,
# then restored, around the calls).
has_cmd() { [[ $1 == apt-get ]]; }
eq deps_apt_dig "dig	bind9-dnsutils" "$(deps_missing dns | cut -f1,2)"
ok deps_apt_core grep -q $'^ethtool\tethtool\t' <<<"$(deps_missing core)"
has_cmd() { [[ $1 == dnf ]]; }
eq deps_dnf_dig "dig	bind-utils" "$(deps_missing dns | cut -f1,2)"
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- sysctl rendering ---------------------------------------------------------------
swap_backend_active() { printf 'none'; }
listening_service_ports() { printf '11000\n11001\n11002\n43582\n'; }
mem_total_mb() { printf '4096'; }
tier_set M
ST_EXPECTED_USERS=0
ST_ROLES='tunnel relay'
ST_F_RXQ=1 ST_F_TUNNELS=("gre1|gre|1430|5.6.7.8|")
policy_resolve
rendered="$(_sysctl_render)"
ok render_qdisc grep -q '^net.core.default_qdisc = fq_codel$' <<<"$rendered"
ok render_forward grep -q '^net.ipv4.ip_forward = 1$' <<<"$rendered"
ok render_budget grep -q '^net.core.netdev_budget = 600$' <<<"$rendered"
nok render_no_budget_usecs grep -q 'netdev_budget_usecs' <<<"$rendered"
nok render_relay_no_rfs grep -q 'rps_sock_flow_entries' <<<"$rendered"
ok render_reserved grep -q '^net.ipv4.ip_local_reserved_ports = 11000-11002,43582$' <<<"$rendered"
ST_ROLES='proxy'
policy_resolve
rendered="$(_sysctl_render)"
ok render_proxy_rfs grep -q '^net.core.rps_sock_flow_entries = 32768$' <<<"$rendered"
ok render_proxy_fq grep -q '^net.core.default_qdisc = fq$' <<<"$rendered"
ok render_inotify grep -q '^fs.inotify.max_user_instances = 8192$' <<<"$rendered"
ok render_ct_forward grep -q '^net.netfilter.nf_conntrack_tcp_timeout_established = 3600$' <<<"$rendered"

# Conntrack is a ceiling: a larger running table is never lowered.
sysctl_get() {
  case "$1" in
    net.ipv4.tcp_available_congestion_control) printf 'reno cubic bbr' ;;
    net.netfilter.nf_conntrack_max) printf '4194304' ;;
    *) printf '?' ;;
  esac
}
policy_resolve
rendered="$(_sysctl_render)"
ok render_ct_ceiling grep -q '^net.netfilter.nf_conntrack_max = 4194304$' <<<"$rendered"

# A Docker web host: conntrack timeouts without becoming a router.
ST_ROLES='web db' ST_F_CONNTRACK=1 ST_ENGINES=('db|Redis')
policy_resolve
rendered="$(_sysctl_render)"
ok render_docker_ct grep -q '^net.netfilter.nf_conntrack_tcp_timeout_established = 7200$' <<<"$rendered"
nok render_docker_no_forward grep -q 'ip_forward' <<<"$rendered"
ok render_overcommit grep -q '^vm.overcommit_memory = 1$' <<<"$rendered"
ok render_dirty grep -q '^vm.dirty_ratio = 10$' <<<"$rendered"
ST_F_CONNTRACK=0 ST_ENGINES=()

# A kernel without IPv6 (ipv6.disable=1): no net.ipv6 keys are written,
# and keys the kernel lacks are "unsupported", never drift.
_sysctl_key_present() { [[ $1 != net.ipv6.* ]]; }
ST_ROLES='tunnel relay'
policy_resolve
rendered="$(_sysctl_render)"
nok render_no_ipv6 grep -q '^net.ipv6' <<<"$rendered"
ok render_v4_forward grep -q '^net.ipv4.ip_forward = 1$' <<<"$rendered"
_sysctl_key_present() { [[ $1 != no.such.* ]]; }
sysctl_get() { printf '1'; }
sysctl_verify $'a.b = 1\nno.such.key = 5'
eq verify_unsupported "0 no.such.key" "$? ${ST_SYSCTL_UNSUPPORTED[*]}"
sysctl_verify $'a.b = 2'
eq verify_drift 3 "$?"

# The generated boot-time IRQ loop is valid POSIX sh.
ST_F_CPU_LIST='0 1 2 3'
ok irq_boot_sh sh -n <<<"$(_nic_irq_boot_lines eth0)"

# Docker daemon.json merge (needs jq; CI runners have it).
if command -v jq >/dev/null 2>&1; then
  merged="$(docker_merge '{"log-driver":"json-file","log-opts":{"max-file":"5"},"live-restore":false}' 0)"
  eq docker_keeps_max_file '"5"' "$(jq -c '.["log-opts"]["max-file"]' <<<"$merged")"
  eq docker_adds_max_size '"10m"' "$(jq -c '.["log-opts"]["max-size"]' <<<"$merged")"
  eq docker_keeps_live_false false "$(jq -c '.["live-restore"]' <<<"$merged")"
  eq docker_adds_nofile 1048576 "$(jq -c '.["default-ulimits"].nofile.Soft' <<<"$merged")"
  merged="$(docker_merge '{"log-driver":"local"}' 1)"
  eq docker_local_untouched null "$(jq -c '.["log-opts"]' <<<"$merged")"
  eq docker_swarm_no_live null "$(jq -c '.["live-restore"]' <<<"$merged")"
  eq docker_added "log rotation, live-restore, container nofile" "$(_docker_added '{}' "$(docker_merge '{}' 0)")"
else
  printf 'skip: docker merge tests (jq not installed)\n'
fi

# --- Manifest + rollback in the sandbox ------------------------------------------------
ST_DRY_RUN=0
log_init
state_init
target="${SANDBOX}/etc-sample.conf"
knob="${SANDBOX}/knob"
printf 'original\n' >"$target"
printf 'old-value\n' >"$knob"
st_track_file "$target"
printf 'changed\n' >"$target"
st_set_runtime "$knob" new-value
eq runtime_written "new-value" "$(cat "$knob")"
eq latest_run "$ST_RUN_ID" "$(manifest_latest_run)"
rollback_latest >/dev/null
eq file_restored "original" "$(cat "$target")"
eq runtime_restored "old-value" "$(cat "$knob")"
eq run_closed "" "$(manifest_latest_run)"

# sysctl.conf overriding our file at boot: conflicts are found (only keys we
# set, only differing values, any spacing/`/` style) and commented out.
later="${SANDBOX}/sysctl.conf"
printf '%s\n' '# comment' 'net.core.default_qdisc=fq_codel' 'net/ipv4/tcp_congestion_control = bbr' \
  'vm.swappiness = 60' 'kernel.pid_max = 99999' >"$later"
want=$'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\nvm.swappiness = 10'
eq conflicts "net.core.default_qdisc vm.swappiness" "$(_sysctl_conflicts "$want" "$later" | cut -f2 | lines)"
_sysctl_neutralize "$later" net.core.default_qdisc vm.swappiness
eq neutralized "" "$(_sysctl_conflicts "$want" "$later")"
ok neutralize_marks grep -q '^# \[server-tools\] superseded by 99-zz-server-tools.conf: vm.swappiness = 60$' "$later"
ok neutralize_keeps grep -q '^kernel.pid_max = 99999$' "$later"
ok sysctl_name_sorts_last test "99-zz-server-tools.conf" '>' "99-sysctl.conf"

# dhclient keeps handing out OUR servers; the block is replaced, never doubled.
dhc="${SANDBOX}/dhclient.conf"
printf 'request subnet-mask;\n' >"$dhc"
has_cmd() { [[ $1 == dhclient ]] || command -v "$1" >/dev/null 2>&1; }
ST_DNS1=1.1.1.1 ST_DNS2=1.0.0.1
_dns_pin_dhclient "$dhc"
ST_DNS1=9.9.9.9 ST_DNS2=149.112.112.112
_dns_pin_dhclient "$dhc"
eq dhclient_once 1 "$(grep -c 'supersede domain-name-servers' "$dhc")"
ok dhclient_latest grep -q '^supersede domain-name-servers 9.9.9.9, 149.112.112.112;$' "$dhc"
ok dhclient_keeps grep -q '^request subnet-mask;$' "$dhc"
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Speed test history: rows are kept, capped and shown newest last.
for i in 1 2 3; do _st_history_add ookla "Server ${i}" "1${i}" 12500000 6250000 ''; done
eq speed_rows 3 "$(grep -vc '^#' "$ST_SPEED_HISTORY")"
ok speed_mbit grep -q $'\t100.0\t50.0\t' "$ST_SPEED_HISTORY"
ok speed_show grep -q 'Server 3' <<<"$(st_speed_history 2)"

# The generated boot-time qdisc block is valid POSIX sh.
ok qdisc_boot_sh sh -n <<<"$(_nic_qdisc_boot_lines eth0)"

# st_write_file: identical content is a no-op (not even tracked).
wfile="${SANDBOX}/limits.conf"
ok write_new st_write_file "$wfile" $'a\nb'
eq write_content $'a\nb' "$(cat "$wfile")"
nok write_same st_write_file "$wfile" $'a\nb'
ok write_changed st_write_file "$wfile" 'c'

# Two older runs: rolling back walks backwards, never re-applies the same run.
printf '2026-01-01 00:00:00\tA\tmodified\t/x\n2026-01-02 00:00:00\tB\tmodified\t/y\n' >>"$ST_MANIFEST_FILE"
eq open_runs "A B" "$(manifest_open_runs | lines)"
manifest_mark_rolled_back B
eq step_back "A" "$(manifest_latest_run)"

# Helpers whose "nothing found" is normal must not trip the program's ERR
# trap (field report 2.4.5: twenty "unhandled failure … grep" lines after
# Quick Optimize on a relay with no proxy services).
quiet_err() { # quiet_err NAME CMD... — CMD runs under the ERR trap; none may fire
  local name="$1" log="${SANDBOX}/err.log"
  shift
  : >"$log"
  (
    set -E -o pipefail
    trap 'printf "%s\n" "$BASH_COMMAND" >>"'"$log"'"' ERR
    "$@" >/dev/null 2>&1
    true
  )
  eq "$name" "" "$(cat "$log")"
}
ST_F_UNITS=$'ssh\ncron\nnftables' ST_F_CONTAINERS=''
quiet_err restart_none _restart_candidates
ST_F_UNITS=$'xray\nssh'
eq restart_xray $'service\txray' "$(_restart_candidates)"
ST_F_UNITS=''
quiet_err ft_devices_none _ft_devices
quiet_err mirror_none _mirror_files
quiet_err wg_ports_none wg_listen_ports
nt_unit="${SANDBOX}/notrack.service"
printf 'ExecStart=/bin/true\n' >"$nt_unit"
quiet_err notrack_ports_none notrack_unit_ports "$nt_unit"
printf 'ExecStart=iptables -t raw -A PREROUTING -p tcp --dport 443 -j CT --notrack\n' >"$nt_unit"
eq notrack_ports 443 "$(notrack_unit_ports "$nt_unit")"
printf '# date\tbackend\n' >"$ST_SPEED_HISTORY"
quiet_err speed_history_empty st_speed_history

printf 'unit: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
