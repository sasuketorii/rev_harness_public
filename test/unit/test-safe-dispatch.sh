#!/usr/bin/env bash
set -euo pipefail

failures=0
tmpdir=$(mktemp -d)
metrics_file=".agent/metrics/dispatch_events.jsonl"
metrics_existed=0
metrics_before=0

cleanup() {
  /bin/rm -f .agent/state/locks/test-001.before.sha256 || true
  /bin/rm -f .agent/state/locks/test-001.after.sha256 || true
  /bin/rm -f .agent/state/locks/test-042.before.sha256 || true
  /bin/rm -f .agent/state/locks/test-042.after.sha256 || true
  if [ -f "$metrics_file" ]; then
    if [ "$metrics_existed" -eq 0 ]; then
      /bin/rm -f "$metrics_file" || true
    elif [ "$metrics_before" -eq 0 ]; then
      : > "$metrics_file"
    else
      sed -n "1,${metrics_before}p" "$metrics_file" > "$tmpdir/dispatch_events.restore"
      mv "$tmpdir/dispatch_events.restore" "$metrics_file"
    fi
  fi
  /bin/rm -rf "$tmpdir" || true
}
trap cleanup EXIT

pass() {
  echo "PASS: $*"
}

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

assert_eq() {
  local got=$1
  local want=$2
  local message=$3
  if [ "$got" = "$want" ]; then
    pass "$message"
  else
    fail "$message (got '$got', want '$want')"
  fi
}

assert_file() {
  local path=$1
  local message=$2
  if [ -f "$path" ]; then
    pass "$message"
  else
    fail "$message"
  fi
}

assert_contains() {
  local path=$1
  local needle=$2
  local message=$3
  if [ -f "$path" ] && grep -Fq "$needle" "$path"; then
    pass "$message"
  else
    fail "$message"
  fi
}

if [ -f "$metrics_file" ]; then
  metrics_existed=1
  metrics_before=$(wc -l < "$metrics_file" | tr -d ' ')
fi

mkdir -p "$tmpdir"
printf 'known content\n' > "$tmpdir/foo.txt"

cat > "$tmpdir/mock-wrapper.sh" <<'EOF_MOCK'
#!/usr/bin/env bash
set -euo pipefail
{
  echo "REVHARNESS_PARALLEL_QUIESCE=${REVHARNESS_PARALLEL_QUIESCE-}"
  echo "REVHARNESS_TASK_ID=${REVHARNESS_TASK_ID-}"
} > "$MOCK_TMPDIR/wrapper-env.log"
cat > "$MOCK_TMPDIR/wrapper-stdin.log"
printf '%s\n' "$*" > "$MOCK_TMPDIR/wrapper-argv.log"
exit 0
EOF_MOCK
chmod +x "$tmpdir/mock-wrapper.sh"

set +e
MOCK_TMPDIR="$tmpdir" bash scripts/safe-dispatch.sh \
  --task-id test-001 \
  --owner-tokens "$tmpdir/foo.txt" \
  --wrapper "$tmpdir/mock-wrapper.sh" \
  --wrapper-args "" \
  -- "test prompt body"
dispatch_code=$?
set -e

assert_eq "$dispatch_code" "0" "safe-dispatch exits 0 when wrapper exits 0"
assert_file ".agent/state/locks/test-001.before.sha256" "before snapshot file exists"
assert_contains ".agent/state/locks/test-001.before.sha256" "$tmpdir/foo.txt" "before snapshot contains owner-token path"
assert_file ".agent/state/locks/test-001.after.sha256" "after snapshot file exists"

last_line=""
if [ -f "$metrics_file" ]; then
  last_line=$(tail -n 1 "$metrics_file")
fi
if printf '%s\n' "$last_line" | grep -Fq '"task_id":"test-001"' &&
  printf '%s\n' "$last_line" | grep -Fq '"event":"safe_dispatch"' &&
  printf '%s\n' "$last_line" | grep -Fq '"exit_code":0'; then
  pass "dispatch_events.jsonl last line contains task_id, event, and exit_code"
else
  fail "dispatch_events.jsonl last line contains task_id, event, and exit_code"
fi

assert_contains "$tmpdir/wrapper-env.log" "REVHARNESS_PARALLEL_QUIESCE=1" "PARALLEL_QUIESCE propagated to wrapper"
assert_contains "$tmpdir/wrapper-env.log" "REVHARNESS_TASK_ID=test-001" "REVHARNESS_TASK_ID propagated to wrapper"
assert_contains "$tmpdir/wrapper-stdin.log" "test prompt body" "prompt passed to wrapper via stdin"

cat > "$tmpdir/mock-wrapper-42.sh" <<'EOF_MOCK_42'
#!/usr/bin/env bash
cat >/dev/null
exit 42
EOF_MOCK_42
chmod +x "$tmpdir/mock-wrapper-42.sh"

set +e
bash scripts/safe-dispatch.sh \
  --task-id test-042 \
  --owner-tokens "$tmpdir/foo.txt" \
  --wrapper "$tmpdir/mock-wrapper-42.sh" \
  --wrapper-args "" \
  -- "test prompt body"
dispatch_42_code=$?
set -e

assert_eq "$dispatch_42_code" "42" "safe-dispatch propagates wrapper exit code 42"

if [ "$failures" -ne 0 ]; then
  echo "$failures TEST(S) FAILED"
  exit 1
fi

echo "ALL TESTS PASSED"
