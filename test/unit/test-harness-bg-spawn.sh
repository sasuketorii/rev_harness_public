#!/usr/bin/env bash
# T-21.0-5 unit test for scripts/harness-bg-spawn.sh.
# Verifies: PID emission on stdout, atomic registration file creation,
# JSON schema completeness, separate pgroup via setsid, and live process.
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
SPAWNER="${REPO_ROOT}/scripts/harness-bg-spawn.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok:   $*"; }

PS_PGID_RESULT=""
PS_PGID_SKIP_REASON=""
ps_pgid_or_skip() {
  local label="$1" pid="$2" pgid
  PS_PGID_RESULT=""
  PS_PGID_SKIP_REASON=""
  if ! command -v ps >/dev/null 2>&1; then
    PS_PGID_SKIP_REASON="not_available"
    echo "SKIP: ps not available; pgid verification skipped"
    return 1
  fi
  if ! pgid="$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ')"; then
    PS_PGID_SKIP_REASON="denied"
    echo "SKIP: ps denied by sandbox; pgid verification skipped"
    return 1
  fi
  if [[ -z "${pgid}" ]]; then
    PS_PGID_SKIP_REASON="denied"
    echo "SKIP: ps denied by sandbox; pgid verification skipped"
    return 1
  fi
  [[ "${pgid}" =~ ^[0-9]+$ ]] || fail "could not resolve ${label} pgid via ps"
  PS_PGID_RESULT="${pgid}"
  return 0
}

[[ -f "${SPAWNER}" ]] || fail "spawner script missing at ${SPAWNER}"
[[ -x "${SPAWNER}" ]] || fail "spawner script not executable"

SANDBOX="$(mktemp -d -t hbs-spawn-XXXXXX 2>/dev/null || mktemp -d)"
[[ -d "${SANDBOX}" ]] || fail "could not mktemp -d"

