#!/usr/bin/env bash
set -euo pipefail

# Semantic-free adopter-setup resume contract.
#
# The adopter setup runs CORE_PHASES = "init hooks doctor" (no semantic phases).
# This test forces the `doctor` phase to fail on the first run, asserts the
# state records doctor=failed with the doctor phase exit code (14), then lets
# doctor succeed and verifies a --resume run verified-skips the already-ok
# init/hooks phases and re-runs doctor to completion.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'cd "$REPO_ROOT" >/dev/null 2>&1 || true; rm -rf "$TMP" >/dev/null 2>&1 || true' EXIT
TARGET="$TMP/target"
STATE_FILE="$TARGET/.rev-harness-state/state.json"

mkdir -p "$TMP/scripts" "$TARGET"
cp "$REPO_ROOT/scripts/rev-harness-adopter-setup.sh" "$TMP/scripts/"
cp "$REPO_ROOT/scripts/_canonical-guard.sh" "$TMP/scripts/"

cat >"$TMP/scripts/init-project.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p .shared
printf 'adopter-resume\n' > .shared/project_id
touch .gitignore
EOF
cat >"$TMP/scripts/install-rev-harness-hooks.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p .git/hooks
printf '# hook\n' > .git/hooks/pre-commit
EOF
# Doctor stub: fails until $TARGET/doctor-success exists, then succeeds.
cat >"$TMP/scripts/harness-doctor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ! -f "$PWD/doctor-success" ]]; then
  printf '{"status":"FAIL"}\n'
  exit 1
fi
printf '{"status":"OK"}\n'
EOF
chmod +x "$TMP"/scripts/*.sh

set +e
(
  cd "$TMP"
  export REVHARNESS_PARALLEL_QUIESCE=1
  export REV_HARNESS_CANONICAL_ROOT="$TMP"
  bash scripts/rev-harness-adopter-setup.sh setup --target "$TARGET" >"$TMP/first.out" 2>"$TMP/first.err"
)
FIRST_RC=$?
set -e

# doctor phase exit code is 14 (see phase_exit_code()).
test "$FIRST_RC" -eq 14
jq -e '.phases.init.status == "ok"
  and .phases.hooks.status == "ok"
  and .phases.doctor.status == "failed"' "$STATE_FILE" >/dev/null

# Let doctor succeed, then resume: init/hooks should verified-skip, doctor re-run.
touch "$TARGET/doctor-success"
(
  cd "$TMP"
  export REVHARNESS_PARALLEL_QUIESCE=1
  export REV_HARNESS_CANONICAL_ROOT="$TMP"
  bash scripts/rev-harness-adopter-setup.sh setup --target "$TARGET" --resume >"$TMP/resume.out"
)

jq -e '.schema == "rev-harness-state/v1"
  and .current_phase == "done"
  and .phases.doctor.status == "ok"' "$STATE_FILE" >/dev/null
grep -q '"event":"verified-skip".*"phase":"init"' "$TMP/resume.out"
grep -q '"event":"verified-skip".*"phase":"hooks"' "$TMP/resume.out"
grep -q '"event":"phase_started".*"phase":"doctor"' "$TMP/resume.out"

printf 'adopter_setup_partial_fail_resume: ok\n'
exit 0
