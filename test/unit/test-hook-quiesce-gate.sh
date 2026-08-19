#!/usr/bin/env bash
# Function-body PARALLEL_QUIESCE gate regression test.
#
# Verifies that when REVHARNESS_PARALLEL_QUIESCE=1 is set, *every* public
# gsd_* function returns 0 with zero side effects, even when invoked via
# `source` instead of the dispatch case (an earlier incident's recursion
# root cause: hook re-entered through wrapper EXIT trap bypassed the
# dispatch-level gate).
#
# Also verifies the inverse: with the env var unset/0, side effects DO
# occur for at least one function (proves the gate is not stuck-closed).
#
# Fail-open contract: a single failed assertion sets rc=1 at exit; we
# never `set -e` so all assertions run and produce a complete diag.

set -u
set -o pipefail 2>/dev/null || true

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${THIS_DIR}/../.." && pwd -P)"
HOOK="${REPO_ROOT}/.claude/hooks/agent-graceful-shutdown.sh"

[[ -r "${HOOK}" ]] || { echo "FAIL: hook not readable at ${HOOK}" >&2; exit 1; }

# Isolated scratch sandbox: redirect __GSD_METRICS_DIR + __GSD_BG_JOBS_DIR
# into a tempdir so the real repo metrics are not polluted by this test.
SCRATCH="$(mktemp -d -t quiesce-tb1-XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "${SCRATCH}" 2>/dev/null || true' EXIT

PASS=0
FAIL=0
DIAG=()

assert_eq() {
  local name="$1" expect="$2" actual="$3"
  if [[ "${expect}" == "${actual}" ]]; then
    PASS=$(( PASS + 1 ))
    echo "  OK   ${name}  (= ${expect})"
  else
    FAIL=$(( FAIL + 1 ))
    DIAG+=("FAIL ${name}: expected=${expect} actual=${actual}")
    echo "  FAIL ${name}  expected=${expect} actual=${actual}" >&2
  fi
}

assert_file_unchanged() {
  local name="$1" path="$2" baseline_lines="$3"
  local now_lines
  if [[ -r "${path}" ]]; then
    now_lines="$(wc -l < "${path}" 2>/dev/null | tr -d ' ')"
  else
    now_lines=0
  fi
  assert_eq "${name}" "${baseline_lines}" "${now_lines}"
}

# ---------------------------------------------------------------------
# Phase 1: QUIESCE=1 — every public gsd_* function MUST be a no-op
# ---------------------------------------------------------------------
echo "[phase 1] REVHARNESS_PARALLEL_QUIESCE=1 — expect zero side effects"

