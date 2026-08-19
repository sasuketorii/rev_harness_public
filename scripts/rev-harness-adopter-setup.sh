#!/usr/bin/env bash
set -euo pipefail

# --- bash-version gate (macOS ships bash 3.2; this codebase requires bash >= 4 for
#     associative-array support used deeper in the install/doctor chain). Fail fast
#     with a clear message instead of a cryptic "declare: -A: invalid option" later. ---
if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  printf 'ERROR: this script requires bash >= 4.0 (detected: %s).\n' "${BASH_VERSION:-unknown}" >&2
  printf 'macOS ships bash 3.2 by default (/bin/bash). Install a newer bash, e.g.:\n' >&2
  printf '  brew install bash\n' >&2
  printf 'Then re-run this command with the new bash explicitly, e.g.:\n' >&2
  printf '  %s/bin/bash %s ...\n' "$(brew --prefix bash 2>/dev/null || printf '/opt/homebrew')" "$0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# A freshly cloned harness checkout ships without .shared/project_id
# (immutable identity artifacts are .gitignored by design). The identity
# guard below needs SOME identity to classify this checkout, and would
# otherwise fail-close on its very first run with a message that names a
# command (`scripts/init-project.sh`) this entrypoint could run itself.
# Auto-bootstrap only when the identity is entirely ABSENT (never when it
# exists but is malformed -- that is left to fail-closed so a corrupted
# identity is not silently papered over) and never overwrite an existing
# artifact; project_id is immutable once created.
if [[ ! -e "$HARNESS_ROOT/.shared/project_id" && -f "$SCRIPT_DIR/project-id.sh" ]]; then
  bootstrap_out=""
  if bootstrap_out="$(PROJECT_ID_REPO_ROOT="$HARNESS_ROOT" bash "$SCRIPT_DIR/project-id.sh" bootstrap "$(basename "$HARNESS_ROOT")" 2>&1)"; then
    printf '[rev-harness-adopter-setup] bootstrapped harness checkout identity: %s\n' "$bootstrap_out" >&2
  else
    printf '[rev-harness-adopter-setup] WARNING: failed to auto-bootstrap harness checkout identity; continuing (identity guard may fail-close):\n%s\n' "$bootstrap_out" >&2
  fi
  unset bootstrap_out
fi

# shellcheck source=scripts/_canonical-guard.sh
source "$SCRIPT_DIR/_canonical-guard.sh"
rev_harness_assert_canonical_root rev-harness-adopter-setup

TARGET_ARG=""
TARGET_ROOT=""
PROJECT_ROOT=""
STATE_FILE=""
LEGACY_SHARED_STATE=""
LEGACY_REGISTRY_STATE=""
SNAPSHOT_ROOT=""
SCHEMA="rev-harness-state/v1"
REPORT_SCHEMA="rev-harness-adopter-setup-report/v1"
CORE_PHASES="init hooks doctor"

DRY_RUN=false
JSON_OUTPUT=false
VERBOSE=false
STRICT=false
RESUME=false
ROLLBACK=""
SUBCOMMAND=""
RUN_ID=""
EXIT_CODE=0
export REVHARNESS_PARALLEL_QUIESCE="${REVHARNESS_PARALLEL_QUIESCE:-1}"

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-adopter-setup.sh <subcommand> [options]

Subcommands:
  init      Run init phase only (.shared/project_id creation)
  setup     Run core phases: init -> hooks -> doctor
  verify    Run harness-doctor only
  resume    Resume from the first failed or pending phase
  status    Display .shared/rev-harness-adopter-setup.state.json

Options:
  --dry-run             Log planned phase events; do not write state or run phases
  --json                Print final machine-readable report
  --verbose             Print phase commands to stderr
  --strict              Run doctor in strict mode
  --target <path>       Install into the adopter project at <path>
  --resume              Resume within setup/init/verify
  --rollback <step>|all Restore owner-token files from a pre-step snapshot
  --help, -h            Show this help

