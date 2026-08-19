#!/usr/bin/env bash
set -u
script_dir() {
  local src="${BASH_SOURCE[0]}"
  case "$src" in
    */*) (cd "${src%/*}" && pwd -P) ;;
    *) pwd -P ;;
  esac
}
TEST_DIR="$(script_dir)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd -P)"
HOOK="${REPO_ROOT}/.claude/hooks/agent-graceful-shutdown.sh"
[[ -f "${HOOK}" ]] || { echo "ERR: hook missing" >&2; exit 1; }
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
SRC_COPY="${TMP_DIR}/hook-defs.sh"
awk '/^# Dispatch\.$/ { stop=1 } stop != 1 { print }' "${HOOK}" > "${SRC_COPY}"
export GSD_IDLE_REMINDER_SECONDS=1
export REVHARNESS_AGENT_START_TS=$(( $(date +%s) - 10 ))
rm -f "${REPO_ROOT}/.agent/runtime/gsd_last_reminder" 2>/dev/null || true
(
  source "${SRC_COPY}"
  rm -f "${__GSD_REPO_ROOT:-/nonexistent}/.agent/runtime/gsd_last_reminder" 2>/dev/null || true
  gsd_idle_reminder 2>&1
)
exit 0
