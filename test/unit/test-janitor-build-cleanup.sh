#!/usr/bin/env bash
set -euo pipefail

script_dir() {
  local src="${BASH_SOURCE[0]}"
  case "$src" in
    */*) (cd "${src%/*}" && pwd -P) ;;
    *) pwd -P ;;
  esac
}

TEST_DIR="$(script_dir)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd -P)"
JANITOR="${REPO_ROOT}/scripts/rev-harness-janitor.sh"
TMP_ROOT="$(mktemp -d)"

trap 'set +e; /bin/rm -rf "$TMP_ROOT"; true' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$JANITOR" ]] || fail "janitor missing"
bash -n "$JANITOR" || fail "janitor syntax check failed"

ROOT=""
HOME_DIR=""

new_sandbox() {
  local name="$1"
  ROOT="$TMP_ROOT/$name/project"
  HOME_DIR="$TMP_ROOT/$name/home"
  mkdir -p "$ROOT" "$HOME_DIR"
}

old_touch() {
  local path="$1"
  find "$path" -exec touch -t 202001010000 {} + 2>/dev/null || true
  touch -t 202001010000 "$path"
}

# The Node semantic backend tree was removed (de-overkill S3-B3); the janitor no
# longer cleans its node_modules/dist. Only the Rust target + cargo cache
# build-artifact targets remain.
populate_old_targets() {
  mkdir -p \
    "$ROOT/harness-rust/target/debug" \
    "$ROOT/harness-rust/target/incremental" \
    "$HOME_DIR/.cargo/registry/cache"
  printf 'debug\n' > "$ROOT/harness-rust/target/debug/old.o"
  printf 'incr\n' > "$ROOT/harness-rust/target/incremental/old.bin"
  printf 'crate\n' > "$HOME_DIR/.cargo/registry/cache/old.crate"
  old_touch "$ROOT/harness-rust/target/debug"
  old_touch "$ROOT/harness-rust/target/incremental"
  old_touch "$HOME_DIR/.cargo/registry/cache"
}

run_janitor() {
  HOME="$HOME_DIR" \
  REVHARNESS_JANITOR_PROJECT_ROOT="$ROOT" \
  REVHARNESS_PARALLEL_QUIESCE="${REVHARNESS_PARALLEL_QUIESCE_CASE:-0}" \
    "$JANITOR" build-cleanup "$@"
}

metrics_file() {
  printf '%s\n' "$ROOT/.agent/metrics/build_cleanup.jsonl"
}

hints_file() {
  printf '%s\n' "$ROOT/.agent/metrics/build_cleanup_hints.jsonl"
}

assert_old_targets_exist() {
  [[ -d "$ROOT/harness-rust/target/debug" ]] || fail "debug target missing"
  [[ -d "$ROOT/harness-rust/target/incremental" ]] || fail "incremental target missing"
  [[ -d "$HOME_DIR/.cargo/registry/cache" ]] || fail "cargo cache missing"
}

assert_old_targets_deleted() {
  [[ ! -e "$ROOT/harness-rust/target/debug" ]] || fail "debug target remained"
  [[ ! -e "$ROOT/harness-rust/target/incremental" ]] || fail "incremental target remained"
  [[ ! -e "$HOME_DIR/.cargo/registry/cache" ]] || fail "cargo cache remained"
}

# 1. Default dry-run: no deletes, JSONL mode=dry_run.
new_sandbox "case-1"
populate_old_targets
run_janitor >/dev/null
assert_old_targets_exist
jq -e '.mode == "dry_run" and .event == "build_cleanup"' "$(metrics_file)" >/dev/null \
  || fail "dry-run JSONL row missing mode/event"
echo "PASS: 1 dry-run default emitted JSONL and preserved targets"

# 2. Apply without acknowledgement exits 2 and does not delete.
new_sandbox "case-2"
populate_old_targets
set +e
run_janitor --apply >"$TMP_ROOT/case-2.out" 2>"$TMP_ROOT/case-2.err"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "apply without ack rc=$rc"
assert_old_targets_exist
echo "PASS: 2 apply without ack refused without deletes"

# 3. Apply with acknowledgement deletes old targets and preserves protected paths.
new_sandbox "case-3"
populate_old_targets
mkdir -p "$ROOT/harness-rust/target/release/latest" "$ROOT/harness-rust/target/criterion"
printf 'release\n' > "$ROOT/harness-rust/target/release/latest/bin"
printf 'bench\n' > "$ROOT/harness-rust/target/criterion/history"
old_touch "$ROOT/harness-rust/target/release/latest"
old_touch "$ROOT/harness-rust/target/criterion"
run_janitor --apply --ack-rebuild-cost >/dev/null
assert_old_targets_deleted
[[ -d "$ROOT/harness-rust/target/release/latest" ]] || fail "release latest deleted"
[[ -d "$ROOT/harness-rust/target/criterion" ]] || fail "criterion deleted"
echo "PASS: 3 apply deleted old targets and preserved protected paths"

# 4. mtime <24h shield protects a recent target under apply.
new_sandbox "case-4"
populate_old_targets
touch "$ROOT/harness-rust/target/debug/recent.o"
touch "$ROOT/harness-rust/target/debug"
run_janitor --apply --ack-rebuild-cost >/dev/null
[[ -d "$ROOT/harness-rust/target/debug" ]] || fail "recent debug target deleted"
[[ ! -e "$ROOT/harness-rust/target/incremental" ]] || fail "old incremental target remained"
echo "PASS: 4 recent mtime shield preserved active target"

# 5. Newest target/release/latest remains even when old cleanup runs.
new_sandbox "case-5"
populate_old_targets
mkdir -p "$ROOT/harness-rust/target/release/old" "$ROOT/harness-rust/target/release/latest"
printf 'old\n' > "$ROOT/harness-rust/target/release/old/bin"
printf 'latest\n' > "$ROOT/harness-rust/target/release/latest/bin"
old_touch "$ROOT/harness-rust/target/release/old"
touch "$ROOT/harness-rust/target/release/latest/bin" "$ROOT/harness-rust/target/release/latest"
run_janitor --apply --ack-rebuild-cost >/dev/null
[[ -d "$ROOT/harness-rust/target/release/latest" ]] || fail "newest release latest deleted"
echo "PASS: 5 target release latest preserved"

# 6. PARALLEL_QUIESCE skips before metrics emission.
new_sandbox "case-6"
populate_old_targets
set +e
REVHARNESS_PARALLEL_QUIESCE_CASE=1 run_janitor >"$TMP_ROOT/case-6.out" 2>"$TMP_ROOT/case-6.err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "quiesce rc=$rc"
grep -Fq 'skip: PARALLEL_QUIESCE active' "$TMP_ROOT/case-6.err" \
  || fail "quiesce skip message missing"
[[ ! -e "$(metrics_file)" ]] || fail "quiesce emitted build_cleanup JSONL"
assert_old_targets_exist
echo "PASS: 6 parallel quiesce no-op emitted no JSONL"

# 7. JSONL schema conformance.
new_sandbox "case-7"
populate_old_targets
run_janitor --json >"$TMP_ROOT/case-7.json"
jq -e '
  .schema_version == "rev-harness-build-cleanup/v1"
  and .ts
  and .event == "build_cleanup"
  and .mode == "dry_run"
  and (.target_count | type == "number")
  and (.freed_bytes | type == "number")
  and (.protected_skipped | type == "number")
  and (.age_threshold_days | type == "number")
  and has("ts_oldest_deleted")
' "$TMP_ROOT/case-7.json" >/dev/null || fail "schema conformance failed"
echo "PASS: 7 JSONL schema contains required keys"

# 8. Stop-hook opt-in writes hints only.
new_sandbox "case-8"
populate_old_targets
HOME="$HOME_DIR" \
REVHARNESS_JANITOR_PROJECT_ROOT="$ROOT" \
REVHARNESS_PARALLEL_QUIESCE=0 \
REVHARNESS_BUILD_CLEANUP_ON_STOP=1 \
  "$JANITOR" build-cleanup --json >"$TMP_ROOT/case-8.json"
[[ -s "$(hints_file)" ]] || fail "hint JSONL not emitted"
[[ ! -e "$(metrics_file)" ]] || fail "regular build_cleanup JSONL emitted during stop hint"
jq -e '.schema_version == "rev-harness-build-cleanup/v1" and .mode == "dry_run"' \
  "$(hints_file)" >/dev/null || fail "hint row schema/mode invalid"
assert_old_targets_exist
echo "PASS: 8 stop-hook opt-in emitted hints only"

echo "PASS: janitor build-cleanup lifecycle"
