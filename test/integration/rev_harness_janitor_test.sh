#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_ROOT=""
PROJECT_ROOT=""
JANITOR=""
FIXTURE_ROOT=""
SYMLINK_ROOT=""
OUTSIDE_ROOT=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]]
}

cleanup() {
  /bin/rm -rf "${TMP_ROOT:-}"
}

trap cleanup EXIT

cleanup_legacy_fixed_tmp_residue() {
  /bin/rm -f \
    /tmp/rev-harness-janitor-apply.out \
    /tmp/rev-harness-janitor-apply.err \
    /tmp/rev-harness-janitor-symlink.out \
    /tmp/rev-harness-janitor-symlink.err \
    /tmp/rev-harness-janitor-outside.out \
    /tmp/rev-harness-janitor-outside.err \
    /tmp/rev-harness-janitor-outside-archive.out \
    /tmp/rev-harness-janitor-outside-archive.err \
    /tmp/rev-harness-janitor-outside-archive-dry.out \
    /tmp/rev-harness-janitor-outside-archive-dry.err \
    /tmp/rev-harness-janitor-symlink-archive-dry.out \
    /tmp/rev-harness-janitor-symlink-archive-dry.err \
    /tmp/rev-harness-janitor-symlink-component-dry.out \
    /tmp/rev-harness-janitor-symlink-component-dry.err \
    2>/dev/null || true
}

setup_test_project() {
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-janitor-test.XXXXXX")"
  TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
  PROJECT_ROOT="$TMP_ROOT/project"
  JANITOR="$PROJECT_ROOT/scripts/rev-harness-janitor.sh"
  FIXTURE_ROOT="$PROJECT_ROOT/.claude/tmp/rev-harness-janitor-test.$$"
  SYMLINK_ROOT="$PROJECT_ROOT/.claude/tmp/rev-harness-janitor-link.$$"

  mkdir -p "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/.claude/tmp"
  cp "$REAL_PROJECT_ROOT/scripts/rev-harness-janitor.sh" "$PROJECT_ROOT/scripts/rev-harness-janitor.sh"
  cp "$REAL_PROJECT_ROOT/scripts/harness-active-artifact-pruner.sh" "$PROJECT_ROOT/scripts/harness-active-artifact-pruner.sh"
  chmod +x "$PROJECT_ROOT/scripts/rev-harness-janitor.sh" "$PROJECT_ROOT/scripts/harness-active-artifact-pruner.sh"
  git -C "$PROJECT_ROOT" init -q
}

run_janitor() {
  (cd "$PROJECT_ROOT" && bash "$JANITOR" "$@")
}

reset_fixture() {
  /bin/rm -rf "$FIXTURE_ROOT"
  mkdir -p "$FIXTURE_ROOT"
}

make_run_dir() {
  local dir="$1"
  local stamp="$2"

  mkdir -p "$dir"
  printf 'summary\n' >"$dir/summary.md"
  touch -t "$stamp" "$dir" "$dir/summary.md"
}

test_help_documents_safety_contract() {
  local output=""

  output="$(run_janitor --help)"

  contains "$output" "This CLI is read-only/dry-run BY DEFAULT" || fail "help should document dry-run-by-default contract"
  contains "$output" "--apply without --ack-prune-cost fails closed" || fail "help should document destructive opt-in fail-closed guarantee"
  contains "$output" "Active lineage and release evidence" || fail "help should document evidence protection"
  contains "$output" "archive is non-mutating in this slice" || fail "help should document dry-run archive contract"
}

test_inspect_summarizes_fixture_without_moving() {
  local output=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  printf 'pointer\n' >"$FIXTURE_ROOT/latest.txt"

  output="$(run_janitor inspect --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0)"

  contains "$output" "janitor_command: inspect" || fail "inspect should identify command"
  contains "$output" "tmp_summary_scope: bounded-depth-2" || fail "inspect should use bounded summary by default"
  contains "$output" "tmp_size_bytes:" || fail "inspect should report tmp size"
  contains "$output" "tmp_file_count:" || fail "inspect should report file count"
  contains "$output" "candidate_count: 1" || fail "inspect should report candidate count"
  contains "$output" "action_count: 1" || fail "inspect should report action count"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "inspect must not move candidate"
}

