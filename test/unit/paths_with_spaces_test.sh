#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SANDBOX="$(mktemp -d)"

cleanup() {
  /bin/rm -rf "$SANDBOX"
}
trap cleanup EXIT

ADOPTER="$SANDBOX/adopter repo"
HARNESS_WITH_SPACES="$SANDBOX/harness root with spaces"

mkdir -p "$ADOPTER" "$HARNESS_WITH_SPACES/scripts"
ADOPTER="$(cd "$ADOPTER" && pwd -P)"
HARNESS_WITH_SPACES="$(cd "$HARNESS_WITH_SPACES" && pwd -P)"
git -C "$ADOPTER" init -q
cp "$REPO_ROOT/scripts/rev-harness-path-leak-guard.sh" "$HARNESS_WITH_SPACES/scripts/rev-harness-path-leak-guard.sh"
chmod +x "$HARNESS_WITH_SPACES/scripts/rev-harness-path-leak-guard.sh"

(
  cd "$ADOPTER"
  PROJECT_ROOT="$ADOPTER" bash "$REPO_ROOT/scripts/install-rev-harness-hooks.sh" install \
    --adopter-root "$ADOPTER" \
    --harness-root "$HARNESS_WITH_SPACES"
) >/dev/null

HOOK="$ADOPTER/.git/hooks/pre-commit"
[[ -x "$HOOK" ]] || { printf 'FAIL: pre-commit hook not installed executable\n' >&2; exit 1; }
grep -Fq "HARNESS_ROOT_LITERAL='$HARNESS_WITH_SPACES'" "$HOOK" \
  || { printf 'FAIL: hook did not preserve spaced harness root literal\n' >&2; cat "$HOOK" >&2; exit 1; }

git -C "$ADOPTER" check-ignore -q .claude/settings.local.json \
  || { printf 'FAIL: .claude/settings.local.json is not gitignored\n' >&2; exit 1; }

(
  cd "$ADOPTER"
  .git/hooks/pre-commit
)

printf 'PASS: install hooks handles harness-root paths with spaces\n'
