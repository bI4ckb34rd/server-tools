#!/usr/bin/env bash
# ============================================================================
# tests/smoke.sh — fast sanity checks that need no root and no network:
# the build succeeds, the output parses, and the CLI contract holds
# (--version/--help, usage errors exit 2 before any root check).
# ============================================================================
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${ROOT_DIR}/dist/server-tools.sh"
VERSION="$(tr -d '[:space:]' <"${ROOT_DIR}/VERSION")"

fail() {
  printf 'smoke: FAIL — %s\n' "$1" >&2
  exit 1
}

# expect_exit CODE ARGS... — the CLI must exit with exactly CODE.
expect_exit() {
  local want="$1" rc=0
  shift
  bash "$DIST" "$@" >/dev/null 2>&1 || rc=$?
  [[ $rc == "$want" ]] || fail "'$*' exited ${rc}, expected ${want}"
}

# Invoke via bash so the test never depends on the exec bit surviving checkout.
bash "${ROOT_DIR}/build.sh" >/dev/null

bash -n "$DIST" || fail "dist does not parse"
if grep -q $'\r' "$DIST"; then
  fail "dist contains CRLF line endings"
fi

out="$(bash "$DIST" --version)"
[[ $out == *"$VERSION"* ]] || fail "--version output '${out}' does not contain '${VERSION}'"

expect_exit 0 --help
expect_exit 2 --definitely-not-an-option
expect_exit 2 --auto --profile
expect_exit 2 --auto --profile no-such-profile
expect_exit 2 --auto --tier Z
expect_exit 2 --auto --users many
expect_exit 2 --set
expect_exit 2 --role proxy # tuning options need --auto or --dry-run
expect_exit 2 --auto --role proxy,bogus
expect_exit 2 --ipv6
expect_exit 2 --ipv6 maybe

help="$(bash "$DIST" --help)"
for flag in --auto --dry-run --diagnose --verify --report --rollback --role --set --settings --no-mss --no-docker --ipv6 --speedtest; do
  grep -q -- "$flag" <<<"$help" || fail "--help should document ${flag}"
done

printf 'smoke: OK (v%s)\n' "$VERSION"