test_inspect_default_avoids_unbounded_du_and_find() {
  local output=""
  local fakebin="$TMP_ROOT/fakebin-inspect"
  local real_find=""
  local real_du=""

  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  mkdir -p "$FIXTURE_ROOT/deep/a/b"
  printf 'deep\n' >"$FIXTURE_ROOT/deep/a/b/not-counted-by-bounded-summary.txt"

  real_find="$(command -v find)"
  real_du="$(command -v du)"
  mkdir -p "$fakebin"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'has_maxdepth=false' \
    'for arg in "$@"; do' \
    '  [[ "$arg" == "-maxdepth" ]] && has_maxdepth=true' \
    'done' \
    'if [[ "$has_maxdepth" != true ]]; then' \
    '  printf "unbounded find rejected: %s\n" "$*" >&2' \
    '  exit 99' \
    'fi' \
    "exec \"$real_find\" \"\$@\"" \
    >"$fakebin/find"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "unbounded du rejected: %s\n" "$*" >&2' \
    'exit 99' \
    >"$fakebin/du"
  chmod +x "$fakebin/find" "$fakebin/du"

  output="$(PATH="$fakebin:$PATH" run_janitor inspect --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0)"

  contains "$output" "tmp_summary_scope: bounded-depth-2" || fail "inspect should report bounded summary scope"
  contains "$output" "candidate_count: 1" || fail "bounded inspect should still report pruner candidate count"
  [[ -x "$real_du" ]] || fail "real du should exist for fixture sanity"
}

