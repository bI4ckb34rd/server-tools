#!/usr/bin/env bash
# ============================================================================
# tests/netns.sh — integration test against a REAL kernel, isolated in a
# private network + mount namespace (needs root: `sudo tests/netns.sh`).
#
# Builds a miniature GRE relay — a multi-TX/single-RX veth uplink, a GRE
# tunnel and a DNAT rule forwarding a port through it — then drives the real
# detection, policy, tuners and rollback against it:
#   facts/roles/policy on real devices, the live qdisc rebuild (mq kept),
#   RPS written to real queues, idempotent MSS rules, host-scoped NOTRACK,
#   tunnel MTU audit, DNAT discovery, and rollback restoring live state.
# Global knobs (THP) are bind-mounted onto scratch files, systemd units are
# not installed, and the global default qdisc is restored on exit — the host
# is left exactly as it was.
# ============================================================================
# The sourced program consumes the globals set below; ShellCheck cannot see that.
# shellcheck disable=SC2034,SC2153,SC2154
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${ROOT_DIR}/dist/server-tools.sh"

if [[ ${ST_NETNS_INNER:-0} != 1 ]]; then
  ((EUID == 0)) || {
    printf 'netns: needs root (sudo %s)\n' "$0" >&2
    exit 1
  }
  bash "${ROOT_DIR}/build.sh" >/dev/null
  exec unshare --net --mount --propagation private env ST_NETNS_INNER=1 bash "$0" "$@"
fi

