#!/usr/bin/env bash
set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL: %s\n' "$1"
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label"
    printf '  expected: %s\n  actual:   %s\n' "$expected" "$actual"
  fi
}

sha256_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

readlink_f() {
  if readlink -f "$1" >/dev/null 2>&1; then
    readlink -f "$1"
  else
    perl -MCwd=abs_path -e 'print abs_path(shift), "\n"' "$1"
  fi
}

write_state_json() {
  local target_root="$1"
  local state_dir="$target_root/.rev-harness-state"
  mkdir -p "$state_dir"
  jq -nc \
    --arg schema "rev-harness-state/v1" \
    --arg run_id "test-run" \
    --arg ts "2026-05-26T00:00:00Z" \
    '{
      schema: $schema,
      run_id: $run_id,
      phase: "init",
      current_phase: "init",
      phases: {
        init: {status:"ok", exit_code:0, started_at:$ts, ended_at:$ts, input_sha256:null}
      },
      history: [],
      last_install_at: $ts,
      last_updated: $ts,
      started_at: $ts
    }' > "$state_dir/state.json"
}

create_legacy_symlinks() {
  local target_root="$1"
  mkdir -p "$target_root/.shared" "$target_root/.agent/registry"
  ln -s "../.rev-harness-state/state.json" "$target_root/.shared/rev-harness-adopter-setup.state.json"
  ln -s "../../.rev-harness-state/state.json" "$target_root/.agent/registry/rev_harness_adoption_state.json"
}

TARGET_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/revharness-state.XXXXXX")"
trap '/bin/rm -rf "$TARGET_ROOT"' EXIT

write_state_json "$TARGET_ROOT"
create_legacy_symlinks "$TARGET_ROOT"

CANONICAL="$TARGET_ROOT/.rev-harness-state/state.json"
LEGACY_SHARED="$TARGET_ROOT/.shared/rev-harness-adopter-setup.state.json"
LEGACY_REGISTRY="$TARGET_ROOT/.agent/registry/rev_harness_adoption_state.json"

canonical_hash="$(sha256_digest "$CANONICAL")"
shared_hash="$(sha256_digest "$(readlink_f "$LEGACY_SHARED")")"
registry_hash="$(sha256_digest "$(readlink_f "$LEGACY_REGISTRY")")"

assert_eq "$canonical_hash" "$shared_hash" "canonical sha256 equals .shared legacy dereference"
assert_eq "$canonical_hash" "$registry_hash" "canonical sha256 equals registry legacy dereference"

phase_pair="$(jq -r '[.phase, .current_phase] | @tsv' "$CANONICAL")"
assert_eq "init	init" "$phase_pair" "phase mirrors current_phase"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf 'FAIL count=%s PASS count=%s\n' "$FAIL_COUNT" "$PASS_COUNT"
  exit 1
fi

printf 'PASS count=%s FAIL count=%s\n' "$PASS_COUNT" "$FAIL_COUNT"
