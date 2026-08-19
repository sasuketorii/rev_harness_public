#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d)"
LAST_OUTPUT=""
LAST_RC=0
cleanup() {
  rm -rf "$SANDBOX" || true
}
trap cleanup EXIT
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}
assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label: missing expected text: $needle" ;;
  esac
  return 0
}
assert_exit() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    fail "$label: exit=$actual expected=$expected output=$LAST_OUTPUT"
  fi
  return 0
}
run_checker() {
  set +e
  LAST_OUTPUT="$(cd "$SANDBOX" && bash scripts/ci/check-wrapper-help-parity.sh "$@" 2>&1)"
  LAST_RC=$?
  set -e
}
write_file() {
  local path="$1"
  shift
  printf '%s\n' "$@" >"$path"
}
mkdir -p "$SANDBOX/scripts/ci" "$SANDBOX/test/golden"
cat >"$SANDBOX/scripts/codex-wrapper.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--help" ]]; then
  printf 'Usage: codex-wrapper.sh --help\n'
  printf 'codex stable help text\n'
  exit 0
fi
exit 64
MOCK
cat >"$SANDBOX/scripts/claude-wrapper.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--help" ]]; then
  printf 'Usage: claude-wrapper.sh --help\n'
  printf 'claude live drift text\n'
  exit 0
fi
exit 64
MOCK
write_file "$SANDBOX/test/golden/codex-wrapper-help.txt" \
  "Usage: codex-wrapper.sh --help" \
  "codex stable help text"
write_file "$SANDBOX/test/golden/claude-wrapper-help.txt" \
  "Usage: claude-wrapper.sh --help" \
  "claude golden text"
codex_sha="$(sha256_file "$SANDBOX/test/golden/codex-wrapper-help.txt")"
claude_golden_sha="$(sha256_file "$SANDBOX/test/golden/claude-wrapper-help.txt")"
printf '%s  test/golden/codex-wrapper-help.txt\n' "$codex_sha" >"$SANDBOX/test/golden/codex-wrapper-help.sha256"
printf '%s  test/golden/claude-wrapper-help.txt\n' "$claude_golden_sha" >"$SANDBOX/test/golden/claude-wrapper-help.sha256"
claude_live="$SANDBOX/claude-live.txt"
write_file "$claude_live" \
  "Usage: claude-wrapper.sh --help" \
  "claude live drift text"
claude_live_sha="$(sha256_file "$claude_live")"
cp "$REPO_ROOT/scripts/ci/check-wrapper-help-parity.sh" "$SANDBOX/scripts/ci/"
run_checker --wrapper codex
assert_exit "Scenario A --wrapper codex" 0 "$LAST_RC"
assert_contains "Scenario A output" "$LAST_OUTPUT" "PASS: codex help matches golden"
run_checker --wrapper claude
assert_exit "Scenario B --wrapper claude" 1 "$LAST_RC"
assert_contains "Scenario B output" "$LAST_OUTPUT" "FAIL: claude help drifted"
assert_contains "Scenario B live sha" "$LAST_OUTPUT" "$claude_live_sha"
assert_contains "Scenario B golden sha" "$LAST_OUTPUT" "$claude_golden_sha"
run_checker --wrapper both
assert_exit "Scenario C --wrapper both" 1 "$LAST_RC"
assert_contains "Scenario C output" "$LAST_OUTPUT" "DRIFT: 1/2 wrappers drifted"
run_checker --help
assert_exit "Scenario D --help" 0 "$LAST_RC"
assert_contains "Scenario D output" "$LAST_OUTPUT" "Usage: scripts/ci/check-wrapper-help-parity.sh"
printf 'OK: test-wrapper-help-parity.sh\n'
exit 0
