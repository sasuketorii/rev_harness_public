#!/usr/bin/env bash
set -euo pipefail

# Exit codes:
# 0 pass, 1 assertion failure, 2 usage error, 3 environment failure.

usage() {
  printf '%s\n' \
    'Usage:' \
    '  hook-fail-behavior-test.sh --post-tool-use --no-semantic'
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  usage >&2
  exit 2
}

env_fail() {
  printf 'ENV: %s\n' "$*" >&2
  exit 3
}

count_lines() {
  local file_path="$1"
  if [[ ! -f "$file_path" ]]; then
    printf '0\n'
    return 0
  fi
  wc -l < "$file_path" | tr -d '[:space:]'
}

now_ms() {
  /usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

write_hostile_binary() {
  local bin_dir="$1"
  local binary_name="$2"
  local marker_path="${bin_dir}/${binary_name}.marker"

  mkdir -p "$bin_dir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'echo %q >&2\n' "hostile ${binary_name} executed"
    printf ': > %q\n' "$marker_path"
    printf '%s\n' 'exit 99'
  } > "$bin_dir/$binary_name"
  chmod +x "$bin_dir/$binary_name"
}

assert_hostile_not_executed() {
  local bin_dir="$1"
  local binary_name="$2"
  [[ ! -e "$bin_dir/${binary_name}.marker" ]] \
    || fail "hostile ${binary_name} binary executed unexpectedly"
}

assert_jsonl_selects() {
  local filter="$1"
  local file_path="$2"
  jq -e "$filter" "$file_path" >/dev/null || fail "jq filter did not match $file_path: $filter"
}

POST_TOOL_USE=0
NO_SEMANTIC=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --post-tool-use)
      POST_TOOL_USE=1
      shift
      ;;
    --no-semantic)
      NO_SEMANTIC=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error
      ;;
  esac
done

[[ "$POST_TOOL_USE" -eq 1 && "$NO_SEMANTIC" -eq 1 ]] || usage_error

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOKS=(
  ".claude/hooks/codex-review-hook.sh"
  ".codex/hooks/codex-review-hook.sh"
)
for hook_rel in "${HOOKS[@]}"; do
  [[ -x "$REPO_ROOT/$hook_rel" ]] \
    || env_fail "hook entrypoint is missing or not executable: $hook_rel"
done
# The queue helper is scripts/review-queue.sh (renamed from the former
# semantic-review-queue.sh; the transitional shim at the old path has been
# removed). The repointed hooks call review-queue.sh, so the fixture below
# must stage and exercise review-queue.sh.
[[ -x "$REPO_ROOT/scripts/review-queue.sh" ]] \
  || env_fail "queue helper is missing or not executable"
command -v jq >/dev/null 2>&1 || env_fail "jq is required"
[[ -x /usr/bin/perl ]] || env_fail "/usr/bin/perl is required for timing"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/hook_fail_behavior.XXXXXX")"
trap '/bin/rm -rf "$tmpdir"' EXIT

# Run the full fail-behavior battery against each hook. A fresh fixture repo is
# built per hook iteration so the second hook's enqueue is never masked by the
# first hook's pending dedupe in the shared events.jsonl.
docs_elapsed_ms=""
for hook_rel in "${HOOKS[@]}"; do
hook_slug="$(printf '%s' "$hook_rel" | tr '/.' '__')"
hook_repo="$tmpdir/hook_repo_${hook_slug}"
hostile_dir="$tmpdir/hostile-bin_${hook_slug}"
docs_stdout="$tmpdir/${hook_slug}.docs.stdout"
docs_stderr="$tmpdir/${hook_slug}.docs.stderr"
docs_warm_stdout="$tmpdir/${hook_slug}.docs-warm.stdout"
docs_warm_stderr="$tmpdir/${hook_slug}.docs-warm.stderr"
code_stdout="$tmpdir/${hook_slug}.code.stdout"
code_stderr="$tmpdir/${hook_slug}.code.stderr"
inherited_backend_stdout="$tmpdir/${hook_slug}.inherited-removed-backend.stdout"
inherited_backend_stderr="$tmpdir/${hook_slug}.inherited-removed-backend.stderr"
outside_stdout="$tmpdir/${hook_slug}.outside.stdout"
outside_stderr="$tmpdir/${hook_slug}.outside.stderr"
bad_pid_stdout="$tmpdir/${hook_slug}.bad-project-id.stdout"
bad_pid_stderr="$tmpdir/${hook_slug}.bad-project-id.stderr"
missing_stdout="$tmpdir/${hook_slug}.missing-helper.stdout"
missing_stderr="$tmpdir/${hook_slug}.missing-helper.stderr"
noexec_stdout="$tmpdir/${hook_slug}.noexec-helper.stdout"
noexec_stderr="$tmpdir/${hook_slug}.noexec-helper.stderr"
docs_start=""
docs_end=""

