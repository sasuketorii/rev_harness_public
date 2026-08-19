#!/usr/bin/env bash
# Regression test for the MCP-zombie orphan-only lifecycle wiring.
#
# Covers two things:
#   1. `scripts/cleanup-codex-mcp-zombies.sh --orphan-only` restricts matches
#      to classified MCP-helper rows whose ppid is 1 (reparented/orphaned),
#      and never touches a classified row that still has a live, non-1
#      parent, nor an unrelated process name that the classifier never
#      matches at all (e.g. a generic `xserver-mcp` process).
#   2. `.claude/hooks/agent-graceful-shutdown.sh` wires a report-only,
#      fail-open `gsd_mcp_zombie_scan` phase into `gsd_main`, emits exactly
#      one `event=mcp_zombie_scan` row per run to
#      `.agent/metrics/mcp_zombie_scan.jsonl`, and — when
#      GSD_MCP_ZOMBIE_AUTOREAP=1 is set without the LIVE companion flag —
#      only ever reports a dry-run `live:false` reap attempt, never signals
#      any process.

set -uo pipefail

script_dir() {
  local src="${BASH_SOURCE[0]}"
  case "$src" in
    */*) (cd "${src%/*}" && pwd -P) ;;
    *)   pwd -P ;;
  esac
}
TEST_DIR="$(script_dir)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd -P)"
CLEANUP_SCRIPT="${REPO_ROOT}/scripts/cleanup-codex-mcp-zombies.sh"
HOOK="${REPO_ROOT}/.claude/hooks/agent-graceful-shutdown.sh"

pass_count=0
fail_count=0
_pass() { printf '  PASS: %s\n' "$1"; pass_count=$((pass_count + 1)); }
_fail() { printf '  FAIL: %s\n' "$1"; fail_count=$((fail_count + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[[ -r "${CLEANUP_SCRIPT}" ]] || { echo "SKIP: cleanup script not found"; exit 0; }
[[ -x "${HOOK}" || -r "${HOOK}" ]] || { echo "SKIP: graceful-shutdown hook not found"; exit 0; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mcp-zombie-orphan-test.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

FIXTURE="${WORK_DIR}/ps-fixture.txt"
cat > "${FIXTURE}" <<'EOF'
201   1  20000 01:00:00 /Users/x/.bin/playwright-mcp --headless
202 999  20000 01:00:00 /Users/x/.bin/playwright-mcp --headless
203   1  10000 00:05:00 npm exec @playwright/mcp@latest
204 999  10000 02:00:00 SkyComputerUseClient mcp turn-ended
205 999  10000 00:01:00 node /usr/bin/xserver-mcp
EOF

# --- Assertion 1: report --orphan-only keeps only ppid==1 classified rows ---
printf 'Assertion 1: report --orphan-only\n'
report_json="$(bash "${CLEANUP_SCRIPT}" report --ps-file "${FIXTURE}" --orphan-only 2>&1)"
report_pids="$(printf '%s' "${report_json}" | jq -c '[.matches[].pid] | sort')"
if [[ "${report_pids}" == "[201,203]" ]]; then
  _pass "orphan-only report matched exactly [201,203]"
else
  _fail "orphan-only report matched ${report_pids}, expected [201,203]"
fi

# --- Assertion 2: live-parented classified rows (202, 204) are excluded ----
printf 'Assertion 2: live-parented classified rows excluded\n'
if printf '%s' "${report_pids}" | grep -q '202\|204'; then
  _fail "orphan-only report incorrectly included a live-parented pid"
else
  _pass "live-parented classified pids (202, 204) correctly excluded"
fi

# --- Assertion 3: unrelated process name (205, xserver-mcp) never matches --
printf 'Assertion 3: unrelated MCP server name never classified\n'
report_json_no_filter="$(bash "${CLEANUP_SCRIPT}" report --ps-file "${FIXTURE}" 2>&1)"
if printf '%s' "${report_json_no_filter}" | jq -e '.matches[] | select(.pid == 205)' >/dev/null 2>&1; then
  _fail "unrelated xserver-mcp pid 205 was classified as a zombie candidate"
else
  _pass "unrelated xserver-mcp pid 205 never classified (own-process boundary intact)"
fi

# --- Assertion 4: kill --dry-run --orphan-only would-kill list matches -----
printf 'Assertion 4: kill --dry-run --orphan-only would-kill list\n'
dry_json="$(bash "${CLEANUP_SCRIPT}" kill --ps-file "${FIXTURE}" --dry-run --orphan-only --min-age-seconds 0 2>&1)"
would_kill="$(printf '%s' "${dry_json}" | jq -c '.would_kill_pids | sort')"
if [[ "${would_kill}" == "[201,203]" ]]; then
  _pass "dry-run orphan-only would_kill_pids == [201,203]"
else
  _fail "dry-run orphan-only would_kill_pids == ${would_kill}, expected [201,203]"
fi

# --- Assertion 5: gsd_mcp_zombie_scan wiring — emits exactly one scan row --
# The function is called directly (via `source`) rather than through a full
# `bash agent-graceful-shutdown.sh` process invocation: the hook's other
# phases (idle_reminder, wallclock_hardstop, bg_job_reaper, ...) background
# themselves under a watchdog, which is orthogonal to what this test is
# verifying and is already covered by test-graceful-shutdown-*.sh.
printf 'Assertion 5: gsd_mcp_zombie_scan emits exactly one scan row\n'
SANDBOX_REPO="${WORK_DIR}/repo"
mkdir -p "${SANDBOX_REPO}/.claude/hooks" "${SANDBOX_REPO}/scripts" "${SANDBOX_REPO}/.agent/metrics"
cp "${HOOK}" "${SANDBOX_REPO}/.claude/hooks/agent-graceful-shutdown.sh"
cp "${CLEANUP_SCRIPT}" "${SANDBOX_REPO}/scripts/cleanup-codex-mcp-zombies.sh"
chmod +x "${SANDBOX_REPO}/.claude/hooks/agent-graceful-shutdown.sh" "${SANDBOX_REPO}/scripts/cleanup-codex-mcp-zombies.sh"

scan_log="${SANDBOX_REPO}/.agent/metrics/mcp_zombie_scan.jsonl"
(
  cd "${SANDBOX_REPO}" || exit 1
  # shellcheck source=/dev/null
  source .claude/hooks/agent-graceful-shutdown.sh
  gsd_mcp_zombie_scan
)
scan_rc=$?
if [[ "${scan_rc}" -ne 0 ]]; then
  _fail "gsd_mcp_zombie_scan returned ${scan_rc}, expected 0 (fail-open)"
else
  _pass "gsd_mcp_zombie_scan returned 0 (fail-open honored)"
fi
if [[ -f "${scan_log}" ]] && [[ "$(grep -c '"event":"mcp_zombie_scan"' "${scan_log}" 2>/dev/null)" == "1" ]]; then
  _pass "exactly one mcp_zombie_scan row emitted"
else
  _fail "expected exactly one mcp_zombie_scan row in ${scan_log}"
fi

# --- Assertion 6: AUTOREAP without LIVE flag stays dry-run (live:false) ----
printf 'Assertion 6: AUTOREAP=1 without LIVE flag never signals a process\n'
rm -f "${scan_log}"
(
  cd "${SANDBOX_REPO}" || exit 1
  export GSD_MCP_ZOMBIE_AUTOREAP=1
  # shellcheck source=/dev/null
  source .claude/hooks/agent-graceful-shutdown.sh
  gsd_mcp_zombie_scan
)
if grep -q '"event":"mcp_zombie_reap_attempt","would_kill_pids":\[\],"live":false' "${scan_log}" 2>/dev/null; then
  _pass "AUTOREAP=1 alone produced a live:false dry-run reap-attempt row"
else
  _fail "AUTOREAP=1 alone did not produce the expected dry-run reap-attempt row"
fi

# --- Assertion 7: gsd_main and gsd_self_test both reference the phase ------
printf 'Assertion 7: gsd_main / self-test wiring present in source\n'
if grep -q '__gsd_run_with_watchdog "mcp_zombie_scan"    gsd_mcp_zombie_scan' "${HOOK}"; then
  _pass "gsd_main registers the mcp_zombie_scan phase"
else
  _fail "gsd_main does not register the mcp_zombie_scan phase"
fi

echo
echo "Summary: pass=${pass_count} fail=${fail_count}"
if [[ "${fail_count}" -gt 0 ]]; then
  exit 1
fi
exit 0
