#!/usr/bin/env bash
# Run the agent-core cargo feature matrix required by the index-first P6 proof.
#
# Exit codes:
#   0  all checks passed
#   1  one or more matrix checks failed
#   2  usage error
#   3  environment error
set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/ci/core-cargo-matrix.sh

Runs:
  - cargo check -p agent-core --no-default-features
  - cargo check -p agent-core
  - cargo check -p agent-core --all-features
  - cargo tree -p agent-core --no-default-features with no tree-sitter-index edge
USAGE
}

die_usage() {
  printf 'core-cargo-matrix: %s\n' "$*" >&2
  usage
  exit 2
}

die_env() {
  printf 'core-cargo-matrix: %s\n' "$*" >&2
  exit 3
}

if [[ "$#" -ne 0 ]]; then
  die_usage "unexpected arguments: $*"
fi

command -v cargo >/dev/null 2>&1 || die_env "cargo is required"
command -v git >/dev/null 2>&1 || die_env "git is required"
command -v rg >/dev/null 2>&1 || die_env "rg is required"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die_env "not a git repository"
HARNESS_RUST="$REPO_ROOT/harness-rust"
[[ -d "$HARNESS_RUST" ]] || die_env "missing harness-rust workspace"

STEP_NAMES=()
STEP_RESULTS=()
STEP_EXITS=()

record_step() {
  STEP_NAMES+=("$1")
  STEP_RESULTS+=("$2")
  STEP_EXITS+=("$3")
}

run_cargo_check() {
  local name="$1"
  shift

  printf '==> %s\n' "$name"
  (
    cd "$HARNESS_RUST" || exit 3
    cargo check "$@"
  )
  local status=$?

  if [[ "$status" -eq 0 ]]; then
    record_step "$name" "PASS" "$status"
  else
    record_step "$name" "FAIL" "$status"
  fi
}

run_tree_edge_assertion() {
  local name="core-only cargo tree has no tree-sitter-index edge"
  local tree_output
  local rg_output
  local status

  printf '==> %s\n' "$name"
  tree_output="$(
    cd "$HARNESS_RUST" || exit 3
    cargo tree -p agent-core --no-default-features
  )"
  status=$?
  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "$tree_output"
    record_step "$name" "FAIL" "$status"
    return
  fi

  rg_output="$(printf '%s\n' "$tree_output" | rg -n 'tree-sitter-index')"
  status=$?
  case "$status" in
    0)
      printf '%s\n' "$rg_output"
      record_step "$name" "FAIL" "$status"
      ;;
    1)
      if [[ -z "$rg_output" ]]; then
        record_step "$name" "PASS" "$status"
      else
        printf '%s\n' "$rg_output"
        record_step "$name" "FAIL" "$status"
      fi
      ;;
    *)
      printf '%s\n' "$rg_output"
      record_step "$name" "FAIL" "$status"
      ;;
  esac
}

run_cargo_check "core-only cargo check" -p agent-core --no-default-features
run_cargo_check "default-feature cargo check" -p agent-core
run_cargo_check "all-features cargo check" -p agent-core --all-features
run_tree_edge_assertion

printf '\n%-56s %-6s %s\n' "step" "result" "exit"
printf '%-56s %-6s %s\n' "----" "------" "----"

overall=0
for i in "${!STEP_NAMES[@]}"; do
  printf '%-56s %-6s %s\n' "${STEP_NAMES[$i]}" "${STEP_RESULTS[$i]}" "${STEP_EXITS[$i]}"
  if [[ "${STEP_RESULTS[$i]}" != "PASS" ]]; then
    overall=1
  fi
done

exit "$overall"
