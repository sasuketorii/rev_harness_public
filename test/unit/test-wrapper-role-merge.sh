#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/codex-wrapper.sh"
SHIM_XHIGH="$REPO_ROOT/scripts/codex-wrapper-xhigh.sh"

export REV_HARNESS_METRICS_DISABLE=1

PASS=0
FAIL=0
TMP_FILES=()
OUT=""
ERR=""
ALL=""
RC=0

cleanup() {
  local file
  for file in "${TMP_FILES[@]}"; do
    rm -f "$file"
  done
}
trap cleanup EXIT

new_tmp() {
  local file
  file="$(mktemp)"
  TMP_FILES+=("$file")
  printf '%s\n' "$file"
}

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

record_result() {
  local name="$1"
  local ok="$2"
  local detail="$3"
  if [[ "$ok" -eq 0 ]]; then
    pass "$name"
  else
    fail "$name $detail"
  fi
}

run_cmd() {
  OUT="$(new_tmp)"
  ERR="$(new_tmp)"
  ALL="$(new_tmp)"
  "$@" >"$OUT" 2>"$ERR"
  RC=$?
  cat "$OUT" "$ERR" >"$ALL"
}

has() { grep -F -q -- "$2" "$1"; }
missing() { ! grep -F -q -- "$2" "$1"; }

assert_same_value_silent_merge() {
  local name="wrapper_role_merge::same_value_silent_merge"
  local ok=0 detail=""
  run_cmd bash "$SHIM_XHIGH" --role reviewer --help
  if [[ "$RC" -ne 0 ]]; then
    ok=1
    detail="expected exit 0, got $RC"
  elif ! missing "$ERR" "--role conflict:"; then
    ok=1
    detail="unexpected role conflict in stderr"
  elif ! has "$ALL" "Usage:"; then
    ok=1
    detail="missing Usage: in combined output"
  fi
  record_result "$name" "$ok" "$detail"
}

assert_shim_chain_value_conflict_dies() {
  local name="wrapper_role_merge::shim_chain_value_conflict_dies"
  local ok=0 detail=""
  run_cmd bash "$SHIM_XHIGH" --role coder --help
  if [[ "$RC" -eq 0 ]]; then
    ok=1
    detail="expected non-zero exit"
  elif ! has "$ERR" "--role conflict:"; then
    ok=1
    detail="missing role conflict in stderr"
  elif ! has "$ERR" "shim source: reviewer"; then
    ok=1
    detail="missing shim source reviewer in stderr"
  fi
  record_result "$name" "$ok" "$detail"
}

assert_single_role_direct_canonical() {
  local name="wrapper_role_merge::single_role_direct_canonical"
  local ok=0 detail=""
  run_cmd bash "$WRAPPER" --role reviewer --help
  if [[ "$RC" -ne 0 ]]; then
    ok=1
    detail="expected exit 0, got $RC"
  elif ! has "$OUT" "Usage:"; then
    ok=1
    detail="missing Usage: in stdout"
  fi
  record_result "$name" "$ok" "$detail"
}

assert_user_duplicate_same_value_merges() {
  local name="wrapper_role_merge::user_duplicate_same_value_merges"
  local ok=0 detail=""
  run_cmd bash "$WRAPPER" --role reviewer --role reviewer --help
  if [[ "$RC" -ne 0 ]]; then
    ok=1
    detail="expected exit 0, got $RC"
  elif ! missing "$ERR" "--role conflict:"; then
    ok=1
    detail="unexpected role conflict in stderr"
  fi
  record_result "$name" "$ok" "$detail"
}

assert_user_duplicate_value_conflict_dies_unset_shim() {
  local name="wrapper_role_merge::user_duplicate_value_conflict_dies_unset_shim"
  local ok=0 detail=""
  run_cmd \
    env -u CODEX_WRAPPER_SHIM_ROLE bash "$WRAPPER" --role reviewer --role coder --help
  if [[ "$RC" -eq 0 ]]; then
    ok=1
    detail="expected non-zero exit"
  elif ! has "$ERR" "--role conflict:"; then
    ok=1
    detail="missing role conflict in stderr"
  elif ! has "$ERR" "shim source: unset"; then
    ok=1
    detail="missing shim source unset in stderr"
  fi
  record_result "$name" "$ok" "$detail"
}

assert_shim_env_hint_unset_after_canonical() {
  local name="wrapper_role_merge::shim_env_hint_unset_after_canonical"
  local ok=0 detail=""
  unset CODEX_WRAPPER_SHIM_ROLE
  bash "$SHIM_XHIGH" --role reviewer --help >/dev/null 2>&1
  if [[ -n "${CODEX_WRAPPER_SHIM_ROLE:-}" ]]; then
    ok=1
    detail="CODEX_WRAPPER_SHIM_ROLE leaked into parent shell"
  fi
  record_result "$name" "$ok" "$detail"
}

printf 'wrapper_role_merge::same_value_silent_merge\n'

assert_same_value_silent_merge
assert_shim_chain_value_conflict_dies
assert_single_role_direct_canonical
assert_user_duplicate_same_value_merges
assert_user_duplicate_value_conflict_dies_unset_shim
assert_shim_env_hint_unset_after_canonical

printf 'SUMMARY: pass=%s fail=%s\n' "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
