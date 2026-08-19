#!/usr/bin/env bash
# Shared helper for test entrypoints that need to invoke a bash >= 4.0
# binary for sub-scripts (this codebase uses associative arrays / mapfile
# deeper in the install/doctor/review chain, which are syntax errors on
# macOS's stock /bin/bash 3.2).
#
# Not meant to be executed directly; source it and call
# harness_resolve_test_bash.
#
#   source ".../lib/resolve_bash.sh"
#   BASH_BIN="$(harness_resolve_test_bash "HARNESS_RELEASE_GATE_BASH" "${HARNESS_RELEASE_GATE_BASH:-}")"
#
# Resolution order:
#   1. explicit override (second argument, typically an env var the caller
#      already read) - honored as-is, no version re-check, since the caller
#      asked for it explicitly.
#   2. the currently-running bash ($BASH), if it is >= 4.0.
#   3. `bash` resolved via PATH, if it is >= 4.0.
#   4. common Homebrew install locations, if >= 4.0.
#
# If none of the above qualifies, prints an actionable error to stderr and
# exits the whole process (not just this function) with status 1 - silently
# falling back to a 3.2 binary just produces a cryptic syntax error later.

harness_bash_major_version() {
  local candidate="$1"
  [[ -n "$candidate" && -x "$candidate" && ! -d "$candidate" ]] || return 1
  "$candidate" -c 'printf "%s" "${BASH_VERSINFO[0]:-0}"' 2>/dev/null
}

harness_resolve_test_bash() {
  local env_var_name="$1"
  local override_value="${2:-}"

  if [[ -n "$override_value" ]]; then
    printf '%s' "$override_value"
    return 0
  fi

  local candidate major
  local candidates=()

  [[ -n "${BASH:-}" ]] && candidates+=("$BASH")
  candidates+=("$(command -v bash 2>/dev/null || true)")
  candidates+=(
    "/opt/homebrew/bin/bash"
    "/usr/local/bin/bash"
    "/bin/bash"
  )

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    major="$(harness_bash_major_version "$candidate" || true)"
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 4 )); then
      printf '%s' "$candidate"
      return 0
    fi
  done

  {
    printf 'FAIL: no bash >= 4.0 found for test execution.\n'
    printf 'This test suite requires bash 4+ (associative arrays / mapfile\n'
    printf 'used deeper in the install/doctor/review chain). macOS ships\n'
    printf 'bash 3.2 as /bin/bash, which cannot run those scripts.\n'
    printf 'Fix: brew install bash\n'
    printf 'Or set %s=/path/to/bash4+ to point at one explicitly, e.g.:\n' "$env_var_name"
    printf '  %s=/opt/homebrew/bin/bash bash %s\n' "$env_var_name" "${0:-<script>}"
  } >&2
  exit 1
}