SANDBOX="$(mktemp -d)"
ORIG_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf '')"
cleanup() {
  [[ -n $ORIG_QDISC ]] && sysctl -qw "net.core.default_qdisc=${ORIG_QDISC}" 2>/dev/null
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# Our own /sys view of this namespace, and scratch copies of global knobs.
mount -t sysfs sysfs /sys
for knob in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
  [[ -e $knob ]] || continue
  fake="${SANDBOX}/$(basename "$knob")"
  printf 'always [madvise] never\n' >"$fake"
  sed -i 's/\[madvise\]/madvise/; s/always/[always]/' "$fake"
  mount --bind "$fake" "$knob"
done

# --- The miniature relay -----------------------------------------------------
ip link set lo up
ip link add veth0 numtxqueues 4 numrxqueues 1 type veth peer name veth1
ip addr add 192.0.2.1/24 dev veth0
ip link set veth0 up
ip link set veth1 up
ip route add default via 192.0.2.254 dev veth0 onlink
modprobe ip_gre 2>/dev/null || :
ip tunnel add gre1 mode gre remote 198.51.100.7 local 192.0.2.1 ttl 255
ip link set gre1 mtu 1476 up
ip addr add 10.9.0.1/30 dev gre1
iptables -w -t nat -A PREROUTING -p tcp --dport 8443 -j DNAT --to-destination 10.9.0.2:443
iptables -w -t nat -A POSTROUTING -o gre1 -j MASQUERADE

export ST_STATE_ROOT="$SANDBOX"
ST_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "$DIST"
trap cleanup EXIT
trap - ERR
set +e
systemd_usable() { return 1; } # never install units on the test host
_mss_ufw_persist() { return 2; }

PASS=0
FAIL=0
eq() {
  if [[ $2 == "$3" ]]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"
  fi
}
ok() {
  local n="$1"
  shift
  if "$@"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n' "$n"
  fi
}

log_init
state_init
config_load

# --- Detection & policy ---------------------------------------------------------
facts_collect
eq iface veth0 "$ST_F_IFACE"
eq rxq 1 "$ST_F_RXQ"
eq txq 4 "$ST_F_TXQ"
eq tunnel "gre1|gre|1476|198.51.100.7|" "${ST_F_TUNNELS[0]:-}"
eq dnat_remote 10.9.0.2 "$ST_F_DNAT_REMOTE"
eq dnat_ports 8443 "$(fw_dnat_ports | paste -sd' ' -)"
roles_resolve 'tunnel,relay'
capacity_resolve
policy_resolve
eq fwd_heavy 1 "$ST_P_FWD_HEAVY"
eq rps 1 "$ST_P_RPS"
eq rfs 0 "$ST_P_RFS"
eq mss 1 "$ST_P_MSS"
ok tunnel_mtu_ok grep -q '^gre1|gre|1476|1476|ok|' <<<"$(tunnel_rows)"

# --- Live qdisc: multi-queue stays mq -------------------------------------------
# pre-2.4.5 collapsed mq into ONE root fq; the 2.4.5 repair must hand the device back
# to the kernel default (net.core.default_qdisc is global, so it cannot be
# changed from inside this namespace — the rebuild itself is what we test).
tc qdisc replace dev veth0 root fq
eq v2_damage fq "$(net_root_qdisc veth0 | awk '{print $1}')"
_migrate_qdisc
ok v2_single_fq_repaired test "$(net_root_qdisc veth0 | awk '{print $1}')" != fq

# --- RPS on the real queue, THP via the scratch knob, offloads via ethtool -----------
gro_before="$ST_F_GRO"
printf 'info: ethtool=%s gro=%s udp-gro-fwd=%s channels=%s/%s\n' \
  "$(command -v ethtool || printf none)" "${ST_F_GRO:-n/a}" "${ST_F_UDPGRO:-n/a}" "$ST_F_CH_CUR" "$ST_F_CH_MAX"
nic_apply
((ST_P_GRO)) && eq gro_enabled on "$(net_offload veth0 gro)"
want="$(cpu_mask_norm "$(cpu_mask_from_list "$ST_P_RPS_CPUS")")"
eq rps_live "$want" "$(cpu_mask_norm "$(cat /sys/class/net/veth0/queues/rx-0/rps_cpus)")"
[[ -e /sys/kernel/mm/transparent_hugepage/enabled ]] &&
  eq thp madvise "$(runtime_read /sys/kernel/mm/transparent_hugepage/enabled)"

# --- MSS: idempotent -----------------------------------------------------------------
mss_apply
mss_apply
eq mss_single_rule 1 "$(iptables -w -t mangle -S FORWARD | grep -c TCPMSS)"
ok mss_verify mss_verify

# --- NOTRACK: scoped to local destinations ----------------------------------------
if _notrack_detect_target; then
  _notrack_rules iptables -A _notrack_specs 443
  ok notrack_scoped grep -q -- '--dport 443 -m addrtype --dst-type LOCAL' <<<"$(iptables -w -t raw -S PREROUTING)"
  _notrack_rules iptables -D _notrack_specs 443
  eq notrack_removed 0 "$(iptables -w -t raw -S | grep -c 'dport 443')"
fi

# --- Flowtable syntax accepted by this kernel (informational) --------------------
if has_cmd nft; then
  if _ft_ruleset veth0 gre1 | nft -c -f - 2>/dev/null; then
    printf 'info: flowtable ruleset accepted by this kernel\n'
  else
    printf 'info: flowtable not supported by this kernel (feature refuses cleanly)\n'
  fi
fi

# --- Rollback restores the live values ----------------------------------------------
rollback_latest >/dev/null
eq rps_restored 0 "$(cpu_mask_norm "$(cat /sys/class/net/veth0/queues/rx-0/rps_cpus)")"
((ST_P_GRO)) && eq gro_restored "$gro_before" "$(net_offload veth0 gro)"
[[ -e /sys/kernel/mm/transparent_hugepage/enabled ]] &&
  eq thp_restored always "$(runtime_read /sys/kernel/mm/transparent_hugepage/enabled)"
ok qdisc_still_default test "$(net_root_qdisc veth0 | awk '{print $1}')" != fq
eq run_closed "" "$(manifest_latest_run)"

printf 'netns: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
