#!/usr/bin/env bash
# Validate Revharness INDEX maps.
#
# Usage:
#   scripts/ci/index-map-check.sh [--strict] [--map docs/INDEX_MAP-X.md] [--base <ref>] [--worktree] [--exempt <pathspec>]
#
# Checks:
#   1. Manifest bijection and pairwise disjoint map scopes.
#   2. Contract header completeness and last-verified commit resolvability.
#   3. Seven-column row shape, enum validity, and map size caps.
#   4. Header and row path resolution, with deprecated/dead-code removed exceptions.
#   5. Invariant ID and executable script reference existence in checks cells.
#   6. Committed-diff freshness with rename handling and Index-Exempt trailers.
#   7. last-verified-commit staleness policy over scoped commits.
#   8. unknown budget and strict gate-unknown rejection.
#
# Exit codes: 0 clean, 1 policy violation, 2 usage error, 3 environment failure.
set -euo pipefail

STRICT=0
BASE_REF=""
WORKTREE=0
MAP_FILTERS=()
EXEMPT_SPECS=()
STALE_THRESHOLD=30
MAX_LINES=250
MAX_ROWS=60

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/ci/index-map-check.sh [--strict] [--map docs/INDEX_MAP-X.md] [--base <ref>] [--worktree] [--exempt <pathspec>]

Exit codes:
  0  clean
  1  policy violation
  2  usage error
  3  environment failure
USAGE
}

die_usage() {
  printf 'index-map-check: %s\n' "$*" >&2
  usage
  exit 2
}

die_env() {
  printf 'index-map-check: %s\n' "$*" >&2
  exit 3
}

failures=0
warnings=0

fail() {
  printf 'FAIL[%s] %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
}

warn() {
  printf 'WARN[%s] %s\n' "$1" "$2" >&2
  warnings=$((warnings + 1))
}

soft() {
  if [[ "$STRICT" -eq 1 ]]; then
    fail "$1" "$2"
  else
    warn "$1" "$2"
  fi
}

trim() {
  local s="$1"
  s="${s#"${s%%[!$' \t\r\n']*}"}"
  s="${s%"${s##*[!$' \t\r\n']}"}"
  printf '%s' "$s"
}

contains_glob() {
  local s="$1"
  [[ "$s" == *'*'* || "$s" == *'?'* || "$s" == *'['* || "$s" == *']'* ]]
}

strip_glob_magic() {
  local s="$1"
  s="${s#:}"
  if [[ "$s" == "(glob)"* ]]; then
    s="${s#"(glob)"}"
  fi
  printf '%s' "$s"
}

is_live_enum() {
  case "$1" in
    default-live|live-when-invoked|opt-in|advisory|dev-only|test-only|deprecated|dead-code|unknown) return 0 ;;
    *) return 1 ;;
  esac
}

is_authority_enum() {
  case "$1" in
    gate|contract|tool|config|doc|evidence) return 0 ;;
    *) return 1 ;;
  esac
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=1
      shift
      ;;
    --map)
      [[ "$#" -ge 2 ]] || die_usage "--map requires a value"
      MAP_FILTERS+=("$2")
      shift 2
      ;;
    --base)
      [[ "$#" -ge 2 ]] || die_usage "--base requires a value"
      BASE_REF="$2"
      shift 2
      ;;
    --worktree)
      WORKTREE=1
      shift
      ;;
    --exempt)
      [[ "$#" -ge 2 ]] || die_usage "--exempt requires a value"
      EXEMPT_SPECS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done

command -v git >/dev/null 2>&1 || die_env "git is required"
command -v rg >/dev/null 2>&1 || die_env "rg is required"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die_env "not a git repository"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || die_env "cannot resolve repository root"

INDEX_ROOT="${INDEX_MAP_ROOT:-$REPO_ROOT}"
MANIFEST_REL="docs/INDEX_MANIFEST.md"
CANONICAL_REL="docs/canonical-invariants.md"
MANIFEST_PATH="$INDEX_ROOT/$MANIFEST_REL"
CANONICAL_PATH="$REPO_ROOT/$CANONICAL_REL"

[[ -r "$MANIFEST_PATH" ]] || die_env "manifest not readable: $MANIFEST_REL"
[[ -r "$CANONICAL_PATH" ]] || die_env "canonical invariants not readable: $CANONICAL_REL"

declare -A TRACKED_FILES=()
while IFS= read -r tracked_file; do
  [[ -n "$tracked_file" ]] && TRACKED_FILES["$tracked_file"]=1