# hook_rel is the in-repo path; the fixture mirrors that same directory layout
# so each hook resolves REPO_ROOT relative to its own location.
hook_dir_rel="$(dirname "$hook_rel")"
mkdir -p \
  "$hook_repo/$hook_dir_rel" \
  "$hook_repo/.claude/tmp" \
  "$hook_repo/.shared" \
  "$hook_repo/scripts" \
  "$hook_repo/docs" \
  "$hook_repo/src"

/bin/cp -p "$REPO_ROOT/$hook_rel" "$hook_repo/$hook_rel"
/bin/cp -p "$REPO_ROOT/scripts/review-queue.sh" "$hook_repo/scripts/review-queue.sh"
# S6 removed scripts/resolve-semantic-project-id.sh; review-queue.sh now resolves
# project_id directly via the kept non-semantic scripts/project-id.sh core resolver,
# so the fixture only needs to mirror that helper.
/bin/cp -p "$REPO_ROOT/scripts/project-id.sh" "$hook_repo/scripts/project-id.sh"
/bin/cp -p "$REPO_ROOT/.shared/project_id" "$hook_repo/.shared/project_id"
: > "$hook_repo/docs/readme.md"
: > "$hook_repo/src/main.rs"
: > "$hook_repo/src/lib.rs"
: > "$hook_repo/src/other.rs"

write_hostile_binary "$hostile_dir" cargo
write_hostile_binary "$hostile_dir" semantic-mcp
write_hostile_binary "$hostile_dir" tree-sitter-index

state_jsonl="$hook_repo/.agent/state/review_queue/events.jsonl"
metrics_jsonl="$hook_repo/.agent/metrics/review_queue_events.jsonl"
export_json="$hook_repo/.claude/tmp/review_queue.json"

printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/docs/readme.md" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
    REVHARNESS_REVIEW_QUEUE_BACKEND=core \
      "./$hook_rel"
  ) >"$docs_warm_stdout" 2>"$docs_warm_stderr" \
  || fail "docs file hook run should skip cleanly"
[[ ! -s "$docs_warm_stdout" ]] || fail "docs warm hook run should stay silent on stdout"
[[ ! -f "$state_jsonl" ]] || fail "docs warm hook run should not enqueue"

docs_start="$(now_ms)"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/docs/readme.md" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
    REVHARNESS_REVIEW_QUEUE_BACKEND=core \
      "./$hook_rel"
  ) >"$docs_stdout" 2>"$docs_stderr" \
  || fail "docs file timed hook run should skip cleanly"
docs_end="$(now_ms)"
docs_elapsed_ms="$(( docs_end - docs_start ))"

[[ ! -s "$docs_stdout" ]] || fail "docs timed hook run should stay silent on stdout"
[[ ! -f "$state_jsonl" ]] || fail "docs timed hook run should not enqueue"
assert_hostile_not_executed "$hostile_dir" cargo
assert_hostile_not_executed "$hostile_dir" semantic-mcp
assert_hostile_not_executed "$hostile_dir" tree-sitter-index

printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/main.rs" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
    unset REVHARNESS_REVIEW_QUEUE_BACKEND
    "./$hook_rel"
  ) >"$code_stdout" 2>"$code_stderr" \
  || fail "code file hook run should enqueue through the core backend"

[[ ! -s "$code_stdout" ]] || fail "code hook run should stay silent on stdout"
[[ -f "$state_jsonl" ]] || fail "code hook run did not create core JSONL state"
assert_jsonl_selects 'select(.op == "enqueue" and .file_path == "src/main.rs" and .source == "hook")' "$state_jsonl"
[[ -f "$export_json" ]] || fail "code hook run did not create compatibility export"
jq -e '.pending_review == true and (.changed_files | index("src/main.rs")) != null' "$export_json" >/dev/null \
  || fail "compatibility export does not include src/main.rs"
[[ -f "$metrics_jsonl" ]] || fail "code hook run did not create metrics"
assert_jsonl_selects 'select(.event == "enqueue-ok" and .backend == "core" and .file_path == "src/main.rs")' "$metrics_jsonl"
assert_hostile_not_executed "$hostile_dir" cargo
assert_hostile_not_executed "$hostile_dir" semantic-mcp
assert_hostile_not_executed "$hostile_dir" tree-sitter-index

