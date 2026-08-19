#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SMOKE="$REPO_ROOT/scripts/ci/phase-done-smoke.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/phase-done-smoke-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
PASS=0
FAIL=0

export REV_HARNESS_TEST_HARNESS="${REV_HARNESS_TEST_HARNESS:-1}"

cleanup() { /bin/rm -rf "$TMP_DIR" || true; }
trap cleanup EXIT

record() {
  local status="$1" name="$2" detail="${3:-}"
  if [[ "$status" == "PASS" ]]; then
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s%s\n' "$name" "${detail:+ ($detail)}" >&2
  fi
}

make_fixture() {
  local root="$1"
  mkdir -p "$root/bin" "$root/harness" "$root/home"
  cat >"$root/bin/rev-harness" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
mode="${SMOKE_STUB_MODE:-happy}"
cmd="${1:-help}"
shift || true
target=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --target) target="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$cmd" == "install" && -z "$target" && "$(pwd -P)" == "${REV_HARNESS_SMOKE_HARNESS_ROOT:-}" ]]; then
  exit 72
fi
case "$cmd" in
  install)
    [[ -n "$target" ]] || target="$(pwd -P)"
    if [[ "$mode" == "f1" ]]; then
      mkdir -p "${REV_HARNESS_SMOKE_HARNESS_ROOT}/.shared"
      printf 'hardcoded-wrong-root\n' >"${REV_HARNESS_SMOKE_HARNESS_ROOT}/.shared/project_id"
      exit 0
    fi
    pid="adopter-smoke-test"
    mkdir -p "$target/.shared" "$target/.rev-harness-state" "$target/.claude" "$target/.git/hooks" "$HOME/rust-db/$pid"
    printf '%s\n' "$pid" >"$target/.shared/project_id"
    jq -nc --arg pid "$pid" '{schema:"rev-harness-state/v1",project_id:$pid,phase:"done",current_phase:"done",phases:{},history:[]}' >"$target/.rev-harness-state/state.json"
    jq -nc --arg pid "$pid" --arg rust "$HOME/rust-db/$pid/semantic.db" '{schema:"rev-harness-paths/v1",project_id:$pid,backend:"rust",semantic_db:$rust,rust_db:$rust}' >"$target/.rev-harness-state/paths.json"
    printf '{"hooks":{"PostToolUse":[{"matcher":"*"}]}}\n' >"$target/.claude/settings.json"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$target/.git/hooks/pre-commit"
    chmod +x "$target/.git/hooks/pre-commit"
    sqlite3 "$HOME/rust-db/$pid/semantic.db" "CREATE TABLE IF NOT EXISTS registry(id);"
    ;;
  status)
    printf 'phase: done\n'
    ;;
  clean)
    printf 'janitor_command: build-cleanup\n'
    ;;
  *)
    printf 'unknown command: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$root/bin/rev-harness"

  cat >"$root/bin/harness-doctor" <<'STUB'
#!/usr/bin/env bash
printf 'Harness Doctor Quick\n- status: OK\n'
STUB
  chmod +x "$root/bin/harness-doctor"

  cat >"$root/bin/privacy-scan" <<'STUB'
#!/usr/bin/env bash
if [[ "${SMOKE_STUB_MODE:-happy}" == "privacy_leak" ]]; then
  printf 'I-2b violated: /Users/redacted/leak\n' >&2
  exit 1
fi
exit 0
STUB
  chmod +x "$root/bin/privacy-scan"

  cat >"$root/bin/semantic-mcp" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --help|-h|help) printf 'semantic-mcp test help\n'; exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$root/bin/semantic-mcp"
}

run_smoke_case() {
  local name="$1" mode="$2" expect="$3" root metrics out err rc
  root="$TMP_DIR/$name"
  metrics="$TMP_DIR/$name.jsonl"
  out="$TMP_DIR/$name.out"
  err="$TMP_DIR/$name.err"
  make_fixture "$root"
  set +e
  HOME="$root/home" \
    SMOKE_STUB_MODE="$mode" \
    REV_HARNESS_BIN="$root/bin/rev-harness" \
    REV_HARNESS_DOCTOR_BIN="$root/bin/harness-doctor" \
    REV_HARNESS_PRIVACY_SCAN="$root/bin/privacy-scan" \
    REV_HARNESS_SMOKE_BINARY="$root/bin/semantic-mcp" \
    REV_HARNESS_SMOKE_HARNESS_ROOT="$root/harness" \
    REV_HARNESS_SMOKE_METRICS_FILE="$metrics" \
    bash "$SMOKE" --phase H >"$out" 2>"$err"
  rc=$?
  set -e
  if [[ "$rc" -eq "$expect" ]]; then
    record PASS "$name exit=$expect"
  else
    record FAIL "$name exit" "expected $expect got $rc"
    cat "$err" >&2
  fi
  [[ -s "$metrics" ]] || { record FAIL "$name metrics" "missing JSONL"; return; }
  if jq -s -e '
      all(.[]; .schema == "phase-done-smoke/v1"
        and (.event == "step" or .event == "summary")
        and (.phase == "H")
        and (.exit_code | type == "number")
        and (.smoke_evidence_sha256 | test("^[0-9a-f]{64}$")))
      and (map(select(.event == "summary")) | length == 1)
    ' "$metrics" >/dev/null; then
    record PASS "$name JSONL schema"
  else
    record FAIL "$name JSONL schema"
    cat "$metrics" >&2
  fi
}

run_smoke_case happy happy 0
run_smoke_case f1 f1 1
run_smoke_case privacy privacy_leak 1

grep -q 'identity' "$TMP_DIR/f1.err" && record PASS "F1 reproducer failed identity" || record FAIL "F1 reproducer failed identity"
grep -q 'I-2b violated' "$TMP_DIR/privacy.err" && record PASS "I-2b violation surfaced" || record FAIL "I-2b violation surfaced"

printf 'Result: %s passed, %s failed\n' "$PASS" "$FAIL"
exit "$FAIL"