done < <(git -C "$REPO_ROOT" ls-files)

declare -A VALID_INVARIANTS=()
while IFS= read -r invariant_id; do
  [[ -n "$invariant_id" ]] && VALID_INVARIANTS["$invariant_id"]=1
done < <(rg -o '(I-[0-9]+[a-z]?|Addon-I-[0-9]+[a-z]?)' "$CANONICAL_PATH" | while IFS= read -r line; do printf '%s\n' "${line##*:}"; done)

declare -A PATHSPEC_CACHE_READY=()
declare -A PATHSPEC_CACHE_OK=()
declare -A PATHSPEC_CACHE_LINES=()
declare -A MAP_SCOPE_SET=()
declare -A MAP_HEAD_PRESENT=()
declare -A COMMIT_RESOLVES=()
declare -A EXEMPT_FILE_SET=()

rel_path_for() {
  local path="$1"
  if [[ "$path" == "$INDEX_ROOT/"* ]]; then
    printf '%s' "${path#"$INDEX_ROOT"/}"
  else
    printf '%s' "$path"
  fi
}

read_path_for_rel() {
  local rel="$1"
  if [[ -e "$INDEX_ROOT/$rel" ]]; then
    printf '%s' "$INDEX_ROOT/$rel"
  else
    printf '%s' "$REPO_ROOT/$rel"
  fi
}

map_exists_for_rel() {
  local rel="$1"
  [[ -f "$INDEX_ROOT/$rel" || -f "$REPO_ROOT/$rel" ]]
}

resolve_pathspec_lines() {
  local spec="$1"
  local out stripped
  if [[ -n "${PATHSPEC_CACHE_READY["$spec"]:-}" ]]; then
    if [[ "${PATHSPEC_CACHE_OK["$spec"]}" -eq 1 ]]; then
      printf '%s\n' "${PATHSPEC_CACHE_LINES["$spec"]}"
      return 0
    fi
    return 1
  fi
  stripped="$(strip_glob_magic "$spec")"
  if ! contains_glob "$stripped"; then
    if [[ -n "${TRACKED_FILES["$stripped"]:-}" || -e "$REPO_ROOT/$stripped" || -e "$INDEX_ROOT/$stripped" ]]; then
      PATHSPEC_CACHE_READY["$spec"]=1
      PATHSPEC_CACHE_OK["$spec"]=1
      PATHSPEC_CACHE_LINES["$spec"]="$stripped"
      printf '%s\n' "$stripped"
      return 0
    fi
    PATHSPEC_CACHE_READY["$spec"]=1
    PATHSPEC_CACHE_OK["$spec"]=0
    PATHSPEC_CACHE_LINES["$spec"]=""
    return 1
  fi
  out="$(git -C "$REPO_ROOT" ls-files -- "$stripped" 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    PATHSPEC_CACHE_READY["$spec"]=1
    PATHSPEC_CACHE_OK["$spec"]=1
    PATHSPEC_CACHE_LINES["$spec"]="$out"
    printf '%s\n' "$out"
    return 0
  fi
  PATHSPEC_CACHE_READY["$spec"]=1
  PATHSPEC_CACHE_OK["$spec"]=0
  PATHSPEC_CACHE_LINES["$spec"]=""
  return 1
}

pathspec_resolves() {
  local spec="$1"
  [[ "$spec" == "-" || -z "$spec" ]] && return 0
  [[ -n "$(resolve_pathspec_lines "$spec" || true)" ]]
}

line_count_file() {
  local file="$1" count=0 line
  while IFS= read -r line; do
    count=$((count + 1))
  done < "$file"
  printf '%s' "$count"
}

split_words() {
  local value="$1" token
  [[ "$value" == "-" || -z "$value" ]] && return 0
  for token in $value; do
    printf '%s\n' "$token"
  done
}

declare -a DISK_MAPS=()
if [[ "${#MAP_FILTERS[@]}" -gt 0 ]]; then
  for map in "${MAP_FILTERS[@]}"; do
    [[ "$map" == docs/INDEX_MAP-*.md ]] || die_usage "--map must be docs/INDEX_MAP-*.md: $map"
    map_exists_for_rel "$map" || die_usage "--map file missing: $map"
    DISK_MAPS+=("$map")
  done
else
  if [[ "$INDEX_ROOT" != "$REPO_ROOT" ]]; then
    while IFS= read -r path; do
      DISK_MAPS+=("$(rel_path_for "$path")")
    done < <(rg --files "$INDEX_ROOT/docs" -g 'INDEX_MAP-*.md' 2>/dev/null || true)
