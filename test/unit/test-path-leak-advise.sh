#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK_SRC="$ROOT/.claude/hooks/path-leak-advise.sh"
POS="$ROOT/test/golden/path-leak/positive.txt"
NEG="$ROOT/test/golden/path-leak/negative.txt"
SCHEMA="$ROOT/test/golden/metrics/path_leak_events.jsonl.schema.json"
TMP="$(mktemp -d /private/tmp/test_pathleak_XXXXXX)"
HOOK_REPO="$TMP/repo"
HOOK="$HOOK_REPO/.claude/hooks/path-leak-advise.sh"
TARGET="$TMP/test.txt"
ERR="$TMP/hook.stderr"
SAMPLES="$TMP/jsonl-samples.log"
PASS=0
FAIL=0

cleanup() { /bin/rm -rf "$TMP"; }
trap cleanup EXIT

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

need_file() {
  if [[ -f "$1" ]]; then pass "fixture exists: ${1#"$ROOT"/}"; else fail "missing fixture: ${1#"$ROOT"/}"; fi
}

eq() {
  local name="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then pass "$name"; else fail "$name (expected=$want actual=$got)"; fi
}

contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else fail "$name (missing: $needle)"; fi
}

event_json() {
  TARGET_FILE="$1" python3 - <<'PY'
import json, os
print(json.dumps({"tool": "Edit", "tool_input": {"file_path": os.environ["TARGET_FILE"]}}))
PY
}

run_hook_file() {
  local payload rc
  payload="$(event_json "$1")"
  printf '%s' "$payload" | "$HOOK" >/dev/null 2>"$ERR"
  rc=$?
  printf '%s\n' "$rc"
}

run_hook_raw() {
  local rc
  printf '%s' "$1" | "$HOOK" >/dev/null 2>"$ERR"
  rc=$?
  printf '%s\n' "$rc"
}

rows() {
  if [[ -f "$METRICS" ]]; then wc -l < "$METRICS" | tr -d ' '; else printf '0\n'; fi
}

reset_hook_output() {
  /bin/rm -f "$METRICS" "$ERR"
}

schema_ok() {
  jq -e . "$SCHEMA" >/dev/null || return 1
  jq -e . "$SAMPLES" >/dev/null || return 1
  SCHEMA_PATH="$SCHEMA" ROWS_PATH="$SAMPLES" python3 - <<'PY'
import datetime, json, os
schema = json.load(open(os.environ["SCHEMA_PATH"], encoding="utf-8"))
required = set(schema["required"])
allowed = set(schema["properties"])
rows = [json.loads(line) for line in open(os.environ["ROWS_PATH"], encoding="utf-8") if line.strip()]
if not rows:
    raise SystemExit("no rows")
for row in rows:
    if set(row) - allowed or required - set(row):
        raise SystemExit("key mismatch")
    if row.get("event") != "path_leak":
        raise SystemExit("event mismatch")
    if row.get("action") not in {"redact", "block", "warn"}:
        raise SystemExit("action mismatch")
    if not isinstance(row.get("source"), str) or not row["source"]:
        raise SystemExit("source mismatch")
    if not isinstance(row.get("match_count"), int) or row["match_count"] < 1:
        raise SystemExit("match_count mismatch")
    if not isinstance(row.get("redacted_preview"), str):
        raise SystemExit("preview mismatch")
    if row.get("agent_family") not in {None, "claude", "codex", "unknown"}:
        raise SystemExit("agent_family mismatch")
    datetime.datetime.fromisoformat(row["ts"].replace("Z", "+00:00"))
PY
}

need_file "$HOOK_SRC"
need_file "$POS"
need_file "$NEG"
need_file "$SCHEMA"
command -v jq >/dev/null 2>&1 && pass "jq available" || fail "jq missing"

mkdir -p "$HOOK_REPO/.claude/hooks"
cp "$HOOK_SRC" "$HOOK"
chmod +x "$HOOK"
METRICS="$(cd "$HOOK_REPO" && pwd -P)/.agent/metrics/path_leak_events.jsonl"
: > "$SAMPLES"

idx=0
while IFS= read -r line || [[ -n "$line" ]]; do
  idx=$((idx + 1))
  reset_hook_output
  printf '%s\n' "$line" > "$TARGET"
  eq "P${idx} exits 0" "0" "$(run_hook_file "$TARGET")"
  eq "P${idx} emits one jsonl row" "1" "$(rows)"
  contains "P${idx} emits stderr warning" "$(cat "$ERR" 2>/dev/null || true)" "path-leak-advise:"
  tail -n 1 "$METRICS" >> "$SAMPLES" 2>/dev/null || true
done < "$POS"

idx=0
while IFS= read -r line || [[ -n "$line" ]]; do
  idx=$((idx + 1))
  reset_hook_output
  printf '%s\n' "$line" > "$TARGET"
  eq "N${idx} exits 0" "0" "$(run_hook_file "$TARGET")"
  eq "N${idx} emits no jsonl row" "0" "$(rows)"
  eq "N${idx} emits no stderr warning" "" "$(cat "$ERR" 2>/dev/null || true)"
done < "$NEG"

reset_hook_output
eq "invalid JSON exits 0" "0" "$(run_hook_raw '{"tool":')"
eq "invalid JSON emits no row" "0" "$(rows)"

if schema_ok; then pass "emitted jsonl rows conform to schema"; else fail "emitted jsonl rows conform to schema"; fi

reset_hook_output
: > "$TARGET"
i=0
while [[ $i -lt 1000 ]]; do
  printf 'line %04d ~/dev/rev_harness/src/lib.rs\n' "$i" >> "$TARGET"
  i=$((i + 1))
done
SECONDS=0
eq "1000-line input exits 0" "0" "$(run_hook_file "$TARGET")"
if [[ "$SECONDS" -le 5 ]]; then pass "1000-line input completes within 5s"; else fail "1000-line input completes within 5s (elapsed=${SECONDS}s)"; fi

if [[ "$FAIL" -eq 0 ]]; then
  printf 'PASS: path-leak-advise coverage (%d assertions)\n' "$PASS"
  exit 0
fi

printf 'FAIL: path-leak-advise coverage (%d passed, %d failed)\n' "$PASS" "$FAIL" >&2
exit 1
