#!/usr/bin/env bash
# install-rev-harness-hooks.sh
#
# Idempotent installer for RevHarness git pre-commit hooks.
#
# Currently wires:
#   - rev-harness-path-leak-guard.sh  (block home-dir absolute paths)
#   - rev-harness-secret-guard.sh     (if present; existing secret scanner)
#
# Usage:
#   bash scripts/install-rev-harness-hooks.sh --harness-root <path>
#                                                 # install (creates .git/hooks/pre-commit)
#   bash scripts/install-rev-harness-hooks.sh --uninstall
#   bash scripts/install-rev-harness-hooks.sh --status
#   bash scripts/install-rev-harness-hooks.sh --without-settings-hooks
#
# The hook delegates to the canonical scripts so updates to the guard
# logic land automatically — the .git/hooks/pre-commit body itself is
# stable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)}"
MARKER="# rev-harness-hooks installed"

usage() {
  cat >&2 <<'USAGE'
usage: bash scripts/install-rev-harness-hooks.sh [install|--uninstall|--status]
       [--with-settings-hooks|--without-settings-hooks]
       [--adopter-root <path>] [--harness-root <path>]
USAGE
}

die() {
  printf 'install-rev-harness-hooks: %s\n' "$*" >&2
  exit "${2:-2}"
}

abs_dir() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  cd "$path" 2>/dev/null && pwd -P
}