(
  set +e
  export REVHARNESS_PARALLEL_QUIESCE=1
  # Force agent start ts to be deep in the past so wallclock_hardstop and
  # idle_reminder would normally trigger their side effects.
  export REVHARNESS_AGENT_START_TS=1
  export GSD_HARDSTOP_SECONDS=1
  export GSD_IDLE_REMINDER_SECONDS=1
  export REVHARNESS_TASK_ID="tb1-quiesce-test"

  # Redirect side-effect destinations into the scratch sandbox by
  # overriding the resolved repo paths inside the sourced hook. The hook
  # computes __GSD_METRICS_DIR from BASH_SOURCE, so source first, then
  # rebind the globals before any function is called.
  # shellcheck disable=SC1090
  source "${HOOK}"
  __GSD_METRICS_DIR="${SCRATCH}/metrics"
  __GSD_TIMEOUT_LOG="${__GSD_METRICS_DIR}/hook_timeout.jsonl"
  __GSD_WRAPPER_EVENTS_LOG="${__GSD_METRICS_DIR}/wrapper_events.jsonl"
  __GSD_BG_JOBS_DIR="${SCRATCH}/bg_jobs"
  mkdir -p "${__GSD_METRICS_DIR}" "${__GSD_BG_JOBS_DIR}"

  # Baseline: nothing in metrics dir, count git-stash entries.
  STASH_BASELINE="$(git -C "${REPO_ROOT}" stash list 2>/dev/null | wc -l | tr -d ' ')"

  # 1a: gsd_dirty_exit_stash — must NOT create a stash.
  rc=0; gsd_dirty_exit_stash; rc=$?
  assert_eq "dirty_exit_stash exit=0" "0" "${rc}"
  STASH_NOW="$(git -C "${REPO_ROOT}" stash list 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "dirty_exit_stash zero new stashes" "${STASH_BASELINE}" "${STASH_NOW}"

  # 1b: gsd_bg_job_reaper — must NOT append to wrapper_events.jsonl.
  rc=0; gsd_bg_job_reaper; rc=$?
  assert_eq "bg_job_reaper exit=0" "0" "${rc}"
  assert_file_unchanged "bg_job_reaper wrapper_events absent" "${__GSD_WRAPPER_EVENTS_LOG}" "0"

  # 1c: gsd_emit_silent_bail — must NOT append to silent_bail.jsonl.
  rc=0; gsd_emit_silent_bail; rc=$?
  assert_eq "emit_silent_bail exit=0" "0" "${rc}"
  assert_file_unchanged "emit_silent_bail jsonl absent" "${__GSD_METRICS_DIR}/silent_bail.jsonl" "0"

  # 1d: gsd_idle_reminder — must NOT write rate-limit marker / no stderr.
  REMINDER_STDERR="$(gsd_idle_reminder 2>&1 1>/dev/null || true)"
  assert_eq "idle_reminder no stderr emit" "" "${REMINDER_STDERR}"

  # 1e: gsd_wallclock_hardstop — must NOT emit timeout row, return 0.
  #     We invoke in a subshell because the non-gated path calls `exit 0`
  #     which would terminate this test. Under the gate it must return.
  ( gsd_wallclock_hardstop ); rc=$?
  assert_eq "wallclock_hardstop exit=0" "0" "${rc}"
  assert_file_unchanged "wallclock_hardstop timeout_log absent" "${__GSD_TIMEOUT_LOG}" "0"

  # 1f: gsd_main aggregator gate — defense in depth.
  rc=0; gsd_main; rc=$?
  assert_eq "gsd_main exit=0 under quiesce" "0" "${rc}"
  assert_file_unchanged "gsd_main wrapper_events still absent" "${__GSD_WRAPPER_EVENTS_LOG}" "0"
  assert_file_unchanged "gsd_main timeout_log still absent" "${__GSD_TIMEOUT_LOG}" "0"
  STASH_NOW2="$(git -C "${REPO_ROOT}" stash list 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "gsd_main zero new stashes" "${STASH_BASELINE}" "${STASH_NOW2}"

  # ---------------------------------------------------------------
  # 1g: Recursion-regression test — simulate wrapper EXIT-trap path.
  # Earlier incident: hook re-entered via wrapper EXIT trap directly
  # (bypassing dispatch case `*)` gate). We now re-source the hook
  # to mimic the trap-time fresh-shell invocation and re-call
  # gsd_main; the function-body gates must still hold.
  # ---------------------------------------------------------------
  # shellcheck disable=SC1090
  source "${HOOK}"
  __GSD_METRICS_DIR="${SCRATCH}/metrics"
  __GSD_TIMEOUT_LOG="${__GSD_METRICS_DIR}/hook_timeout.jsonl"
  __GSD_WRAPPER_EVENTS_LOG="${__GSD_METRICS_DIR}/wrapper_events.jsonl"
  __GSD_BG_JOBS_DIR="${SCRATCH}/bg_jobs"
  rc=0; gsd_main; rc=$?
  assert_eq "gsd_main exit=0 after re-source (recursion regression)" "0" "${rc}"
  STASH_NOW3="$(git -C "${REPO_ROOT}" stash list 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "recursion regression zero new stashes" "${STASH_BASELINE}" "${STASH_NOW3}"

  # Propagate counters out of subshell via files.
  printf '%d\n' "${PASS}" > "${SCRATCH}/phase1_pass"
  printf '%d\n' "${FAIL}" > "${SCRATCH}/phase1_fail"
)

