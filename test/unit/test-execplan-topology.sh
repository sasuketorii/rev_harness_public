#!/usr/bin/env bash
# Regression tests for dispatch_topology lint.

set -u
set -o pipefail 2>/dev/null || true

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${THIS_DIR}/../.." && pwd -P)"
SCRIPT="${REPO_ROOT}/scripts/ci/check-execplan-topology.sh"

SCRATCH="$(mktemp -d -t execplan-topology-test-XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "${SCRATCH}" 2>/dev/null || true' EXIT

PASS=0
FAIL=0
RUN_OUT=""

assert_eq() {
  local name="$1" expect="$2" actual="$3"
  if [[ "${expect}" == "${actual}" ]]; then
    PASS=$(( PASS + 1 ))
    echo "  OK   ${name} (= ${expect})"
  else
    FAIL=$(( FAIL + 1 ))
    echo "  FAIL ${name} expected=${expect} actual=${actual}" >&2
  fi
}

assert_contains() {
  local name="$1" file="$2" needle="$3"
  if grep -Fq "${needle}" "${file}"; then
    PASS=$(( PASS + 1 ))
    echo "  OK   ${name}"
  else
    FAIL=$(( FAIL + 1 ))
    echo "  FAIL ${name} missing ${needle}" >&2
    sed -n '1,120p' "${file}" >&2
  fi
}

run_case() {
  local name="$1" file="$2" expected_rc="$3"
  shift 3
  local out="${SCRATCH}/${name}.out"
  local rc
  bash "${SCRIPT}" --file "${file}" "$@" > "${out}" 2>&1
  rc=$?
  assert_eq "${name} exit" "${expected_rc}" "${rc}"
  RUN_OUT="${out}"
}

cat > "${SCRATCH}/clean.md" <<'EOF'
---
title: clean
---

```yaml
dispatch_topology:
  phases:
    21.0.5:
      batches:
        - id: B1
          tasks: [T-A, T-B]
          owner_tokens:
            T-A: ["a.sh", "shared/a.txt"]
            T-B:
              - "b.sh"
              - "shared/b.txt"
        - id: B2
          tasks: [T-C, T-D]
          owner_tokens:
            T-C: ["c.sh"]
            T-D: ["d.sh"]
```

#### T-A - clean
file_owner_token:
  - "a.sh"
  - "shared/a.txt"

#### T-B - clean
file_owner_token: ["b.sh", "shared/b.txt"]

#### T-C - clean
file_owner_token: ["c.sh"]

#### T-D - clean
file_owner_token: ["d.sh"]
EOF

cat > "${SCRATCH}/collision.md" <<'EOF'
```yaml
dispatch_topology:
  phases:
    21.0.5:
      batches:
        - id: B1
          tasks: [T-A, T-B]
          owner_tokens:
            T-A: ["same.sh"]
            T-B:
              - "same.sh"
```
EOF

cat > "${SCRATCH}/mismatch.md" <<'EOF'
```yaml
dispatch_topology:
  phases:
    21.0.5:
      batches:
        - id: B1
          tasks: [T-X]
          owner_tokens:
            T-X: ["a.sh"]
```

#### T-X - mismatch
file_owner_token: ["b.sh"]
EOF

cat > "${SCRATCH}/noblock.md" <<'EOF'
# ExecPlan without topology

#### T-X - no topology
file_owner_token: ["a.sh"]
EOF

cat > "${SCRATCH}/collision_mismatch.md" <<'EOF'
```yaml
dispatch_topology:
  phases:
    21.0.5:
      batches:
        - id: B1
          tasks: [T-A, T-B]
          owner_tokens:
            T-A: ["same.sh"]
            T-B: ["same.sh"]
```

#### T-A - mismatch plus collision
file_owner_token: ["different.sh"]

#### T-B - collision only
file_owner_token: ["same.sh"]
EOF

echo "[fixture 1] clean"
run_case "clean" "${SCRATCH}/clean.md" 0 >/dev/null

echo "[fixture 2] collision"
run_case "collision" "${SCRATCH}/collision.md" 1
assert_contains "collision diagnostic" "${RUN_OUT}" "COLLISION:"

echo "[fixture 3] mismatch"
run_case "mismatch" "${SCRATCH}/mismatch.md" 2
assert_contains "mismatch diagnostic" "${RUN_OUT}" "owner_tokens_mismatch"

echo "[fixture 4a] no block default"
run_case "noblock_default" "${SCRATCH}/noblock.md" 0
assert_contains "no block info" "${RUN_OUT}" "INFO: no dispatch_topology"

echo "[fixture 4b] no block strict"
run_case "noblock_strict" "${SCRATCH}/noblock.md" 3 --strict
assert_contains "no block strict diagnostic" "${RUN_OUT}" "STRICT: no dispatch_topology"

echo "[fixture 5] collision and mismatch"
run_case "collision_mismatch" "${SCRATCH}/collision_mismatch.md" 1
assert_contains "priority collision diagnostic" "${RUN_OUT}" "COLLISION:"
assert_contains "priority mismatch diagnostic" "${RUN_OUT}" "owner_tokens_mismatch"

echo "PASS=${PASS} FAIL=${FAIL}"
if (( FAIL == 0 )); then
  exit 0
fi
exit 1