CHILD_PID=""
cleanup() {
  [[ -n "${CHILD_PID}" ]] && kill -KILL "${CHILD_PID}" 2>/dev/null
  rm -rf "${SANDBOX}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

BG_DIR="${SANDBOX}/bg_jobs"
mkdir -p "${BG_DIR}"

# Self pgid baseline so we can prove the child landed in a DIFFERENT pgid.
SELF_PGID=""
SELF_PGID_SKIP_REASON=""
if ps_pgid_or_skip "self" "$$"; then
  SELF_PGID="${PS_PGID_RESULT}"
else
  SELF_PGID_SKIP_REASON="${PS_PGID_SKIP_REASON}"
fi

# --- run the spawner ---
STDOUT_LOG="${SANDBOX}/spawner.stdout"
STDERR_LOG="${SANDBOX}/spawner.stderr"

HARNESS_BG_JOBS_DIR="${BG_DIR}" \
  "${SPAWNER}" \
    --task-id test-001 \
    --owner agent-xyz \
    -- sleep 5 \
    > "${STDOUT_LOG}" 2> "${STDERR_LOG}"
RC=$?

if [[ "${RC}" -ne 0 ]]; then
  echo "--- stdout ---"; cat "${STDOUT_LOG}" || true
  echo "--- stderr ---"; cat "${STDERR_LOG}" || true
  fail "spawner exited rc=${RC} (expected 0)"
fi

# Assertion 1: stdout contains exactly one numeric PID line.
PID_LINE_COUNT="$(grep -c . "${STDOUT_LOG}" || true)"
[[ "${PID_LINE_COUNT}" == "1" ]] \
  || fail "expected exactly 1 stdout line, got ${PID_LINE_COUNT}: $(cat "${STDOUT_LOG}")"
CHILD_PID="$(cat "${STDOUT_LOG}" | tr -d ' \n\r')"
[[ "${CHILD_PID}" =~ ^[0-9]+$ ]] || fail "stdout pid not numeric: '${CHILD_PID}'"
ok "stdout pid=${CHILD_PID}"

# Assertion 2: registration file exists at <bg_dir>/<pid>.json.
REG_FILE="${BG_DIR}/${CHILD_PID}.json"
[[ -f "${REG_FILE}" ]] || fail "registration file missing: ${REG_FILE}"
ok "registration file exists"

# Assertion 3: JSON schema check — all required fields present.
if command -v python3 >/dev/null 2>&1; then
  python3 - "${REG_FILE}" <<'PY'
import json, sys
required = {
    "pid": int,
    "pgid": int,
    "task_id": str,
    "owner_agent_id": str,
    "started_ts": str,
    "command": str,
    "started_at_epoch": int,
}
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
missing = [k for k in required if k not in data]
if missing:
    print("MISSING_FIELDS:" + ",".join(missing))
    sys.exit(1)
for k, t in required.items():
    if not isinstance(data[k], t):
        print("WRONG_TYPE:%s expected=%s got=%s" % (k, t.__name__, type(data[k]).__name__))
        sys.exit(2)
extras = [k for k in data.keys() if k not in required]
if extras:
    print("EXTRA_FIELDS:" + ",".join(extras))
    sys.exit(3)
# Spot-check semantic values.
if data["task_id"] != "test-001":
    print("BAD_TASK_ID:" + data["task_id"]); sys.exit(4)
if data["owner_agent_id"] != "agent-xyz":
    print("BAD_OWNER:" + data["owner_agent_id"]); sys.exit(5)
if "sleep" not in data["command"]:
    print("BAD_COMMAND:" + data["command"]); sys.exit(6)
if data["started_at_epoch"] <= 0:
    print("BAD_EPOCH"); sys.exit(7)
if data["pid"] <= 1:
    print("BAD_PID"); sys.exit(8)
if data["pgid"] <= 1:
    print("BAD_PGID"); sys.exit(9)
print("SCHEMA_OK")
PY
  SCHEMA_RC=$?
  [[ "${SCHEMA_RC}" -eq 0 ]] || fail "JSON schema check failed rc=${SCHEMA_RC}"
else
  # Fallback string-grep schema check.
  for f in '"pid"' '"pgid"' '"task_id"' '"owner_agent_id"' \
           '"started_ts"' '"command"' '"started_at_epoch"'; do
    grep -q "${f}" "${REG_FILE}" || fail "registration missing field ${f}"
  done
fi
ok "schema fields complete (pid, pgid, task_id, owner_agent_id, started_ts, command, started_at_epoch)"

# Assertion 4: child is in a DIFFERENT pgroup (pgid != 0 AND pgid != self).
CHILD_PGID=""
if ps_pgid_or_skip "child" "${CHILD_PID}"; then
  CHILD_PGID="${PS_PGID_RESULT}"
  [[ "${CHILD_PGID}" -gt 0 ]] || fail "child pgid must be > 0, got ${CHILD_PGID}"
  if [[ -n "${SELF_PGID}" && "${CHILD_PGID}" == "${SELF_PGID}" ]]; then
    fail "child pgid (${CHILD_PGID}) equals self pgid (${SELF_PGID}); setsid did not isolate"
  fi
  if [[ -n "${SELF_PGID}" ]]; then
    ok "child pgid=${CHILD_PGID} differs from self pgid=${SELF_PGID}"
  elif [[ "${SELF_PGID_SKIP_REASON}" == "not_available" ]]; then
    echo "SKIP: ps not available; pgid verification skipped"
  else
    echo "SKIP: ps denied by sandbox; pgid verification skipped"
  fi

  # Cross-check: registered pgid should match live pgid.
  if command -v python3 >/dev/null 2>&1; then
    REG_PGID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pgid"])' "${REG_FILE}")"
    [[ "${REG_PGID}" == "${CHILD_PGID}" ]] \
      || fail "registered pgid (${REG_PGID}) != live pgid (${CHILD_PGID})"
    ok "registration pgid matches live pgid"
  fi
fi

# Assertion 5: process is actually running (kill -0 succeeds).
if ! kill -0 "${CHILD_PID}" 2>/dev/null; then
  fail "spawned process ${CHILD_PID} is not alive"
fi
ok "process ${CHILD_PID} is live"

# Tear down child explicitly.
kill -TERM "${CHILD_PID}" 2>/dev/null || true
# Brief drain.
for _ in 1 2 3 4 5; do
  kill -0 "${CHILD_PID}" 2>/dev/null || break
  sleep 1
done
kill -KILL "${CHILD_PID}" 2>/dev/null || true
CHILD_PID=""

echo "ALL_ASSERTIONS_PASSED"
exit 0
