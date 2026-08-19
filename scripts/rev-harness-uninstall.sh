#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

JSON_OUTPUT=false
PRINT_CHECKLIST=true
APPLY=false

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-uninstall.sh [--print-checklist] [--json]

Default mode is checklist-only (advisory). The checklist never deletes anything.
EOF
}

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# The canonical clone this script is running from — used instead of a
# guessed directory name so the PATH-removal example and the reported cargo
# target path are always accurate, regardless of what the adopter named
# their local checkout (the documented default in docs/adoption-guide.md is
# `rev_harness_public`, but adopters may rename it).
CANONICAL_SCRIPTS_DIR="$SCRIPT_DIR"
CANONICAL_CARGO_TARGET="$PROJECT_ROOT/harness-rust/target"

emit_json() {
  local backup_present=false
  [[ -e "$PROJECT_ROOT/.git/hooks/pre-commit.rev-harness.bak" ]] && backup_present=true
  local scripts_dir_json cargo_target_json
  scripts_dir_json="$(json_escape "$CANONICAL_SCRIPTS_DIR")"
  cargo_target_json="$(json_escape "$CANONICAL_CARGO_TARGET")"
  cat <<EOF
[
  {"step":1,"title":"Remove canonical PATH export","scripts_dir":"${scripts_dir_json}","find_command":"grep -n '${scripts_dir_json}' \"\${HOME}/.zshrc\" \"\${HOME}/.bashrc\"","remove_command_template":"sed -i.bak \"\\\\|<scripts_dir>|d\" <rc-file>","note":"this checkout's scripts dir is ${scripts_dir_json}; find the matching PATH line first, then remove it"},
  {"step":2,"title":"Delete adopter state","path":".agent/registry/rev_harness_adoption_state.json"},
  {"step":3,"title":"Review installed links and dirs","paths":[".claude/",".agent/active/"],"action":"remove only RevHarness-created symlinks or dirs after inspection"},
  {"step":4,"title":"Restore pre-commit hook","backup":".git/hooks/pre-commit.rev-harness.bak","backup_present":$backup_present},
  {"step":5,"title":"Decide project identity","path":".shared/project_id","note":"immutable identity; do not delete unless explicitly retiring the project"},
  {"step":6,"title":"Canonical cargo target","path":"${cargo_target_json}","note":"canonical-side cache, not adopter-side"}
]
EOF
}

emit_human() {
  local backup_note="backup not detected"
  [[ -e "$PROJECT_ROOT/.git/hooks/pre-commit.rev-harness.bak" ]] && backup_note="backup exists at .git/hooks/pre-commit.rev-harness.bak"
  cat <<EOF
RevHarness uninstall checklist (advisory only)

1. Remove canonical PATH export line from shell rc files. This checkout's
   scripts directory is:
     $CANONICAL_SCRIPTS_DIR
   Find the matching line first (it may differ if you renamed the checkout):
     grep -n '$CANONICAL_SCRIPTS_DIR' "\${HOME}/.zshrc" "\${HOME}/.bashrc" 2>/dev/null
   Then remove it, e.g.:
     sed -i.bak "\\|$CANONICAL_SCRIPTS_DIR|d" "\${HOME}/.zshrc"
     sed -i.bak "\\|$CANONICAL_SCRIPTS_DIR|d" "\${HOME}/.bashrc"

2. Delete adopter state:
   rm -f .agent/registry/rev_harness_adoption_state.json

3. Inspect installed links or dirs before removal:
   .claude/
   .agent/active/
   Remove only symlinks or directories created by the RevHarness install.

4. Restore .git/hooks/pre-commit if needed.
   Expected backup: .git/hooks/pre-commit.rev-harness.bak ($backup_note)

5. Decide what to do with .shared/project_id.
   This is immutable project identity; do not delete unless explicitly retiring the project.

6. Cargo target cleanup is canonical-side only:
   $CANONICAL_CARGO_TARGET
   This is not adopter-side uninstall state.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --print-checklist) PRINT_CHECKLIST=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    --apply)
      APPLY=true
      shift
      ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'rev-harness-uninstall: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# --apply remains deferred (no destructive path in the advisory uninstall).
if [[ "$APPLY" == true ]]; then
  printf 'uninstall --apply: deferred (this command is advisory checklist-only)\n' >&2
  exit 2
fi

if [[ "$PRINT_CHECKLIST" == true && "$JSON_OUTPUT" == true ]]; then
  emit_json
else
  emit_human
fi
