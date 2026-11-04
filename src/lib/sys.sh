# shellcheck shell=bash
# ============================================================================
# lib/sys.sh — dependency-free host facts: commands, OS, kernel, CPU, memory,
# virtualisation, packages, sysctl reads. Pure readers: nothing here changes
# the system except pkg_install (which callers gate behind user consent).
# ============================================================================

has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  ((EUID == 0)) || die "This tool must be run as root (try: sudo -i)."
}

os_pretty_name() {
  local name=''
  if [[ -r /etc/os-release ]]; then
    name="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")" || name=''
  fi
  printf '%s' "${name:-unknown}"
}

os_id() {
  local id=''
  [[ -r /etc/os-release ]] && id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
  printf '%s' "${id:-unknown}"
}

kernel_release() { uname -r 2>/dev/null || printf 'unknown'; }

kernel_base() {
  local rel
  rel="$(kernel_release)"
  printf '%s' "${rel%%-*}"
}

detect_virt() {
  local virt=''
  if has_cmd systemd-detect-virt; then
    # Exit code 1 simply means "not virtualised"; the answer is on stdout.
    virt="$(systemd-detect-virt 2>/dev/null)" || virt="${virt:-none}"
  fi
  printf '%s' "${virt:-unknown}"
}

# virt_is_container [VIRT] — 0 inside an OS container (LXC, OpenVZ,
# Docker, nspawn): the kernel belongs to the host, so swap, cpufreq, the
# clock and many sysctls are not ours to change.
# shellcheck disable=SC2120 # the argument is optional
virt_is_container() {
  case "${1:-${ST_F_VIRT:-unknown}}" in
    lxc | lxc-libvirt | openvz | docker | podman | systemd-nspawn | rkt | proot | pouch) return 0 ;;
  esac
  return 1
}

