#!/usr/bin/env bash
# Regression test for the PROJECT_ROOT self-reference bug: an adopter's
# pre-commit hook must scan the ADOPTER's own staged diff, not the harness's.
#
# Before the fix, rev-harness-secret-guard.sh hardcoded PROJECT_ROOT to its
# own script location (SCRIPT_DIR/..), so the hook installed into an adopter
# repo silently scanned the harness checkout instead of the adopter's staged
# changes. A commit containing a real secret would succeed unblocked.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ADOPTER="$(mktemp -d)"

cleanup() {
  /bin/rm -rf "$ADOPTER"
}
trap cleanup EXIT

git -C "$ADOPTER" init -q
git -C "$ADOPTER" config user.email "rev-harness-test@example.invalid"
git -C "$ADOPTER" config user.name "RevHarness Test"

(
  cd "$ADOPTER"
  PROJECT_ROOT="$ADOPTER" bash "$REPO_ROOT/scripts/install-rev-harness-hooks.sh" install \
    --adopter-root "$ADOPTER" \
    --harness-root "$REPO_ROOT" \
    --without-settings-hooks
) >/dev/null

# A well-formed AWS access key shape. agent-core secret scan's fixture
# patterns recognize this; see harness-rust/crates/agent-core/tests/secret_scan_fixtures.
printf 'AKIAIOSFODNN7EXAMPLE\n' > "$ADOPTER/aws.txt"
git -C "$ADOPTER" add aws.txt

set +e
git -C "$ADOPTER" commit -m "test secret guard scans adopter diff" \
  >"$ADOPTER/commit.out" 2>"$ADOPTER/commit.err"
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  printf 'FAIL: commit succeeded; expected secret-guard to block a staged AWS key\n' >&2
  printf -- '--- stdout ---\n' >&2
  cat "$ADOPTER/commit.out" >&2
  printf -- '--- stderr ---\n' >&2
  cat "$ADOPTER/commit.err" >&2
  exit 1
fi

# The finding must reference the adopter's own file (aws.txt), proving the
# scan actually read the adopter's staged diff rather than the harness's.
if ! grep -Fq 'aws.txt' "$ADOPTER/commit.out" "$ADOPTER/commit.err" 2>/dev/null; then
  printf 'FAIL: guard output did not reference adopter file aws.txt (wrong scan target?)\n' >&2
  printf -- '--- stdout ---\n' >&2
  cat "$ADOPTER/commit.out" >&2
  printf -- '--- stderr ---\n' >&2
  cat "$ADOPTER/commit.err" >&2
  exit 1
fi

printf 'PASS: pre-commit secret guard blocks a staged AWS key in the adopter repo\n'
