#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  PASS=$((PASS + 1))
}

assert_not_empty() {
  local name="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    pass
  else
    fail "$name"
  fi
}

assert_not_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass
  else
    fail "$name"
  fi
}

assert_contains_either() {
  local name="$1"
  local haystack="$2"
  local needle_a="$3"
  local needle_b="$4"
  if [[ "$haystack" == *"$needle_a"* || "$haystack" == *"$needle_b"* ]]; then
    pass
  else
    fail "$name"
  fi
}

assert_redacted_warning() {
  local name="$1"
  local stderr="$2"
  assert_not_empty "$name emits stderr warning" "$stderr"
  assert_not_contains "$name does not leak /Users path" "$stderr" "/Users/"
  assert_contains_either "$name redacts HOME to tilde" "$stderr" "~/.rev_harness" "~/"
}

readonly_parent="$TMP_ROOT/readonly-parent"
mkdir -p "$readonly_parent"
chmod 500 "$readonly_parent"

# HOME itself is below a read-only parent, so default HOME/.rev_harness creation fails.
blocked_home="$readonly_parent/home"

# shellcheck source=scripts/_shim-log.sh
source "$PROJECT_ROOT/scripts/_shim-log.sh"

export HOME="$blocked_home"
unset REV_HARNESS_SHIM_HITS_LOG

stderr="$(
  shim_log_hit "task-tool" "arg1" "arg2" 2>&1 >/dev/null
)"

assert_redacted_warning "mkdir failure" "$stderr"

write_home="$TMP_ROOT/write-home"
mkdir -p "$write_home/.rev_harness"
chmod 500 "$write_home/.rev_harness"
export HOME="$write_home"

stderr="$(
  shim_log_hit "task-tool" "arg1" "arg2" 2>&1 >/dev/null
)"

assert_redacted_warning "append failure" "$stderr"

if [[ "$FAIL" -ne 0 ]]; then
  fail "unexpected assertion failure count: $FAIL"
fi

printf 'PASS test-shim-log-privacy\n'
exit 0
