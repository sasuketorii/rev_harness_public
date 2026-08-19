#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: review-queue-backend-smoke.sh --no-semantic'
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

skip_prereq() {
  printf 'PREREQ: %s\n' "$*" >&2
  exit 3
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "expected file missing: $path"
}

require_jq() {
  command -v jq >/dev/null 2>&1 || skip_prereq "jq is required"
}

write_hostile_binary() {
  local dir="$1"
  local name="$2"
  local marker="$dir/${name}.called"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf ': > %q\n' "$marker"
    printf 'printf %q >&2\n' "unexpected ${name} invocation"
    printf '%s\n' 'exit 99'
  } > "$dir/$name"
  chmod +x "$dir/$name"
}

assert_not_called() {
  local dir="$1"
  local name="$2"
  [[ ! -e "$dir/${name}.called" ]] || fail "unexpected ${name} invocation"
}

expect_queue_failure() {
  local label="$1"
  local stdout_path="$2"
  local stderr_path="$3"
  shift 3

  if "$@" >"$stdout_path" 2>"$stderr_path"; then
    fail "$label should fail closed"
  fi
}

NO_SEMANTIC=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-semantic)
      NO_SEMANTIC=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$NO_SEMANTIC" -eq 1 ]] || {
  usage >&2
  exit 2
}
require_jq

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QUEUE="$REPO_ROOT/scripts/review-queue.sh"
[[ -x "$QUEUE" ]] || fail "queue helper must be executable"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/review_queue_backend_smoke.XXXXXX")"
trap '/bin/rm -rf "$tmpdir"' EXIT

hostile_bin="$tmpdir/hostile-bin"
state_dir="$tmpdir/state"
metrics="$tmpdir/review_queue_events.jsonl"
export_json="$tmpdir/review_queue.json"
lease_json="$tmpdir/lease.json"
mkdir -p "$hostile_bin"
write_hostile_binary "$hostile_bin" cargo
write_hostile_binary "$hostile_bin" semantic-mcp

queue_env=(
  REVHARNESS_REVIEW_QUEUE_BACKEND=core
  REVHARNESS_REVIEW_QUEUE_STATE_DIR="$state_dir"
  REVHARNESS_REVIEW_QUEUE_METRICS="$metrics"
  PATH="$hostile_bin:$PATH"
)

env "${queue_env[@]}" "$QUEUE" enqueue \
  --repo-root "$REPO_ROOT" \
  --file-path src/p2_queue_a.rs \
  --source smoke \
  --export-json "$export_json" >/dev/null
env "${queue_env[@]}" "$QUEUE" enqueue \
  --repo-root "$REPO_ROOT" \
  --file-path src/p2_queue_b.rs \
  --source smoke >/dev/null
duplicate_output="$(
  env "${queue_env[@]}" "$QUEUE" enqueue \
    --repo-root "$REPO_ROOT" \
    --file-path ./src/p2_queue_a.rs \
    --source smoke
)"

assert_not_called "$hostile_bin" cargo
assert_not_called "$hostile_bin" semantic-mcp
require_file "$state_dir/events.jsonl"
require_file "$export_json"
require_file "$metrics"

[[ "$(jq -r '.duplicate' <<< "$duplicate_output")" == "true" ]] \
  || fail "duplicate enqueue should return duplicate=true"
[[ "$(jq -r '.pending_count' "$export_json")" == "1" ]] \
  || fail "compatibility export should preserve pending_count after first enqueue"
[[ "$(jq -s '[.[] | select(.op == "enqueue")] | length' "$state_dir/events.jsonl")" == "2" ]] \
  || fail "durable JSONL should contain two non-duplicate enqueue events"
jq -e 'select(.event == "enqueue-ok" and .file_path == "src/p2_queue_a.rs")' "$metrics" >/dev/null \
  || fail "enqueue-ok metric missing"
jq -e 'select(.event == "enqueue-skipped" and .reason == "duplicate-pending")' "$metrics" >/dev/null \
  || fail "enqueue-skipped duplicate metric missing"

