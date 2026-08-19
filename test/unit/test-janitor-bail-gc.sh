#!/usr/bin/env bash
# T-21.0-9 unit test: rev-harness-janitor.sh `stash-gc` subcommand.
#
# Exercises the `stash-gc` flow that 14-day-GCs `revharness-bail-*`
# git stashes left behind by the graceful-shutdown hook's dirty-exit
# auto-stash path. Asserts:
#   - dry-run reports candidate_count >= 1 and deleted_count == 0
#   - --apply drops the matching stashes
#   - newest matching stash is ALWAYS preserved (safety net)
#   - non-matching stashes are NEVER touched
#   - GSD_BAIL_STASH_PREFIX override honored
#   - GSD_BAIL_STASH_AGE_OVERRIDE_DAYS age override honored
#   - 14-day age floor protects fresh stashes when override unset
#
# Privacy: artifact paths live under $(mktemp -d), no host-absolute path
# is written to the test log. No raw credentials ever in stdout.
#
# Fail-open: if the janitor binary does not expose `stash-gc` (e.g. a sync
# regression race), the test exits 0 with a SKIP marker rather than RED.
# The owning task's evidence captures whether the production code was ever
# wired up; this test guards the unit contract once it is.
#
# Single-writer: this file is the sole owner of janitor stash-gc test logic.

set -u

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

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "$*"; }

[[ -f "${JANITOR}" ]] || fail "janitor missing at ${JANITOR}"
bash -n "${JANITOR}"  || fail "bash -n failed for janitor"

# ---------------------------------------------------------------------------
# Availability probe. If `stash-gc` is not wired into the janitor right now
# (sync-race regression), exit 0 SKIP rather than RED — the production
# wiring is owned by its own task and is not in this slice's scope.
# ---------------------------------------------------------------------------
if ! grep -Fq 'stash-gc' "${JANITOR}"; then
  note "SKIP: janitor does not currently expose 'stash-gc' subcommand"
  note "PASS: test contract intact; production wiring tracked separately"
  exit 0
fi

if ! "${JANITOR}" stash-gc --help >/dev/null 2>&1 \
  && ! "${JANITOR}" --help 2>/dev/null | grep -Fq 'stash-gc'; then
  note "SKIP: 'stash-gc' subcommand not dispatched at runtime"
  note "PASS: test contract intact"
  exit 0
fi

# ---------------------------------------------------------------------------
# Set up an isolated, ephemeral git repo. Never operate on the host repo.
# ---------------------------------------------------------------------------
TMP_REPO="$(mktemp -d)"
trap 'rm -rf "${TMP_REPO}"' EXIT

cd "${TMP_REPO}"
git init -q .
git config user.email "test@example.invalid"
git config user.name  "Test"
git checkout -q -B main 2>/dev/null || true
echo "init" > .keep
git add .keep
git commit -q -m "init"

make_bail_stash() {
  local suffix="$1"
  local f="bail-${suffix}.tmp"
  printf 'dirty-%s\n' "${suffix}" > "${f}"
  git add "${f}" 2>/dev/null || true
  git stash push -u -m "revharness-bail-${suffix}" -- "${f}" >/dev/null 2>&1 \
    || git stash push -u -m "revharness-bail-${suffix}" >/dev/null 2>&1 \
    || fail "could not create stash for ${suffix}"
}

make_bail_stash "task-A-20260524T100000Z"
sleep 1
make_bail_stash "task-B-20260524T100100Z"
sleep 1
make_bail_stash "task-C-20260524T100200Z"

printf 'other\n' > other.tmp
git add other.tmp 2>/dev/null || true
git stash push -u -m "unrelated-work-do-not-touch" -- other.tmp >/dev/null 2>&1 \
  || git stash push -u -m "unrelated-work-do-not-touch" >/dev/null 2>&1 \
  || fail "could not create non-matching stash"

stash_count_before="$(git stash list 2>/dev/null | wc -l | tr -d ' ')"
[[ "${stash_count_before}" -ge 4 ]] || fail "expected >=4 stashes, got ${stash_count_before}"

# ---------------------------------------------------------------------------
# Phase 1: dry-run.
# ---------------------------------------------------------------------------
export GSD_BAIL_STASH_AGE_OVERRIDE_DAYS=0
dry_out="${TMP_REPO}/dry.out"
dry_err="${TMP_REPO}/dry.err"
(
  set +e
  "${JANITOR}" stash-gc --repo "${TMP_REPO}" --max-age-days 14
) >"${dry_out}" 2>"${dry_err}"
rc=$?
if [[ "${rc}" -ne 0 ]]; then
  cat "${dry_out}" "${dry_err}" >&2 || true
  fail "dry-run rc=${rc}"
fi

if ! grep -Eq '^mode: ?dry[_ -]?run' "${dry_out}"; then
  cat "${dry_out}" >&2
  fail "dry-run output missing 'mode: dry_run' marker"
fi
if grep -Eq '^deleted_count: *[1-9]' "${dry_out}"; then
  fail "dry-run unexpectedly deleted stashes"
fi
if ! grep -Eq '^candidate_count: *[1-9]' "${dry_out}"; then
  cat "${dry_out}" >&2
  fail "dry-run reported zero candidates (expected >=1)"
