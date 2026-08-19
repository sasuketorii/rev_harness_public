#!/usr/bin/env bash
# project_id / state-contraction integration test.
#
# Semantic-free core kernel only (see docs/architecture/why-no-semantic-index.md);
# there is no semantic-mcp project-id resolver or launcher in this harness, so
# this test only covers the load-bearing kernel:
#   - the core .claude/settings.json autostart-clean regression guard,
#   - init-project project_id bootstrap (idempotent, non-forbidden id),
#   - reviewer state-contraction (no durable reviews/fixes/session payload in state).
#
# Note on core semantic-mcp autostart (invariant I-13): Core `.claude/settings.json`
# deliberately does not carry an `mcpServers["semantic-mcp"]` autostart entry;
# the semantic layer is an opt-in addon configured elsewhere (per-machine
# `.mcp.json` / explicit addon
# install), not a core default. `test_settings_no_semantic_autostart` below is
# a regression guard asserting the core default settings stay autostart-clean.
# It asserts ABSENCE from the core default settings only — it does NOT forbid
# the semantic addon from ever being configured opt-in.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="$REPO_ROOT/.claude/commands/lib"
INIT_PROJECT="$REPO_ROOT/scripts/init-project.sh"
SETTINGS_FILE="$REPO_ROOT/.claude/settings.json"
TEST_PROMPT_DIR=""
TEST_CODER_OUTPUT=""
TEST_TMPDIR=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
}

test_settings_no_semantic_autostart() {
  # Demotion guard (invariant I-13): core .claude/settings.json must NOT
  # autostart semantic-mcp. The semantic layer is opt-in (configured elsewhere),
  # so the core default settings stay autostart-clean. This guards against a
  # regression that re-adds a semantic-mcp autostart entry to core defaults.
  if jq -e '.mcpServers["semantic-mcp"] // empty' "$SETTINGS_FILE" >/dev/null 2>&1; then
    fail "core .claude/settings.json must not autostart semantic-mcp (invariant I-13); found mcpServers[\"semantic-mcp\"] entry"
  fi
}

test_init_project_bootstrap() {
  local tmprepo="$1/init"
  mkdir -p "$tmprepo/scripts"

  cp "$INIT_PROJECT" "$tmprepo/scripts/init-project.sh"
  cp "$REPO_ROOT/scripts/project-id.sh" "$tmprepo/scripts/project-id.sh"
  chmod +x "$tmprepo/scripts/init-project.sh" "$tmprepo/scripts/project-id.sh"

  bash "$tmprepo/scripts/init-project.sh" init-demo >/dev/null

  [[ -f "$tmprepo/.shared/project_id" ]] || fail "init-project did not create .shared/project_id"
  local first_id=""
  first_id="$(tr -d '\r\n' < "$tmprepo/.shared/project_id")"
  [[ "$first_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || fail "init-project created invalid project_id: $first_id"
  [[ "$first_id" != "agent_base" ]] || fail "init-project created forbidden literal project_id"

  printf 'preexisting-fixed-id\n' > "$tmprepo/.shared/project_id"
  bash "$tmprepo/scripts/init-project.sh" other-seed >/dev/null
  [[ "$(tr -d '\r\n' < "$tmprepo/.shared/project_id")" == "preexisting-fixed-id" ]] || fail "init-project overwrote existing project_id"
}

test_reviewer_state_contraction() {
  local tmpdir="$1/reviewer"
  local state_dir="$tmpdir/state"
  local prompt_dir="$tmpdir/prompts"
  local output_dir="$tmpdir/out"
  local coder_output="$tmpdir/coder_output.md"
  local reviews_file="$tmpdir/reviews.md"
  local state_file=""

  mkdir -p "$state_dir" "$prompt_dir" "$output_dir"
  printf '# reviewer prompt\n' > "$prompt_dir/reviewer_safety.md"
  printf 'coder output\n' > "$coder_output"
  printf '# aggregated reviews\n' > "$reviews_file"
  TEST_PROMPT_DIR="$prompt_dir"
  TEST_CODER_OUTPUT="$coder_output"

  # shellcheck source=/dev/null
  source "$LIB_DIR/utils.sh"
  # shellcheck source=/dev/null
  source "$LIB_DIR/state.sh"
  # shellcheck source=/dev/null
  source "$LIB_DIR/reviewer.sh"

  state_file="$(state_init "$tmpdir/plan.md" "reviewer_state_contraction" "$state_dir")"
  state_load "$state_file"
  state_upsert_phase "impl" "2"

  _ensure_codex_wrapper() { return 0; }
  _get_prompt_dir() { printf '%s\n' "$TEST_PROMPT_DIR"; }
  _reviewer_build_out_of_window_dependency_alert() { printf '%s\n' ""; }
  _reviewer_build_packet() { printf '%s\n' "$TEST_CODER_OUTPUT"; }
  reviewer_run_single() {
    local _reviewer_name="$1"
    local _coder_output="$2"
    local output_file="$3"
    local _timeout_secs="${4:-}"
    printf 'review ok\n' > "$output_file"
  }

  reviewer_run_parallel "safety" "$coder_output" "$output_dir" 5 "impl" "$state_dir" "impl" || fail "reviewer_run_parallel failed after reviewer session APIs were removed"
  reviewer_record_to_state "impl" "1" "$reviews_file" || fail "reviewer_record_to_state should no-op successfully"

  jq -e '.phases | length == 1 and .[0].name == "impl"' "$state_file" >/dev/null || fail "state phase setup mismatch"
  if jq -e '.phases[] | has("reviews") or has("fixes")' "$state_file" >/dev/null; then
    fail "live state.json still contains durable reviewer payload fields"
  fi
  if jq -e '.. | objects | select(has("session_id"))' "$state_file" >/dev/null; then
    fail "live state.json still contains reviewer session metadata"
  fi

  return 0
}

main() {
  require_cmd jq

  TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/project_id_state_contraction.XXXXXX")"
  trap 'rm -rf "$TEST_TMPDIR" || true' EXIT

  test_settings_no_semantic_autostart
  test_init_project_bootstrap "$TEST_TMPDIR"
  test_reviewer_state_contraction "$TEST_TMPDIR"

  printf 'PASS: project_id_state_contraction\n'
  return 0
}

main "$@"
exit 0