else
    declare -A seen_disk_map=()
    while IFS= read -r path; do
      [[ -n "${seen_disk_map["$path"]:-}" ]] && continue
      seen_disk_map["$path"]=1
      DISK_MAPS+=("$path")
    done < <(git -C "$REPO_ROOT" ls-files 'docs/INDEX_MAP-*.md')
    while IFS= read -r path; do
      [[ -n "${seen_disk_map["$path"]:-}" ]] && continue
      seen_disk_map["$path"]=1
      DISK_MAPS+=("$path")
    done < <(git -C "$REPO_ROOT" ls-files --others --exclude-standard 'docs/INDEX_MAP-*.md')
  fi
fi

[[ "${#DISK_MAPS[@]}" -gt 0 ]] || fail "manifest" "no docs/INDEX_MAP-*.md files found"

declare -A REGISTRY_PRESENT=()
declare -a REGISTRY_MAPS=()
while IFS= read -r line; do
  [[ "$line" == \|* ]] || continue
  body="${line#|}"
  body="${body%|}"
  IFS='|' read -r c1 c2 c3 c4 c5 c6 extra <<< "$body"
  map="$(trim "$c1")"
  [[ "$map" == docs/INDEX_MAP-*.md ]] || continue
  if [[ -n "${extra:-}" ]]; then
    fail "manifest" "registry row has too many columns for $map"
  fi
  REGISTRY_PRESENT["$map"]=1
  REGISTRY_MAPS+=("$map")
  [[ -n "$(trim "$c2")" && -n "$(trim "$c3")" && -n "$(trim "$c4")" && -n "$(trim "$c5")" && -n "$(trim "$c6")" ]] \
    || fail "manifest" "registry row for $map has empty required metadata"
done < "$MANIFEST_PATH"

for map in "${DISK_MAPS[@]}"; do
  [[ -n "${REGISTRY_PRESENT[$map]:-}" ]] || fail "manifest" "$map exists on disk but is missing from manifest registry"
done
for map in "${REGISTRY_MAPS[@]}"; do
  map_exists_for_rel "$map" || fail "manifest" "$map is registered but does not exist"
done

declare -A HEADER_VALUE=()
declare -A MAP_SCOPE_FILES=()

required_keys=(purpose scope out-of-scope row-granularity last-updated last-verified-commit related-invariants validation update-triggers exceptions unknown-budget)

parse_header() {
  local map="$1" file="$2" in_header=0 line key value seen=0
  for key in "${required_keys[@]}"; do
    HEADER_VALUE["$map:$key"]=""
  done
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "## Contract Header" ]]; then
      in_header=1
      seen=1
      continue
    fi
    if [[ "$in_header" -eq 1 && "$line" == "## "* ]]; then
      break
    fi
    if [[ "$in_header" -eq 1 && "$line" =~ ^-[[:space:]]+([^:]+):(.*)$ ]]; then
      key="$(trim "${BASH_REMATCH[1]}")"
      value="$(trim "${BASH_REMATCH[2]}")"
      HEADER_VALUE["$map:$key"]="$value"
    fi
  done < "$file"
  [[ "$seen" -eq 1 ]] || fail "header" "$map missing ## Contract Header"
  for key in "${required_keys[@]}"; do
    [[ -n "${HEADER_VALUE["$map:$key"]}" ]] || fail "header" "$map missing header key: $key"
  done
}

