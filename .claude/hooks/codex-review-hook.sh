#!/bin/sh
# shellcheck shell=bash
if [ "${1-}" != "--__codex-review-hook-bash__" ]; then
  unset BASH_ENV ENV JQ_BIN
  exec /bin/bash --noprofile --norc "$0" --__codex-review-hook-bash__ "$@"
fi
shift
#
# codex-review-hook.sh - shell adapter for review-queue hook ingress
#
# The caller-facing hook path remains a shell adapter ingress for Claude Code
# compatibility. P3 moved PostToolUse pre-filtering into this shell adapter so
# skipped files do not require Rust toolchain work.
# Hook ingress pins the core review queue backend: inherited
# REVHARNESS_REVIEW_QUEUE_BACKEND is unset before invoking the queue helper.
#
set -euo pipefail

script_dir() {
  local source_path="${BASH_SOURCE[0]}"
  case "$source_path" in
    */*)
      cd "${source_path%/*}" && pwd -P
      ;;
    *)
      pwd -P
      ;;
  esac
}

log_hook() {
  echo "[review-hook] $*" >&2
}

die_hook() {
  log_hook "ERROR: $*"
  exit 1
}

SCRIPT_DIR="$(script_dir)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
QUEUE_FILE="${REPO_ROOT}/.claude/tmp/review_queue.json"
QUEUE_HELPER="${REPO_ROOT}/scripts/review-queue.sh"

# Trusted absolute directories that may supply `jq`, scanned in this fixed
# order. Resolution deliberately ignores inherited PATH ordering and the
# (now-unset) JQ_BIN env so an attacker cannot inject a binary by reordering
# PATH or exporting JQ_BIN. This mirrors the trusted-binary philosophy in
# scripts/review-queue.sh (trusted_system_binary_path /
# is_trusted_runtime_binary): resolve only from a fixed allowlist, then
# validate the canonical target.
TRUSTED_JQ_DIRS=(
  /usr/bin
  /bin
  /usr/local/bin
  /opt/homebrew/bin
  /opt/local/bin
)

# Trusted prefix roots that a trusted-dir `jq` symlink may legitimately resolve
# into. Standard package managers place the real binary in a versioned install
# tree (e.g. Homebrew's /opt/homebrew/Cellar, MacPorts' /opt/local) and expose
# it via a symlink in a trusted bin dir; canonicalizing must not reject that
# normal layout. Anything resolving outside these roots is rejected.
TRUSTED_JQ_PREFIXES=(
  /usr
  /bin
  /usr/local
  /opt/homebrew
  /opt/local
)

canonicalize_existing_file() {
  # Resolve an existing regular file to its canonical absolute path by
  # canonicalizing the parent directory (via cd/pwd -P, which resolves all
  # symlink components) and re-appending the leaf. Fails if the parent is not a
  # real directory or the leaf is not a regular file after resolution.
  local target="${1:-}"
  local parent_dir=""
  local leaf=""
  local canonical_parent=""
  local canonical_path=""

  [[ -n "$target" && "$target" == /* ]] || return 1
  parent_dir="${target%/*}"
  [[ -n "$parent_dir" ]] || parent_dir="/"
  leaf="${target##*/}"
  [[ -n "$leaf" ]] || return 1

  canonical_parent="$(cd "$parent_dir" 2>/dev/null && pwd -P)" || return 1
  if [[ "$canonical_parent" == "/" ]]; then
    canonical_path="/$leaf"
  else
    canonical_path="$canonical_parent/$leaf"
  fi

  # The leaf itself may be a symlink; resolve one more hop via its own parent.
  while [[ -L "$canonical_path" ]]; do
    local link_target=""
    link_target="$(/usr/bin/readlink "$canonical_path")" || return 1
    if [[ "$link_target" != /* ]]; then
      link_target="${canonical_path%/*}/$link_target"
    fi
    local next_parent="${link_target%/*}"
    [[ -n "$next_parent" ]] || next_parent="/"
    local next_leaf="${link_target##*/}"
    canonical_parent="$(cd "$next_parent" 2>/dev/null && pwd -P)" || return 1
    if [[ "$canonical_parent" == "/" ]]; then
      canonical_path="/$next_leaf"
    else
      canonical_path="$canonical_parent/$next_leaf"
    fi
  done

  [[ -f "$canonical_path" && -x "$canonical_path" && ! -L "$canonical_path" ]] || return 1
  printf '%s\n' "$canonical_path"
}

