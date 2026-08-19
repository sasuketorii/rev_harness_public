#!/usr/bin/env bash
# NOTE: This is an internal delegate invoked by `scripts/rev-harness install`
# (the canonical facade). It is not a second public entry point; end users
# should run `bash scripts/rev-harness install` and never call this file
# directly. See docs/manual/rev-harness-lifecycle.md.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=false
JSON_OUTPUT=false
VERBOSE=false
STRICT=false
SETUP_ONLY=false
TARGET_ARG=""

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-install.sh [--dry-run] [--json] [--verbose] [--strict] [--setup-only] [--target <path>]

INTERNAL DELEGATE — not a public entry point. `scripts/rev-harness install`
calls this file; end users should run that facade command instead of
invoking this script directly.

Thin composer for rev-harness-adopter-setup.sh setup.
--setup-only is accepted for the façade alias; it still delegates to setup.
Init-only flows remain available through rev-harness-adopter-setup.sh directly.

Exit codes:
  Propagates rev-harness-adopter-setup.sh unchanged.
EOF
}

die() {
  printf 'rev-harness-install: %s\n' "$*" >&2
  exit 2
}

args=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --strict) STRICT=true; shift ;;
    --setup-only) SETUP_ONLY=true; shift ;;
    --target) [[ "$#" -ge 2 ]] || die "--target requires a path"; TARGET_ARG="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -f "$SCRIPT_DIR/rev-harness-adopter-setup.sh" ]] || die "missing composer target"

args+=(setup)
[[ -n "$TARGET_ARG" ]] && args+=(--target "$TARGET_ARG")
[[ "$DRY_RUN" == true ]] && args+=(--dry-run)
[[ "$JSON_OUTPUT" == true ]] && args+=(--json)
[[ "$VERBOSE" == true ]] && args+=(--verbose)
[[ "$STRICT" == true ]] && args+=(--strict)
[[ "$SETUP_ONLY" == true ]] && :

exec bash "$SCRIPT_DIR/rev-harness-adopter-setup.sh" "${args[@]}"