Exit codes:
  0 success
  2 prerequisite missing or CLI misuse
  10 phase_init failed
  13 phase_hooks failed
  14 phase_doctor failed
  15 state.json corruption
  16 resume requested but no state.json
  70 vendoring detected by canonical guard
  71 lease timeout
  72 self-install refused
EOF
}

log() { [[ "$JSON_OUTPUT" == true ]] || printf '[rev-harness-adopter-setup] %s\n' "$*" >&2; }
vlog() { [[ "$VERBOSE" == true ]] && printf '[rev-harness-adopter-setup] %s\n' "$*" >&2 || true; }

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
new_run_id() { date -u +"%Y%m%dT%H%M%SZ"; }

phase_exit_code() {
  case "$1" in
    init) printf '10' ;;
    hooks) printf '13' ;;
    doctor) printf '14' ;;
    *) printf '2' ;;
  esac
}

hash_file() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    printf 'MISSING'
  elif [[ ! -f "$path" ]]; then
    printf 'NONREGULAR'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

phase_owner_paths() {
  case "$1" in
    init) printf '.gitignore\n.shared/project_id\n' ;;
    hooks) printf '.claude/settings.local.json\n.git/hooks/pre-commit\n.agent/registry/model_policy.json\n.agent/generated/codex_model_policy.runtime.json\n' ;;
    *) return 0 ;;
  esac
}

phase_input_sha() {
  local phase="$1" rel data=""
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    data="${data}$(hash_file "$PROJECT_ROOT/$rel")  $rel"$'\n'
  done <<EOF
$(phase_owner_paths "$phase")
EOF
  [[ -n "$data" ]] || data="NONE  $phase"
  printf '%s' "$data" | shasum -a 256 | awk '{print $1}'
}

event() {
  local event_name="$1" phase="$2" status="$3" code="${4:-0}" input="${5:-}"
  printf '{"schema":"adopter_setup/v1","event":"%s","run_id":"%s","phase":"%s","status":"%s","exit_code":%s,"input_sha256":"%s","ts":"%s"}\n' \
    "$(json_escape "$event_name")" "$(json_escape "$RUN_ID")" "$(json_escape "$phase")" \
    "$(json_escape "$status")" "$code" "$(json_escape "$input")" "$(now_iso)"
}

require_tools() {
  local missing=""
  for tool in git jq awk shasum; do
    command -v "$tool" >/dev/null 2>&1 || missing="${missing} ${tool}"
  done
  [[ -z "$missing" ]] || { printf 'rev-harness-adopter-setup: missing required tools:%s\n' "$missing" >&2; exit 2; }
}

resolve_setup_roots() {
  TARGET_ROOT="$(resolve_target_root "$TARGET_ARG")" || exit $?
  PROJECT_ROOT="$TARGET_ROOT"
  STATE_FILE="$TARGET_ROOT/.rev-harness-state/state.json"
  LEGACY_SHARED_STATE="$TARGET_ROOT/.shared/rev-harness-adopter-setup.state.json"
  LEGACY_REGISTRY_STATE="$TARGET_ROOT/.agent/registry/rev_harness_adoption_state.json"
  SNAPSHOT_ROOT="$TARGET_ROOT/.rev-harness-state/snapshots"
  export PROJECT_ROOT
}

initial_state_json() {
  local ts="$1"
  jq -nc --arg schema "$SCHEMA" --arg run_id "$RUN_ID" --arg ts "$ts" '
    {
      schema: $schema,
      run_id: $run_id,
      phase: "init",
      current_phase: "init",
      phases: {
        init: {status:"pending", exit_code:0, started_at:null, ended_at:null, input_sha256:null},
        hooks: {status:"pending", exit_code:0, started_at:null, ended_at:null, input_sha256:null},
        doctor: {status:"pending", exit_code:0, started_at:null, ended_at:null, input_sha256:null}
      },
      history: [],
      last_install_at: null,
      started_at: $ts,
      last_updated: $ts
    }'
}