canonical_jq_target_is_trusted() {
  # The canonical jq target must live under a trusted prefix root, must not be
  # under the repo root, and must not sit in a world-writable directory (shim /
  # tampering protection in the spirit of the queue helper).
  local canonical_path="${1:-}"
  local prefix=""
  local matched=0
  local canonical_repo_root=""
  local target_dir=""

  [[ -n "$canonical_path" && "$canonical_path" == /* ]] || return 1

  for prefix in "${TRUSTED_JQ_PREFIXES[@]}"; do
    if [[ "$canonical_path" == "$prefix" || "$canonical_path" == "$prefix/"* ]]; then
      matched=1
      break
    fi
  done
  (( matched == 1 )) || return 1

  # Never trust a jq that resolves inside the repo tree.
  canonical_repo_root="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || canonical_repo_root="$REPO_ROOT"
  if [[ "$canonical_path" == "$canonical_repo_root" || "$canonical_path" == "$canonical_repo_root/"* ]]; then
    return 1
  fi

  # Reject world-writable hosting directories (drop-in shim surface). Inspect
  # the "other" write bit from the mode string rather than -w (which only
  # reflects the current caller's access).
  local perms=""
  target_dir="${canonical_path%/*}"
  [[ -n "$target_dir" ]] || target_dir="/"
  perms="$(/bin/ls -ld "$target_dir" 2>/dev/null | cut -c1-10)"
  [[ -n "$perms" ]] || return 1
  [[ "${perms:8:1}" != "w" ]] || return 1

  return 0
}

resolve_jq() {
  local dir=""
  local candidate=""
  local canonical_path=""

  for dir in "${TRUSTED_JQ_DIRS[@]}"; do
    candidate="$dir/jq"
    [[ -x "$candidate" && ! -d "$candidate" ]] || continue
    canonical_path="$(canonicalize_existing_file "$candidate")" || continue
    canonical_jq_target_is_trusted "$canonical_path" || continue
    printf '%s\n' "$canonical_path"
    return 0
  done

  die_hook "no trusted jq found in: ${TRUSTED_JQ_DIRS[*]}"
}

parse_json_field() {
  # Fail-closed JSON field read. Distinguishes:
  #   * jq ran and the field is legitimately absent  -> stdout empty, rc 0
  #   * jq ran and the field is present              -> stdout value, rc 0
  #   * jq INVOCATION failed (broken/hostile binary) -> die_hook (fail-closed)
  # We do NOT use `jq -e` here (whose non-zero "empty result" status is
  # indistinguishable from a real execution failure) and we never swallow the
  # status with `|| true`. Instead we capture jq's real exit status and treat
  # any non-zero as a hard failure.
  local jq_bin="$1"
  local filter="$2"
  local payload="$3"
  local output=""
  local status=0

  output="$("$jq_bin" -r "$filter" <<< "$payload" 2>/dev/null)" || status=$?
  if (( status != 0 )); then
    die_hook "jq invocation failed (rc=$status) while parsing hook input; refusing to fail open"
  fi
  # jq prints the literal string "null" for an absent field with `// empty`
  # already guarding that, but guard defensively in case the filter yields null.
  [[ "$output" != "null" ]] || output=""
  printf '%s' "$output"
}

trim_trailing_slash() {
  local path_value="${1:-}"
  while [[ "$path_value" != "/" && "$path_value" == */ ]]; do
    path_value="${path_value%/}"
  done
  printf '%s\n' "$path_value"
}

dirname_shell() {
  local path_value="${1:-}"
  path_value="$(trim_trailing_slash "$path_value")"
  case "$path_value" in
    */*)
      path_value="${path_value%/*}"
      [[ -n "$path_value" ]] || path_value="/"
      printf '%s\n' "$path_value"
      ;;
    *)
      printf '.\n'
      ;;
  esac
}

path_extension() {
  local path_value="${1:-}"
  local base_name=""

  base_name="${path_value##*/}"
  case "$base_name" in
    ""|.*)
      if [[ "$base_name" != *.* || "$base_name" == .* && "${base_name#*.}" != *.* ]]; then
        printf '\n'
        return 0
      fi
      ;;
  esac
  [[ "$base_name" == *.* ]] || {
    printf '\n'
    return 0
  }
  printf '%s\n' "${base_name##*.}"
}

is_code_file() {
  local path_value="${1:-}"
  local ext=""

  ext="$(path_extension "$path_value")"
  case "$ext" in
    sh|py|js|ts|tsx|rs|go|java|rb|php|c|cpp|h|hpp)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

path_starts_with_root() {
  local path_value="${1:-}"
  local root="${2:-}"
  [[ "$path_value" == "$root" || "$path_value" == "$root/"* ]]
}