# run_bounded SECONDS CMD... — CMD with a time limit (coreutils timeout).
# A wedged dockerd never answers `docker ps`; unbounded, one hung daemon
# would freeze every ServerTools command, the status screen included.
run_bounded() {
  local secs="$1"
  shift
  if has_cmd timeout; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

mem_total_mb() {
  awk '/^MemTotal:/ {print int($2 / 1024); exit}' /proc/meminfo 2>/dev/null || printf '0'
}

# cpu_list_expand "0-3,6,8-9" — one CPU id per line.
cpu_list_expand() {
  local item low high
  while IFS= read -r item; do
    if [[ $item =~ ^([0-9]+)-([0-9]+)$ ]]; then
      low="${BASH_REMATCH[1]}"
      high="${BASH_REMATCH[2]}"
      while ((low <= high)); do
        printf '%s\n' "$low"
        low=$((low + 1))
      done
    elif [[ $item =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$item"
    fi
  done < <(tr ',' '\n' <<<"${1:-}")
}

# cpu_online_list — online CPU ids, one per line. Read from sysfs, not nproc:
# nproc honours OMP_NUM_THREADS and the caller's affinity/cgroup, and ids
# are not guaranteed to be contiguous (offline or hot-unplugged vCPUs).
cpu_online_list() {
  local online=''
  [[ -r /sys/devices/system/cpu/online ]] && online="$(cat /sys/devices/system/cpu/online 2>/dev/null)"
  if [[ -n $online ]]; then
    cpu_list_expand "$online"
    return 0
  fi
  local n
  n="$(nproc --all 2>/dev/null)" || n="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)" || n=1
  [[ $n =~ ^[0-9]+$ ]] || n=1
  seq 0 $((n - 1))
}

cpu_cores() {
  local n
  n="$(cpu_online_list | wc -l | tr -d '[:space:]')"
  [[ $n =~ ^[1-9][0-9]*$ ]] || n=1
  printf '%s' "$n"
}

cpu_model() {
  local model
  model="$(awk -F': *' '/^(model name|Model)/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)" || model=''
  printf '%s' "${model:-unknown}"
}

# cpu_mask_from_list "1 2 3" — kernel bitmap ("0000000e" / "00000001,ffffffff")
# for rps_cpus/xps_cpus: comma-separated 32-bit hex words, most significant
# first. Handles sparse ids and any CPU count.
cpu_mask_from_list() {
  local cpu max=0 i out=''
  local -a words=()
  while IFS= read -r cpu; do
    [[ $cpu =~ ^[0-9]+$ ]] || continue
    i=$((cpu / 32))
    words[i]=$((${words[i]:-0} | (1 << (cpu % 32))))
    ((i > max)) && max=$i
  done < <(ports_split "${1:-}")
  for ((i = max; i >= 0; i--)); do
    out+="$(printf '%08x' "${words[i]:-0}")"
    ((i > 0)) && out+=','
  done
  printf '%s' "$out"
}

# cpu_mask_norm MASK — canonical form for comparing kernel bitmaps: the
# kernel pads to nr_cpu_ids and inserts commas, so "f", "0000000f" and
# "00000000,0000000f" are the same set.
cpu_mask_norm() {
  local m="${1//,/}"
  m="${m,,}"
  m="${m#"${m%%[!0]*}"}"
  printf '%s' "${m:-0}"
}

uptime_pretty() {
  local secs
  secs="$(cut -d. -f1 /proc/uptime 2>/dev/null)" || secs=''
  [[ $secs =~ ^[0-9]+$ ]] || {
    printf 'unknown'
    return 0
  }
  printf '%dd %dh %dm' $((secs / 86400)) $((secs % 86400 / 3600)) $((secs % 3600 / 60))
}

load_avg() {
  cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || printf 'unknown'
}

# ver_ge A B — true when dotted version A >= B.
ver_ge() {
  [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

# sysctl_get KEY — current value or "?" when unavailable.
sysctl_get() {
  local value=''
  if has_cmd sysctl; then
    value="$(sysctl -n "$1" 2>/dev/null)" || value=''
  fi
  printf '%s' "${value:-?}"
}

# pkg_install PACKAGE... — install with the host's package manager, quietly
# (output goes to the log), lean (no recommends) and patient with a held apt
# lock (unattended-upgrades on fresh VPS images).
ST_PKG_INDEX_UPDATED=0

pkg_install() {
  (($# > 0)) || return 0
  if has_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    local -a apt_opts=(-y -qq -o DPkg::Lock::Timeout=120 --no-install-recommends)
    if ((ST_PKG_INDEX_UPDATED == 0)); then
      apt-get -o DPkg::Lock::Timeout=120 update -qq >>"$ST_LOG_FILE" 2>&1 ||
        log_warn "apt index update failed — trying the install anyway."
      ST_PKG_INDEX_UPDATED=1
    fi
    apt-get install "${apt_opts[@]}" "$@" >>"$ST_LOG_FILE" 2>&1
  elif has_cmd dnf; then
    dnf install -y "$@" >>"$ST_LOG_FILE" 2>&1
  elif has_cmd yum; then
    yum install -y "$@" >>"$ST_LOG_FILE" 2>&1
  elif has_cmd pacman; then
    pacman -Sy --noconfirm --needed "$@" >>"$ST_LOG_FILE" 2>&1
  else
    log_error "No supported package manager found to install: $*."
    return 1
  fi
}

# systemd_usable — a real systemd we can write units for.
systemd_usable() {
  [[ -d /etc/systemd/system ]] && has_cmd systemctl
}

# systemd_enable_oneshot UNIT — daemon-reload + enable + manifest row.
# Returns 0 on success, 3 when persistence could not be set up.
systemd_enable_oneshot() {
  local unit="$1"
  systemctl daemon-reload 2>>"$ST_LOG_FILE" ||
    log_warn "systemd daemon-reload failed — ${unit} is written but not loaded yet."
  if systemctl enable "$unit" >/dev/null 2>>"$ST_LOG_FILE"; then
    manifest_add unit "$unit"
    return 0
  fi
  log_warn "Could not enable ${unit} — the change is live now but will not survive a reboot."
  return 3
}
