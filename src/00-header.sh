#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
# src/00-header.sh — strict mode, global constants, exit-code contract, ERR
# trap. This file MUST be first in the build order (see build.sh SOURCES).
# ============================================================================

set -Eeuo pipefail
# Hardened IFS: deliberately NO space. See lib/net.sh (ports_split/join_sp)
# for the two idioms this breaks and the helpers that replace them.
IFS=$'\n\t'

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  printf 'ServerTools requires bash >= 4.4 (found %s)\n' "${BASH_VERSION}" >&2
  exit 1
fi

readonly ST_NAME="ServerTools"
readonly ST_VERSION="@VERSION@"
readonly ST_REPO_URL="https://github.com/Sir-Adnan/server-tools"
# On-disk state layout version (manifest actions, runtime backups, config
# keys). pre-2.4.5 installs carry no `schema` key and are migrated once by
# state/migrate.sh.
readonly ST_SCHEMA=3

# Filesystem layout (FHS): config in /etc, state and backups in /var/lib,
# log in /var/log. Nothing is ever written to /tmp (predictable names in
# world-writable directories are a symlink-attack risk for a root tool).
# ST_STATE_ROOT relocates ONLY ServerTools' own state (config, manifest, backups,
# log) — used by tests/unit.sh to exercise rollback in a sandbox. Never set
# in production.
readonly ST_STATE_ROOT="${ST_STATE_ROOT:-}"
readonly ST_ETC_DIR="${ST_STATE_ROOT}/etc/server-tools"
readonly ST_CONFIG_FILE="${ST_ETC_DIR}/config"
readonly ST_LIB_DIR="${ST_STATE_ROOT}/var/lib/server-tools"
readonly ST_BACKUP_DIR="${ST_LIB_DIR}/backups"
readonly ST_ORIGINAL_DIR="${ST_BACKUP_DIR}/original"
readonly ST_MANIFEST_FILE="${ST_LIB_DIR}/manifest.tsv"

# Run ids sort chronologically within one format, but rollback no longer
# relies on sorting (the manifest is append-only, so file order IS time
# order). Two runs inside the same second — a scripted `--auto && --verify`
# chain — must still never share a backup directory, or the second run would
# overwrite the first run's "before" copies.
ST_RUN_ID="$(date +%Y%m%d-%H%M%S)"
[[ -e ${ST_BACKUP_DIR}/runs/${ST_RUN_ID} ]] && ST_RUN_ID+="-$$"
readonly ST_RUN_ID
readonly ST_RUN_BACKUP_DIR="${ST_BACKUP_DIR}/runs/${ST_RUN_ID}"

# Runtime flags — may be flipped by CLI arguments before initialisation.
ST_OPT_DEBUG=0
ST_OPT_NO_COLOR=0
ST_OPT_BATCH=0
ST_OPT_JSON=0
ST_DRY_RUN=0

# Exit-code contract (documented in --help and docs/ARCHITECTURE.md):
#   0  every step succeeded (or was legitimately skipped)
#   1  at least one step FAILED
#   2  usage error (bad CLI arguments)
#   3  everything applied but at least one step reported a WARNING / drift
# ST_EXIT_CODE only ever escalates: warn (3) never overwrites fail (1).
ST_EXIT_CODE=0

st_escalate_exit() { # st_escalate_exit CODE
  case "$1" in
    1) ST_EXIT_CODE=1 ;;
    3) ((ST_EXIT_CODE == 1)) || ST_EXIT_CODE=3 ;;
  esac
}

on_unhandled_error() {
  local exit_code="$1" line="$2" command="$3"
  local msg="unhandled failure (exit=${exit_code}) at line ${line}: ${command}"
  if declare -F log_error >/dev/null 2>&1; then
    log_error "$msg"
  else
    printf '\n[%s] %s\n' "$ST_NAME" "$msg" >&2
  fi
}
trap 'on_unhandled_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
