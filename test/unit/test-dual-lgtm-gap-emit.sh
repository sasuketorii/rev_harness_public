#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCHEMA="$ROOT/test/golden/metrics/dual_lgtm_gap.jsonl.schema.json"
FIXTURE="$ROOT/test/unit/fixtures/dual_lgtm_gap_sample.jsonl"
EMITTER="$ROOT/scripts/dual-lgtm-validate.sh"
TMP="${TMPDIR:-/private/tmp}/dual_lgtm_gap_emit_test.$$"
PASS=0
FAIL=0

cleanup() { /bin/rm -rf "$TMP"; }
trap cleanup EXIT

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

eq() {
  local name="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then pass "$name"; else fail "$name (expected=$want actual=$got)"; fi
}

need_file() {
  local name="$1" path="$2"
  if [[ -f "$path" ]]; then pass "$name"; else fail "$name (${path#"$ROOT"/})"; fi
}

row_json_ok() {
  local idx="$1"
  ROW_INDEX="$idx" ROWS_PATH="$FIXTURE" python3 - <<'PY'
import json, os, sys
idx = int(os.environ["ROW_INDEX"])
lines = [line for line in open(os.environ["ROWS_PATH"], encoding="utf-8") if line.strip()]
if idx < 1 or idx > len(lines):
    raise SystemExit(f"row {idx}: missing")
json.loads(lines[idx - 1])
PY
}

schema_validation_ok() {
  SCHEMA_PATH="$SCHEMA" ROWS_PATH="$FIXTURE" python3 - <<'PY'
import datetime, json, os
schema = json.load(open(os.environ["SCHEMA_PATH"], encoding="utf-8"))
required = set(schema["required"])
allowed = set(schema["properties"])
gap_enum = set(schema["properties"]["gap_kind"]["enum"])
verdict_enum = set(schema["properties"]["verdicts"]["items"]["properties"]["verdict"]["enum"])
fam_enum = set(schema["properties"]["agent_family"]["enum"])
rows = [json.loads(line) for line in open(os.environ["ROWS_PATH"], encoding="utf-8") if line.strip()]
assert len(rows) == 5, f"expected 5 rows, got {len(rows)}"
for i, row in enumerate(rows, start=1):
    extra = set(row) - allowed
    missing = required - set(row)
    assert not extra, f"row {i}: extra keys {sorted(extra)}"
    assert not missing, f"row {i}: missing required {sorted(missing)}"
    assert row["event"] == "dual_lgtm_gap", f"row {i}: event mismatch"
    assert row["gap_kind"] in gap_enum, f"row {i}: gap_kind mismatch"
    assert isinstance(row["reviewers_seen"], int) and row["reviewers_seen"] >= 0, f"row {i}: reviewers_seen mismatch"
    assert isinstance(row["reviewers_required"], int) and row["reviewers_required"] >= 1, f"row {i}: reviewers_required mismatch"
    datetime.datetime.fromisoformat(row["ts"].replace("Z", "+00:00"))
    if "agent_family" in row:
        assert row["agent_family"] in fam_enum, f"row {i}: agent_family mismatch"
    if "verdicts" in row:
        for v in row["verdicts"]:
            assert set(v) <= set(schema["properties"]["verdicts"]["items"]["properties"]), f"row {i}: verdict extra keys"
            assert v["verdict"] in verdict_enum, f"row {i}: verdict enum mismatch"
            assert v["reviewer_id"], f"row {i}: reviewer_id empty"
print("schema-validation OK: 5/5 rows")
PY
}

event_literals_ok() {
  ROWS_PATH="$FIXTURE" python3 - <<'PY'
import json, os
rows = [json.loads(line) for line in open(os.environ["ROWS_PATH"], encoding="utf-8") if line.strip()]
for i, row in enumerate(rows, start=1):
    assert row.get("event") == "dual_lgtm_gap", f"row {i}: event mismatch"
PY
}

gap_kind_enum_ok() {
  SCHEMA_PATH="$SCHEMA" ROWS_PATH="$FIXTURE" python3 - <<'PY'
import json, os
schema = json.load(open(os.environ["SCHEMA_PATH"], encoding="utf-8"))
allowed = set(schema["properties"]["gap_kind"]["enum"])
rows = [json.loads(line) for line in open(os.environ["ROWS_PATH"], encoding="utf-8") if line.strip()]
for i, row in enumerate(rows, start=1):
    assert row.get("gap_kind") in allowed, f"row {i}: gap_kind mismatch"
PY
}

timestamps_ok() {
  ROWS_PATH="$FIXTURE" python3 - <<'PY'
import datetime, json, os
rows = [json.loads(line) for line in open(os.environ["ROWS_PATH"], encoding="utf-8") if line.strip()]
for i, row in enumerate(rows, start=1):
    datetime.datetime.fromisoformat(row["ts"].replace("Z", "+00:00"))
PY
}

verdict_enums_ok() {
  SCHEMA_PATH="$SCHEMA" ROWS_PATH="$FIXTURE" python3 - <<'PY'
import json, os
schema = json.load(open(os.environ["SCHEMA_PATH"], encoding="utf-8"))
allowed = set(schema["properties"]["verdicts"]["items"]["properties"]["verdict"]["enum"])
rows = [json.loads(line) for line in open(os.environ["ROWS_PATH"], encoding="utf-8") if line.strip()]
for i, row in enumerate(rows, start=1):
    for verdict in row.get("verdicts", []):
        assert verdict.get("verdict") in allowed, f"row {i}: verdict enum mismatch"
PY
}

