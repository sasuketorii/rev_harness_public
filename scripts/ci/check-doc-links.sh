#!/usr/bin/env bash
# Scan markdown files under docs/** and the repo root for relative links and
# backtick-quoted repo-relative paths, and verify the targets exist on disk.
#
# Scope: docs/**/*.md and the top-level *.md files. This is a read-only
# checker; it never modifies files. Exit 0 when no broken references are
# found, exit 1 otherwise (with a report on stdout).

set -u
set -o pipefail 2>/dev/null || true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$REPO_ROOT"

FILES=()
while IFS= read -r -d '' f; do
  FILES+=("$f")
done < <(find docs -name '*.md' -print0 2>/dev/null)
while IFS= read -r -d '' f; do
  FILES+=("$f")
done < <(find . -maxdepth 1 -name '*.md' -print0 2>/dev/null)

BROKEN=0
CHECKED=0

resolve_and_check() {
  local src_file="$1" raw="$2" base="$3"

  local target="$raw"
  # Strip a trailing markdown heading anchor (#foo) -- anchors aren't
  # validated, only the file/path portion.
  target="${target%%#*}"
  [[ -z "$target" ]] && return 0

  # Skip URLs, mailto, env-var-prefixed, and templated paths.
  case "$target" in
    http://*|https://*|mailto:*|\$*|%*|~/*|*\<*\>*) return 0 ;;
  esac
  # Skip glob patterns (not a single resolvable path).
  case "$target" in
    *'*'*) return 0 ;;
  esac
  # Skip known runtime-generated paths: these directories are shipped empty
  # (state/log/lock/scratch output written at run time, not distributed
  # content) so a specific file under them is expected to be absent in a
  # fresh checkout. Only the *directory* existing is meaningful here.
  case "$target" in
    .agent/active/*|.agent/archive/*|.agent/state/*|.agent/metrics/*|.agent/snapshots*|.agent/generated/*|.agent/context/*|.claude/tmp/*|.claude/scheduled_tasks.lock|.agent/project_id|*/.claude/tmp/*|*/.agent/active/*|harness-rust/target/*|*/harness-rust/target/*)
      return 0 ;;
  esac
  # Same rationale as above, for two more run-local paths that get quoted in
  # docs as bare directories/files (no trailing filename or glob), so the
  # wildcard forms above don't match them: `.claude/tmp` (the run-local
  # scratch root itself, referenced without a path under it) and
  # `.agent/release-gate/` (referenced as the directory itself). Also skip
  # `.agent/registry/rev_harness_adoption_state.json`: this is a symlink
  # created by `rev-harness install` at adoption time (see
  # docs/getting-started/uninstall.md), not a file shipped in the repo. And
  # `harness-rust/target` (the bare Cargo build directory, quoted in the
  # uninstall doc as the thing `rev-harness clean` removes): it is
  # gitignored build output, absent from a fresh checkout by design.
  case "$target" in
    .claude/tmp|.agent/release-gate/|.agent/registry/rev_harness_adoption_state.json|harness-rust/target)
      return 0 ;;
  esac
  # `.claude/settings.local.json` (and its installer-written timestamped
  # backup) is written into an *adopted* project by `rev-harness install`;
  # it is never shipped inside this repo, so it is expected absent here too.
  case "$target" in
    .claude/settings.local.json|.claude/settings.local.json.bak.*)
      return 0 ;;
  esac
  # Skip a small, explicit set of doc-example paths that are not distributed
  # files: fictional paths used inside code-review / tutorial examples
  # (`src/db/user.ts`, `src/lib.rs`), and files a tutorial or smoke test
  # creates at runtime in the *reader's own* project or a throwaway sandbox
  # (`src/greet.py`), never shipped in this repo. Kept as an exact-match list
  # (not a wildcard) so a real broken link under src/ is still caught.
  case "$target" in
    src/greet.py|src/db/user.ts|src/lib.rs)
      return 0 ;;
  esac

  local resolved
  if [[ "$target" == /* ]]; then
    resolved=".${target}"
  elif [[ "$base" == "root" ]]; then
    resolved="$target"
  else
    local dir
    dir="$(dirname "$src_file")"
    resolved="$dir/$target"
  fi

  CHECKED=$((CHECKED + 1))
  if [[ ! -e "$resolved" ]]; then
    echo "BROKEN: $src_file -> $raw"
    BROKEN=$((BROKEN + 1))
  fi
}

for f in "${FILES[@]}"; do
  # Markdown inline links: [text](path) -- resolved relative to the file's dir.
  while IFS= read -r link; do
    resolve_and_check "$f" "$link" "file-relative"
  done < <(grep -oE '\]\([^)[:space:]]+\)' "$f" 2>/dev/null | sed -E 's/^\]\((.*)\)$/\1/')

  # Backtick-quoted repo-relative paths that look like docs/scripts/test refs
  # -- these are always written relative to the repo root, not the file.
  while IFS= read -r link; do
    resolve_and_check "$f" "$link" "root"
  done < <(grep -oE '`(docs|scripts|test|\.agent|\.agent_rules|\.claude|\.agents|\.github|harness-rust|src|setup)/[A-Za-z0-9_./-]+`' "$f" 2>/dev/null | sed -E 's/^`(.*)`$/\1/')
done

echo "---"
echo "checked=$CHECKED broken=$BROKEN files=${#FILES[@]}"

if [[ "$BROKEN" -gt 0 ]]; then
  exit 1
fi
exit 0
