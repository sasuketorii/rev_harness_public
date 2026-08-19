#!/usr/bin/env bash
set -euo pipefail

script_dir() {
  local src="${BASH_SOURCE[0]}"
  case "$src" in
    */*) (cd "${src%/*}" && pwd -P) ;;
    *) pwd -P ;;
  esac
}

TEST_DIR="$(script_dir)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd -P)"
JANITOR="${REPO_ROOT}/scripts/rev-harness-janitor.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

stash_snapshot() {
  git -C "$TMP_REPO" stash list --format='%gd %gs'
}

[[ -f "$JANITOR" ]] || fail "janitor missing"
bash -n "$JANITOR" || fail "janitor syntax check failed"

TMP_REPO="$(mktemp -d)"
trap 'set +e; rm -rf "$TMP_REPO"; true' EXIT

git -C "$TMP_REPO" init -q .
git -C "$TMP_REPO" config user.email "test@example.invalid"
git -C "$TMP_REPO" config user.name "Test"
git -C "$TMP_REPO" checkout -q -B main 2>/dev/null || true

printf 'base\n' > "$TMP_REPO/tracked.txt"
git -C "$TMP_REPO" add tracked.txt
git -C "$TMP_REPO" commit -q -m "base"

make_bail_stash() {
  local suffix="$1"
  printf 'dirty-%s\n' "$suffix" >> "$TMP_REPO/tracked.txt"
  git -C "$TMP_REPO" stash push -m "revharness-bail-${suffix}" -- tracked.txt >/dev/null 2>&1 \
    || fail "could not create bail stash ${suffix}"
}

make_bail_stash "quiesce-A"
sleep 1
make_bail_stash "quiesce-B"

before="$(stash_snapshot)"
before_count="$(printf '%s\n' "$before" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$before_count" -ge 2 ]] || fail "expected at least two stashes"

quiesce_out="$TMP_REPO/quiesce.out"
quiesce_err="$TMP_REPO/quiesce.err"
REVHARNESS_PARALLEL_QUIESCE=1 "$JANITOR" stash-gc --repo "$TMP_REPO" --max-age-days 0 \
  >"$quiesce_out" 2>"$quiesce_err" || fail "quiesced stash-gc returned non-zero"

after_quiesce="$(stash_snapshot)"
[[ "$after_quiesce" == "$before" ]] || fail "quiesced stash-gc mutated stash list"
grep -Fq 'janitor: stash-gc skipped (REVHARNESS_PARALLEL_QUIESCE=1)' "$quiesce_err" \
  || fail "quiesced stash-gc did not report skip"
echo "PASS: quiesced stash-gc exited 0 and left stashes unchanged"

normal_out="$TMP_REPO/normal.out"
normal_err="$TMP_REPO/normal.err"
REVHARNESS_PARALLEL_QUIESCE=0 GSD_BAIL_STASH_AGE_OVERRIDE_DAYS=0 \
  "$JANITOR" stash-gc --repo "$TMP_REPO" --max-age-days 14 \
  >"$normal_out" 2>"$normal_err" || {
    cat "$normal_out" "$normal_err" >&2 || true
    fail "normal stash-gc returned non-zero"
  }

grep -Fq 'janitor_command: stash-gc' "$normal_out" \
  || fail "normal stash-gc did not execute stash-gc path"
grep -Eq '^candidate_count: *[0-9]+' "$normal_out" \
  || fail "normal stash-gc did not report candidate_count"
grep -Fq 'REVHARNESS_PARALLEL_QUIESCE=1' "$normal_err" \
  && fail "normal stash-gc reported quiesce skip"

echo "PASS: normal stash-gc path executed without error"
echo "PASS: janitor quiesce guard"