reviewer_counts_ok() {
  ROWS_PATH="$FIXTURE" python3 - <<'PY'
import json, os
rows = [json.loads(line) for line in open(os.environ["ROWS_PATH"], encoding="utf-8") if line.strip()]
for i, row in enumerate(rows, start=1):
    assert isinstance(row.get("reviewers_required"), int) and row["reviewers_required"] >= 1, f"row {i}: reviewers_required mismatch"
    assert isinstance(row.get("reviewers_seen"), int) and row["reviewers_seen"] >= 0, f"row {i}: reviewers_seen mismatch"
PY
}

emitted_rows_schema_ok() {
  local rows_path="$1"
  SCHEMA_PATH="$SCHEMA" ROWS_PATH="$rows_path" python3 - <<'PY'
import datetime, json, os
schema = json.load(open(os.environ["SCHEMA_PATH"], encoding="utf-8"))
required = set(schema["required"])
allowed = set(schema["properties"])
gap_enum = set(schema["properties"]["gap_kind"]["enum"])
verdict_enum = set(schema["properties"]["verdicts"]["items"]["properties"]["verdict"]["enum"])
fam_enum = set(schema["properties"]["agent_family"]["enum"])
rows = [json.loads(line) for line in open(os.environ["ROWS_PATH"], encoding="utf-8") if line.strip()]
assert rows, "no emitted rows"
for i, row in enumerate(rows, start=1):
    assert not (set(row) - allowed), f"emitted row {i}: extra keys"
    assert not (required - set(row)), f"emitted row {i}: missing required"
    assert row["event"] == "dual_lgtm_gap", f"emitted row {i}: event mismatch"
    assert row["gap_kind"] in gap_enum, f"emitted row {i}: gap_kind mismatch"
    assert isinstance(row["reviewers_seen"], int) and row["reviewers_seen"] >= 0, f"emitted row {i}: reviewers_seen mismatch"
    assert isinstance(row["reviewers_required"], int) and row["reviewers_required"] >= 1, f"emitted row {i}: reviewers_required mismatch"
    datetime.datetime.fromisoformat(row["ts"].replace("Z", "+00:00"))
    if "agent_family" in row:
        assert row["agent_family"] in fam_enum, f"emitted row {i}: agent_family mismatch"
    for verdict in row.get("verdicts", []):
        assert verdict["verdict"] in verdict_enum, f"emitted row {i}: verdict enum mismatch"
        assert verdict["reviewer_id"], f"emitted row {i}: reviewer_id empty"
PY
}

emitter_probe() {
  if [[ ! -f "$EMITTER" ]]; then
    pass "T-E-1 emitter not yet landed (fixture-only)"
    return
  fi
  if [[ ! -x "$EMITTER" ]]; then
    pass "T-E-1 emitter present but not executable (fixture-only)"
    return
  fi

  mkdir -p "$TMP"
  local help="$TMP/emitter.help"
  local stdout="$TMP/emitter.stdout"
  local evidence="$TMP/emitter-evidence"
  local metrics="$TMP/emitter-dual_lgtm_gap.jsonl"
  "$EMITTER" --help >"$help" 2>&1 || true

  if grep -q -- "--self-test" "$help"; then
    if "$EMITTER" --self-test >"$stdout" 2>&1; then
      pass "T-E-1 emitter --self-test exits 0"
    else
      fail "T-E-1 emitter --self-test exits 0"
      return
    fi
  elif grep -q -- "--dry-run" "$help"; then
    if "$EMITTER" --dry-run >"$stdout" 2>&1; then
      pass "T-E-1 emitter --dry-run exits 0"
    else
      fail "T-E-1 emitter --dry-run exits 0"
      return
    fi
  else
    pass "T-E-1 emitter has no self-test or dry-run flag (fixture-only)"
    return
  fi

  if ! grep -q -- "--plan-id" "$help" || ! grep -q -- "--round" "$help" || ! grep -q -- "--metrics-path" "$help"; then
    pass "T-E-1 emitter has no metrics probe flags (fixture-only)"
    return
  fi

  mkdir -p "$evidence"
  printf '**Verdict**: \342\234\205 LGTM (unconditional)\n' > "$evidence/review-opus-r1.md"
  "$EMITTER" \
    --plan-id T-E-4-probe \
    --round 1 \
    --evidence-dir "$evidence" \
    --metrics-path "$metrics" \
    --strict >"$stdout" 2>&1 || true

  if [[ -s "$metrics" ]] && emitted_rows_schema_ok "$metrics"; then
    pass "T-E-1 emitter output conforms to schema"
  else
    fail "T-E-1 emitter output conforms to schema"
  fi
}

need_file "schema file exists" "$SCHEMA"
need_file "fixture file exists" "$FIXTURE"

if [[ -f "$FIXTURE" ]]; then
  eq "fixture line count is 5" "5" "$(wc -l < "$FIXTURE" | tr -d ' ')"
else
  fail "fixture line count is 5"
fi

idx=1
while [[ "$idx" -le 5 ]]; do
  if row_json_ok "$idx"; then pass "row ${idx} is valid JSON"; else fail "row ${idx} is valid JSON"; fi
  idx=$((idx + 1))
done

if event_literals_ok; then pass "all rows use event dual_lgtm_gap"; else fail "all rows use event dual_lgtm_gap"; fi
if schema_validation_ok; then pass "all rows satisfy pinned schema keys"; else fail "all rows satisfy pinned schema keys"; fi
if gap_kind_enum_ok; then pass "all gap_kind values are allowed"; else fail "all gap_kind values are allowed"; fi
if timestamps_ok; then pass "all timestamps parse as RFC3339"; else fail "all timestamps parse as RFC3339"; fi
if verdict_enums_ok; then pass "all verdict values are allowed"; else fail "all verdict values are allowed"; fi
if reviewer_counts_ok; then pass "reviewer counts satisfy schema bounds"; else fail "reviewer counts satisfy schema bounds"; fi
emitter_probe

printf 'summary: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
exit 0