test_plan_is_dry_run() {
  local output=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  output="$(run_janitor plan --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0)"

  contains "$output" "janitor_command: plan" || fail "plan should identify command"
  contains "$output" "archive_enabled: false" || fail "plan should not enable archive"
  contains "$output" "would_archive: 20200101_000001" || fail "plan should show dry-run archive candidate"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "plan must not move candidate"
  [[ ! -e "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "plan must not create archive output"
}

test_archive_without_archive_dir_is_dry_run() {
  local output=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  output="$(run_janitor archive --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0)"

  contains "$output" "janitor_command: archive" || fail "archive should identify command"
  contains "$output" "archive_enabled: false" || fail "archive without archive-dir should remain dry-run"
  contains "$output" "would_archive: 20200101_000001" || fail "archive dry-run should show candidate"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "archive without archive-dir must not move candidate"
}

test_archive_with_archive_dir_is_dry_run_and_non_mutating() {
  local output=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  output="$(run_janitor archive --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --archive-dir "$FIXTURE_ROOT/.archive")"

  contains "$output" "archive_enabled: false" || fail "explicit archive-dir should not enable live archive"
  contains "$output" "archive_dir: $FIXTURE_ROOT/.archive" || fail "archive should echo validated archive dir"
  contains "$output" "would_archive: 20200101_000001" || fail "archive should report dry-run candidate"
  contains "$output" "reviewed authorization manifest" || fail "archive should explain authorization requirement"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "source must remain during archive dry-run"
  [[ ! -e "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "archive dry-run must not create archive output"
  [[ ! -e "$PROJECT_ROOT/20200101_000001" ]] || fail "archive must not escape selected root"
}

test_json_archive_with_archive_dir_is_non_mutating() {
  local json=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  json="$(run_janitor archive --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --archive-dir "$FIXTURE_ROOT/.archive" --json)"

  printf '%s\n' "$json" | jq -e '
    .janitor_command == "archive"
    and .delete_enabled == false
    and .archive_enabled == false
    and .dry_run == true
    and .actions == ["20200101_000001"]
  ' >/dev/null || fail "archive JSON should remain dry-run and non-mutating"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "json archive must not move candidate"
  [[ ! -e "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "json archive dry-run must not create archive output"
}

test_json_plan_reports_no_delete_path() {
  local json=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  json="$(run_janitor plan --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --json)"

  printf '%s\n' "$json" | jq -e '
    .schema_version == "rev-harness-janitor/v1"
    and .janitor_command == "plan"
    and .delete_enabled == false
    and .archive_enabled == false
    and .dry_run == true
    and .candidate_count == 1
    and .action_count == 1
    and .actions == ["20200101_000001"]
  ' >/dev/null || fail "plan JSON schema/content should be agent-friendly"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "json plan must not move candidate"
}

test_plan_uses_single_tracked_file_probe_for_many_candidates() {
  local json=""
  local fakebin="$TMP_ROOT/fakebin"
  local count_file="$TMP_ROOT/git-ls-files-count.txt"
  local real_git=""
  local idx=""

  reset_fixture
  for idx in 1 2 3 4 5; do
    make_run_dir "$FIXTURE_ROOT/20200101_00000$idx" "202001010000"
  done

  real_git="$(command -v git)"
  mkdir -p "$fakebin"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$*" == *" ls-files "* ]]; then' \
    '  printf x >>"$GIT_LS_FILES_COUNT_FILE"' \
    'fi' \
    "exec \"$real_git\" \"\$@\"" \
    >"$fakebin/git"
  chmod +x "$fakebin/git"
  : >"$count_file"

  json="$(GIT_LS_FILES_COUNT_FILE="$count_file" PATH="$fakebin:$PATH" run_janitor plan --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --json)"

  printf '%s\n' "$json" | jq -e '
    .candidate_count == 5
    and .action_count == 5
  ' >/dev/null || fail "bounded plan should still report all direct run candidates"
  [[ "$(wc -c <"$count_file" | tr -d '[:space:]')" == "1" ]] \
    || fail "plan should batch tracked-file protection instead of probing each candidate"
}

test_pruner_preserves_tracked_tmp_files_when_project_path_has_glob_metacharacters() {
  local glob_project="$TMP_ROOT/project-[x]"
  local glob_janitor="$glob_project/scripts/rev-harness-janitor.sh"
  local glob_fixture="$glob_project/.claude/tmp/20200101_000001"
  local json=""

  mkdir -p "$glob_project/scripts" "$glob_project/.claude/tmp"
  cp "$REAL_PROJECT_ROOT/scripts/rev-harness-janitor.sh" "$glob_janitor"
  cp "$REAL_PROJECT_ROOT/scripts/harness-active-artifact-pruner.sh" "$glob_project/scripts/harness-active-artifact-pruner.sh"
  chmod +x "$glob_janitor" "$glob_project/scripts/harness-active-artifact-pruner.sh"
  git -C "$glob_project" init -q

  mkdir -p "$glob_fixture"
  printf 'tracked fixture\n' >"$glob_fixture/keep.txt"
  git -C "$glob_project" add .claude/tmp/20200101_000001/keep.txt

  json="$(
    cd "$glob_project"
    bash "$glob_janitor" plan --root .claude/tmp --keep-latest 0 --max-age-days 0 --json
  )"

  printf '%s\n' "$json" | jq -e '
    .candidate_count == 1
    and .protected_count == 1
    and .action_count == 0
    and .actions == []
  ' >/dev/null || fail "tracked tmp candidate should be protected when project path contains glob metacharacters"
  [[ -f "$glob_fixture/keep.txt" ]] || fail "tracked tmp file must remain in place"
}

test_plan_candidate_discovery_is_bounded_to_known_locations() {
  local json=""

  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  make_run_dir "$FIXTURE_ROOT/random/deep/20200101_000002" "202001010000"
  make_run_dir "$FIXTURE_ROOT/task/runs/20200101_000003" "202001010000"
  mkdir -p "$FIXTURE_ROOT/manifested/deep/path"
  printf '%s\n' '{"schema_version":"artifact-lifecycle/v1","state":"superseded","latest_pointer":"none","pinned_baseline":"none","run_disposable":"YES","superseded_by":"newer","safe_delete_class":"scratch"}' \
    >"$FIXTURE_ROOT/manifested/deep/path/artifact-lifecycle-manifest.json"

  json="$(run_janitor plan --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --json)"

  printf '%s\n' "$json" | jq -e '
    .candidate_count == 3
    and (.actions | index("20200101_000001"))
    and (.actions | index("task/runs/20200101_000003"))
    and (.actions | index("manifested/deep/path"))
    and ((.actions | index("random/deep/20200101_000002")) | not)
  ' >/dev/null || fail "candidate discovery should use direct roots, runs children, and manifests only"
}

test_janitor_extensions_report_manifest_residue_without_mutation() {
  local json=""
  reset_fixture
  mkdir -p "$FIXTURE_ROOT/20200101_000001"
  printf '%s\n' \
    '{"schema_version":"rev-harness-evidence-manifest/v1","artifacts":[],"reviewer_capsule":{}}' \
    >"$FIXTURE_ROOT/20200101_000001/evidence-manifest.json"
  printf '%s\n' \
    '{"schema_version":"rev-harness-dirty-surface/v1","owned_review_set":[],"paths":[]}' \
    >"$FIXTURE_ROOT/20200101_000001/dirty-surface.json"
  printf '%s\n' \
    '{"schema_version":"rev-harness-worker-lifecycle/v1","workers":[{"state":"closed","artifact_paths":[]}]}' \
    >"$FIXTURE_ROOT/20200101_000001/worker-lifecycle.json"

  json="$(run_janitor plan --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --json)"

  printf '%s\n' "$json" | jq -e '
    .delete_enabled == false
    and .apply_enabled == false
    and .archive_enabled == false
    and .janitor_extensions.schema_version == "rev-harness-janitor-extensions/v1"
    and .janitor_extensions.delete_enabled == false
    and .janitor_extensions.apply_enabled == false
    and .janitor_extensions.project_state_mutation_enabled == false
    and .janitor_extensions.finding_count == 3
    and ([.janitor_extensions.findings[].residue_type] | sort == ["dirty_surface_manifest","evidence_manifest","worker_lifecycle_manifest"])
    and all(.janitor_extensions.findings[]; .planned_action == "inspect-only" and .delete_enabled == false and .archive_only_candidate == true)
    and (.janitor_extensions.findings[] | select(.residue_type == "evidence_manifest") | .has_reviewer_capsule == true)
    and (.janitor_extensions.findings[] | select(.residue_type == "dirty_surface_manifest") | .has_owned_review_set == true)
    and (.janitor_extensions.findings[] | select(.residue_type == "worker_lifecycle_manifest") | .has_worker_artifact_paths == true)
  ' >/dev/null || fail "janitor extension JSON should report manifest residue as inspect-only"

  [[ -f "$FIXTURE_ROOT/20200101_000001/evidence-manifest.json" ]] || fail "extension scan must not move evidence manifest"
  [[ ! -e "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "extension scan must not archive without archive command"
}

test_janitor_extension_scan_is_bounded_to_known_residue_locations() {
  local json=""
  reset_fixture
  mkdir -p "$FIXTURE_ROOT/20200101_000001/deep/a/b"
  printf '%s\n' \
    '{"schema_version":"rev-harness-evidence-manifest/v1","reviewer_capsule":{}}' \
    >"$FIXTURE_ROOT/20200101_000001/evidence-manifest.json"
  printf '%s\n' \
    '{"schema_version":"rev-harness-evidence-manifest/v1","reviewer_capsule":{}}' \
    >"$FIXTURE_ROOT/20200101_000001/deep/a/b/evidence-manifest.json"
  printf '%s\n' \
    '{"schema_version":"rev-harness-evidence-manifest/v1","reviewer_capsule":{}}' \
    >"$FIXTURE_ROOT/20200101_000001/unbounded-random.json"

  json="$(run_janitor plan --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --json)"

  printf '%s\n' "$json" | jq -e '
    .janitor_extensions.finding_count == 1
    and .janitor_extensions.findings[0].path == "20200101_000001/evidence-manifest.json"
  ' >/dev/null || fail "extension scan should be bounded by maxdepth and known residue names"
}

test_apply_path_fails_closed() {
  local stdout_file="$TMP_ROOT/rev-harness-janitor-apply.out"
  local stderr_file="$TMP_ROOT/rev-harness-janitor-apply.err"
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  if run_janitor plan --root "$FIXTURE_ROOT" --apply >"$stdout_file" 2>"$stderr_file"; then
    fail "apply path should fail closed"
  fi
  contains "$(<"$stderr_file")" "apply is not supported" \
    || fail "apply failure should mention apply is not supported"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "apply failure must not move candidate"
}

test_symlink_and_path_escape_fail_closed() {
  local symlink_stdout="$TMP_ROOT/rev-harness-janitor-symlink.out"
  local symlink_stderr="$TMP_ROOT/rev-harness-janitor-symlink.err"
  local outside_stdout="$TMP_ROOT/rev-harness-janitor-outside.out"
  local outside_stderr="$TMP_ROOT/rev-harness-janitor-outside.err"
  local archive_stdout="$TMP_ROOT/rev-harness-janitor-outside-archive.out"
  local archive_stderr="$TMP_ROOT/rev-harness-janitor-outside-archive.err"
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  mkdir -p "$FIXTURE_ROOT/real-root"
  ln -s "$FIXTURE_ROOT/real-root" "$SYMLINK_ROOT"

  if run_janitor inspect --root "$SYMLINK_ROOT" >"$symlink_stdout" 2>"$symlink_stderr"; then
    fail "symlink root should fail closed"
  fi
  contains "$(<"$symlink_stderr")" "symlink" || fail "symlink failure should mention symlink"

  OUTSIDE_ROOT="$(mktemp -d "$TMP_ROOT/rev-harness-janitor-outside.XXXXXX")"
  if run_janitor plan --root "$OUTSIDE_ROOT" >"$outside_stdout" 2>"$outside_stderr"; then
    fail "repo-outside root should fail closed"
  fi
  contains "$(<"$outside_stderr")" "--root" || fail "outside root should mention root boundary"

  if run_janitor archive \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --archive-dir "$OUTSIDE_ROOT/archive" >"$archive_stdout" 2>"$archive_stderr"; then
    fail "repo-outside archive dir should fail closed"
  fi
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "source should remain after archive path escape failure"
  [[ ! -e "$OUTSIDE_ROOT/archive" ]] || fail "outside archive dir should not be created"
}

test_archive_dry_run_validates_archive_dir() {
  local symlink_archive=""
  local component_target=""
  local component_link=""
  local outside_stdout="$TMP_ROOT/rev-harness-janitor-outside-archive-dry.out"
  local outside_stderr="$TMP_ROOT/rev-harness-janitor-outside-archive-dry.err"
  local symlink_stdout="$TMP_ROOT/rev-harness-janitor-symlink-archive-dry.out"
  local symlink_stderr="$TMP_ROOT/rev-harness-janitor-symlink-archive-dry.err"
  local component_stdout="$TMP_ROOT/rev-harness-janitor-symlink-component-dry.out"
  local component_stderr="$TMP_ROOT/rev-harness-janitor-symlink-component-dry.err"

  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  OUTSIDE_ROOT="$(mktemp -d "$TMP_ROOT/rev-harness-janitor-outside-dry.XXXXXX")"
  if run_janitor archive \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --archive-dir "$OUTSIDE_ROOT/archive" \
    --dry-run >"$outside_stdout" 2>"$outside_stderr"; then
    fail "repo-outside archive dir dry-run should fail closed"
  fi
  contains "$(<"$outside_stderr")" "--archive-dir" \
    || fail "outside archive-dir dry-run failure should mention archive-dir"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "source should remain after dry-run outside archive path failure"
  [[ ! -e "$OUTSIDE_ROOT/archive" ]] || fail "outside archive dir dry-run should not create archive dir"

  mkdir -p "$FIXTURE_ROOT/archive-target"
  symlink_archive="$FIXTURE_ROOT/archive-link"
  ln -s "$FIXTURE_ROOT/archive-target" "$symlink_archive"
  if run_janitor archive \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --archive-dir "$symlink_archive/" \
    --dry-run \
    --json >"$symlink_stdout" 2>"$symlink_stderr"; then
    fail "symlink archive dir dry-run should fail closed"
  fi
  contains "$(<"$symlink_stderr")" "symlink" \
    || fail "symlink archive-dir dry-run failure should mention symlink"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "source should remain after dry-run symlink archive path failure"
  [[ ! -e "$FIXTURE_ROOT/archive-target/20200101_000001" ]] || fail "symlink archive dir dry-run should not move candidate"

  component_target="$FIXTURE_ROOT/component-target"
  component_link="$FIXTURE_ROOT/component-link"
  mkdir -p "$component_target"
  ln -s "$component_target" "$component_link"
  if run_janitor archive \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --archive-dir "$component_link/archive" \
    --dry-run >"$component_stdout" 2>"$component_stderr"; then
    fail "symlink archive path component dry-run should fail closed"
  fi
  contains "$(<"$component_stderr")" "symlink path component" \
    || fail "symlink path component dry-run failure should mention path component"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "source should remain after dry-run symlink component failure"
  [[ ! -e "$component_target/archive" ]] || fail "symlink component dry-run should not create archive dir"
}

# --- plans-archive dir-class (STATUS sentinel) tests -------------------------
#
# These exercise the -d branch added in BT3: a DIRECTORY-class plan under
# .agent/active is archivable ONLY via a git-tracked top-level STATUS sentinel
# carrying a completion marker, and only if floor + tracked + (anchored) live-ref
# gates all pass. Each test rebuilds a clean .agent fixture so the suite stays
# order-independent.

pa_reset() {
  # Fresh .agent/active + .agent/archive/plans, committed base so git ls-files /
  # git grep see a real tree. The never-delete floor name is hardcoded in the
  # janitor, so the floor test creates a dir with that exact name.
  /bin/rm -rf "$PROJECT_ROOT/.agent"
  mkdir -p "$PROJECT_ROOT/.agent/active" "$PROJECT_ROOT/.agent/archive/plans"
  # .gitkeep so the empty archive dir is a real tracked path.
  printf '' >"$PROJECT_ROOT/.agent/archive/plans/.gitkeep"
}

pa_commit() {
  git -C "$PROJECT_ROOT" add -A >/dev/null 2>&1 || true
  git -C "$PROJECT_ROOT" -c user.email=t@t.invalid -c user.name=t \
    commit -q -m "pa fixture" >/dev/null 2>&1 || true
}

test_plans_archive_dir_without_status_is_refused() {
  local output=""
  pa_reset
  mkdir -p "$PROJECT_ROOT/.agent/active/plan_nostatus/sub"
  printf 'body\n' >"$PROJECT_ROOT/.agent/active/plan_nostatus/notes.md"
  printf 'deep\n' >"$PROJECT_ROOT/.agent/active/plan_nostatus/sub/deep.md"
  pa_commit

  output="$(run_janitor plans-archive --plan plan_nostatus --dry-run)"

  contains "$output" "refused no-completion-marker" || fail "dir without STATUS should be refused no-completion-marker"
  contains "$output" "moved_count: 0" || fail "dir without STATUS must not be a move candidate"
  [[ -d "$PROJECT_ROOT/.agent/active/plan_nostatus" ]] || fail "refused dir must remain in active"
}

test_plans_archive_dir_with_untracked_status_is_refused() {
  local output=""
  pa_reset
  mkdir -p "$PROJECT_ROOT/.agent/active/plan_untracked"
  printf 'body\n' >"$PROJECT_ROOT/.agent/active/plan_untracked/notes.md"
  pa_commit
  # STATUS added AFTER the commit and never `git add`ed => untracked sentinel.
  printf 'STATUS: COMPLETE\n' >"$PROJECT_ROOT/.agent/active/plan_untracked/STATUS"

  output="$(run_janitor plans-archive --plan plan_untracked --dry-run)"

  contains "$output" "refused no-completion-marker" || fail "untracked STATUS must not authorize a dir move"
  contains "$output" "moved_count: 0" || fail "untracked-STATUS dir must not be a move candidate"
}

test_plans_archive_dir_with_tracked_complete_status_dry_runs_would_move() {
  local output=""
  pa_reset
  mkdir -p "$PROJECT_ROOT/.agent/active/plan_done/sub"
  printf 'body\n' >"$PROJECT_ROOT/.agent/active/plan_done/notes.md"
  printf 'deep\n' >"$PROJECT_ROOT/.agent/active/plan_done/sub/deep.md"
  printf 'STATUS: COMPLETE\n' >"$PROJECT_ROOT/.agent/active/plan_done/STATUS"
  pa_commit

  output="$(run_janitor plans-archive --plan plan_done --dry-run)"

  contains "$output" "would_move plan_done" || fail "tracked STATUS: COMPLETE dir with no live refs should dry-run as would_move"
  contains "$output" "moved_count: 1" || fail "would_move dir should count once"
  [[ -d "$PROJECT_ROOT/.agent/active/plan_done" ]] || fail "dry-run must not move the dir"
}

test_plans_archive_dir_with_pending_status_is_refused() {
  local output=""
  pa_reset
  mkdir -p "$PROJECT_ROOT/.agent/active/plan_pending"
  printf 'body\n' >"$PROJECT_ROOT/.agent/active/plan_pending/notes.md"
  # A genuine in-flight sentinel: a blocker word and NO completion marker.
  printf 'STATUS: WIP — pending acceptance\n' \
    >"$PROJECT_ROOT/.agent/active/plan_pending/STATUS"
  pa_commit

  output="$(run_janitor plans-archive --plan plan_pending --dry-run)"

  contains "$output" "refused no-completion-marker" || fail "pending/WIP STATUS dir should be refused (no completion marker)"
  contains "$output" "blocker=" || fail "pending/WIP STATUS should report the detected blocker word"
  contains "$output" "moved_count: 0" || fail "pending/WIP dir must not be a move candidate"
}

test_plans_archive_dir_with_complete_and_blocker_status_is_refused() {
  # Fail-closed: a STATUS that carries BOTH a completion marker AND a blocker
  # word must be REFUSED — the blocker vetoes the completion marker. A
  # still-in-flight sentinel can never authorize a move even if it also says
  # "COMPLETE".
  local output=""
  pa_reset
  mkdir -p "$PROJECT_ROOT/.agent/active/plan_both"
  printf 'body\n' >"$PROJECT_ROOT/.agent/active/plan_both/notes.md"
  printf 'STATUS: COMPLETE\nnote: pending acceptance\n' \
    >"$PROJECT_ROOT/.agent/active/plan_both/STATUS"
  pa_commit

  output="$(run_janitor plans-archive --plan plan_both --dry-run)"

  contains "$output" "refused no-completion-marker" || fail "STATUS with both COMPLETE and a blocker must be refused (blocker vetoes marker)"
  contains "$output" "blocker=" || fail "both-present STATUS should report the detected blocker word"
  contains "$output" "moved_count: 0" || fail "both-present STATUS dir must not be a move candidate"
  [[ -d "$PROJECT_ROOT/.agent/active/plan_both" ]] || fail "refused both-present dir must remain in active"
}

test_plans_archive_live_referenced_dir_is_refused() {
  local output=""
  pa_reset
  # A genuinely live-referenced completed dir.
  mkdir -p "$PROJECT_ROOT/.agent/active/plan_live"
  printf 'body\n' >"$PROJECT_ROOT/.agent/active/plan_live/notes.md"
  printf 'STATUS: COMPLETE\n' >"$PROJECT_ROOT/.agent/active/plan_live/STATUS"
  # A tracked file OUTSIDE the lifecycle dirs that names plan_live (a live ref).
  mkdir -p "$PROJECT_ROOT/docs"
  printf 'see .agent/active/plan_live/notes.md for details\n' >"$PROJECT_ROOT/docs/roadmap.md"
  pa_commit

  output="$(run_janitor plans-archive --plan plan_live --dry-run)"

  contains "$output" "refused live-referenced plan_live" || fail "genuinely live-referenced dir must be refused"
  contains "$output" "moved_count: 0" || fail "live-referenced dir must not be a move candidate"
}

test_plans_archive_prefix_sibling_is_not_mis_refused() {
  # HAZARD 1: dir name that is a PREFIX of a referenced sibling must NOT be
  # mis-gated by the sibling's references (and the genuinely-referenced sibling
  # IS refused). Anchored match proves both directions.
  local out_prefix="" out_sibling=""
  pa_reset

  # The short dir (prefix) — completed, NO references to itself.
  mkdir -p "$PROJECT_ROOT/.agent/active/plan_phase-G"
  printf 'body\n' >"$PROJECT_ROOT/.agent/active/plan_phase-G/notes.md"
  printf 'STATUS: SUPERSEDED\n' >"$PROJECT_ROOT/.agent/active/plan_phase-G/STATUS"

  # The longer sibling — completed, IS referenced by a tracked doc.
  mkdir -p "$PROJECT_ROOT/.agent/active/plan_phase-G-rfc-round2"
  printf 'body\n' >"$PROJECT_ROOT/.agent/active/plan_phase-G-rfc-round2/notes.md"
  printf 'STATUS: SUPERSEDED\n' >"$PROJECT_ROOT/.agent/active/plan_phase-G-rfc-round2/STATUS"

  # The ONLY external reference names the LONGER sibling. A bare substring match
  # would substring-hit "plan_phase-G" and mis-refuse it; anchoring prevents that.
  mkdir -p "$PROJECT_ROOT/docs"
  printf 'cite plan_phase-G-rfc-round2/notes.md\n' >"$PROJECT_ROOT/docs/cite.md"
  pa_commit

  # Prefix dir: NOT mis-refused (no anchored ref to it) => would_move.
  out_prefix="$(run_janitor plans-archive --plan plan_phase-G --dry-run)"
  contains "$out_prefix" "would_move plan_phase-G " || fail "prefix dir must NOT be mis-gated by sibling references (anchored match)"

  # Sibling dir: genuinely referenced => refused.
  out_sibling="$(run_janitor plans-archive --plan plan_phase-G-rfc-round2 --dry-run)"
  contains "$out_sibling" "refused live-referenced plan_phase-G-rfc-round2" || fail "genuinely-referenced sibling must be refused"
}

test_plans_archive_floor_still_refuses_active_governance_diet() {
  local output=""
  pa_reset
  # The hardcoded never-delete-floor entry is plan_20260628_1933_governance_diet.md.
  mkdir -p "$PROJECT_ROOT/.agent/active/plan_20260628_1933_governance_diet.md"
  printf 'body\n' >"$PROJECT_ROOT/.agent/active/plan_20260628_1933_governance_diet.md/notes.md"
  printf 'STATUS: COMPLETE\n' \
    >"$PROJECT_ROOT/.agent/active/plan_20260628_1933_governance_diet.md/STATUS"
  pa_commit

  # Even with a tracked STATUS: COMPLETE, the floor must refuse FIRST.
  output="$(run_janitor plans-archive --plan plan_20260628_1933_governance_diet.md --dry-run)"

  contains "$output" "refused never-delete-floor plan_20260628_1933_governance_diet.md" \
    || fail "never-delete floor must still refuse the active governance-diet plan even with a completion sentinel"
  contains "$output" "moved_count: 0" || fail "floored plan must not be a move candidate"
}

test_plans_archive_apply_writes_nested_manifest_hashes() {
  # HAZARD 2: --apply must write a manifest with a sha256 entry for EVERY file
  # in the tree (nested files included), not just top-level.
  local output="" manifest=""
  pa_reset
  mkdir -p "$PROJECT_ROOT/.agent/active/plan_multi/a/b"
  printf 'top\n' >"$PROJECT_ROOT/.agent/active/plan_multi/top.md"
  printf 'mid\n' >"$PROJECT_ROOT/.agent/active/plan_multi/a/mid.md"
  printf 'deep\n' >"$PROJECT_ROOT/.agent/active/plan_multi/a/b/deep.md"
  printf 'STATUS: COMPLETE\n' >"$PROJECT_ROOT/.agent/active/plan_multi/STATUS"
  pa_commit

  output="$(run_janitor plans-archive --plan plan_multi --apply)"
  contains "$output" "moved plan_multi" || fail "apply should move the completed dir"
  [[ -d "$PROJECT_ROOT/.agent/archive/plans/plan_multi" ]] || fail "apply should relocate dir under archive/plans"
  [[ ! -e "$PROJECT_ROOT/.agent/active/plan_multi" ]] || fail "apply should remove dir from active"

  manifest="$PROJECT_ROOT/.agent/archive/plans/plan_multi.archive-manifest.json"
  [[ -f "$manifest" ]] || fail "apply should write the archive manifest"

  # Every file in the moved tree (including STATUS + nested deep.md) must be hashed.
  jq -e '
    (.file_count >= 4)
    and ([.files[].path] | any(test("plan_multi/STATUS$")))
    and ([.files[].path] | any(test("plan_multi/top\\.md$")))
    and ([.files[].path] | any(test("plan_multi/a/mid\\.md$")))
    and ([.files[].path] | any(test("plan_multi/a/b/deep\\.md$")))
    and (all(.files[]; .sha256 | test("^[0-9a-f]{64}$")))
  ' "$manifest" >/dev/null || fail "manifest must contain a real sha256 for every nested file in the tree"
}

test_no_fixed_tmp_output_residue() {
  local path=""

  for path in \
    /tmp/rev-harness-janitor-apply.out \
    /tmp/rev-harness-janitor-apply.err \
    /tmp/rev-harness-janitor-symlink.out \
    /tmp/rev-harness-janitor-symlink.err \
    /tmp/rev-harness-janitor-outside.out \
    /tmp/rev-harness-janitor-outside.err \
    /tmp/rev-harness-janitor-outside-archive.out \
    /tmp/rev-harness-janitor-outside-archive.err \
    /tmp/rev-harness-janitor-outside-archive-dry.out \
    /tmp/rev-harness-janitor-outside-archive-dry.err \
    /tmp/rev-harness-janitor-symlink-archive-dry.out \
    /tmp/rev-harness-janitor-symlink-archive-dry.err \
    /tmp/rev-harness-janitor-symlink-component-dry.out \
    /tmp/rev-harness-janitor-symlink-component-dry.err; do
    [[ ! -e "$path" ]] || fail "fixed /tmp residue should not remain: $path"
  done
}

cleanup_legacy_fixed_tmp_residue
setup_test_project

test_help_documents_safety_contract
test_inspect_summarizes_fixture_without_moving
test_inspect_default_avoids_unbounded_du_and_find
test_plan_is_dry_run
test_archive_without_archive_dir_is_dry_run
test_archive_with_archive_dir_is_dry_run_and_non_mutating
test_json_archive_with_archive_dir_is_non_mutating
test_json_plan_reports_no_delete_path
test_plan_uses_single_tracked_file_probe_for_many_candidates
test_pruner_preserves_tracked_tmp_files_when_project_path_has_glob_metacharacters
test_plan_candidate_discovery_is_bounded_to_known_locations
test_janitor_extensions_report_manifest_residue_without_mutation
test_janitor_extension_scan_is_bounded_to_known_residue_locations
test_apply_path_fails_closed
test_symlink_and_path_escape_fail_closed
test_archive_dry_run_validates_archive_dir
test_plans_archive_dir_without_status_is_refused
test_plans_archive_dir_with_untracked_status_is_refused
test_plans_archive_dir_with_tracked_complete_status_dry_runs_would_move
test_plans_archive_dir_with_pending_status_is_refused
test_plans_archive_dir_with_complete_and_blocker_status_is_refused
test_plans_archive_live_referenced_dir_is_refused
test_plans_archive_prefix_sibling_is_not_mis_refused
test_plans_archive_floor_still_refuses_active_governance_diet
test_plans_archive_apply_writes_nested_manifest_hashes
test_no_fixed_tmp_output_residue

printf 'PASS: rev_harness_janitor_test\n'
