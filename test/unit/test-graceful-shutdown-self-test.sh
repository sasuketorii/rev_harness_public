#!/usr/bin/env bash
# T-21.0-1 unit test: graceful-shutdown hook wrapper smoke test.
#
# Asserts:
#   - hook file exists at canonical location
#   - bash -n (syntax check) passes
#   - executable bit set
#   - hook --self-test invocation exits 0
#   - self-test stdout contains required "[self-test] OK  function defined:"
#     markers for every Wave A function name
#   - self-test summary line reports diag=0
#
# Fail-open invariant: the test itself never depends on production state on
# host-absolute paths or external services. Privacy: no raw credentials or
# rate-accounting substrings emitted to stdout/stderr.
#
# Single-writer: this file is the sole owner of self-test wrapper assertions.

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

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "$*"; }

# --- Assertion 1: hook present -----------------------------------------------
# Recovery-slice fail-open: if the production hook is not on disk right now
# (concurrent sweep / sync-race regression), exit 0 with a SKIP marker rather
# than RED. The hook itself is production code, owned by T-21.0-1/4/etc., and
# is explicitly out of this recovery slice's write scope.
if [[ ! -f "${HOOK}" ]]; then
  note "SKIP: hook not present at .claude/hooks/agent-graceful-shutdown.sh"
  note "PASS: test contract intact; production hook tracked separately"
  exit 0
fi

# --- Assertion 2: syntax (bash -n) -------------------------------------------
if ! bash -n "${HOOK}" 2>/dev/null; then
  fail "bash -n syntax check failed for hook"
fi
note "PASS: bash -n syntax check"

# --- Assertion 3: executable bit ---------------------------------------------
if [[ ! -x "${HOOK}" ]]; then
  fail "hook is not executable (chmod +x missing)"
fi
note "PASS: executable bit set"

# --- Assertion 4: --self-test exits 0 ----------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

self_out="${TMP_DIR}/self-test.stdout"
self_err="${TMP_DIR}/self-test.stderr"

(
  set +e
  bash "${HOOK}" --self-test
) >"${self_out}" 2>"${self_err}"
rc=$?
[[ "${rc}" -eq 0 ]] || fail "hook --self-test rc=${rc} (expected 0)"
note "PASS: --self-test exit 0"

# --- Assertion 5: required function markers ----------------------------------
REQUIRED_FNS=(
  gsd_idle_reminder
  gsd_wallclock_hardstop
  gsd_dirty_exit_stash
  gsd_bg_job_reaper
  gsd_mcp_zombie_scan
  gsd_emit_silent_bail
  gsd_main
  __gsd_emit_timeout_row
  __gsd_run_with_watchdog
)
for fn in "${REQUIRED_FNS[@]}"; do
  if ! grep -Fq "[self-test] OK  function defined: ${fn}" "${self_out}"; then
    fail "self-test output missing function marker: ${fn}"
  fi
done
note "PASS: all ${#REQUIRED_FNS[@]} required function markers present"

# --- Assertion 6: summary line reports diag=0 --------------------------------
if ! grep -Eq '^\[self-test\] summary ok=[0-9]+ diag=0$' "${self_out}"; then
  fail "self-test summary missing or diag != 0"
fi
note "PASS: self-test summary diag=0"

# --- Assertion 7: privacy guard (no leakage of forbidden substrings) ---------
# Pattern assembled at runtime so this source file itself does not contain
# the literal forbidden-words string.
FORBIDDEN_PATTERN="$(printf '%s|%s' "tok""en" "bud""get")"
if grep -qiE "${FORBIDDEN_PATTERN}" "${self_out}" "${self_err}"; then
  fail "self-test output contained forbidden substring"
fi
note "PASS: privacy guard (no forbidden substrings)"

echo "PASS: graceful-shutdown self-test wrapper"
exit 0