env "${queue_env[@]}" "$QUEUE" lease \
  --repo-root "$REPO_ROOT" \
  --lease-run-id p2-smoke \
  --lease-seconds 60 > "$lease_json"
lease_owner="$(jq -r '.lease_owner' "$lease_json")"
[[ -n "$lease_owner" && "$lease_owner" != "null" ]] || fail "lease_owner should be present"
[[ "$(jq -r '.leased_count' "$lease_json")" == "2" ]] || fail "lease should cover two queued files"

leased_reenqueue_json="$tmpdir/leased_reenqueue.json"
env "${queue_env[@]}" "$QUEUE" enqueue \
  --repo-root "$REPO_ROOT" \
  --file-path src/p2_queue_a.rs \
  --source smoke > "$leased_reenqueue_json"
[[ "$(jq -r '.queued' "$leased_reenqueue_json")" == "true" ]] \
  || fail "leased re-enqueue should record a fresh enqueue event"
[[ "$(jq -r '.duplicate' "$leased_reenqueue_json")" == "false" ]] \
  || fail "leased re-enqueue should not report duplicate pending"
[[ "$(jq -r '.item.queue_state' "$leased_reenqueue_json")" == "leased" ]] \
  || fail "leased re-enqueue should preserve leased state"
[[ "$(jq -r '.item.lease_owner' "$leased_reenqueue_json")" == "$lease_owner" ]] \
  || fail "leased re-enqueue should preserve lease_owner"
[[ "$(jq -r '.item | has("lease_run_id")' "$leased_reenqueue_json")" == "false" ]] \
  || fail "public item object should omit legacy-absent lease_run_id"
env "${queue_env[@]}" "$QUEUE" export-json \
  --repo-root "$REPO_ROOT" \
  --output "$tmpdir/after_leased_reenqueue.json" >/dev/null
jq -e --arg owner "$lease_owner" '.items[] | select(.file_path == "src/p2_queue_a.rs" and .queue_state == "leased" and .lease_owner == $owner)' \
  "$tmpdir/after_leased_reenqueue.json" >/dev/null \
  || fail "intermediate export should show leased ownership preserved"
jq -e '.items[] | select(has("lease_run_id"))' "$tmpdir/after_leased_reenqueue.json" >/dev/null \
  && fail "export item objects should omit legacy-absent lease_run_id"

expect_queue_failure \
  "absolute expected file" \
  "$tmpdir/absolute_expected.stdout" \
  "$tmpdir/absolute_expected.stderr" \
  env "${queue_env[@]}" "$QUEUE" complete \
    --repo-root "$REPO_ROOT" \
    --lease-owner "$lease_owner" \
    --lease-run-id p2-smoke \
    --expected-file "$REPO_ROOT/src/p2_queue_a.rs"
grep -q "file_path must be repo-relative" "$tmpdir/absolute_expected.stderr" \
  || fail "absolute expected file should be rejected fail-closed"

expect_queue_failure \
  "omitted run id should not wildcard" \
  "$tmpdir/without_run_id.stdout" \
  "$tmpdir/without_run_id.stderr" \
  env "${queue_env[@]}" "$QUEUE" complete \
    --repo-root "$REPO_ROOT" \
    --lease-owner "$lease_owner" \
    --expected-file src/p2_queue_a.rs
grep -q "expected files are not all leased by owner" "$tmpdir/without_run_id.stderr" \
  || fail "omitted run id should not match run-scoped lease"

env "${queue_env[@]}" "$QUEUE" complete \
  --repo-root "$REPO_ROOT" \
  --lease-owner "$lease_owner" \
  --lease-run-id p2-smoke \
  --expected-file ./src/p2_queue_a.rs \
  --expected-file src/p2_queue_b.rs > "$tmpdir/complete.json"
