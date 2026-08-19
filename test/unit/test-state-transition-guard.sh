#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="${REPO_ROOT}/scripts/state-transition-guard.sh"
PASS=0
FAIL=0

sha_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

seed_state() {
  local path="$1"
  local state="$2"
  mkdir -p "$(dirname "$path")"
  jq -n --arg state "$state" \
    '{plan_id:"seed", round:0, state:$state, transitioned_at:"1970-01-01T00:00:00Z", transition_reason:"seed", evidence_paths:{opus:"", codex:""}, sha256:{opus:"", codex:""}}' >"$path"
}

record() {
  local name="$1"
  local status="$2"
  local detail="${3:-}"
  if [[ "$status" == "PASS" ]]; then
    echo "PASS: ${name}"
    PASS=$((PASS+1))
  else
    echo "FAIL: ${name}${detail:+ (${detail})}"
    FAIL=$((FAIL+1))
  fi
}

assert_no_tmp() {
  local dir="$1"
  local found
  found="$(find "$dir" -maxdepth 1 -type f -name '*.tmp.*' -print | head -n 1)"
  [[ -z "$found" ]]
}

run_case() {
  local name="$1"
  local initial="$2"
  local target="$3"
  local expect_rc="$4"
  local expect_forbidden="$5"
  local dir state_file before after out rc got_sha_change

  dir="$(mktemp -d)"
  state_file="${dir}/dual_lgtm_state.json"
  [[ "$initial" == "missing" ]] || seed_state "$state_file" "$initial"
  before=""
  [[ -f "$state_file" ]] && before="$(sha_file "$state_file")"

  out="$(bash "$GUARD" \
    --plan-id unit-plan \
    --round 1 \
    --target-state "$target" \
    --state-file "$state_file" \
    --reason "$name" 2>&1)"
  rc=$?

  if [[ "$rc" -eq "$expect_rc" ]]; then
    if [[ "$expect_forbidden" == "yes" ]] && ! printf '%s\n' "$out" | grep -q 'forbidden transition'; then
      record "$name" "FAIL" "missing forbidden diagnostic"
      /bin/rm -rf "$dir"
      return
    fi
    if ! assert_no_tmp "$(dirname "$state_file")"; then
      record "$name" "FAIL" "temporary file remained"
      /bin/rm -rf "$dir"
      return
    fi
    if [[ "$expect_rc" -eq 0 ]]; then
      after="$(sha_file "$state_file")"
      got_sha_change="no"
      [[ "$before" != "$after" ]] && got_sha_change="yes"
      if [[ "$got_sha_change" != "yes" ]]; then
        record "$name" "FAIL" "sha256 did not change"
        /bin/rm -rf "$dir"
        return
      fi
      if [[ "$(jq -r '.state' "$state_file")" != "$target" ]]; then
        record "$name" "FAIL" "target state was not written"
        /bin/rm -rf "$dir"
        return
      fi
    fi
    record "$name" "PASS"
  else
    record "$name" "FAIL" "expected rc ${expect_rc} got ${rc}: ${out}"
  fi
  /bin/rm -rf "$dir"
}

run_case "pending -> confirmed" "missing" "dual_lgtm_confirmed" 0 "no"
run_case "pending -> blocked" "missing" "dual_lgtm_blocked" 0 "no"
run_case "confirmed -> blocked" "dual_lgtm_confirmed" "dual_lgtm_blocked" 1 "yes"
run_case "confirmed -> pending" "dual_lgtm_confirmed" "dual_lgtm_pending" 1 "yes"
run_case "blocked -> pending" "dual_lgtm_blocked" "dual_lgtm_pending" 0 "no"

echo "---"
echo "Result: ${PASS} passed, ${FAIL} failed"
exit "${FAIL}"
