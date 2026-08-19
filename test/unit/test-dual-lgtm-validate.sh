#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRIPT="$ROOT/scripts/dual-lgtm-validate.sh"
SCHEMA="$ROOT/test/golden/metrics/dual_lgtm_gap.jsonl.schema.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test_dual_lgtm_XXXXXX")"
PASS=0
FAIL=0
SCENARIOS=0

cleanup() { /bin/rm -rf "$TMP"; }
trap cleanup EXIT
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
warn() { printf 'WARN: %s\n' "$1" >&2; }
eq() { if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1 (expected=$2 actual=$3)"; fi; }
rows() { if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else printf '0\n'; fi; }
contains_file() { grep -F "$3" "$2" >/dev/null 2>&1 && pass "$1" || fail "$1 (missing: $3)"; }

write_review() {
  case "$2" in
    lgtm) printf '%s\n' '**Verdict**: ✅ LGTM (unconditional)' > "$1" ;;
    bad) printf '%s\n' '**Verdict**: Request Changes' > "$1" ;;
    missing) : ;;
    *) fail "unknown fixture state: $2" ;;
  esac
}

schema_ok() {
  local file="$1"
  [[ ! -s "$file" ]] && return 0
  if command -v python3 >/dev/null 2>&1; then
    SCHEMA_PATH="$SCHEMA" ROWS_PATH="$file" python3 - <<'PY'
import datetime, json, os
s=json.load(open(os.environ["SCHEMA_PATH"], encoding="utf-8"))
req=set(s["required"]); allowed=set(s["properties"]); keys=req|{"verdicts","agent_family"}
gap=set(s["properties"]["gap_kind"]["enum"])
verdict=set(s["properties"]["verdicts"]["items"]["properties"]["verdict"]["enum"])
agent=set(s["properties"]["agent_family"]["enum"])
for line in open(os.environ["ROWS_PATH"], encoding="utf-8"):
    if not line.strip(): continue
    row=json.loads(line); assert set(row)==keys and not (set(row)-allowed) and not (req-set(row))
    datetime.datetime.fromisoformat(row["ts"].replace("Z","+00:00"))
    assert row["event"]=="dual_lgtm_gap" and isinstance(row["task_id"], str) and row["task_id"]
    assert row["gap_kind"] in gap and row["agent_family"] in agent
    assert isinstance(row["reviewers_seen"], int) and row["reviewers_seen"] >= 0
    assert isinstance(row["reviewers_required"], int) and row["reviewers_required"] >= 1
    assert isinstance(row["verdicts"], list) and row["verdicts"]
    for item in row["verdicts"]:
        assert set(item)=={"reviewer_id","verdict"}
        assert isinstance(item["reviewer_id"], str) and item["reviewer_id"]
        assert item["verdict"] in verdict
PY
  elif command -v jq >/dev/null 2>&1; then
    jq -e . "$file" >/dev/null
  else
    warn "python3 and jq missing; schema check skipped for $file"
    return 0
  fi
}

run_case() {
  local name="$1" opus="$2" codex="$3" mode="$4" want_rc="$5" want_rows="$6" want_gap="$7" want_seen="$8"
  local dir evidence metrics out rc
  dir="$TMP/$name"; evidence="$dir/evidence"; metrics="$dir/m.jsonl"; mkdir -p "$evidence"
  write_review "$evidence/review-opus-r1.md" "$opus"
  write_review "$evidence/review-codex-r1.md" "$codex"
  rc=0
  out="$(bash "$SCRIPT" --plan-id unit --round 1 --evidence-dir "$evidence" --metrics-path "$metrics" "$mode" 2>&1)" || rc=$?
  printf '%s\n' "$out" > "$dir/stdout.log"
  eq "$name exits $want_rc" "$want_rc" "$rc"
  eq "$name row count" "$want_rows" "$(rows "$metrics")"
  if [[ "$want_rows" != "0" ]]; then
    contains_file "$name gap_kind" "$metrics" "\"gap_kind\":\"$want_gap\""
    contains_file "$name reviewers_seen" "$metrics" "\"reviewers_seen\":$want_seen"
    contains_file "$name reviewers_required" "$metrics" '"reviewers_required":2'
  fi
  if schema_ok "$metrics"; then pass "$name jsonl conforms to schema"; else fail "$name jsonl conforms to schema"; fi
  SCENARIOS=$((SCENARIOS + 1))
}

[[ -f "$SCRIPT" ]] && pass "validator exists" || fail "validator exists"
[[ -f "$SCHEMA" ]] && pass "schema exists" || fail "schema exists"

run_case "both LGTM" lgtm lgtm --strict 0 0 "" ""
run_case "opus only" lgtm missing --strict 1 1 missing_reviewer 1
run_case "codex only" missing lgtm --strict 1 1 missing_reviewer 1
run_case "both missing" missing missing --strict 1 1 missing_reviewer 0
run_case "verdict mismatch" lgtm bad --strict 2 1 verdict_mismatch 2
run_case "soft both missing" missing missing --soft 0 1 missing_reviewer 0

if [[ "$FAIL" -eq 0 && "$SCENARIOS" -eq 6 ]]; then
  printf 'PASS: dual-lgtm-validate coverage (%d scenarios, %d assertions)\n' "$SCENARIOS" "$PASS"
  exit 0
fi
printf 'FAIL: dual-lgtm-validate coverage (%d scenarios, %d passed, %d failed)\n' "$SCENARIOS" "$PASS" "$FAIL" >&2
exit 1
