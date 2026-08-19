#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$PROJECT_ROOT/scripts/rev-harness-model-io-guard.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/model-io-guard-test.XXXXXX")"
SAFE_Q_REL=".claude/tmp/call-invoke-guard/unit-test-quarantine-$$"
SAFE_Q="$PROJECT_ROOT/$SAFE_Q_REL"

cleanup() {
  /bin/rm -rf "$TMP_ROOT"
  /bin/rm -rf "$SAFE_Q"
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

test_prompt_budget_blocks_without_prompt_text() {
  local prompt="$TMP_ROOT/prompt.txt"
  local report="$TMP_ROOT/prompt-report.json"
  local prompt_secret="PROMPT_SENTINEL_DO_NOT_LEAK_20260606"

  printf '%s\n' "$prompt_secret" > "$prompt"
  if bash "$GUARD" prompt-budget --file "$prompt" --label "unit:prompt" --max-bytes 4 --warn-bytes 2 2>"$report"; then
    fail "prompt budget should block"
  fi

  assert_contains "$report" '"event":"prompt_budget"'
  assert_contains "$report" '"status":"block"'
  assert_not_contains "$report" "$prompt_secret"
}

test_scan_output_blocks_marker_ids_only() {
  local raw="$TMP_ROOT/raw-output.md"
  local report="$TMP_ROOT/scan-report.json"
  local quarantine="$SAFE_Q"
  local raw_secret="RAW_MODEL_OUTPUT_SENTINEL_DO_NOT_LEAK_20260606"
  local tool_args_secret="TOOL_ARGS_SENTINEL_DO_NOT_LEAK_20260606"

  {
    printf 'normal prose before marker\n'
    printf 'call <invoke name="unsafe"><parameter name="args">%s</parameter></invoke>\n' "$tool_args_secret"
    printf '<tool_use name="danger">%s</tool_use>\n' "$raw_secret"
    printf '{"type":"tool_result","content":"%s"}\n' "$raw_secret"
    printf '<subagent_notification>\n'
    printf '{"trigger_turn":1,"other_recipients":["x"]}\n'
    printf '```json\n{"type":"tool_use","input":"%s"}\n```\n' "$tool_args_secret"
  } > "$raw"

  if bash "$GUARD" scan-output --file "$raw" --label "unit:scan" --quarantine-dir "$quarantine" 2>"$report"; then
    fail "scan-output should block marker output"
  fi

  assert_contains "$report" '"event":"scan_output"'
  assert_contains "$report" '"status":"block"'
  assert_contains "$report" 'transport_xml_call_invoke'
  assert_contains "$report" 'transport_malformed_invoke_block'
  assert_contains "$report" 'transport_xml_tool_call'
  assert_contains "$report" 'transport_json_tool_call'
  assert_contains "$report" 'transport_json_tool_result'
  assert_contains "$report" 'transport_code_fence_tool_payload'
  assert_contains "$report" 'transport_unknown_tool_marker'
  assert_contains "$report" '"sha256"'
  assert_not_contains "$report" '"artifact_id"'
  assert_not_contains "$report" '"artifact_ref"'
  assert_not_contains "$report" '"quarantine_file"'
  assert_not_contains "$report" "$PROJECT_ROOT"
  assert_not_contains "$report" "$TMP_ROOT"
  assert_not_contains "$report" "$(basename "$raw")"
  assert_not_contains "$report" "$raw_secret"
  assert_not_contains "$report" "$tool_args_secret"
  [[ "$(find "$quarantine" -type f | wc -l | tr -d '[:space:]')" -ge 1 ]] || fail "expected quarantine file"
}

test_external_quarantine_dir_rejected_without_content() {
  local raw="$TMP_ROOT/external-raw.md"
  local report="$TMP_ROOT/external-report.json"
  local raw_secret="EXTERNAL_QUARANTINE_RAW_SENTINEL_DO_NOT_LEAK"

  printf '<tool_use name="x">%s</tool_use>\n' "$raw_secret" > "$raw"
  if bash "$GUARD" scan-output --file "$raw" --label "unit:external" --quarantine-dir "$TMP_ROOT/external-q" 2>"$report"; then
    fail "external quarantine dir should be rejected"
  fi

  assert_contains "$report" '"reason":"unsafe_quarantine_dir"'
  assert_not_contains "$report" "$raw_secret"
  assert_not_contains "$report" "$TMP_ROOT"
}

test_scan_output_allows_domain_json() {
  local raw="$TMP_ROOT/domain.json"
  local report="$TMP_ROOT/domain-report.json"
  local quarantine="$SAFE_Q/domain"

  printf '{"domain":"ordinary","items":[{"name":"tooling","result":true}]}\n' > "$raw"
  bash "$GUARD" scan-output --file "$raw" --label "unit:domain" --quarantine-dir "$quarantine" 2>"$report"
  assert_contains "$report" '"status":"pass"'
}

test_self_test() {
  bash "$GUARD" --self-test >/dev/null
}

test_reviewer_no_double_quarantine_stub_path() {
  local raw="$TMP_ROOT/reviewer-raw.md"
  local output="$TMP_ROOT/reviewer-output.md"
  local raw_secret="REVIEWER_DOUBLE_QUARANTINE_SENTINEL_DO_NOT_LEAK"

  log_warn() { :; }
  log_error() { :; }
  REPO_ROOT="$PROJECT_ROOT" REV_HARNESS_MODEL_IO_GUARD="$GUARD" source "$PROJECT_ROOT/.claude/commands/lib/reviewer.sh"

  printf '<tool_use name="reviewer">%s</tool_use>\n' "$raw_secret" > "$raw"
  _reviewer_quarantine_raw_stdout "$raw" "$output" "reviewer unsafe output"

  [[ ! -e "$output.quarantine.raw" ]] || fail "reviewer created second raw quarantine"
  [[ ! -e "$raw" ]] || fail "reviewer raw stdout should be removed after sanitized stub"
  assert_contains "$output" 'reviewer unsafe output'
  assert_not_contains "$output" '.quarantine.raw'
  assert_not_contains "$output" "$raw_secret"
  assert_not_contains "$output" "$TMP_ROOT"
}

test_coder_nonzero_output_is_scanned_and_sanitized() {
  local fake_repo="$TMP_ROOT/fake-repo"
  local plan="$fake_repo/plan.md"
  local output="$TMP_ROOT/coder-output.md"
  local raw_secret="CODER_NONZERO_RAW_SENTINEL_DO_NOT_LEAK"

  mkdir -p "$fake_repo/scripts"
  /bin/cp "$GUARD" "$fake_repo/scripts/rev-harness-model-io-guard.sh"
  chmod +x "$fake_repo/scripts/rev-harness-model-io-guard.sh"
  cat > "$fake_repo/scripts/codex-wrapper.sh" <<EOF
#!/usr/bin/env bash
printf '<tool_use name="coder">%s</tool_use>\\n' "$raw_secret"
exit 42
EOF
  chmod +x "$fake_repo/scripts/codex-wrapper.sh"
  printf 'simple plan\n' > "$plan"

  log_warn() { :; }
  log_info() { :; }
  log_error() { :; }
  die() { printf '%s\n' "$*" >&2; return 1; }
  create_temp_file() { mktemp "${TMPDIR:-/tmp}/coder-nonzero.XXXXXX"; }
  get_latest_codex_session() { :; }

  REPO_ROOT="$fake_repo" REV_HARNESS_MODEL_IO_GUARD="$fake_repo/scripts/rev-harness-model-io-guard.sh" source "$PROJECT_ROOT/.claude/commands/lib/coder.sh"
  if _coder_run_codex_prompt "$plan" "prompt" "$output"; then
    fail "non-zero wrapper should fail"
  fi

  assert_contains "$output" 'model I/O guard blocked unsafe output'
  assert_not_contains "$output" "$raw_secret"
  assert_not_contains "$output" '<tool_use'
}

test_session_nonzero_output_is_scanned_and_sanitized() {
  local fake_repo="$TMP_ROOT/fake-session-repo"
  local output="$TMP_ROOT/session-output.md"
  local raw_secret="SESSION_NONZERO_RAW_SENTINEL_DO_NOT_LEAK"

  mkdir -p "$fake_repo/scripts"
  /bin/cp "$GUARD" "$fake_repo/scripts/rev-harness-model-io-guard.sh"
  chmod +x "$fake_repo/scripts/rev-harness-model-io-guard.sh"
  cat > "$fake_repo/scripts/claude-wrapper.sh" <<EOF
#!/usr/bin/env bash
output=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --output) output="\${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
printf '<tool_use name="session">%s</tool_use>\\n' "$raw_secret" > "\$output"
exit 42
EOF
  chmod +x "$fake_repo/scripts/claude-wrapper.sh"

  log_warn() { :; }
  log_info() { :; }
  log_error() { :; }
  die() { printf '%s\n' "$*" >&2; return 1; }
  create_temp_file() { mktemp "${TMPDIR:-/tmp}/session-nonzero.XXXXXX"; }

  REPO_ROOT="$fake_repo" REV_HARNESS_MODEL_IO_GUARD="$fake_repo/scripts/rev-harness-model-io-guard.sh" source "$PROJECT_ROOT/.claude/commands/lib/session.sh"
  if _session_run_claude_wrapper "unit_session" "prompt" "output" "failed" "5" "prompt text" "$output"; then
    fail "non-zero claude wrapper should fail"
  fi

  assert_contains "$output" 'model I/O guard blocked unsafe output'
  assert_not_contains "$output" "$raw_secret"
  assert_not_contains "$output" '<tool_use'
}

test_prompt_budget_blocks_without_prompt_text
test_scan_output_blocks_marker_ids_only
test_external_quarantine_dir_rejected_without_content
test_scan_output_allows_domain_json
test_self_test
test_reviewer_no_double_quarantine_stub_path
test_coder_nonzero_output_is_scanned_and_sanitized
test_session_nonzero_output_is_scanned_and_sanitized

printf 'PASS: test-model-io-guard\n'
