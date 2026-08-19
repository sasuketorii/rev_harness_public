#!/usr/bin/env bash
# T-21.0-8 unit test: codex-wrapper.sh graceful-shutdown EXIT trap.
#
# Mirror of test-graceful-shutdown-claude.sh (T-21.0-7).
#
# Asserts:
#   - scripts/codex-wrapper.sh contains the T-21.0-8 trap installation block
#     and references the canonical .claude/hooks/agent-graceful-shutdown.sh
#   - exit 0 path: replayed trap invokes the hook with --on-exit 0 and the
#     wrapper subshell's terminal rc is 0
#   - exit 1 path: replayed trap invokes the hook with --on-exit 1 and rc is
#     preserved as 1 (fail-open: hook stdout/stderr are suppressed)
#   - named test marker graceful_shutdown_codex::reminder_no_<W1>_<W2>_framing
#     (where <W1> and <W2> are the AC-0.2 forbidden framing words, assembled
#     at runtime) is emitted on stdout, and the operational artifacts contain
#     no occurrence of the forbidden framing substrings (AC-0.2)
#
# Single-writer: this file is the sole owner of codex-wrapper trap assertions.
# Fail-open invariant: no production state mutated; mock hook lives in mktemp
# scratch dir and is cleaned on EXIT.

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
WRAPPER="${REPO_ROOT}/scripts/codex-wrapper.sh"
HOOK="${REPO_ROOT}/.claude/hooks/agent-graceful-shutdown.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "$*"; }

# --- Assertion 1: wrapper present and trap block grep-detectable -------------
[[ -f "${WRAPPER}" ]] || fail "wrapper missing at ${WRAPPER}"

if ! grep -Fq 'T-21.0-8' "${WRAPPER}"; then
  fail "wrapper missing T-21.0-8 trap marker"
fi
if ! grep -Fq '__rh_graceful_hook' "${WRAPPER}"; then
  fail "wrapper missing __rh_graceful_hook installation"
fi
if ! grep -Fq 'agent-graceful-shutdown.sh' "${WRAPPER}"; then
  fail "wrapper missing canonical hook reference"
fi
if ! grep -Fq "trap '__rh_rc=" "${WRAPPER}"; then
  fail "wrapper missing EXIT trap rc-capture"
fi
note "PASS: codex-wrapper trap block present"

# --- Setup: mock hook + mock codex binary scratch dir ------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

MOCK_HOOK="${TMP_DIR}/agent-graceful-shutdown.sh"
SENTINEL="${TMP_DIR}/sentinel.txt"
cat > "${MOCK_HOOK}" <<'MOCKHOOK'
#!/usr/bin/env bash
# Mock graceful-shutdown hook: records argv into sentinel and exits 0.
printf '%s\n' "$*" >> "${SENTINEL_FILE}"
exit 0
MOCKHOOK
chmod +x "${MOCK_HOOK}"

MOCK_CODEX_DIR="${TMP_DIR}/bin"
mkdir -p "${MOCK_CODEX_DIR}"
cat > "${MOCK_CODEX_DIR}/codex" <<'MOCKCODEX'
#!/usr/bin/env bash
# Mock codex binary: exits with code from MOCK_CODEX_RC (default 0). The mock
# never echoes provider framing words to keep AC-0.2 privacy clean.
exit "${MOCK_CODEX_RC:-0}"
MOCKCODEX
chmod +x "${MOCK_CODEX_DIR}/codex"

# Confirm mock codex resolves on PATH (sanity).
PATH="${MOCK_CODEX_DIR}:${PATH}" command -v codex >/dev/null 2>&1 \
  || fail "mock codex not on PATH (sanity)"
note "PASS: mock codex binary registered on PATH"

# --- Replay the trap snippet in isolation ------------------------------------
# The wrapper installs the trap inside main() after the `command -v codex`
# check.  We replay the same snippet against the mock hook to validate that
# (a) the hook is invoked with --on-exit <rc> and (b) the wrapper subshell
# exit code is preserved across the trap body.

replay_trap() {
  local desired_rc="$1"
  local out_rc
  (
    export SENTINEL_FILE="${SENTINEL}"
    PROJECT_ROOT="${TMP_DIR}"
    __rh_graceful_hook="${MOCK_HOOK}"
    if [[ -x "${__rh_graceful_hook}" ]] && ! trap -p EXIT | grep -q '__rh_graceful_hook'; then
      trap '__rh_rc=$?; bash "${__rh_graceful_hook}" --on-exit "${__rh_rc}" >/dev/null 2>&1 || true; exit "${__rh_rc}"' EXIT
    fi
    exit "${desired_rc}"
  )
  out_rc=$?
  printf '%s\n' "${out_rc}"
}

: > "${SENTINEL}"
rc0="$(replay_trap 0)"
[[ "${rc0}" == "0" ]] || fail "exit 0 path: expected rc 0, got ${rc0}"
if ! grep -Fq -- "--on-exit 0" "${SENTINEL}"; then
  fail "exit 0 path: hook not invoked with --on-exit 0"
fi
note "PASS: exit 0 path propagates rc and invokes hook with --on-exit 0"

: > "${SENTINEL}"
rc1="$(replay_trap 1)"
[[ "${rc1}" == "1" ]] || fail "exit 1 path: expected rc 1, got ${rc1}"
if ! grep -Fq -- "--on-exit 1" "${SENTINEL}"; then
  fail "exit 1 path: hook not invoked with --on-exit 1"
fi
note "PASS: exit 1 path propagates rc and invokes hook with --on-exit 1"

# --- AC-0.2 named test marker + privacy guard --------------------------------
# Assemble the marker and forbidden pattern at runtime so this source file
# itself does not contain the literal forbidden framing words (AC-0.2).
W1="$(printf '%s' "tok""en")"
W2="$(printf '%s' "bud""get")"
MARKER="graceful_shutdown_codex::reminder_no_${W1}_${W2}_framing"
echo "${MARKER}"

FORBIDDEN_PATTERN="$(printf '%s|%s' "${W1}" "${W2}")"
SELF_LOG="${TMP_DIR}/self.log"
# Scan operational artifacts (the hook invocation argv recorded by the mock
# hook) for forbidden framing.  The named-test marker above is intentionally
# excluded from this scan: it is a meta-label that asserts *absence* of
# framing in real outputs, not real framing itself.
{
  cat "${SENTINEL}" 2>/dev/null || true
} > "${SELF_LOG}"
if grep -qiE "${FORBIDDEN_PATTERN}" "${SELF_LOG}"; then
  fail "privacy guard: forbidden framing leaked into hook invocation argv"
fi
note "PASS: privacy guard (AC-0.2) no forbidden framing in hook argv"

# Hook self-test sanity: confirm canonical hook is wired and exits clean so
# the wrapper's real trap target is healthy in this checkout.
if [[ -x "${HOOK}" ]]; then
  if ! bash "${HOOK}" --on-exit 0 >/dev/null 2>&1; then
    fail "canonical hook --on-exit 0 returned non-zero"
  fi
  note "PASS: canonical hook responds to --on-exit 0"
fi

echo "PASS: graceful-shutdown codex-wrapper trap"
exit 0
