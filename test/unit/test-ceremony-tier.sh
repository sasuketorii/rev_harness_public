#!/usr/bin/env bash
# Focused unit test for _derive_ceremony_tier in .claude/commands/auto_orchestrate.sh.
#
# Proves the metrics-churn exclusion fix: runtime telemetry under .agent/metrics/
# is data, not a ceremony-relevant surface, and must not set or dilute the tier.
#
# Cases:
#   1. metrics-only churn          -> empty after exclusion -> fail-closed-upward -> heavy
#   2. heavy file + metrics churn  -> heavy (promotion still works)
#   3. docs file  + metrics churn  -> standard (metrics no longer forces a wrong class)
#
# auto_orchestrate.sh is source-guarded (`if [[ "${BASH_SOURCE[0]}" == "$0" ]]`)
# so sourcing it does NOT run main. It DOES enable `set -euo pipefail`, so the
# function under test is invoked in a guarded subshell-free way and benign
# non-zero returns are tolerated explicitly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUTO_ORCHESTRATE="$PROJECT_ROOT/.claude/commands/auto_orchestrate.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$AUTO_ORCHESTRATE" ]] || fail "missing: $AUTO_ORCHESTRATE"

# shellcheck source=/dev/null
source "$AUTO_ORCHESTRATE"

# Stub log_* to no-ops: the real ones write to a main-only log path that does
# not exist in a sourced unit context.
log_warn()  { :; }
log_info()  { :; }
log_error() { :; }

# Controlled change surface: the test drives _coordination_collect_changed_files_json
# so the result is deterministic and not contaminated by the live worktree.
TEST_CHANGED_JSON='[]'
_coordination_collect_changed_files_json() {
  printf '%s' "$TEST_CHANGED_JSON"
}

# Run the function with a guarded call so a benign non-zero does not abort under
# `set -e`. It is documented to always return 0, but we belt-and-suspender it.
derive() {
  CEREMONY_TIER=""
  _derive_ceremony_tier "implementation" "$PROJECT_ROOT/.agent/active/plan_unit_test.md" || true
}

assert_tier() {
  local label="$1" expected="$2"
  [[ "$CEREMONY_TIER" == "$expected" ]] \
    || fail "$label: expected CEREMONY_TIER=$expected, got '$CEREMONY_TIER'"
  printf 'PASS: %s -> CEREMONY_TIER=%s\n' "$label" "$CEREMONY_TIER"
}

# Case 1: metrics-only churn (+ plan) -> empty after exclusion -> heavy.
TEST_CHANGED_JSON='[".agent/metrics/dispatch_events.jsonl","'".agent/active/plan_unit_test.md"'"]'
derive
assert_tier "metrics-only-churn" "heavy"

# Case 2: real heavy file + metrics churn -> heavy (promotion still works).
TEST_CHANGED_JSON='["scripts/codex-wrapper.sh",".agent/metrics/dispatch_events.jsonl"]'
derive
assert_tier "heavy-file+metrics" "heavy"

# Case 3: docs file + metrics churn -> standard (metrics no longer forces a wrong class).
TEST_CHANGED_JSON='["docs/foo.md",".agent/metrics/dispatch_events.jsonl"]'
derive
assert_tier "docs+metrics" "standard"

printf 'OK: all ceremony-tier metrics-exclusion cases passed\n'