canonicalize_state_json() {
  local json="$1" ts
  ts="$(now_iso)"
  jq -c --arg schema "$SCHEMA" --arg run_id "$RUN_ID" --arg ts "$ts" '
    .schema = $schema
    | .run_id = (.run_id // $run_id)
    | .phase = (.phase // .current_phase // "init")
    | .current_phase = .phase
    | .phases = (.phases // {})
    | .history = (if (.history // []) | type == "array" then (.history // [])[-50:] else [] end)
    | .last_install_at = (.last_install_at // null)
    | .started_at = (.started_at // $ts)
    | .last_updated = (.last_updated // $ts)' <<<"$json"
}

replace_with_relative_symlink() {
  local path="$1" target="$2" tmp
  mkdir -p "$(dirname "$path")"
  tmp="$path.$$.$RANDOM.tmp"
  /bin/rm -f "$tmp"
  ln -s "$target" "$tmp"
  mv -f "$tmp" "$path"
}

ensure_state_legacy_symlinks() {
  replace_with_relative_symlink "$LEGACY_SHARED_STATE" "../.rev-harness-state/state.json"
  replace_with_relative_symlink "$LEGACY_REGISTRY_STATE" "../../.rev-harness-state/state.json"
}

write_state_json() {
  local json="$1" tmp
  mkdir -p "$(dirname "$STATE_FILE")"
  json="$(canonicalize_state_json "$json")"
  tmp="$STATE_FILE.$$.$RANDOM.tmp"
  printf '%s\n' "$json" > "$tmp"
  mv "$tmp" "$STATE_FILE"
  ensure_state_legacy_symlinks
}

migrate_legacy_state_json() {
  local legacy="" json
  [[ ! -f "$STATE_FILE" ]] || return 0
  if [[ -f "$LEGACY_SHARED_STATE" && ! -L "$LEGACY_SHARED_STATE" ]]; then
    legacy="$LEGACY_SHARED_STATE"
  elif [[ -f "$LEGACY_REGISTRY_STATE" && ! -L "$LEGACY_REGISTRY_STATE" ]]; then
    legacy="$LEGACY_REGISTRY_STATE"
  fi
  [[ -n "$legacy" ]] || return 0
  jq empty "$legacy" >/dev/null 2>&1 || exit 15
  json="$(cat "$legacy")"
  RUN_ID="$(jq -r '.run_id // empty' "$legacy")"
  [[ -n "$RUN_ID" ]] || RUN_ID="$(new_run_id)"
  write_state_json "$json"
}

load_state_json() {
  migrate_legacy_state_json
  if [[ ! -f "$STATE_FILE" ]]; then
    [[ "$RESUME" == true ]] && exit 16
    RUN_ID="$(new_run_id)"
    initial_state_json "$(now_iso)"
    return 0
  fi
  jq -e --arg schema "$SCHEMA" '.schema == $schema and (.phases | type == "object") and .phase == .current_phase' "$STATE_FILE" >/dev/null 2>&1 || exit 15
  RUN_ID="$(jq -r '.run_id' "$STATE_FILE")"
  cat "$STATE_FILE"
}

state_update_phase() {
  local state="$1" phase="$2" status="$3" code="$4" input="${5:-}" ts
  ts="$(now_iso)"
  jq -c --arg p "$phase" --arg s "$status" --arg ts "$ts" --arg input "$input" --argjson code "$code" '
    .phase = (if $s == "ok" and $p == "doctor" then "done" else $p end)
    | .current_phase = .phase
    | .last_updated = $ts
    | .phases[$p].status = $s
    | .phases[$p].exit_code = $code
    | .phases[$p].input_sha256 = (if $input == "" then .phases[$p].input_sha256 else $input end)
    | if $s == "running" then .phases[$p].started_at = $ts else .phases[$p].ended_at = $ts end' <<<"$state"
}


snapshot_phase() {
  local phase="$1" rel dest backup safe owners
  [[ "$DRY_RUN" == false ]] || return 0
  [[ "$phase" != "doctor" ]] || return 0
  owners="$(phase_owner_paths "$phase" || true)"
  [[ -n "$owners" ]] || return 0
  mkdir -p "$SNAPSHOT_ROOT/$RUN_ID/files/$phase"
  dest="$SNAPSHOT_ROOT/$RUN_ID/pre-$phase.sha256"
  : > "$dest"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    safe="${rel//\//__}"
    backup="MISSING"
    if [[ -f "$PROJECT_ROOT/$rel" && ! -L "$PROJECT_ROOT/$rel" ]]; then
      backup="$SNAPSHOT_ROOT/$RUN_ID/files/$phase/$safe"
      cp "$PROJECT_ROOT/$rel" "$backup"
    fi
    printf '%s  %s  %s\n' "$(hash_file "$PROJECT_ROOT/$rel")" "$rel" "$backup" >> "$dest"
  done <<EOF
$(phase_owner_paths "$phase")
EOF
}

rollback_phase() {
  local phase="$1" manifest hash rel backup current state owners
  manifest="$SNAPSHOT_ROOT/$RUN_ID/pre-$phase.sha256"
  owners="$(phase_owner_paths "$phase" || true)"
  if [[ ! -f "$manifest" ]]; then
    if [[ -n "$owners" ]]; then
      printf 'rollback snapshot not found: %s\n' "$manifest" >&2
      exit 15
    fi
    state="$(load_state_json)"
    state="$(jq -c --arg p "$phase" --arg ts "$(now_iso)" '
      .phase = $p
      | .current_phase = .phase
      | .last_updated = $ts
      | .phases[$p] = {status:"pending", exit_code:0, started_at:null, ended_at:null, input_sha256:null}' <<<"$state")"
    write_state_json "$state"
    return 0
  fi
  while IFS='  ' read -r hash rel backup; do
    [[ -n "$rel" ]] || continue
    current="$(hash_file "$PROJECT_ROOT/$rel")"
    if [[ "$hash" == "MISSING" ]]; then
      [[ ! -e "$PROJECT_ROOT/$rel" ]] || /bin/rm -f "$PROJECT_ROOT/$rel"
    else
      [[ -f "$backup" ]] || { printf 'rollback backup not found: %s\n' "$backup" >&2; exit 15; }
      mkdir -p "$(dirname "$PROJECT_ROOT/$rel")"
      cp "$backup" "$PROJECT_ROOT/$rel"
      [[ "$(hash_file "$PROJECT_ROOT/$rel")" == "$hash" ]] || exit 15
    fi
    vlog "rollback $phase: $rel $current -> $hash"
  done < "$manifest"
  state="$(load_state_json)"
  state="$(jq -c --arg p "$phase" --arg ts "$(now_iso)" '
    .phase = $p
    | .current_phase = .phase
    | .last_updated = $ts
    | .phases[$p] = {status:"pending", exit_code:0, started_at:null, ended_at:null, input_sha256:null}' <<<"$state")"
  write_state_json "$state"
}

# Tier-1 harness-owned registry files (.agent/registry/rev_harness_distribution_manifest.json
# managed_candidate_globs) are not blind-copied wholesale by install -- that full-tree sync is
# the (currently deferred) `rev-harness upgrade apply`. But harness-doctor.sh unconditionally
# BLOCKs on a missing .agent/registry/model_policy.json and its generated runtime artifact, and
# install's own final phase IS doctor -- so a first-time adopter must leave install with at
# least this minimum populated, or every fresh install ends in a guaranteed BLOCK with no
# existing command able to clear it. Copy just the model-policy source (create-if-absent; it is
# harness-owned so blind-overwrite is safe) and regenerate the derived runtime artifact locally
# via the canonical generator so the two always hash-match.
sync_registry_model_policy() {
  local src_policy="$HARNESS_ROOT/.agent/registry/model_policy.json"
  local src_runtime="$HARNESS_ROOT/.agent/generated/codex_model_policy.runtime.json"

  [[ -f "$src_policy" && ! -L "$src_policy" ]] || return 0

  # The runtime artifact is a derived, hash-linked-to-policy file that is
  # intentionally NOT part of this checkout's tracked distribution
  # (.agent/generated/** is adopter-local/preserve-only, so a fresh clone of
  # the harness itself has none either). `generate` also cross-checks the
  # harness's OWN docs/.codex mirrors against model_policy.json, which is
  # only meaningful run against HARNESS_ROOT -- never against an arbitrary
  # adopter tree, whose docs/.codex layout is adopter-owned and unrelated.
  # So: (re)generate the harness checkout's own runtime artifact here, then
  # hand the adopter an exact copy of both the policy and its matching
  # runtime file.
  if [[ -f "$HARNESS_ROOT/scripts/model-policy.sh" ]]; then
    # NOTE: this script's own resolve_setup_roots() exports PROJECT_ROOT=
    # $TARGET_ROOT for the adopter phases; explicitly re-point it at
    # HARNESS_ROOT here or model-policy.sh would silently self-check the
    # adopter tree instead of the harness checkout.
    if ! PROJECT_ROOT="$HARNESS_ROOT" bash "$HARNESS_ROOT/scripts/model-policy.sh" generate; then
      printf '[rev-harness-adopter-setup] WARNING: failed to (re)generate the harness checkout own model-policy runtime artifact; adopter will be left without one and doctor will BLOCK on it\n' >&2
      return 0
    fi
  fi

  mkdir -p "$TARGET_ROOT/.agent/registry"
  cp "$src_policy" "$TARGET_ROOT/.agent/registry/model_policy.json"

  if [[ -f "$src_runtime" ]]; then
    mkdir -p "$TARGET_ROOT/.agent/generated"
    cp "$src_runtime" "$TARGET_ROOT/.agent/generated/codex_model_policy.runtime.json"
  fi
}

run_phase_command() {
  local phase="$1"
  case "$phase" in
    init) (cd "$TARGET_ROOT" && PROJECT_ROOT="$TARGET_ROOT" HARNESS_ROOT="$HARNESS_ROOT" REVHARNESS_PARALLEL_QUIESCE=1 REVHARNESS_INIT_PHASE_OF_SETUP=1 bash "$HARNESS_ROOT/scripts/init-project.sh" adopter) ;;
    hooks)
      (cd "$TARGET_ROOT" && PROJECT_ROOT="$TARGET_ROOT" HARNESS_ROOT="$HARNESS_ROOT" REVHARNESS_PARALLEL_QUIESCE=1 bash "$HARNESS_ROOT/scripts/install-rev-harness-hooks.sh" install --adopter-root "$TARGET_ROOT" --harness-root "$HARNESS_ROOT") || return $?
      sync_registry_model_policy
      ;;
    doctor)
      if [[ "$STRICT" == true ]]; then
        (cd "$TARGET_ROOT" && PROJECT_ROOT="$TARGET_ROOT" HARNESS_ROOT="$HARNESS_ROOT" REVHARNESS_PARALLEL_QUIESCE=1 bash "$HARNESS_ROOT/scripts/harness-doctor.sh" --quick --strict --json)
      else
        (cd "$TARGET_ROOT" && PROJECT_ROOT="$TARGET_ROOT" HARNESS_ROOT="$HARNESS_ROOT" REVHARNESS_PARALLEL_QUIESCE=1 bash "$HARNESS_ROOT/scripts/harness-doctor.sh" --quick --json)
      fi
      ;;
  esac
}

phase_sequence() {
  case "$SUBCOMMAND" in
    init) printf 'init\n' ;;
    setup|resume) printf '%s\n' $CORE_PHASES ;;
    verify) printf 'doctor\n' ;;
  esac
}

should_skip_phase() {
  local state="$1" phase="$2" recorded current
  [[ "$RESUME" == true ]] || return 1
  [[ "$(jq -r --arg p "$phase" '.phases[$p].status' <<<"$state")" == "ok" ]] || return 1
  recorded="$(jq -r --arg p "$phase" '.phases[$p].input_sha256 // empty' <<<"$state")"
  current="$(phase_input_sha "$phase")"
  [[ -n "$recorded" && "$recorded" == "$current" ]]
}

run_phases() {
  local state phase input rc phase_code
  state="$(load_state_json)"
  RUN_ID="$(jq -r '.run_id' <<<"$state")"
  for phase in $(phase_sequence); do
    if [[ "$DRY_RUN" == true ]]; then
      input="$(phase_input_sha "$phase")"
      event phase_started "$phase" running 0 "$input"
      event phase_ok "$phase" ok 0 "$input"
      continue
    fi
    if should_skip_phase "$state" "$phase"; then
      input="$(phase_input_sha "$phase")"
      event verified-skip "$phase" ok 0 "$input"
      continue
    fi
    input="$(phase_input_sha "$phase")"
    snapshot_phase "$phase"
    event phase_started "$phase" running 0 "$input"
    state="$(state_update_phase "$state" "$phase" running 0 "$input")"; write_state_json "$state"
    vlog "running phase=$phase"
    set +e
    run_phase_command "$phase"
    rc=$?
    set -e
    input="$(phase_input_sha "$phase")"
    if [[ "$rc" -eq 0 ]]; then
      state="$(state_update_phase "$state" "$phase" ok 0 "$input")"; write_state_json "$state"
      event phase_ok "$phase" ok 0 "$input"
    else
      phase_code="$(phase_exit_code "$phase")"
      state="$(state_update_phase "$state" "$phase" failed "$rc" "$input")"; write_state_json "$state"
      event phase_failed "$phase" failed "$rc" "$input"
      EXIT_CODE="$phase_code"
      return "$phase_code"
    fi
  done
  if [[ "$DRY_RUN" == false && "$SUBCOMMAND" != "verify" ]]; then
    state="$(load_state_json)"
    state="$(jq -c --arg ts "$(now_iso)" '.last_install_at = $ts | .last_updated = $ts' <<<"$state")"
    write_state_json "$state"
  fi
  return 0
}

render_report() {
  local status="$1" code="$2" state phase_json
  if [[ -f "$STATE_FILE" && "$DRY_RUN" == false ]]; then
    state="$(cat "$STATE_FILE")"
    phase_json="$(jq -c '.phases' <<<"$state")"
    printf '{"schema_version":"%s","status":"%s","run_id":"%s","current_phase":"%s","phases":%s,"exit_code":%s}\n' \
      "$REPORT_SCHEMA" "$status" "$(jq -r '.run_id' <<<"$state")" "$(jq -r '.current_phase' <<<"$state")" "$phase_json" "$code"
  else
    printf '{"schema_version":"%s","status":"%s","run_id":"%s","current_phase":"%s","phases":{},"exit_code":%s}\n' \
      "$REPORT_SCHEMA" "$status" "$RUN_ID" "${SUBCOMMAND:-status}" "$code"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    init|setup|verify|resume|status) SUBCOMMAND="$1"; [[ "$1" == "resume" ]] && RESUME=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --strict) STRICT=true; shift ;;
    --target) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; TARGET_ARG="$2"; shift 2 ;;
    --resume) RESUME=true; shift ;;
    --rollback) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; ROLLBACK="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ -n "$SUBCOMMAND" ]] || { usage >&2; exit 2; }
resolve_setup_roots
require_tools

if [[ "$SUBCOMMAND" == "status" ]]; then
  RUN_ID="$(new_run_id)"
  if [[ "$JSON_OUTPUT" == true ]]; then
    render_report ok 0
  elif [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    printf 'no state file: %s\n' "$STATE_FILE"
  fi
  exit 0
fi

if [[ -n "$ROLLBACK" ]]; then
  [[ "$DRY_RUN" == false ]] || exit 0
  state="$(load_state_json)"
  RUN_ID="$(jq -r '.run_id' <<<"$state")"
  if [[ "$ROLLBACK" == "all" ]]; then
    for p in doctor hooks init; do rollback_phase "$p"; done
  else
    rollback_phase "$ROLLBACK"
  fi
  render_report ok 0
  exit 0
fi

if run_phases; then
  event run_summary "" ok 0 ""
  [[ "$JSON_OUTPUT" == true ]] && render_report ok 0
  exit 0
else
  code="$EXIT_CODE"
  event run_summary "" failed "$code" ""
  [[ "$JSON_OUTPUT" == true ]] && render_report failed "$code"
  exit "$code"
fi
