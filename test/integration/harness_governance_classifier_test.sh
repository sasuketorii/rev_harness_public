#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLASSIFIER="$PROJECT_ROOT/scripts/harness-governance-classifier.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

run_classifier() {
  (cd "$PROJECT_ROOT" && bash "$CLASSIFIER" "$@")
}

assert_classifier() {
  local expected="$1"
  shift
  local actual=""

  actual="$(run_classifier --json -- "$@" | jq -r '.classifier')"
  [[ "$actual" == "$expected" ]] || fail "expected $expected for $*, got $actual"
}

test_docs_reference_is_light() {
  assert_classifier light docs/official-docs-links.md
}

test_unclassified_defaults_standard() {
  assert_classifier standard unknown.surface
}

test_script_is_standard() {
  assert_classifier standard scripts/harness-check-planner.sh
}

test_integration_is_standard() {
  assert_classifier standard test/integration/harness_check_planner_test.sh
}

test_wrapper_is_heavy() {
  assert_classifier heavy scripts/codex-wrapper.sh
}

test_dot_prefixed_wrapper_is_heavy() {
  assert_classifier heavy ./scripts/codex-wrapper.sh
}

test_absolute_wrapper_is_heavy() {
  assert_classifier heavy "$PROJECT_ROOT/scripts/codex-wrapper.sh"
}

test_double_slash_absolute_wrapper_is_heavy() {
  assert_classifier heavy "$PROJECT_ROOT//scripts/codex-wrapper.sh"
}

test_parent_alias_wrapper_is_heavy() {
  assert_classifier heavy "../$(basename "$PROJECT_ROOT")/scripts/codex-wrapper.sh"
}

test_acceptance_truth_is_heavy() {
  assert_classifier heavy docs/manual/verification-truth-matrix.md
}

test_codex_config_is_heavy() {
  assert_classifier heavy .codex/config.toml
}

test_task_lineage_ledger_is_heavy() {
  assert_classifier heavy .agent/active/sow/task-lineage-ledger.md
}

test_dot_prefixed_task_lineage_ledger_is_heavy() {
  assert_classifier heavy ./.agent/active/sow/task-lineage-ledger.md
}

test_absolute_task_lineage_ledger_is_heavy() {
  assert_classifier heavy "$PROJECT_ROOT/.agent/active/sow/task-lineage-ledger.md"
}

test_double_slash_absolute_task_lineage_ledger_is_heavy() {
  assert_classifier heavy "$PROJECT_ROOT//.agent/active/sow/task-lineage-ledger.md"
}

test_embedded_dot_task_lineage_ledger_is_heavy() {
  assert_classifier heavy .agent/active/sow/./task-lineage-ledger.md
}

test_embedded_dotdot_task_lineage_ledger_is_heavy() {
  assert_classifier heavy .agent/active/sow/../sow/task-lineage-ledger.md
}

test_parent_alias_task_lineage_ledger_is_heavy() {
  assert_classifier heavy "../$(basename "$PROJECT_ROOT")/.agent/active/sow/task-lineage-ledger.md"
}

test_root_external_markdown_does_not_use_light_fallback() {
  assert_classifier standard ../outside.md
}

test_active_plan_is_standard() {
  assert_classifier standard .agent/active/plan_20260506_worldclass_harness_operating_model.md
}

test_mixed_paths_choose_heaviest() {
  assert_classifier heavy docs/official-docs-links.md scripts/codex-wrapper.sh
}

test_json_shape() {
  run_classifier --json -- docs/official-docs-links.md \
    | jq -e '.advisory_only == true and (.reasons | length) >= 1 and .gate_tier == "quick"' >/dev/null \
    || fail "json shape should expose advisory mode, reasons, and gate_tier hint"
}

# Demote reconciliation (S6): the governance classifier is a Slice-B fast preflight
# advisory only. It MUST NOT emit ceremony-routing fields (operating_mode /
# reviewer_default), so it cannot route ceremony divergently from the canonical
# classifier. It names the single ceremony authority and declares emits_ceremony=false.
test_no_ceremony_fields_emitted() {
  run_classifier --json -- docs/official-docs-links.md \
    | jq -e 'has("operating_mode") == false
        and has("reviewer_default") == false
        and .emits_ceremony == false
        and .ceremony_authority == "scripts/rev-harness-task-classifier.sh"' >/dev/null \
    || fail "governance classifier must not emit ceremony fields and must name the canonical ceremony authority"
}

test_no_ceremony_fields_emitted_text() {
  local output=""
  output="$(run_classifier -- docs/official-docs-links.md)"
  ! grep -q 'operating_mode=' <<<"$output" \
    || fail "text output must not emit operating_mode"
  ! grep -q 'reviewer_default=' <<<"$output" \
    || fail "text output must not emit reviewer_default"
  grep -q 'emits_ceremony=false' <<<"$output" \
    || fail "text output must declare emits_ceremony=false"
}

# Single reconciled answer for the path the plan flagged as divergent: the
# governance preflight hint for docs/official-docs-links.md is `light`, matching
# the canonical classifier's light-safe surface for that exact path. The two
# classifiers no longer diverge on ceremony class for this path because the
# governance classifier no longer routes ceremony at all.
test_official_docs_links_single_reconciled_class() {
  assert_classifier light docs/official-docs-links.md
  local canonical="$PROJECT_ROOT/scripts/rev-harness-task-classifier.sh"
  local canonical_class=""
  canonical_class="$(cd "$PROJECT_ROOT" && bash "$canonical" classify --intent reference-cleanup --files docs/official-docs-links.md --json | jq -r '.task_class')"
  [[ "$canonical_class" == "light" ]] \
    || fail "canonical classifier should treat docs/official-docs-links.md light-safe surface as light, got $canonical_class"
}

test_docs_reference_is_light
test_unclassified_defaults_standard
test_script_is_standard
test_integration_is_standard
test_wrapper_is_heavy
test_dot_prefixed_wrapper_is_heavy
test_absolute_wrapper_is_heavy
test_double_slash_absolute_wrapper_is_heavy
test_parent_alias_wrapper_is_heavy
test_acceptance_truth_is_heavy
test_codex_config_is_heavy
test_task_lineage_ledger_is_heavy
test_dot_prefixed_task_lineage_ledger_is_heavy
test_absolute_task_lineage_ledger_is_heavy
test_double_slash_absolute_task_lineage_ledger_is_heavy
test_embedded_dot_task_lineage_ledger_is_heavy
test_embedded_dotdot_task_lineage_ledger_is_heavy
test_parent_alias_task_lineage_ledger_is_heavy
test_root_external_markdown_does_not_use_light_fallback
test_active_plan_is_standard
test_mixed_paths_choose_heaviest
test_json_shape
test_no_ceremony_fields_emitted
test_no_ceremony_fields_emitted_text
test_official_docs_links_single_reconciled_class

printf 'PASS: harness_governance_classifier_test\n'
