#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$PROJECT_ROOT/scripts/rev-harness-model-io-guard.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/user-prompt-submit-rollover.XXXXXX")"

cleanup() {
  /bin/rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file" || fail "missing expected text: $needle"
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    fail "unexpected private content leaked: $needle"
  fi
}

run_hook() {
  local payload="$1"
  local stderr_file="$2"
  local policy="${3:-}"
  local env_args=(
    REV_HARNESS_USER_PROMPT_SUBMIT_EVIDENCE_DIR="$TMP_ROOT/evidence"
    REV_HARNESS_USER_PROMPT_SUBMIT_MAX_TRANSCRIPT_BYTES=120
    REV_HARNESS_USER_PROMPT_SUBMIT_WARN_TRANSCRIPT_BYTES=80
    REV_HARNESS_USER_PROMPT_SUBMIT_MAX_EVENTS=5
    REV_HARNESS_USER_PROMPT_SUBMIT_MAX_TOOL_EVENTS=2
  )
  if [[ -n "$policy" ]]; then
    env_args+=(REV_HARNESS_USER_PROMPT_SUBMIT_POLICY="$policy")
  fi
  printf '%s' "$payload" | env "${env_args[@]}" bash "$GUARD" user-prompt-submit --stdin-json 2>"$stderr_file"
}

write_threshold_exceeded_transcript() {
  local transcript="$1"
  local transcript_secret="$2"
  local tool_args_secret="$3"

  {
    printf '{"role":"user","content":"%s"}\n' "$transcript_secret"
    printf '{"role":"assistant","content":[{"type":"tool_use","input":"%s"}]}\n' "$tool_args_secret"
    printf '{"role":"user","content":"more private transcript text"}\n'
    printf '{"role":"assistant","content":[{"type":"tool_result","content":"private result"}]}\n'
    printf '{"role":"assistant","content":"padding padding padding padding padding padding padding"}\n'
    printf '{"role":"user","content":"line count exceeds"}\n'
  } > "$transcript"
}

assert_threshold_report_metrics_only() {
  local report="$1"
  local status="$2"
  local policy="$3"
  local prompt_secret="$4"
  local transcript_secret="$5"
  local tool_args_secret="$6"

  assert_contains "$report" '"event_rows":6'
  assert_contains "$report" "\"status\":\"$status\""
  assert_contains "$report" '"reason":"threshold_exceeded"'
  assert_contains "$report" "\"policy\":\"$policy\""
  assert_contains "$report" '"tool_calls":1'
  assert_contains "$report" '"tool_results":1'
  assert_not_contains "$report" "$prompt_secret"
  assert_not_contains "$report" "$transcript_secret"
  assert_not_contains "$report" "$tool_args_secret"
}

test_default_warns_with_metrics_only() {
  local transcript="$TMP_ROOT/transcript.jsonl"
  local report="$TMP_ROOT/hook-report.json"
  local transcript_secret="TRANSCRIPT_SENTINEL_DO_NOT_LEAK_20260606"
  local prompt_secret="USER_PROMPT_SENTINEL_DO_NOT_LEAK_20260606"
  local tool_args_secret="HOOK_TOOL_ARGS_SENTINEL_DO_NOT_LEAK_20260606"

  write_threshold_exceeded_transcript "$transcript" "$transcript_secret" "$tool_args_secret"

  local payload
  payload="$(printf '{"prompt":"%s","transcript_path":"%s"}' "$prompt_secret" "$transcript")"
  run_hook "$payload" "$report"
  assert_threshold_report_metrics_only "$report" "warn" "warn" "$prompt_secret" "$transcript_secret" "$tool_args_secret"
}

test_explicit_block_blocks_with_metrics_only() {
  local transcript="$TMP_ROOT/transcript-block.jsonl"
  local report="$TMP_ROOT/hook-block-report.json"
  local transcript_secret="TRANSCRIPT_BLOCK_SENTINEL_DO_NOT_LEAK_20260606"
  local prompt_secret="USER_PROMPT_BLOCK_SENTINEL_DO_NOT_LEAK_20260606"
  local tool_args_secret="HOOK_TOOL_ARGS_BLOCK_SENTINEL_DO_NOT_LEAK_20260606"
  local status=0

  write_threshold_exceeded_transcript "$transcript" "$transcript_secret" "$tool_args_secret"

  local payload
  payload="$(printf '{"prompt":"%s","transcript_path":"%s"}' "$prompt_secret" "$transcript")"
  if run_hook "$payload" "$report" "block"; then
    fail "UserPromptSubmit should block over thresholds when policy=block"
  else
    status=$?
  fi
  [[ "$status" -eq 2 ]] || fail "expected block exit 2, got $status"
  assert_threshold_report_metrics_only "$report" "block" "block" "$prompt_secret" "$transcript_secret" "$tool_args_secret"
}

test_malformed_json_fails_open_without_content() {
  local report="$TMP_ROOT/malformed-report.json"
  printf '{not-json USER_PROMPT_SUBMIT_PRIVATE_TEXT' | bash "$GUARD" user-prompt-submit --stdin-json 2>"$report"
  assert_contains "$report" '"status":"fail_open"'
  assert_contains "$report" 'malformed_hook_json'
  assert_not_contains "$report" 'USER_PROMPT_SUBMIT_PRIVATE_TEXT'
}

test_missing_transcript_passes_open() {
  local report="$TMP_ROOT/missing-transcript-report.json"
  printf '{"prompt":"MISSING_TRANSCRIPT_PROMPT_SECRET"}' | run_hook "$(cat)" "$report"
  assert_contains "$report" '"status":"pass"'
  assert_not_contains "$report" 'MISSING_TRANSCRIPT_PROMPT_SECRET'
}

test_default_warns_with_metrics_only
test_explicit_block_blocks_with_metrics_only
test_malformed_json_fails_open_without_content
test_missing_transcript_passes_open

printf 'PASS: test-user-prompt-submit-rollover\n'