parse_rows() {
  local map="$1" file="$2" in_rows=0 line body c1 c2 c3 c4 c5 c6 c7 extra pipes row_count=0 unknown_count=0 unknown_budget
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "## Rows" ]]; then
      in_rows=1
      continue
    fi
    if [[ "$in_rows" -eq 1 && "$line" == "## "* ]]; then
      break
    fi
    [[ "$in_rows" -eq 1 && "$line" == \|* ]] || continue
    [[ "$line" == "|---"* || "$line" == "| path "* ]] && continue
    pipes="${line//[!|]/}"
    if [[ "${#pipes}" -ne 8 ]]; then
      fail "row-shape" "$map row must have exactly 7 columns: $line"
      continue
    fi
    body="${line#|}"
    body="${body%|}"
    IFS='|' read -r c1 c2 c3 c4 c5 c6 c7 extra <<< "$body"
    path="$(trim "$c1")"
    live="$(trim "$c4")"
    authority="$(trim "$c5")"
    checks="$(trim "$c6")"
    notes="$(trim "$c7")"
    row_count=$((row_count + 1))
    [[ -n "$path" ]] || fail "row-shape" "$map row has empty path"
    is_live_enum "$live" || fail "row-shape" "$map invalid live enum '$live' for $path"
    is_authority_enum "$authority" || fail "row-shape" "$map invalid authority enum '$authority' for $path"
    if [[ "$live" == "unknown" ]]; then
      unknown_count=$((unknown_count + 1))
      if [[ "$authority" == "gate" ]]; then
        soft "unknown" "$map has unknown live status on authority=gate row: $path"
      fi
    fi
    if [[ "$map" == "docs/INDEX_MAP-GATES.md" && ( -z "$checks" || "$checks" == "-" ) ]]; then
      fail "row-shape" "$map gate row has empty checks cell: $path"
    fi
    if [[ "$live" == "deprecated" || "$live" == "dead-code" ]] && [[ "$notes" == *"removed:"* ]]; then
      :
    elif [[ "$path" == "-" || -z "$path" ]]; then
      fail "path" "$map row has empty path"
    elif ! pathspec_resolves "$path"; then
      fail "path" "$map row path does not resolve: $path"
    fi
    validate_checks "$map" "$path" "$checks"
  done < "$file"
  if [[ "$row_count" -eq 0 ]]; then
    fail "row-shape" "$map has no rows in ## Rows"
  fi
  if [[ "$row_count" -gt "$MAX_ROWS" ]]; then
    fail "size" "$map has $row_count rows; max is $MAX_ROWS"
  fi
  unknown_budget="${HEADER_VALUE["$map:unknown-budget"]}"
  if [[ ! "$unknown_budget" =~ ^[0-9]+$ ]]; then
    fail "header" "$map unknown-budget must be an integer"
  elif [[ "$unknown_count" -gt "$unknown_budget" ]]; then
    soft "unknown" "$map unknown rows $unknown_count exceed budget $unknown_budget"
  fi
}

invariant_exists() {
  local id="$1"
  [[ -n "${VALID_INVARIANTS["$id"]:-}" ]]
}

