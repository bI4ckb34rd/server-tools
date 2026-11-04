# shellcheck shell=bash
# ============================================================================
# features/docker.sh — Docker engine hygiene for hosts that run containers
# (bots, sites, panels, nodes). Three daemon.json settings, MERGED with jq
# into whatever the operator already has — existing values always win:
#
#   log-opts max-size/max-file  json-file container logs are unbounded by
#                               default: the most common "disk full" on bot
#                               and panel hosts;
#   live-restore                containers keep running while dockerd itself
#                               restarts (not allowed in Swarm mode);
#   default-ulimits nofile      containers inherit dockerd's limit, never
#                               /etc/security/limits.d.
#
# Applied with a reload (SIGHUP): live-restore takes effect, nothing stops.
# Log rotation and ulimits need a dockerd restart and only reach containers
# created afterwards — the step says so and only OFFERS the restart.
# ============================================================================

readonly ST_DOCKER_DAEMON='/etc/docker/daemon.json'
readonly ST_DOCKER_CONTAINERS='/var/lib/docker/containers'
ST_DOCKER_CHANGED=0

# Existing keys are never overwritten: `{defaults} + existing` lets the
# operator's values win, and has() keeps an explicit live-restore=false.
# shellcheck disable=SC2016 # jq program, $vars are jq's
readonly ST_DOCKER_JQ='
  (if ((.["log-driver"] // "json-file") == "json-file")
     then .["log-opts"] = ({"max-size": $size, "max-file": "3"} + (.["log-opts"] // {}))
     else . end)
  | (if $swarm == "1" or has("live-restore") then . else .["live-restore"] = true end)
  | .["default-ulimits"] = ((.["default-ulimits"] // {})
      | if has("nofile") then . else .nofile = {"Name": "nofile", "Soft": 1048576, "Hard": 1048576} end)'

docker_available() {
  has_cmd docker && [[ -S /var/run/docker.sock ]]
}

_docker_current() {
  if [[ -s $ST_DOCKER_DAEMON ]]; then
    cat "$ST_DOCKER_DAEMON"
  else
    printf '{}'
  fi
}

_docker_swarm_active() {
  [[ "$(run_bounded 8 docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" == active ]]
}

# docker_merge JSON SWARM(0|1) — the merged daemon.json (needs jq).
docker_merge() {
  jq --arg size "$(config_get docker_log_size)" --arg swarm "$2" "$ST_DOCKER_JQ" <<<"$1"
}

# _docker_added CURRENT MERGED — the settings the merge adds, comma separated.
_docker_added() {
  local out='' spec path label
  for spec in '.["log-opts"]["max-size"]|log rotation' '.["live-restore"]|live-restore' \
    '.["default-ulimits"]["nofile"]|container nofile'; do
    path="${spec%%|*}"
    label="${spec#*|}"
    if [[ "$(jq -c "$path" <<<"$1" 2>/dev/null)" == null && "$(jq -c "$path" <<<"$2" 2>/dev/null)" != null ]]; then
      out+="${out:+, }${label}"
    fi
  done
  printf '%s' "$out"
}

# _docker_validate FILE — dockerd's own check where it has one (Docker 23+);
# jq has already proved the file parses.
_docker_validate() {
  has_cmd dockerd || return 0
  local help
  help="$(dockerd --help 2>&1)" || help=''
  grep -q -- '--validate' <<<"$help" || return 0
  dockerd --validate --config-file "$1" >>"$ST_LOG_FILE" 2>&1
}

# docker_apply — runner step. 0 ok, 1 failed, 2 not applicable, 3 warning.
docker_apply() {
  ST_DOCKER_CHANGED=0
  ((ST_P_DOCKER)) || return 2
  deps_ensure docker || log_debug "jq not installed (see above)"
  if ! has_cmd jq; then
    log_warn "jq is unavailable — ${ST_DOCKER_DAEMON} left unchanged (it cannot be merged safely without it)."
    return 3
  fi
  local cur merged swarm=0 added rc=0
  cur="$(_docker_current)"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$cur"; then
    log_warn "${ST_DOCKER_DAEMON} is not a valid JSON object — left as-is (dockerd would refuse it too)."
    return 3
  fi
  _docker_swarm_active && swarm=1
  if ! merged="$(docker_merge "$cur" "$swarm")"; then
    log_error "Could not merge ${ST_DOCKER_DAEMON} — left unchanged."
    return 1
  fi
  if [[ "$(jq -S . <<<"$cur")" == "$(jq -S . <<<"$merged")" ]]; then
    log_note "Docker already has bounded logs, live-restore and container nofile."
    return 0
  fi
  added="$(_docker_added "$cur" "$merged")"

  local tmp="${ST_LIB_DIR}/daemon.json.new"
  printf '%s\n' "$merged" >"$tmp"
  if ! _docker_validate "$tmp"; then
    rm -f "$tmp"
    log_warn "dockerd rejected the merged configuration — ${ST_DOCKER_DAEMON} left unchanged (details in the log)."
    return 3
  fi
  st_track_file "$ST_DOCKER_DAEMON"
  mkdir -p "$(dirname "$ST_DOCKER_DAEMON")"
  mv -f "$tmp" "$ST_DOCKER_DAEMON"
  chmod 0644 "$ST_DOCKER_DAEMON"
  ST_DOCKER_CHANGED=1
  log_note "daemon.json: added ${added:-settings} (existing values kept)."

  if has_cmd systemctl && systemctl reload docker 2>>"$ST_LOG_FILE"; then
    log_note "Reloaded dockerd — live-restore is active, no container was stopped."
  else
    log_warn "Could not reload dockerd — the settings apply at its next restart."
    rc=3
  fi
  log_note "Log rotation and nofile reach containers created after a Docker restart (docker compose up -d --force-recreate)."
  ((swarm)) && log_note "Swarm mode is active: live-restore is not supported there and was left off."
  log_info "docker daemon.json merged: ${added}"
  return "$rc"
}

# docker_verify — doctor contract: 0 logs are bounded, 2 no Docker, 3 the
# default json-file driver runs without a size limit.
docker_verify() {
  docker_available || return 2
  local cfg driver size
  cfg="$(_docker_current)"
  if has_cmd jq; then
    driver="$(jq -r '.["log-driver"] // "json-file"' <<<"$cfg" 2>/dev/null)" || return 3
    size="$(jq -r '.["log-opts"]["max-size"] // ""' <<<"$cfg" 2>/dev/null)" || size=''
  else
    driver="$(grep -oE '"log-driver"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$cfg" | grep -oE '"[^"]+"$' | tr -d '"')" || driver=''
    size="$(grep -oE '"max-size"' <<<"$cfg")" || size=''
    driver="${driver:-json-file}"
  fi
  [[ $driver != json-file || -n $size ]] && return 0
  return 3
}

# docker_dry_run — what the step would merge, without touching anything.
docker_dry_run() {
  ((ST_P_DOCKER)) || return 0
  printf '\n%s[Docker engine]%s\n' "$C_TITLE" "$C_RESET"
  if ! has_cmd jq; then
    printf '  would install jq, then merge log rotation, live-restore and container nofile into %s\n' "$ST_DOCKER_DAEMON"
    return 0
  fi
  local cur merged swarm=0
  cur="$(_docker_current)"
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$cur"; then
    printf '  %s is not valid JSON — would be left as-is\n' "$ST_DOCKER_DAEMON"
    return 0
  fi
  _docker_swarm_active && swarm=1
  merged="$(docker_merge "$cur" "$swarm")" || return 0
  if [[ "$(jq -S . <<<"$cur")" == "$(jq -S . <<<"$merged")" ]]; then
    printf '  (already configured)\n'
  else
    printf '  %s: would add %s, then reload dockerd (no container stops)\n' \
      "$ST_DOCKER_DAEMON" "$(_docker_added "$cur" "$merged")"
  fi
}

# docker_offer_restart — interactive follow-up after the step changed
# daemon.json. With live-restore on, containers survive the restart.
docker_offer_restart() {
  ((ST_DOCKER_CHANGED)) || return 0
  ((ST_OPT_BATCH)) && {
    printf '%sNote:%s restart Docker in a quiet moment to apply log rotation and nofile: systemctl restart docker\n' "$C_MUTED" "$C_RESET"
    return 0
  }
  local live
  live="$(run_bounded 8 docker info --format '{{.LiveRestoreEnabled}}' 2>/dev/null)" || live=''
  if [[ $live == true ]]; then
    printf '%slive-restore is on:%s running containers keep running while Docker restarts.\n' "$C_OK" "$C_RESET"
  else
    printf '%slive-restore is off:%s restarting Docker restarts every container.\n' "$C_WARN" "$C_RESET"
  fi
  ui_confirm "Restart Docker now so log rotation and container limits take effect?" || return 0
  if systemctl restart docker 2>>"$ST_LOG_FILE"; then
    printf '%sDocker restarted.%s Recreate containers to give them the new log limits.\n' "$C_OK" "$C_RESET"
  else
    log_error "Docker restart failed — check: systemctl status docker (rollback restores daemon.json)."
  fi
}

# _docker_big_logs [MIN_MB] — "SIZE_MB<TAB>container<TAB>path", largest first.
_docker_big_logs() {
  local min_mb="${1:-0}" out id name size path
  [[ -d $ST_DOCKER_CONTAINERS ]] || return 0
  out="$(find "$ST_DOCKER_CONTAINERS" -maxdepth 2 -name '*-json.log' -size "+${min_mb}M" -printf '%s\t%p\n' 2>/dev/null |
    sort -rn | head -n 10)" || out=''
  while IFS=$'\t' read -r size path; do
    [[ -n $path ]] || continue
    id="$(basename "$(dirname "$path")")"
    name="$(run_bounded 5 docker inspect --format '{{.Name}}' "$id" 2>/dev/null)" || name="${id:0:12}"
    printf '%s\t%s\t%s\n' "$((size / 1048576))" "${name#/}" "$path"
  done <<<"$out"
}

docker_audit() {
  ui_section "Docker engine"
  if ! docker_available; then
    ui_step_note idle "Docker is not running on this server."
    return 2
  fi
  local cfg version live driver proxies total
  cfg="$(_docker_current)"
  version="$(run_bounded 8 docker version --format '{{.Server.Version}}' 2>/dev/null)" || version='?'
  live="$(run_bounded 8 docker info --format '{{.LiveRestoreEnabled}}' 2>/dev/null)" || live='?'
  ui_kv "Version" "$version"
  ui_kv "live-restore" "$live"
  if docker_verify; then
    ui_step_note ok "Container logs are bounded."
  else
    ui_step_note warn "json-file logs have no size limit — they grow until the disk is full (Quick Optimize fixes it)."
  fi
  if has_cmd jq; then
    driver="$(jq -c '{"log-driver": .["log-driver"], "log-opts": .["log-opts"], "live-restore": .["live-restore"]}' <<<"$cfg" 2>/dev/null)" || driver=''
    [[ -n $driver ]] && ui_kv "daemon.json" "$driver"
  fi

  ui_section "Largest container logs"
  total="$(find "$ST_DOCKER_CONTAINERS" -maxdepth 2 -name '*-json.log' -printf '%s\n' 2>/dev/null |
    awk '{s += $1} END {printf "%d", s / 1048576}')" || total=0
  ui_kv "All logs" "${total} MB"
  local mb name _path
  while IFS=$'\t' read -r mb name _path; do
    [[ -n $name ]] && ui_kv "$name" "${mb} MB"
  done < <(_docker_big_logs 1 | head -n 5)

  proxies="$(pgrep -c -x docker-proxy 2>/dev/null)" || proxies=0
  if ((proxies > 20)); then
    ui_step_note warn "${proxies} docker-proxy processes (one per published port). \"userland-proxy\": false in daemon.json lets iptables do it instead."
  fi
  ui_section "Disk usage"
  run_bounded 20 docker system df 2>/dev/null | sed 's/^/    /' || ui_step_note idle "docker system df did not answer."
  return 0
}

# docker_logs_truncate — empty container logs above 100 MB, after consent.
# Not reversible (the log text is gone), which the prompt says.
docker_logs_truncate() {
  local list mb name path
  list="$(_docker_big_logs 100)"
  if [[ -z $list ]]; then
    printf 'No container log is larger than 100 MB.\n'
    return 0
  fi
  while IFS=$'\t' read -r mb name path; do
    printf '  %6s MB  %s\n' "$mb" "$name"
  done <<<"$list"
  printf '%sThe log text is deleted for good; containers keep running.%s\n' "$C_WARN" "$C_RESET"
  ui_confirm "Empty these logs now?" || return 0
  while IFS=$'\t' read -r mb name path; do
    if truncate -s 0 "$path" 2>>"$ST_LOG_FILE"; then
      log_info "docker log truncated: ${name} (${mb} MB)"
    else
      log_warn "Could not truncate the log of ${name}."
    fi
  done <<<"$list"
  printf '%sDone.%s\n' "$C_OK" "$C_RESET"
}

docker_menu() {
  while true; do
    ui_logo
    ui_title "Docker engine"
    ui_menu_item 1 "Audit" "logs, live-restore, limits, disk usage"
    ui_menu_item 2 "Apply hygiene" "log rotation · live-restore · container nofile"
    ui_menu_item 3 "Empty huge logs" "container logs above 100 MB"
    ui_menu_item 0 "Back"
    local choice
    read -rp "$(_ui_prompt)" choice || return 0
    case "$choice" in
      1) docker_audit || true ;;
      2)
        # An explicit menu choice applies even with docker_tuning=off.
        facts_collect force
        ST_P_DOCKER="$ST_F_DOCKER"
        ST_STEP_IDX=0 ST_STEP_TOTAL=1
        st_run_step "Docker engine (log rotation, live-restore, nofile)" docker_apply
        docker_offer_restart
        ;;
      3) docker_logs_truncate ;;
      0) return 0 ;;
      *)
        ui_invalid
        continue
        ;;
    esac
    ui_pause
  done
}