[[ "$(jq -r '.completed_count' "$tmpdir/complete.json")" == "2" ]] || fail "complete should close both leased files"
jq -e '.items[] | select(has("lease_run_id"))' "$tmpdir/complete.json" >/dev/null \
  && fail "complete item objects should omit legacy-absent lease_run_id"
env "${queue_env[@]}" "$QUEUE" export-json \
  --repo-root "$REPO_ROOT" \
  --output "$tmpdir/after_complete.json" >/dev/null
[[ "$(jq -r '.pending_review' "$tmpdir/after_complete.json")" == "false" ]] \
  || fail "export after complete should have no pending review"

empty_lease_json="$tmpdir/empty_lease.json"
env "${queue_env[@]}" "$QUEUE" lease \
  --repo-root "$REPO_ROOT" \
  --lease-run-id empty-run \
  --lease-seconds 60 > "$empty_lease_json"
[[ "$(jq -r '.leased_count' "$empty_lease_json")" == "0" ]] \
  || fail "empty lease should lease zero files"
[[ "$(jq -r '.lease_run_id' "$empty_lease_json")" == "empty-run" ]] \
  || fail "empty lease should echo requested lease_run_id"

env "${queue_env[@]}" "$QUEUE" enqueue \
  --repo-root "$REPO_ROOT" \
  --file-path src/p2_requeue.rs \
  --source smoke >/dev/null
env "${queue_env[@]}" "$QUEUE" lease \
  --repo-root "$REPO_ROOT" \
  --lease-run-id p2-requeue \
  --lease-seconds 60 > "$tmpdir/requeue_lease.json"
requeue_owner="$(jq -r '.lease_owner' "$tmpdir/requeue_lease.json")"
env "${queue_env[@]}" "$QUEUE" requeue \
  --repo-root "$REPO_ROOT" \
  --lease-owner "$requeue_owner" \
  --lease-run-id p2-requeue \
  --expected-file ./src/p2_requeue.rs \
  --error retry > "$tmpdir/requeue.json"
[[ "$(jq -r '.requeued_count' "$tmpdir/requeue.json")" == "1" ]] \
  || fail "requeue should normalize ./ expected file"
jq -e '.items[] | select(has("lease_run_id"))' "$tmpdir/requeue.json" >/dev/null \
  && fail "requeue item objects should omit legacy-absent lease_run_id"

env "${queue_env[@]}" "$QUEUE" enqueue \
  --repo-root "$REPO_ROOT" \
  --file-path src/p2_no_run.rs \
  --source smoke >/dev/null
project_id="$(jq -r 'select(.project_id != null) | .project_id' "$state_dir/events.jsonl" | tail -n 1)"
now="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
jq -nc \
  --arg project_id "$project_id" \
  --arg owner "lease-norun" \
  --arg leased_at "$now" \
  --argjson items '["src/p2_no_run.rs"]' \
  '{schema_version:1, op:"lease", project_id:$project_id, lease_owner:$owner, lease_run_id:null, leased_at:$leased_at, lease_expires_at:"2099-01-01T00:00:00Z", items:$items}' \
  >> "$state_dir/events.jsonl"
env "${queue_env[@]}" "$QUEUE" complete \
  --repo-root "$REPO_ROOT" \
  --lease-owner lease-norun \
  --expected-file src/p2_no_run.rs > "$tmpdir/no_run_complete.json"
[[ "$(jq -r '.completed_count' "$tmpdir/no_run_complete.json")" == "1" ]] \
  || fail "complete without run id should match no-run lease"

expect_queue_failure \
  "invalid source" \
  "$tmpdir/invalid_source.stdout" \
  "$tmpdir/invalid_source.stderr" \
  env "${queue_env[@]}" "$QUEUE" enqueue \
    --repo-root "$REPO_ROOT" \
    --file-path src/invalid_source.rs \
    --source bad/source
grep -q "source must contain only" "$tmpdir/invalid_source.stderr" \
  || fail "invalid source should use fail-closed validation error"

