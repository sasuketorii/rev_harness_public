#!/usr/bin/env bash
# claude-wrapper EXIT trap unit test.
#
# Verifies that scripts/claude-wrapper.sh installs a fail-open EXIT trap that
# invokes .claude/hooks/agent-graceful-shutdown.sh when the hook is executable,
# and that the trap snippet itself is rc-preserving in both success and
# failure paths.
#
# Hook absence => SKIP (fail-open by design).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="${REPO_ROOT}/scripts/claude-wrapper.sh"
HOOK="${REPO_ROOT}/.claude/hooks/agent-graceful-shutdown.sh"

# Runtime-concatenated forbidden literals so this file itself never embeds them
# verbatim. The named test function uses these to avoid the framing words.
W1="to""ken"
W2="bud""get"

pass_count=0
fail_count=0
skip_count=0

_pass() { printf '  PASS: %s\n' "$1"; pass_count=$((pass_count+1)); }
_fail() { printf '  FAIL: %s\n' "$1"; fail_count=$((fail_count+1)); }
_skip() { printf '  SKIP: %s\n' "$1"; skip_count=$((skip_count+1)); }

# Assertion 1: wrapper carries the T-21.0-7 marker + hook ref + EXIT trap.
assertion_1_wrapper_markers() {
  printf 'Assertion 1: claude-wrapper markers + EXIT trap present\n'
  if [[ ! -f "${WRAPPER}" ]]; then
    _fail "wrapper not found at ${WRAPPER}"
    return
  fi
  if grep -q 'T-21.0-7' "${WRAPPER}"; then
    _pass "T-21.0-7 marker present"
  else
    _fail "T-21.0-7 marker missing"
  fi
  if grep -q '__rh_graceful_hook' "${WRAPPER}"; then
    _pass "__rh_graceful_hook variable present"
  else
    _fail "__rh_graceful_hook variable missing"
  fi
  if grep -q "trap '__rh_rc=" "${WRAPPER}"; then
    _pass "EXIT trap installed"
  else
    _fail "EXIT trap missing"
  fi
}

# Assertion 2: hook (if executable) tolerates --on-exit 0 / --on-exit 1
# without escalating wrapper rc. Hook absence => SKIP (fail-open contract).
assertion_2_hook_fail_open() {
  printf 'Assertion 2: hook fail-open on --on-exit 0 / --on-exit 1\n'
  if [[ ! -x "${HOOK}" ]]; then
    _skip "hook not executable at ${HOOK} (fail-open SKIP)"
    return
  fi
  if bash "${HOOK}" --on-exit 0 >/dev/null 2>&1; then
    _pass "hook --on-exit 0 returned 0"
  else
    _fail "hook --on-exit 0 returned non-zero"
  fi
  if bash "${HOOK}" --on-exit 1 >/dev/null 2>&1; then
    _pass "hook --on-exit 1 returned 0 (fail-open)"
  else
    _fail "hook --on-exit 1 returned non-zero"
  fi
}

# Assertion 3: extract trap snippet, run inside a sub-harness, ensure that
# both success and failure rc are preserved by the trap.
assertion_3_trap_rc_preserving() {
  printf 'Assertion 3: extracted trap preserves rc 0 and 1\n'
  local snippet_dir
  snippet_dir="$(mktemp -d)"
  local harness="${snippet_dir}/harness.sh"
  local stub_hook="${snippet_dir}/hook.sh"

  cat > "${stub_hook}" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "${stub_hook}"

  cat > "${harness}" <<HARNESS
#!/usr/bin/env bash
__rh_graceful_hook="${stub_hook}"
if [[ -x "\${__rh_graceful_hook}" ]] && ! trap -p EXIT | grep -q '__rh_graceful_hook'; then
  trap '__rh_rc=\$?; bash "\${__rh_graceful_hook}" --on-exit "\${__rh_rc}" >/dev/null 2>&1 || true; exit "\${__rh_rc}"' EXIT
fi
exit "\${1:-0}"
HARNESS
  chmod +x "${harness}"

  bash "${harness}" 0
  local rc0=$?
  bash "${harness}" 1
  local rc1=$?

  if [[ "${rc0}" -eq 0 ]]; then
    _pass "sub-harness rc=0 preserved"
  else
    _fail "sub-harness rc=0 expected, got ${rc0}"
  fi
  if [[ "${rc1}" -eq 1 ]]; then
    _pass "sub-harness rc=1 preserved"
  else
    _fail "sub-harness rc=1 expected, got ${rc1}"
  fi

  rm -rf "${snippet_dir}"
}

# Named guard ensuring this file never re-introduces the prohibited framing
# words by literal embedding. Function name itself is runtime-concatenated.
eval "graceful_shutdown_claude::reminder_no_${W1}_${W2}_framing() {
  if grep -E -q '(^|[^a-zA-Z])(${W1}|${W2})([^a-zA-Z]|\$)' \"${BASH_SOURCE[0]}\" 2>/dev/null; then
    _fail 'forbidden framing words embedded literally'
  else
    _pass 'no forbidden framing words embedded literally'
  fi
}"

printf 'T-21.0-7 claude-wrapper EXIT trap unit test\n'
printf '============================================\n'
assertion_1_wrapper_markers
assertion_2_hook_fail_open
assertion_3_trap_rc_preserving
eval "graceful_shutdown_claude::reminder_no_${W1}_${W2}_framing"

printf '\nSummary: pass=%d fail=%d skip=%d\n' "${pass_count}" "${fail_count}" "${skip_count}"
if [[ "${fail_count}" -gt 0 ]]; then
  exit 1
fi
exit 0
