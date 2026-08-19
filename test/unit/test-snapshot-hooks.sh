#!/usr/bin/env bash
set -u

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${THIS_DIR}/../.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HARNESS_SNAPSHOT_DIR="$tmp/snapshots"
export HARNESS_TASK_ID="test-T-B-4"
export HARNESS_REPO_ROOT="$tmp"
export REVHARNESS_PARALLEL_QUIESCE="${REVHARNESS_PARALLEL_QUIESCE:-1}"

failures=0

pass() {
  printf 'PASS %s\n' "$1"
}

fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}

assert_true() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

find_snapshot() {
  local event="$1" path="$2"
  find "$HARNESS_SNAPSHOT_DIR" -path "*/${HARNESS_TASK_ID}/${event}/${path}" -type f 2>/dev/null | head -n 1
}

run_hook() {
  local hook="$1" json="$2"
  printf '%s' "$json" | bash "$hook"
  return $?
}

cd "$tmp" || exit 1

printf 'before\n' > "$tmp/foo.txt"
run_hook "$REPO_ROOT/.claude/hooks/snapshot-pre.sh" '{"tool_name":"Edit","tool_input":{"file_path":"foo.txt"}}'
pre_rc=$?
pre_snapshot="$(find_snapshot pre foo.txt)"
if [ "$pre_rc" -eq 0 ] && [ -f "$pre_snapshot" ]; then
  pass "pre snapshot on existing file"
else
  fail "pre snapshot on existing file"
fi

if [ -f "$HARNESS_SNAPSHOT_DIR/index.jsonl" ] && python3 - "$HARNESS_SNAPSHOT_DIR/index.jsonl" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
raise SystemExit(0 if any(row.get("event") == "pre" and row.get("file_path") == "foo.txt" for row in rows) else 1)
PY
then
  pass "pre index row appended"
else
  fail "pre index row appended"
fi

printf 'SECRET_SHOULD_NOT_SNAPSHOT\n' > "$tmp/.env"
run_hook "$REPO_ROOT/.claude/hooks/snapshot-pre.sh" '{"tool_name":"Edit","tool_input":{"file_path":".env"}}'
if ! find "$HARNESS_SNAPSHOT_DIR" -path '*/.env' -type f 2>/dev/null | grep -q .; then
  pass "denylist skip"
else
  fail "denylist skip"
fi

set +e
run_hook "$REPO_ROOT/.claude/hooks/snapshot-pre.sh" '{"tool_name":"Write","tool_input":{"file_path":"does-not-exist.txt"}}'
missing_rc=$?
set -u
if [ "$missing_rc" -eq 0 ]; then
  pass "fail-open on missing file"
else
  fail "fail-open on missing file"
fi

printf 'hello' > "$tmp/bar.txt"
run_hook "$REPO_ROOT/.claude/hooks/snapshot-post.sh" '{"tool_name":"Write","tool_input":{"file_path":"bar.txt"}}'
post_rc=$?
if [ "$post_rc" -eq 0 ] && python3 - "$HARNESS_SNAPSHOT_DIR/index.jsonl" <<'PY'
import json, re, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
for row in reversed(rows):
    if row.get("event") == "post" and row.get("file_path") == "bar.txt":
        raise SystemExit(0 if re.fullmatch(r"[0-9a-f]{64}", row.get("sha256") or "") else 1)
raise SystemExit(1)
PY
then
  pass "post snapshot computes sha"
else
  fail "post snapshot computes sha"
fi

if python3 - "$HARNESS_SNAPSHOT_DIR/index.jsonl" <<'PY'
import json, sys
required = {"ts", "event", "tool", "file_path", "task_id"}
with open(sys.argv[1], encoding="utf-8") as fh:
    rows = [json.loads(line) for line in fh if line.strip()]
if not rows:
    raise SystemExit(1)
for row in rows[-5:]:
    if not required.issubset(row):
        raise SystemExit(1)
raise SystemExit(0)
PY
then
  pass "schema check via python3"
else
  fail "schema check via python3"
fi

if [ "$failures" -eq 0 ]; then
  exit 0
fi
exit 1