validate_checks() {
  local map="$1" row_path="$2" checks="$3" token script_path
  [[ "$checks" == "-" || -z "$checks" ]] && return 0
  for token in $checks; do
    token="${token//\`/}"
    token="${token%,}"
    token="${token%;}"
    token="${token%.}"
    if [[ "$token" =~ ^(I-[0-9]+[a-z]?|Addon-I-[0-9]+[a-z]?)$ ]]; then
      invariant_exists "$token" || fail "reference" "$map row $row_path references missing invariant $token"
    elif [[ "$token" == scripts/* || "$token" == .claude/hooks/* || "$token" == test/integration/* ]]; then
      script_path="$REPO_ROOT/$token"
      [[ -e "$script_path" ]] || script_path="$INDEX_ROOT/$token"
      if [[ ! -e "$script_path" ]]; then
        fail "reference" "$map row $row_path references missing script $token"
      elif [[ "$token" == *.sh && ! -x "$script_path" ]]; then
        fail "reference" "$map row $row_path references non-executable script $token"
      fi
    fi
  done
}

path_in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$needle" == "$item" ]] && return 0
  done
  return 1
}

collect_scope_files() {
  local map="$1" scope out exceptions spec file files=() filtered=()
  local -A exclude_file=()
  scope="${HEADER_VALUE["$map:scope"]}"
  out="${HEADER_VALUE["$map:out-of-scope"]}"
  exceptions="${HEADER_VALUE["$map:exceptions"]}"
  while IFS= read -r spec; do
    pathspec_resolves "$spec" || fail "path" "$map header scope does not resolve: $spec"
    while IFS= read -r file; do
      [[ -n "$file" ]] && files+=("$file")
    done < <(resolve_pathspec_lines "$spec" || true)
  done < <(split_words "$scope")
  while IFS= read -r spec; do
    while IFS= read -r file; do
      [[ -n "$file" ]] && exclude_file["$file"]=1
    done < <(resolve_pathspec_lines "$spec" || true)
  done < <(split_words "$out"$'\n'"$exceptions")
  for file in "${files[@]}"; do
    [[ -n "${exclude_file["$file"]:-}" ]] && continue
    filtered+=("$file")
    MAP_SCOPE_SET["$map:$file"]=1
  done
  MAP_SCOPE_FILES["$map"]="${filtered[*]}"
}

resolve_base() {
  if [[ -n "$BASE_REF" ]]; then
    git -C "$REPO_ROOT" rev-parse --verify "$BASE_REF^{commit}" >/dev/null 2>&1 || return 1
    printf '%s' "$BASE_REF"
    return 0
  fi
  if git -C "$REPO_ROOT" rev-parse --verify origin/main >/dev/null 2>&1; then
    git -C "$REPO_ROOT" merge-base HEAD origin/main
    return 0
  fi
  if git -C "$REPO_ROOT" rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    printf '%s' "HEAD~1"
    return 0
  fi
  return 1
}

map_touched_in_worktree() {
  local map="$1" status
  if [[ "$INDEX_ROOT" != "$REPO_ROOT" ]]; then
    [[ -f "$INDEX_ROOT/$map" ]]
    return
  fi
  status="$(git -C "$REPO_ROOT" status --porcelain=v1 -- "$map" 2>/dev/null || true)"
  [[ -n "$status" ]]
}

map_committed_at_head() {
  local map="$1"
  if [[ -n "${MAP_HEAD_PRESENT["$map"]:-}" ]]; then
    [[ "${MAP_HEAD_PRESENT["$map"]}" -eq 1 ]]
    return
  fi
  if git -C "$REPO_ROOT" cat-file -e "HEAD:$map" 2>/dev/null; then
    MAP_HEAD_PRESENT["$map"]=1
    return 0
  fi
  MAP_HEAD_PRESENT["$map"]=0
  return 1
}

commit_resolves() {
  local commit="$1"
  if [[ -n "${COMMIT_RESOLVES["$commit"]:-}" ]]; then
    [[ "${COMMIT_RESOLVES["$commit"]}" -eq 1 ]]
    return
  fi
  if git -C "$REPO_ROOT" cat-file -e "$commit^{commit}" 2>/dev/null; then
    COMMIT_RESOLVES["$commit"]=1
    return 0
  fi
  COMMIT_RESOLVES["$commit"]=0
  return 1
}

commit_range_has_exempt() {
  local base="$1"
  git -C "$REPO_ROOT" log --format=%B "$base"..HEAD 2>/dev/null | rg -q '^Index-Exempt:[[:space:]]+.+'
}

changed_files_for_range() {
  local base="$1" line status rest p2 file
  git -C "$REPO_ROOT" diff --name-status -M "$base"...HEAD | while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r status rest <<< "$line"
    if [[ "$status" == R* ]]; then
      IFS=$'\t' read -r _ _old_path p2 <<< "$line"
      file="$p2"
    elif [[ "$status" == D* ]]; then
      continue
    else
      file="$rest"
    fi
    [[ -n "$file" ]] && printf '%s\n' "$file"
  done
}

file_exempt_by_arg() {
  local file="$1"
  [[ "${#EXEMPT_SPECS[@]}" -gt 0 && -n "${EXEMPT_FILE_SET["$file"]:-}" ]]
}

build_exempt_file_set() {
  local spec file
  [[ "${#EXEMPT_SPECS[@]}" -gt 0 ]] || return 0
  for spec in "${EXEMPT_SPECS[@]}"; do
    while IFS= read -r file; do
      [[ -n "$file" ]] && EXEMPT_FILE_SET["$file"]=1
    done < <(git -C "$REPO_ROOT" ls-files -- "$spec" 2>/dev/null || true)
  done
}

scope_contains_file() {
  local map="$1" file="$2"
  [[ -n "${MAP_SCOPE_SET["$map:$file"]:-}" ]]
}

for map in "${DISK_MAPS[@]}"; do
  file="$(read_path_for_rel "$map")"
  [[ -r "$file" ]] || { fail "manifest" "$map is not readable"; continue; }
  parse_header "$map" "$file"
  lines="$(line_count_file "$file")"
  if [[ "$lines" -gt "$MAX_LINES" ]]; then
    fail "size" "$map has $lines lines; max is $MAX_LINES"
  fi
  commit="${HEADER_VALUE["$map:last-verified-commit"]}"
  date="${HEADER_VALUE["$map:last-updated"]}"
  granularity="${HEADER_VALUE["$map:row-granularity"]}"
  validation="${HEADER_VALUE["$map:validation"]}"
  [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "header" "$map last-updated must be YYYY-MM-DD"
  [[ "$commit" =~ ^[0-9a-fA-F]{7,40}$ ]] || fail "header" "$map last-verified-commit must be 7-40 hex"
  commit_resolves "$commit" || fail "header" "$map last-verified-commit does not resolve: $commit"
  if commit_resolves "$commit"; then
    git -C "$REPO_ROOT" merge-base --is-ancestor "$commit" HEAD 2>/dev/null || fail "header" "$map last-verified-commit is not an ancestor of HEAD: $commit"
  fi
  [[ "$granularity" == "surface" || "$granularity" == "file" ]] || fail "header" "$map row-granularity must be surface or file"
  [[ "$validation" == "scripts/ci/index-map-check.sh" ]] || fail "header" "$map validation must be scripts/ci/index-map-check.sh"
  collect_scope_files "$map"
  parse_rows "$map" "$file"
done

declare -A SCOPE_OWNER=()
for map in "${DISK_MAPS[@]}"; do
  IFS=' ' read -r -a scoped_files <<< "${MAP_SCOPE_FILES["$map"]:-}"
  for scoped_file in "${scoped_files[@]}"; do
    [[ -n "$scoped_file" ]] || continue
    if [[ -n "${SCOPE_OWNER["$scoped_file"]:-}" ]]; then
      fail "manifest" "scope overlap between ${SCOPE_OWNER["$scoped_file"]} and $map: $scoped_file"
    else
      SCOPE_OWNER["$scoped_file"]="$map"
    fi
  done
done

if base="$(resolve_base)"; then
  declare -a CHANGED_FILES=()
  declare -A COMMITTED_MAP_CHANGED=()
  while IFS= read -r changed; do
    [[ -n "$changed" ]] || continue
    CHANGED_FILES+=("$changed")
    for map in "${DISK_MAPS[@]}"; do
      [[ "$changed" == "$map" ]] && COMMITTED_MAP_CHANGED["$map"]=1
    done
  done < <(changed_files_for_range "$base")
  build_exempt_file_set
  exempt_trailer=0
  commit_range_has_exempt "$base" && exempt_trailer=1
  for changed in "${CHANGED_FILES[@]}"; do
    [[ -n "$changed" ]] || continue
    file_exempt_by_arg "$changed" && continue
    for map in "${DISK_MAPS[@]}"; do
      map_committed_at_head "$map" || continue
      if scope_contains_file "$map" "$changed"; then
        if [[ -z "${COMMITTED_MAP_CHANGED["$map"]:-}" && "$exempt_trailer" -eq 0 ]]; then
          soft "freshness" "$changed changed since $base but $map was not updated and no Index-Exempt trailer was found"
        fi
      fi
    done
  done

  if [[ "$WORKTREE" -eq 1 ]]; then
    declare -A WORKTREE_MAP_CHANGED=()
    for map in "${DISK_MAPS[@]}"; do
      map_touched_in_worktree "$map" && WORKTREE_MAP_CHANGED["$map"]=1
    done
    while IFS= read -r changed; do
      changed="${changed#?? }"
      [[ -n "$changed" ]] || continue
      for map in "${DISK_MAPS[@]}"; do
        if scope_contains_file "$map" "$changed" && [[ -z "${WORKTREE_MAP_CHANGED["$map"]:-}" ]]; then
          soft "freshness" "worktree path $changed matches $map but map is not changed"
        fi
      done
    done < <(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)
  fi

  for map in "${DISK_MAPS[@]}"; do
    commit="${HEADER_VALUE["$map:last-verified-commit"]}"
    if commit_resolves "$commit"; then
      scope="${HEADER_VALUE["$map:scope"]}"
      read -r -a scope_args <<< "$scope"
      count="$(git -C "$REPO_ROOT" rev-list --count "$commit"..HEAD -- "${scope_args[@]}" 2>/dev/null || printf '0')"
      if [[ "$count" =~ ^[0-9]+$ && "$count" -gt "$STALE_THRESHOLD" ]]; then
        soft "staleness" "$map has $count scoped commits since last-verified-commit; threshold is $STALE_THRESHOLD"
      fi
    fi
  done
else
  soft "freshness" "could not resolve base ref; skipped committed freshness and staleness checks"
fi

if [[ "$failures" -gt 0 ]]; then
  printf 'FAIL index-map-check: failures=%s warnings=%s strict=%s\n' "$failures" "$warnings" "$STRICT" >&2
  exit 1
fi

printf 'PASS index-map-check: maps=%s warnings=%s strict=%s\n' "${#DISK_MAPS[@]}" "$warnings" "$STRICT"