expect_queue_failure \
  "invalid lease run id" \
  "$tmpdir/invalid_run.stdout" \
  "$tmpdir/invalid_run.stderr" \
  env "${queue_env[@]}" "$QUEUE" lease \
    --repo-root "$REPO_ROOT" \
    --lease-run-id bad/source \
    --lease-seconds 60
grep -q "lease_run_id must contain only" "$tmpdir/invalid_run.stderr" \
  || fail "invalid lease run id should use fail-closed validation error"

expect_queue_failure \
  "invalid lease owner" \
  "$tmpdir/invalid_owner.stdout" \
  "$tmpdir/invalid_owner.stderr" \
  env "${queue_env[@]}" "$QUEUE" complete \
    --repo-root "$REPO_ROOT" \
    --lease-owner bad/source \
    --lease-run-id p2-smoke \
    --expected-file src/p2_queue_a.rs
grep -q "lease_owner must contain only" "$tmpdir/invalid_owner.stderr" \
  || fail "invalid lease owner should use fail-closed validation error"

mkdir -p "$state_dir/queue.lock.d"
printf '%s\n' '999999' > "$state_dir/queue.lock.d/pid"
touch -t 200001010000 "$state_dir/queue.lock.d/pid" "$state_dir/queue.lock.d"
env "${queue_env[@]}" "$QUEUE" enqueue \
  --repo-root "$REPO_ROOT" \
  --file-path src/stale_lock_recovered.rs \
  --source smoke >/dev/null
jq -e 'select(.event == "lock-reclaimed" and .backend == "core" and .reason == "stale-lock-reclaimed")' "$metrics" >/dev/null \
  || fail "stale lock recovery metric missing"
[[ ! -d "$state_dir/queue.lock.d" ]] \
  || fail "lock dir should be released after stale-lock recovery enqueue"

unwritable_parent="$tmpdir/unwritable"
mkdir -p "$unwritable_parent"
chmod 500 "$unwritable_parent"
expect_queue_failure \
  "unwritable state dir" \
  "$tmpdir/fail_closed.stdout" \
  "$tmpdir/fail_closed.stderr" \
  env \
    REVHARNESS_REVIEW_QUEUE_BACKEND=core \
    REVHARNESS_REVIEW_QUEUE_STATE_DIR="$unwritable_parent/state" \
    REVHARNESS_REVIEW_QUEUE_METRICS="$metrics" \
    PATH="$hostile_bin:$PATH" \
    "$QUEUE" enqueue --repo-root "$REPO_ROOT" --file-path src/fail_closed.rs --source smoke
chmod 700 "$unwritable_parent"
jq -e 'select(.event == "backend-unavailable" and .backend == "core" and .fail_behavior == "fail-closed")' "$metrics" >/dev/null \
  || fail "backend-unavailable fail-closed metric missing"

if env \
  REVHARNESS_REVIEW_QUEUE_BACKEND=/tmp/bad/source \
  REVHARNESS_REVIEW_QUEUE_STATE_DIR="$state_dir" \
  REVHARNESS_REVIEW_QUEUE_METRICS="$metrics" \
  PATH="$hostile_bin:$PATH" \
  "$QUEUE" enqueue --repo-root "$REPO_ROOT" --file-path src/unknown_backend.rs --source smoke \
  >"$tmpdir/unknown.stdout" 2>"$tmpdir/unknown.stderr"; then
  fail "unknown backend should fail closed"
fi
jq -e 'select(.event == "backend-unavailable" and .backend == "unknown" and .reason == "unknown-backend:tmpbadsource")' "$metrics" >/dev/null \
  || fail "unknown backend metric missing"
jq -e 'select(.event == "backend-unavailable" and .backend == "unknown" and (.reason | contains("/") or contains("\\")))' "$metrics" >/dev/null \
  && fail "unknown backend metric should not contain path separators"

assert_not_called "$hostile_bin" cargo
assert_not_called "$hostile_bin" semantic-mcp

printf 'PASS: review_queue_backend_smoke --no-semantic\n'