git_hook_path() {
  local root="$1" hook="${2:-pre-commit}" top path
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" \
    || die "adopter-root is not a git repository: $root"
  path="$(git -C "$top" rev-parse --git-path "hooks/$hook" 2>/dev/null)" \
    || die "failed to resolve $hook hook path for adopter-root: $root"
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$top" "$path" ;;
  esac
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

ensure_local_settings_ignored() {
  local root="$1" top exclude_file
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" \
    || die "adopter-root is not a git repository: $root"
  exclude_file="$(git -C "$top" rev-parse --git-path info/exclude 2>/dev/null)" \
    || die "failed to resolve git exclude path for adopter-root: $root"
  case "$exclude_file" in
    /*) ;;
    *) exclude_file="$top/$exclude_file" ;;
  esac
  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"
  grep -Fxq '.claude/settings.local.json' "$exclude_file" 2>/dev/null \
    || printf '%s\n' '.claude/settings.local.json' >> "$exclude_file"
  grep -Fxq '.claude/settings.local.json.*' "$exclude_file" 2>/dev/null \
    || printf '%s\n' '.claude/settings.local.json.*' >> "$exclude_file"
}

action="install"
with_settings_hooks=1
adopter_root="$REPO_ROOT"
harness_root=""
harness_root_seen=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    install) action="install"; shift ;;
    --uninstall) action="--uninstall"; shift ;;
    --status) action="--status"; shift ;;
    --with-settings-hooks) with_settings_hooks=1; shift ;;
    --without-settings-hooks) with_settings_hooks=0; shift ;;
    --adopter-root)
      [[ "$#" -ge 2 ]] || die "--adopter-root requires a path"
      adopter_root="$2"
      shift 2
      ;;
    --harness-root)
      [[ "$#" -ge 2 ]] || die "--harness-root requires a path"
      harness_root="$2"
      harness_root_seen=1
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

adopter_root="$(abs_dir "$adopter_root")" || die "adopter-root does not exist: $adopter_root"
HOOK="$(git_hook_path "$adopter_root" pre-commit)"
POST_HOOK="$(git_hook_path "$adopter_root" post-commit)"

case "$action" in
  --uninstall)
    removed=0
    if [[ -f "$HOOK" ]] && grep -q "$MARKER" "$HOOK" 2>/dev/null; then
      /bin/rm -f -- "$HOOK"
      echo "removed $HOOK"
      removed=1
    fi
    if [[ -f "$POST_HOOK" ]] && grep -q "$MARKER" "$POST_HOOK" 2>/dev/null; then
      /bin/rm -f -- "$POST_HOOK"
      echo "removed $POST_HOOK"
      removed=1
    fi
    [[ "$removed" -eq 1 ]] || echo "no rev-harness hook to remove"
    exit 0
    ;;
  --status)
    status_rc=1
    if [[ -f "$HOOK" ]] && grep -q "$MARKER" "$HOOK" 2>/dev/null; then
      echo "installed: $HOOK"
      status_rc=0
    fi
    if [[ -f "$POST_HOOK" ]] && grep -q "$MARKER" "$POST_HOOK" 2>/dev/null; then
      echo "installed: $POST_HOOK"
      status_rc=0
    fi
    [[ "$status_rc" -eq 0 ]] || echo "not installed"
    exit "$status_rc"
    ;;
  install|"")
    ;;
  *)
    echo "unknown action: $action (use: install | --uninstall | --status)" >&2
    usage
    exit 2
    ;;
esac

if [[ "$harness_root_seen" -ne 1 || -z "$harness_root" ]]; then
  die "harness-root required; pass --harness-root <path> (usually the RevHarness root)" 2
fi
harness_root="$(abs_dir "$harness_root")" || die "harness-root does not exist: $harness_root"
if [[ ! -f "$harness_root/scripts/rev-harness-path-leak-guard.sh" ]]; then
  die "harness-root missing scripts/rev-harness-path-leak-guard.sh: $harness_root"
fi

mkdir -p "$(dirname "$HOOK")"

if [[ -f "$HOOK" ]] && ! grep -q "$MARKER" "$HOOK"; then
  echo "WARN: existing $HOOK is not managed by rev-harness; backing up to ${HOOK}.bak" >&2
  /bin/cp -- "$HOOK" "${HOOK}.bak"
fi

HARNESS_ROOT_QUOTED="$(shell_quote "$harness_root")"
ADOPTER_ROOT_QUOTED="$(shell_quote "$adopter_root")"

cat >"$HOOK" <<HOOK
#!/usr/bin/env bash
# rev-harness-hooks installed
set -e
HARNESS_ROOT_LITERAL=$HARNESS_ROOT_QUOTED
ADOPTER_ROOT_LITERAL=$ADOPTER_ROOT_QUOTED

# 1. path-leak guard (blocks ~/dev/ absolute paths in staged diff)
if [[ -x "\$HARNESS_ROOT_LITERAL/scripts/rev-harness-path-leak-guard.sh" ]]; then
  PROJECT_ROOT="\$ADOPTER_ROOT_LITERAL" REV_HARNESS_REPO_ROOT="\$ADOPTER_ROOT_LITERAL" \
    bash "\$HARNESS_ROOT_LITERAL/scripts/rev-harness-path-leak-guard.sh" || exit \$?
fi

# 2. secret guard (existing scanner, if present)
if [[ -x "\$HARNESS_ROOT_LITERAL/scripts/rev-harness-secret-guard.sh" ]]; then
  PROJECT_ROOT="\$ADOPTER_ROOT_LITERAL" REV_HARNESS_REPO_ROOT="\$ADOPTER_ROOT_LITERAL" \
    bash "\$HARNESS_ROOT_LITERAL/scripts/rev-harness-secret-guard.sh" check --staged-only || exit \$?
fi

exit 0
HOOK
chmod +x "$HOOK"
echo "installed: $HOOK"
echo ""
echo "verify: bash scripts/install-rev-harness-hooks.sh --status"
echo "test:   git commit --dry-run (will run guards on staged diff)"
echo "bypass: git commit --no-verify (use sparingly)"

if [[ "$with_settings_hooks" == "1" ]]; then
  settings_dir="$adopter_root/.claude"
  settings_file="$settings_dir/settings.local.json"
  run_id="$(date -u +"%Y%m%dT%H%M%SZ")-$$"
  mkdir -p "$settings_dir"
  ensure_local_settings_ignored "$adopter_root"
  if [[ ! -f "$settings_file" ]]; then
    printf '{}\n' > "$settings_file"
  fi
  bash "$SCRIPT_DIR/_settings-merge.sh" merge \
    --config "$settings_file" \
    --harness-root "$harness_root" \
    --run-id "$run_id"
fi