# The only live review-queue backend is `core`; any non-core value of
# REVHARNESS_REVIEW_QUEUE_BACKEND
# now fails closed in the queue helper. This case proves the hook still pins
# core ingress by sanitizing a hostile *inherited* backend value (`semantic`):
# the hook must strip it so the .rs edit still enqueues through the core
# backend instead of reaching the fail-closed unknown-backend path or any
# hostile cargo/semantic-mcp/tree-sitter stub.
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/other.rs" \
  | (
    cd "$hook_repo"
    export REVHARNESS_REVIEW_QUEUE_BACKEND=semantic
    PATH="$hostile_dir:$PATH" \
      "./$hook_rel"
  ) >"$inherited_backend_stdout" 2>"$inherited_backend_stderr" \
  || fail "inherited removed backend hook run should enqueue through the pinned core backend"

[[ ! -s "$inherited_backend_stdout" ]] || fail "inherited removed-backend hook run should stay silent on stdout"
assert_jsonl_selects 'select(.op == "enqueue" and .file_path == "src/other.rs" and .source == "hook")' "$state_jsonl"
assert_jsonl_selects 'select(.event == "enqueue-ok" and .backend == "core" and .file_path == "src/other.rs")' "$metrics_jsonl"
assert_hostile_not_executed "$hostile_dir" cargo
assert_hostile_not_executed "$hostile_dir" semantic-mcp
assert_hostile_not_executed "$hostile_dir" tree-sitter-index

# --- Security: trusted-jq resolution + fail-closed parse -------------------
# These cases prove the hook resolves jq for its OWN input parsing ONLY from
# trusted absolute dirs (never from inherited PATH ordering or the JQ_BIN env)
# and never silently skips a real code edit when a hostile/broken jq is
# presented. The downstream queue helper (scripts/review-queue.sh) is
# now ALSO hardened to resolve jq from a trusted allowlist, so a hostile PATH jq
# can never execute end-to-end (hook -> queue helper). Case 1 asserts that
# end-to-end: the hostile jq marker stays ABSENT and the .rs edit still
# enqueues via trusted jq.
jq_hostile_path_stdout="$tmpdir/${hook_slug}.jq-hostile-path.stdout"
jq_hostile_path_stderr="$tmpdir/${hook_slug}.jq-hostile-path.stderr"
jq_hostile_env_stdout="$tmpdir/${hook_slug}.jq-hostile-env.stdout"
jq_hostile_env_stderr="$tmpdir/${hook_slug}.jq-hostile-env.stderr"
jq_broken_stdout="$tmpdir/${hook_slug}.jq-broken.stdout"
jq_broken_stderr="$tmpdir/${hook_slug}.jq-broken.stderr"

# Case 1: hostile `jq` earliest on PATH that exits non-zero / emits garbage and
# drops a marker when run, on a .rs payload. The hostile jq is poisoned on PATH
# for the ENTIRE invocation, so it would be consulted by the hook AND by the
# downstream queue helper if either trusted bare `jq`. Because BOTH now resolve
# jq only from trusted absolute dirs:
#   (a) the hostile PATH jq is NEVER executed end-to-end (its marker stays
#       ABSENT), and
#   (b) the .rs edit still enqueues via trusted jq (rc 0, state row created).
# The pre-existing fail-OPEN bug would have swallowed a broken jq with `|| true`
# and silently skipped the enqueue; the prior partial fix (hook-only) could
# still run the hostile jq inside the queue helper and fail closed. This case
# now proves the full hardening: no hostile execution, no silent skip.
write_hostile_binary "$hostile_dir" jq
: > "$hook_repo/src/jq_path_case.rs"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/jq_path_case.rs" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
    REVHARNESS_REVIEW_QUEUE_BACKEND=core \
      "./$hook_rel"
  ) >"$jq_hostile_path_stdout" 2>"$jq_hostile_path_stderr" \
  || fail "hostile-PATH-jq .rs edit should enqueue via trusted jq (rc 0), not skip or fail"
# The hostile jq must never have executed anywhere in the hook -> queue-helper
# chain: if it had, its marker would exist (and rc would have been non-zero).
assert_hostile_not_executed "$hostile_dir" jq
# And the code edit must still have enqueued via the trusted jq.
assert_jsonl_selects 'select(.op == "enqueue" and .file_path == "src/jq_path_case.rs" and .source == "hook")' "$state_jsonl"
[[ ! -s "$jq_hostile_path_stdout" ]] || fail "hostile-PATH-jq run should stay silent on stdout"
/bin/rm -f "$hostile_dir/jq" "$hostile_dir/jq.marker"