P1_PASS="$(cat "${SCRATCH}/phase1_pass" 2>/dev/null || echo 0)"
P1_FAIL="$(cat "${SCRATCH}/phase1_fail" 2>/dev/null || echo 0)"
PASS=$(( PASS + P1_PASS ))
FAIL=$(( FAIL + P1_FAIL ))

# ---------------------------------------------------------------------
# Phase 2: QUIESCE unset — at least one function MUST produce side effect
# (proves the gate is not stuck-closed in the implementation).
# We exercise gsd_emit_silent_bail because it has no destructive
# side effects (no git stash) — it only writes one JSONL row.
# ---------------------------------------------------------------------
echo "[phase 2] REVHARNESS_PARALLEL_QUIESCE unset — expect emit_silent_bail row"

(
  set +e
  unset REVHARNESS_PARALLEL_QUIESCE
  export REVHARNESS_TASK_ID="tb1-quiesce-test"
  export REVHARNESS_AGENT_FAMILY="unknown"

  # shellcheck disable=SC1090
  source "${HOOK}"
  __GSD_METRICS_DIR="${SCRATCH}/metrics_p2"
  __GSD_TIMEOUT_LOG="${__GSD_METRICS_DIR}/hook_timeout.jsonl"
  __GSD_WRAPPER_EVENTS_LOG="${__GSD_METRICS_DIR}/wrapper_events.jsonl"
  __GSD_BG_JOBS_DIR="${SCRATCH}/bg_jobs_p2"
  mkdir -p "${__GSD_METRICS_DIR}" "${__GSD_BG_JOBS_DIR}"

  rc=0; gsd_emit_silent_bail; rc=$?
  assert_eq "ungated emit_silent_bail exit=0" "0" "${rc}"
  if [[ -s "${__GSD_METRICS_DIR}/silent_bail.jsonl" ]]; then
    PASS=$(( PASS + 1 ))
    echo "  OK   ungated emit_silent_bail wrote a row"
  else
    FAIL=$(( FAIL + 1 ))
    echo "  FAIL ungated emit_silent_bail did not write a row — gate may be stuck-closed" >&2
  fi

  # Also verify QUIESCE=0 (explicit, not just unset) behaves like unset.
  rm -f "${__GSD_METRICS_DIR}/silent_bail.jsonl"
  export REVHARNESS_PARALLEL_QUIESCE=0
  rc=0; gsd_emit_silent_bail; rc=$?
  assert_eq "QUIESCE=0 emit_silent_bail exit=0" "0" "${rc}"
  if [[ -s "${__GSD_METRICS_DIR}/silent_bail.jsonl" ]]; then
    PASS=$(( PASS + 1 ))
    echo "  OK   QUIESCE=0 emit_silent_bail wrote a row"
  else
    FAIL=$(( FAIL + 1 ))
    echo "  FAIL QUIESCE=0 emit_silent_bail did not write — gate too aggressive" >&2
  fi

  printf '%d\n' "${PASS}" > "${SCRATCH}/phase2_pass"
  printf '%d\n' "${FAIL}" > "${SCRATCH}/phase2_fail"
)

P2_PASS="$(cat "${SCRATCH}/phase2_pass" 2>/dev/null || echo 0)"
P2_FAIL="$(cat "${SCRATCH}/phase2_fail" 2>/dev/null || echo 0)"
PASS=$(( PASS + P2_PASS ))
FAIL=$(( FAIL + P2_FAIL ))

echo
echo "[summary] pass=${PASS} fail=${FAIL}"
if (( FAIL > 0 )); then
  echo "DIAG:"
  for d in "${DIAG[@]:-}"; do
    echo "  - ${d}"
  done
  exit 1
fi
exit 0