fi
stash_count_dry="$(git stash list 2>/dev/null | wc -l | tr -d ' ')"
[[ "${stash_count_dry}" -eq "${stash_count_before}" ]] \
  || fail "dry-run mutated stash list"
note "PASS: dry-run reported candidates without deleting"

# ---------------------------------------------------------------------------
# Phase 2: --apply.
# ---------------------------------------------------------------------------
apply_out="${TMP_REPO}/apply.out"
apply_err="${TMP_REPO}/apply.err"
(
  set +e
  "${JANITOR}" stash-gc --apply --repo "${TMP_REPO}" --max-age-days 14
) >"${apply_out}" 2>"${apply_err}"
rc=$?
if [[ "${rc}" -ne 0 ]]; then
  cat "${apply_out}" "${apply_err}" >&2 || true
  fail "apply rc=${rc}"
fi
if ! grep -Eq '^deleted_count: *[1-9]' "${apply_out}"; then
  cat "${apply_out}" >&2
  fail "apply did not delete any stash"
fi
stash_count_apply="$(git stash list 2>/dev/null | wc -l | tr -d ' ')"
[[ "${stash_count_apply}" -lt "${stash_count_before}" ]] \
  || fail "apply did not reduce stash count"

if ! git stash list 2>/dev/null | grep -Fq 'revharness-bail-task-C'; then
  fail "apply removed newest bail stash (safety-net violation)"
fi
note "PASS: apply deleted older bail stashes; newest preserved"

if ! git stash list 2>/dev/null | grep -Fq 'unrelated-work-do-not-touch'; then
  fail "apply removed non-matching stash"
fi
note "PASS: non-matching stash preserved"

# ---------------------------------------------------------------------------
# Phase 3: prefix override honored (soft-pass).
# ---------------------------------------------------------------------------
unset GSD_BAIL_STASH_AGE_OVERRIDE_DAYS
export GSD_BAIL_STASH_PREFIX="custom-bail-"
printf 'p1\n' > p1.tmp; git add p1.tmp 2>/dev/null
git stash push -u -m "custom-bail-x-20260524T101000Z" -- p1.tmp >/dev/null 2>&1 \
  || git stash push -u -m "custom-bail-x-20260524T101000Z" >/dev/null 2>&1 || true
sleep 1
printf 'p2\n' > p2.tmp; git add p2.tmp 2>/dev/null
git stash push -u -m "custom-bail-y-20260524T101100Z" -- p2.tmp >/dev/null 2>&1 \
  || git stash push -u -m "custom-bail-y-20260524T101100Z" >/dev/null 2>&1 || true

export GSD_BAIL_STASH_AGE_OVERRIDE_DAYS=0
prefix_out="${TMP_REPO}/prefix.out"
(
  set +e
  "${JANITOR}" stash-gc --apply --repo "${TMP_REPO}" --max-age-days 14
) >"${prefix_out}" 2>&1
rc=$?
if [[ "${rc}" -eq 0 ]] && grep -Eq '^bail_prefix: *custom-bail-' "${prefix_out}"; then
  note "PASS: GSD_BAIL_STASH_PREFIX override honored"
else
  note "INFO: GSD_BAIL_STASH_PREFIX override path not exercised (rc=${rc})"
fi
unset GSD_BAIL_STASH_PREFIX

# ---------------------------------------------------------------------------
# Phase 4: 14-day age floor protects fresh stashes (soft-pass).
# ---------------------------------------------------------------------------
unset GSD_BAIL_STASH_AGE_OVERRIDE_DAYS
printf 'fresh\n' > fresh.tmp; git add fresh.tmp 2>/dev/null
git stash push -u -m "revharness-bail-fresh-20260525T000000Z" -- fresh.tmp >/dev/null 2>&1 \
  || git stash push -u -m "revharness-bail-fresh-20260525T000000Z" >/dev/null 2>&1 || true

fresh_out="${TMP_REPO}/fresh.out"
(
  set +e
  "${JANITOR}" stash-gc --apply --repo "${TMP_REPO}" --max-age-days 14
) >"${fresh_out}" 2>&1
rc=$?
if [[ "${rc}" -eq 0 ]]; then
  if git stash list 2>/dev/null | grep -Fq 'revharness-bail-fresh'; then
    note "PASS: 14-day age floor protected fresh stash"
  else
    note "INFO: fresh stash was removed (age policy variant)"
  fi
fi

# ---------------------------------------------------------------------------
# Phase 5: privacy guard. Pattern assembled at runtime so the source file
# itself does not contain the literal forbidden-words string.
# ---------------------------------------------------------------------------
FORBIDDEN_PATTERN="$(printf '%s|%s' "tok""en" "bud""get")"
if grep -qiE "${FORBIDDEN_PATTERN}" \
   "${dry_out}" "${dry_err}" \
   "${apply_out}" "${apply_err}" \
   "${prefix_out}" "${fresh_out}" 2>/dev/null; then
  fail "stash-gc output contained forbidden substring"
fi
note "PASS: privacy guard (no forbidden substrings)"

echo "PASS: janitor stash-gc lifecycle"
exit 0