# Case 2: hostile JQ_BIN env pointing at a malicious executable, with a clean
# PATH (real jq available). The /bin/sh trampoline unsets JQ_BIN, so the hostile
# binary is never consulted: the edit still enqueues via the trusted jq and the
# hostile JQ_BIN binary never runs (its marker is never dropped). This proves an
# inherited JQ_BIN cannot inject a binary nor cause a silent skip.
hostile_env_jq="$tmpdir/${hook_slug}-jqenv-bin"
write_hostile_binary "$hostile_env_jq" jq
: > "$hook_repo/src/jq_env_case.rs"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/jq_env_case.rs" \
  | (
    cd "$hook_repo"
    REVHARNESS_REVIEW_QUEUE_BACKEND=core \
    JQ_BIN="$hostile_env_jq/jq" \
      "./$hook_rel"
  ) >"$jq_hostile_env_stdout" 2>"$jq_hostile_env_stderr" \
  || fail "hostile-JQ_BIN code edit should enqueue via trusted jq, not skip or crash"
assert_hostile_not_executed "$hostile_env_jq" jq
[[ ! -s "$jq_hostile_env_stdout" ]] || fail "hostile-JQ_BIN run should stay silent on stdout"
assert_jsonl_selects 'select(.op == "enqueue" and .file_path == "src/jq_env_case.rs" and .source == "hook")' "$state_jsonl"

# Case 3: jq execution fails on an Edit-shaped payload. We feed malformed JSON
# (clean PATH, so the resolved trusted jq is genuine) which makes jq exit
# non-zero. The fix captures jq's real exit status and fails CLOSED via
# die_hook; the pre-existing `|| true` swallow would have produced an empty
# parse and a silent rc-0 skip of an enqueue-shaped edit. Assert fail-closed
# non-zero with an observable jq-failure message, NOT a silent skip.
if printf '{"tool_name":"Edit","tool_input":{"file_path": THIS_IS_NOT_JSON' \
  | (
    cd "$hook_repo"
    REVHARNESS_REVIEW_QUEUE_BACKEND=core \
      "./$hook_rel"
  ) >"$jq_broken_stdout" 2>"$jq_broken_stderr"; then
  fail "malformed JSON (jq exits non-zero) must fail closed, not silently skip"
fi
grep -Fq -- "jq invocation failed" "$jq_broken_stderr" \
  || fail "jq execution failure should be observable on stderr (fail-closed)"
# --------------------------------------------------------------------------

outside_file="$tmpdir/${hook_slug}.outside.rs"
: > "$outside_file"
events_before="$(count_lines "$state_jsonl")"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$outside_file" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
      "./$hook_rel"
  ) >"$outside_stdout" 2>"$outside_stderr" \
  || fail "repo-outside hook run should skip cleanly"
events_after="$(count_lines "$state_jsonl")"
[[ "$events_after" == "$events_before" ]] || fail "repo-outside file should not enqueue"
grep -Fq -- "Skipping file outside repo: $outside_file" "$outside_stderr" \
  || fail "repo-outside skip should be logged"

printf 'bad\nid\n' > "$hook_repo/.shared/project_id"
if printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/lib.rs" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
      "./$hook_rel"
  ) >"$bad_pid_stdout" 2>"$bad_pid_stderr"; then
  fail "malformed project_id should fail closed for enqueue-eligible files"
fi
grep -Eq 'project_id|Failed to enqueue DB review queue item' "$bad_pid_stderr" \
  || fail "malformed project_id failure should be observable on stderr"
/bin/cp -p "$REPO_ROOT/.shared/project_id" "$hook_repo/.shared/project_id"

/bin/mv "$hook_repo/scripts/review-queue.sh" "$hook_repo/scripts/review-queue.sh.missing"
if printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/lib.rs" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
      "./$hook_rel"
  ) >"$missing_stdout" 2>"$missing_stderr"; then
  fail "missing queue helper should fail closed for enqueue-eligible files"
fi
grep -Fq -- "queue helper not found or not executable" "$missing_stderr" \
  || fail "missing queue helper failure should include hook stderr"
/bin/mv "$hook_repo/scripts/review-queue.sh.missing" "$hook_repo/scripts/review-queue.sh"

chmod -x "$hook_repo/scripts/review-queue.sh"
if printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/lib.rs" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
      "./$hook_rel"
  ) >"$noexec_stdout" 2>"$noexec_stderr"; then
  fail "non-executable queue helper should fail closed for enqueue-eligible files"
fi
grep -Fq -- "queue helper not found or not executable" "$noexec_stderr" \
  || fail "non-executable queue helper failure should include hook stderr"
chmod +x "$hook_repo/scripts/review-queue.sh"

assert_hostile_not_executed "$hostile_dir" cargo
assert_hostile_not_executed "$hostile_dir" semantic-mcp
assert_hostile_not_executed "$hostile_dir" tree-sitter-index

printf 'PASS: hook-fail-behavior-test hook=%s docs_elapsed_ms=%s\n' "$hook_rel" "$docs_elapsed_ms"
done

printf 'PASS: hook-fail-behavior-test docs_elapsed_ms=%s\n' "$docs_elapsed_ms"