normalize_candidate_path() {
  local candidate="${1:-}"
  local canonical_repo_root="${2:-}"
  local depth="${3:-0}"
  local current=""
  local remaining=""
  local component=""
  local target=""
  local target_path=""

  [[ -n "$candidate" ]] || die_hook "path is required"
  [[ "$candidate" == /* ]] || die_hook "absolute path is required for normalization: $candidate"
  (( depth <= 40 )) || die_hook "too many symlink expansions while normalizing: $candidate"

  current="/"
  remaining="${candidate#/}"
  while [[ -n "$remaining" ]]; do
    if [[ "$remaining" == */* ]]; then
      component="${remaining%%/*}"
      remaining="${remaining#*/}"
    else
      component="$remaining"
      remaining=""
    fi

    case "$component" in
      ""|.)
        continue
        ;;
      ..)
        if [[ "$current" != "/" ]]; then
          current="${current%/*}"
          [[ -n "$current" ]] || current="/"
        fi
        continue
        ;;
    esac

    if [[ "$current" == "/" ]]; then
      current="/$component"
    else
      current="$current/$component"
    fi

    if [[ -L "$current" ]]; then
      target="$(/usr/bin/readlink "$current")" \
        || die_hook "failed to read symlink: $current"
      if [[ "$target" == /* ]]; then
        target_path="$target"
      else
        target_path="$(dirname_shell "$current")/$target"
      fi
      current="$(normalize_candidate_path "$target_path" "$canonical_repo_root" "$((depth + 1))")"
    elif [[ -e "$current" ]]; then
      :
    else
      # Match the old Rust hook: missing suffixes stay lexical so newly
      # created files can still be normalized before they exist.
      :
    fi
  done

  printf '%s\n' "$(trim_trailing_slash "$current")"
}

normalize_file_path() {
  local raw_path="${1:-}"
  local canonical_repo_root="${2:-}"
  local candidate=""
  local normalized=""
  local relative=""

  [[ -n "$raw_path" ]] || die_hook "path is required"
  [[ -n "$canonical_repo_root" ]] || die_hook "repo root is required"

  if [[ "$raw_path" == /* ]]; then
    candidate="$raw_path"
  else
    candidate="${canonical_repo_root}/${raw_path}"
  fi

  normalized="$(normalize_candidate_path "$candidate" "$canonical_repo_root")"
  if ! path_starts_with_root "$normalized" "$canonical_repo_root"; then
    printf 'outside:%s\n' "$raw_path"
    return 0
  fi

  relative="${normalized#"$canonical_repo_root"}"
  relative="${relative#/}"
  printf 'relative:%s\n' "$relative"
}

ensure_queue_helper_executable() {
  [[ -f "$QUEUE_HELPER" && -x "$QUEUE_HELPER" ]] \
    || die_hook "queue helper not found or not executable: $QUEUE_HELPER"
}

parse_duplicate_flag() {
  local output="${1:-}"
  local jq_bin="$2"

  if "$jq_bin" -e '.duplicate == true' >/dev/null 2>&1 <<< "$output"; then
    return 0
  fi
  return 1
}

enqueue_file() {
  local file_path="$1"
  local jq_bin="$2"
  local enqueue_output=""

  ensure_queue_helper_executable
  if ! enqueue_output="$(/usr/bin/env -u REVHARNESS_REVIEW_QUEUE_BACKEND \
    "$QUEUE_HELPER" enqueue \
    --repo-root "$REPO_ROOT" \
    --file-path "$file_path" \
    --source hook \
    --export-json "$QUEUE_FILE")"; then
    die_hook "Failed to enqueue DB review queue item for: $file_path"
  fi

  if parse_duplicate_flag "$enqueue_output" "$jq_bin"; then
    log_hook "Already pending in DB review queue: $file_path"
  else
    log_hook "Queued for review via DB authority: $file_path"
  fi
}

main() {
  local jq_bin=""
  local input=""
  local tool_name=""
  local raw_file_path=""
  local normalized_result=""
  local normalized_kind=""
  local normalized_path=""

  jq_bin="$(resolve_jq)"
  input="$(cat)"
  input="${input#"${input%%[!$' \t\r\n']*}"}"
  input="${input%"${input##*[!$' \t\r\n']}"}"
  [[ -n "$input" ]] || return 0

  tool_name="$(parse_json_field "$jq_bin" '.tool_name // empty' "$input")"
  [[ -n "$tool_name" ]] || return 0
  case "$tool_name" in
    Edit|Write)
      ;;
    *)
      return 0
      ;;
  esac

  raw_file_path="$(parse_json_field "$jq_bin" '.tool_input.file_path // empty' "$input")"
  [[ -n "$raw_file_path" ]] || return 0

  normalized_result="$(normalize_file_path "$raw_file_path" "$REPO_ROOT")"
  normalized_kind="${normalized_result%%:*}"
  normalized_path="${normalized_result#*:}"
  case "$normalized_kind" in
    outside)
      log_hook "Skipping file outside repo: $normalized_path"
      return 0
      ;;
    relative)
      ;;
    *)
      die_hook "internal normalization error for: $raw_file_path"
      ;;
  esac

  is_code_file "$normalized_path" || return 0
  enqueue_file "$normalized_path" "$jq_bin"
}

main "$@"
