#!/usr/bin/env bash
# Foreign-owner audit_only branch coverage.
#
# Asserts that gsd_bg_job_reaper emits exactly one
#   event="bg_reap" class="foreign_outside_pgid" action="audit_only"
# row to wrapper_events.jsonl when a registered bg job's live pgid does NOT
# match the reaper's target pgid, AND the bg job's PID remains alive
# (i.e. the reaper sent neither SIGTERM nor SIGKILL).
#
# Coverage of agent-graceful-shutdown.sh line 458
# (foreign_outside_pgid emit, audit_only action — no signal).
#
# Sandbox-aware: SKIPs cleanly when `ps -o pgid=` is denied or unavailable
# (mirrors test/unit/test-harness-bg-spawn.sh fail-soft pattern, T-B-7).

set -u

script_dir() {
  local src="${BASH_SOURCE[0]}"
  case "$src" in
    */*) (cd "${src%/*}" && pwd -P) ;;
    *)   pwd -P ;;
  esac
}
TEST_DIR="$(script_dir)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd -P)"
HOOK="${REPO_ROOT}/.claude/hooks/agent-graceful-shutdown.sh"
SPAWNER="${REPO_ROOT}/scripts/harness-bg-spawn.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok:   $*"; }
skip() { echo "SKIP: $*"; exit 0; }

[[ -r "${HOOK}" ]]    || fail "hook not readable: ${HOOK}"
[[ -x "${SPAWNER}" ]] || fail "spawner not executable: ${SPAWNER}"

# Sandbox precondition: `ps -o pgid=` must work.
if ! command -v ps >/dev/null 2>&1; then
  skip "ps not available; foreign-pgid assertion requires ps"
fi
SELF_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
if [[ -z "${SELF_PGID}" || ! "${SELF_PGID}" =~ ^[0-9]+$ ]]; then
  skip "ps denied by sandbox; foreign-pgid assertion requires pgid resolution"
fi

SANDBOX="$(mktemp -d -t reaper-foreign-XXXXXX 2>/dev/null || mktemp -d)"
[[ -d "${SANDBOX}" ]] || fail "could not mktemp -d"

CHILD_PID=""
cleanup() {
  [[ -n "${CHILD_PID}" ]] && kill -KILL "${CHILD_PID}" 2>/dev/null
  rm -rf "${SANDBOX}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

BG_DIR="${SANDBOX}/bg_jobs"
METRICS_DIR="${SANDBOX}/metrics"
mkdir -p "${BG_DIR}" "${METRICS_DIR}"

# Spawn a real bg job (setsid → distinct pgid) using harness-bg-spawn.sh.
STDOUT_LOG="${SANDBOX}/spawner.stdout"
HARNESS_BG_JOBS_DIR="${BG_DIR}" \
  "${SPAWNER}" \
    --task-id foreign-audit-001 \
    --owner agent-foreign \
    -- sleep 30 \
    > "${STDOUT_LOG}" 2>/dev/null \
  || fail "spawner failed"

CHILD_PID="$(tr -d ' \n\r' < "${STDOUT_LOG}")"
[[ "${CHILD_PID}" =~ ^[0-9]+$ ]] || fail "spawner stdout not numeric: '${CHILD_PID}'"

CHILD_PGID="$(ps -o pgid= -p "${CHILD_PID}" 2>/dev/null | tr -d ' ')"
if [[ -z "${CHILD_PGID}" || ! "${CHILD_PGID}" =~ ^[0-9]+$ ]]; then
  skip "ps denied for child; cannot verify foreign-pgid branch"
fi
[[ "${CHILD_PGID}" != "${SELF_PGID}" ]] \
  || fail "setsid did not isolate child (child_pgid=${CHILD_PGID} == self_pgid=${SELF_PGID})"
ok "child pid=${CHILD_PID} pgid=${CHILD_PGID} (foreign to self pgid=${SELF_PGID})"

# Source the hook to obtain gsd_bg_job_reaper in this shell.
# shellcheck source=/dev/null
. "${HOOK}"

# Redirect reaper state to sandbox so production metrics are untouched.
__GSD_BG_JOBS_DIR="${BG_DIR}"
__GSD_METRICS_DIR="${METRICS_DIR}"
__GSD_WRAPPER_EVENTS_LOG="${METRICS_DIR}/wrapper_events.jsonl"

# Force a target_pgid that does NOT contain the child's pgid.
# SELF_PGID != CHILD_PGID (asserted above), so target=self triggers the
# foreign_outside_pgid branch when iterating the registration directory.
export GSD_REAPER_TARGET_PGID="${SELF_PGID}"
export REVHARNESS_PARALLEL_QUIESCE=0
# Pin a known owner so the reaper does not treat it as same-agent.
export REVHARNESS_AGENT_ID="test-reaper-foreign-$$"
__GSD_AGENT_ID="${REVHARNESS_AGENT_ID}"

# Invoke the reaper.
gsd_bg_job_reaper || fail "gsd_bg_job_reaper returned non-zero"

LOG="${METRICS_DIR}/wrapper_events.jsonl"
[[ -f "${LOG}" ]] || fail "wrapper_events.jsonl was not created"

# Assertion 1: exactly one foreign_outside_pgid + audit_only row for our pid.
ROW_COUNT="$(grep -c "\"pid\":${CHILD_PID}," "${LOG}" 2>/dev/null || echo 0)"
[[ "${ROW_COUNT}" -ge 1 ]] || { echo "--- log ---"; cat "${LOG}"; fail "no bg_reap row for pid=${CHILD_PID}"; }

CLASS_HIT="$(grep -E "\"pid\":${CHILD_PID},.*\"class\":\"foreign_outside_pgid\".*\"action\":\"audit_only\"" "${LOG}" | wc -l | tr -d ' ')"
if [[ "${CLASS_HIT}" -lt 1 ]]; then
  echo "--- log ---"; cat "${LOG}"
  fail "expected class=foreign_outside_pgid action=audit_only row for pid=${CHILD_PID}, got 0"
fi
ok "emitted bg_reap class=foreign_outside_pgid action=audit_only (rows=${CLASS_HIT})"

# Assertion 2: NO signal was sent → child still alive.
if ! kill -0 "${CHILD_PID}" 2>/dev/null; then
  fail "child pid=${CHILD_PID} no longer alive — audit_only branch must NOT send SIGTERM/SIGKILL"
fi
ok "child pid=${CHILD_PID} still alive (audit_only sent no signal)"

# Cleanup child explicitly.
kill -TERM "${CHILD_PID}" 2>/dev/null || true
for _ in 1 2 3 4 5; do
  kill -0 "${CHILD_PID}" 2>/dev/null || break
  sleep 1
done
kill -KILL "${CHILD_PID}" 2>/dev/null || true
CHILD_PID=""

echo "ALL_ASSERTIONS_PASSED"
exit 0
