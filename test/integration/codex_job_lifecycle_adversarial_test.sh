#!/usr/bin/env bash
#
# codex_job_lifecycle_adversarial_test.sh
#
# Adversarial lifecycle / evidence-integrity matrix for scripts/codex-job.sh
# (0.0.7 hardening). Mirrors the durability/receipt guarantees of the
# codex-claude-caller supervisor/runner reference implementation:
#
#   - success / non-zero exit / timeout
#   - forged-evidence rejection (fake exit_code, missing/mismatched terminal
#     receipt, protected-copy mismatch) -> fail-closed, never reported success
#   - EPIPE / direct-receipt loss recovery via status/wait reconstruction
#   - supervisor + real child SIGKILL orphaning -> durable fail-closed finalize
#   - PID reuse / start-token mismatch detection (never reports running, never
#     signals an unrelated live PID)
#   - PGID-aware stop / reap of proven descendants only (unrelated PIDs unharmed)
#   - processes-report empties once jobs reach a terminal receipt
#   - concurrent same-cwd execution + 80-way stress with unique ids
#
# No real codex CLI and no API billing: the codex-wrapper entrypoint is replaced
# by a lightweight echo/sleep fake via the REV_HARNESS_JOB_WRAPPER test seam.
#
# Self-contained. Isolates REV_HARNESS_RUN_DIR under mktemp per case. A watchdog
# converts a hang into a diagnostic FAIL (exit 124).

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CODEX_JOB="$ROOT_DIR/scripts/codex-job.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-job-adversarial.XXXXXX")"
BIN_DIR="$TMP_DIR/bin"
mkdir -p "$BIN_DIR"
WATCHDOG_PID=""
TEST_PID="$$"
FAILS=0

# Track child/supervisor PIDs we deliberately spawn so cleanup never leaks.
LEAK_PIDS=()

cleanup() {
  local p
  for p in "${LEAK_PIDS[@]:-}"; do
    [[ -n "$p" ]] || continue
    kill -9 "$p" 2>/dev/null || true
  done
  if [[ -n "$WATCHDOG_PID" ]]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
  fi
  /bin/rm -rf "$TMP_DIR"
}
trap cleanup EXIT

timeout_diagnostics() {
  printf 'FAIL: codex_job_lifecycle_adversarial timed out after %s seconds\n' \
    "${CODEX_JOB_ADVERSARIAL_TIMEOUT_SECONDS:-240}" >&2
  ps -Ao pid=,ppid=,pgid=,stat=,command= 2>/dev/null \
    | awk '/codex-job|fake-wrapper|slow-wrapper/ { print }' >&2 || true
  exit 124
}
trap timeout_diagnostics ALRM

(
  sleep "${CODEX_JOB_ADVERSARIAL_TIMEOUT_SECONDS:-240}"
  kill -ALRM "$TEST_PID" 2>/dev/null || true
) &
WATCHDOG_PID="$!"

# ---- helpers ----------------------------------------------------------------

note() { printf '%s\n' "$*"; }
ok()   { printf 'ok   - %s\n' "$*"; }
bad()  { printf 'FAIL - %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

# codex-job.sh must run from within the canonical checkout; pin the guard root.
export REV_HARNESS_CANONICAL_ROOT="$ROOT_DIR"

cj() {
  # cj <run_dir> <args...> ; forwards REV_HARNESS_RUN_DIR isolation.
  local rd="$1"; shift
  REV_HARNESS_RUN_DIR="$rd" \
  REV_HARNESS_JOB_WRAPPER="$FAKE_WRAPPER" \
    bash "$CODEX_JOB" "$@"
}

cj_slow() {
  local rd="$1"; shift
  REV_HARNESS_RUN_DIR="$rd" \
  REV_HARNESS_JOB_WRAPPER="$SLOW_WRAPPER" \
    bash "$CODEX_JOB" "$@"
}

# extract a scalar JSON field from a single-line object (string or number).
jget() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || { printf ''; return 0; }
  awk -v k="\"${key}\"" '
    { i=index($0,k); if(i==0) next; r=substr($0,i+length(k));
      sub(/^[ \t]*:[ \t]*/,"",r);
      if(substr(r,1,1)=="\""){ v=substr(r,2); e=index(v,"\""); if(e>0)v=substr(v,1,e-1); print v }
      else { v=r; sub(/[,}].*/,"",v); gsub(/[ \t\r\n]/,"",v); print v }
      exit }' "$file"
}

new_run() { local d="$1"; /bin/rm -rf "$d" 2>/dev/null; mkdir -p "$d"; }

# ---- fakes ------------------------------------------------------------------

FAKE_WRAPPER="$BIN_DIR/fake-wrapper.sh"
cat > "$FAKE_WRAPPER" <<'EOF'
#!/usr/bin/env bash
# Consumes stdin, emits one output line, exits with FAKE_RC (default 0).
cat >/dev/null 2>&1 || true
printf 'fake-wrapper output line\n'
exit "${FAKE_RC:-0}"
EOF
chmod +x "$FAKE_WRAPPER"

SLOW_WRAPPER="$BIN_DIR/slow-wrapper.sh"
cat > "$SLOW_WRAPPER" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
sleep 60
exit 0
EOF
chmod +x "$SLOW_WRAPPER"

# ---- cases ------------------------------------------------------------------

# 1) success path: two-stage receipts, protected copy, wait exit 0 completed.
case_success() {
  local rd="$TMP_DIR/success"; new_run "$rd"
  local jid; jid="$(cj "$rd" start --role reviewer 'hi' 2>/dev/null)"
  [[ -n "$jid" ]] || { bad "success: no job id"; return; }
  [[ -f "$rd/jobs/$jid/receipt.started.json" ]] || bad "success: no started receipt"
  [[ -f "$rd/jobs/$jid/meta.json" ]] || bad "success: no meta.json"
  local out rc
  out="$(cj "$rd" wait "$jid" --timeout 15 2>/dev/null)"; rc=$?
  [[ "$rc" -eq 0 ]] || bad "success: wait rc=$rc expected 0"
  case "$out" in *'"state":"completed"'*) : ;; *) bad "success: state not completed" ;; esac
  [[ -f "$rd/jobs/$jid/receipt.terminal.json" ]] || bad "success: no terminal receipt"
  [[ -f "$rd/state/codex-job/protected/$jid/terminal.json" ]] || bad "success: no protected terminal copy"
  [[ "$(jget "$rd/jobs/$jid/receipt.terminal.json" exit_code)" == "0" ]] || bad "success: terminal exit_code!=0"
  ok "success: started+terminal receipts, protected copy, wait exit 0"
}

# 2) non-zero exit: failed state, exit code preserved through wait.
case_nonzero_exit() {
  local rd="$TMP_DIR/nonzero"; new_run "$rd"
  local jid; jid="$(REV_HARNESS_RUN_DIR="$rd" REV_HARNESS_JOB_WRAPPER="$FAKE_WRAPPER" FAKE_RC=3 \
    bash "$CODEX_JOB" start 'x' 2>/dev/null)"
  local rc; cj "$rd" wait "$jid" --timeout 15 >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 3 ]] || bad "nonzero: wait rc=$rc expected 3"
  [[ "$(jget "$rd/jobs/$jid/status.json" exit_code)" == "3" ]] || bad "nonzero: status exit_code!=3"
  [[ "$(jget "$rd/jobs/$jid/status.json" state)" == "failed" ]] || bad "nonzero: state!=failed"
  ok "nonzero exit: failed state with exit_code=3 preserved"
}

# 3) timeout: 124, still running, no exit_code, processes-report shows it alive.
case_timeout() {
  local rd="$TMP_DIR/timeout"; new_run "$rd"
  local jid; jid="$(cj_slow "$rd" start 'slow' 2>/dev/null)"
  local sup; sup="$(cat "$rd/jobs/$jid/pid" 2>/dev/null)"; LEAK_PIDS+=("$sup")
  local out rc
  out="$(cj_slow "$rd" wait "$jid" --timeout 2 2>/dev/null)"; rc=$?
  [[ "$rc" -eq 124 ]] || bad "timeout: wait rc=$rc expected 124"
  case "$out" in *'"state":"running"'*) : ;; *) bad "timeout: state not running" ;; esac
  [[ ! -f "$rd/jobs/$jid/exit_code" ]] || bad "timeout: exit_code present while running"
  local pr; pr="$(cj_slow "$rd" processes-report 2>/dev/null)"
  case "$pr" in *"$jid"*'"proven_alive":true'*) : ;; *) bad "timeout: processes-report missing alive child" ;; esac
  ok "timeout: rc=124, running, no exit_code, processes-report proven-alive"
  # stop it (also exercises PGID-aware stop) and confirm unrelated shell survives.
  local cpid; cpid="$(jget "$rd/jobs/$jid/child.json" child_pid)"; LEAK_PIDS+=("$cpid")
  cj_slow "$rd" stop "$jid" --grace 3 >/dev/null 2>&1
  sleep 1
  if kill -0 "$cpid" 2>/dev/null; then bad "stop: child $cpid still alive after stop"; else ok "stop: PGID-aware TERM stopped proven child group"; fi
  kill -0 "$TEST_PID" 2>/dev/null && ok "stop: unrelated test PID $TEST_PID untouched" || bad "stop: harmed the test process"
}

# 4) forged success: exit_code=0 but no valid terminal receipt -> fail-closed.
case_forged_missing_receipt() {
  local rd="$TMP_DIR/forged1"; new_run "$rd"
  local jid; jid="$(cj "$rd" start 'x' 2>/dev/null)"
  cj "$rd" wait "$jid" --timeout 15 >/dev/null 2>&1
  /bin/rm -f "$rd/jobs/$jid/receipt.terminal.json" "$rd/jobs/$jid/status.json" \
            "$rd/state/codex-job/protected/$jid/terminal.json"
  printf '0\n' > "$rd/jobs/$jid/exit_code"
  local st; st="$(cj "$rd" status "$jid" 2>/dev/null)"
  case "$st" in
    *'"state":"failed"'*'"exit_code":1'*) ok "forged (missing receipt): fail-closed to failed/exit 1" ;;
    *) bad "forged (missing receipt): not fail-closed -> $st" ;;
  esac
}

# 4b) forged success: protected authoritative copy disagrees with jobdir exit.
case_forged_protected_mismatch() {
  local rd="$TMP_DIR/forged2"; new_run "$rd"
  local jid; jid="$(cj "$rd" start 'x' 2>/dev/null)"
  cj "$rd" wait "$jid" --timeout 15 >/dev/null 2>&1
  # attacker flips protected copy to a different exit code; jobdir says 0.
  printf '{"schema_version":1,"event":"finished","job_id":"%s","exit_code":7,"completed_at_epoch":1,"log_sha256":"x","child_pgid":1}\n' \
    "$jid" > "$rd/state/codex-job/protected/$jid/terminal.json"
  /bin/rm -f "$rd/jobs/$jid/status.json"
  local st; st="$(cj "$rd" status "$jid" 2>/dev/null)"
  case "$st" in
    *'"state":"failed"'*) ok "forged (protected mismatch): fail-closed to failed" ;;
    *) bad "forged (protected mismatch): not fail-closed -> $st" ;;
  esac
}

# 4c) truncated/garbage exit_code content rejected.
case_forged_garbage_exitcode() {
  local rd="$TMP_DIR/forged3"; new_run "$rd"
  local jid; jid="$(cj "$rd" start 'x' 2>/dev/null)"
  cj "$rd" wait "$jid" --timeout 15 >/dev/null 2>&1
  printf 'not-a-number\n' > "$rd/jobs/$jid/exit_code"
  /bin/rm -f "$rd/jobs/$jid/status.json"
  local st; st="$(cj "$rd" status "$jid" 2>/dev/null)"
  case "$st" in
    *'"state":"failed"'*'"exit_code":1'*) ok "forged (garbage exit_code): rejected, fail-closed" ;;
    *) bad "forged (garbage exit_code): not fail-closed -> $st" ;;
  esac
}

# 5) EPIPE / direct-receipt loss: delete status.json on a legit completed job ->
#    status/wait reconstruct the terminal state from durable receipts.
case_epipe_recovery() {
  local rd="$TMP_DIR/epipe"; new_run "$rd"
  local jid; jid="$(cj "$rd" start 'x' 2>/dev/null)"
  cj "$rd" wait "$jid" --timeout 15 >/dev/null 2>&1
  /bin/rm -f "$rd/jobs/$jid/status.json"
  local st; st="$(cj "$rd" status "$jid" 2>/dev/null)"
  case "$st" in
    *'"state":"completed"'*'"exit_code":0'*) ok "EPIPE recovery: status.json reconstructed as completed/0" ;;
    *) bad "EPIPE recovery: not reconstructed -> $st" ;;
  esac
}

# 6) supervisor + real child SIGKILL orphaning -> durable fail-closed finalize,
#    not reported running/completed; becomes terminal + gc-able.
case_orphan_sigkill() {
  local rd="$TMP_DIR/orphan"; new_run "$rd"
  local jid; jid="$(cj_slow "$rd" start 'x' 2>/dev/null)"
  local sup cpid
  sup="$(cat "$rd/jobs/$jid/pid")"
  cpid="$(jget "$rd/jobs/$jid/child.json" child_pid)"
  kill -9 "$sup" "$cpid" 2>/dev/null || true
  sleep 1
  local st; st="$(cj_slow "$rd" status "$jid" 2>/dev/null)"
  case "$st" in
    *'"state":"failed"'*) ok "orphan SIGKILL: fail-closed to failed (not running/completed)" ;;
    *) bad "orphan SIGKILL: unexpected state -> $st" ;;
  esac
  [[ -f "$rd/jobs/$jid/exit_code" ]] || bad "orphan SIGKILL: not durably terminal (no exit_code)"
  [[ "$(jget "$rd/jobs/$jid/receipt.terminal.json" event)" == "orphan_finalized" ]] \
    || bad "orphan SIGKILL: no orphan_finalized receipt"
  # gc must now be able to remove it (terminal + ended).
  cj_slow "$rd" gc --ttl 0 >/dev/null 2>&1
  [[ ! -d "$rd/jobs/$jid" ]] || bad "orphan SIGKILL: gc failed to remove finalized orphan"
  ok "orphan SIGKILL: durable terminal, gc-collectable"
}

# 7) PID reuse / start-token mismatch: forged child.json pointing at a live but
#    unrelated PID with the wrong start-token must NOT report running, and must
#    NOT signal the unrelated PID.
case_pid_reuse() {
  local rd="$TMP_DIR/pidreuse"; new_run "$rd"
  local jid; jid="$(cj_slow "$rd" start 'x' 2>/dev/null)"
  local sup oldc
  sup="$(cat "$rd/jobs/$jid/pid")"
  oldc="$(jget "$rd/jobs/$jid/child.json" child_pid)"
  kill -9 "$sup" "$oldc" 2>/dev/null || true
  sleep 1
  # unrelated live victim we must never signal.
  sleep 90 &
  local victim=$!; LEAK_PIDS+=("$victim")
  printf '{"schema_version":1,"job_id":"%s","child_pid":%s,"child_pgid":%s,"child_start_token":"BOGUS TOKEN 1999","started_at_epoch":1}\n' \
    "$jid" "$victim" "$victim" > "$rd/jobs/$jid/child.json"
  /bin/rm -f "$rd/jobs/$jid/status.json"
  printf '{"job_id":"%s","state":"running","role":"standard","pid":%s,"started_at":"2026-01-01T00:00:00Z","ended_at":null,"exit_code":null}\n' \
    "$jid" "$sup" > "$rd/jobs/$jid/status.json"
  local st; st="$(cj_slow "$rd" status "$jid" 2>/dev/null)"
  case "$st" in
    *'"state":"running"'*) bad "pid-reuse: still reported running despite token mismatch" ;;
    *'"state":"failed"'*) ok "pid-reuse: token mismatch -> failed, not running" ;;
    *) bad "pid-reuse: unexpected -> $st" ;;
  esac
  # stop/reap must refuse to signal the unrelated victim.
  cj_slow "$rd" stop "$jid" --grace 1 >/dev/null 2>&1 || true
  if kill -0 "$victim" 2>/dev/null; then ok "pid-reuse: unrelated victim PID $victim not signaled"; else bad "pid-reuse: signaled unrelated victim PID"; fi
}

# 8) reap: proven-alive children stopped, orphaned children finalized, unrelated
#    PIDs untouched; processes-report empties afterwards.
case_reap() {
  local rd="$TMP_DIR/reap"; new_run "$rd"
  local j1 j2
  j1="$(cj_slow "$rd" start 'alive' 2>/dev/null)"
  j2="$(cj_slow "$rd" start 'orphan' 2>/dev/null)"
  local c1; c1="$(jget "$rd/jobs/$j1/child.json" child_pid)"; LEAK_PIDS+=("$c1")
  local s2 c2
  s2="$(cat "$rd/jobs/$j2/pid")"; c2="$(jget "$rd/jobs/$j2/child.json" child_pid)"
  kill -9 "$s2" "$c2" 2>/dev/null || true
  sleep 1
  sleep 90 & local victim=$!; LEAK_PIDS+=("$victim")
  cj_slow "$rd" reap --grace 3 >/dev/null 2>&1
  sleep 1
  kill -0 "$victim" 2>/dev/null && ok "reap: unrelated victim PID untouched" || bad "reap: harmed unrelated victim PID"
  [[ "$(jget "$rd/jobs/$j1/status.json" state)" == "failed" ]] || bad "reap: alive job not stopped"
  [[ -f "$rd/jobs/$j2/exit_code" ]] || bad "reap: orphan not finalized to terminal"
  local pr; pr="$(cj_slow "$rd" processes-report 2>/dev/null)"
  [[ -z "$pr" ]] || bad "reap: processes-report not empty after reap -> $pr"
  ok "reap: alive stopped, orphan finalized, processes-report empty"
}

# 9) path traversal / bad job-id rejected with usage exit 64 (containment).
case_path_traversal() {
  local rd="$TMP_DIR/trav"; new_run "$rd"
  local sub bad_id rc
  for sub in status wait result stop; do
    for bad_id in '../etc' '..' 'a/b' 'ZZZ' '/abs' 'short'; do
      REV_HARNESS_RUN_DIR="$rd" bash "$CODEX_JOB" "$sub" "$bad_id" >/dev/null 2>&1
      rc=$?
      [[ "$rc" -eq 64 ]] || { bad "traversal: $sub '$bad_id' rc=$rc expected 64"; return; }
    done
  done
  ok "path traversal: status/wait/result/stop reject bad job-ids with exit 64"
}

# 10) MCP/auth-noise + no-output job: fake wrapper emitting only noise on stderr
#     and no stdout still yields a clean terminal receipt (exit 0).
case_noise_no_output() {
  local rd="$TMP_DIR/noise"; new_run "$rd"
  local noise="$BIN_DIR/noise-wrapper.sh"
  cat > "$noise" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
printf 'MCP client warning: could not reach optional server\n' >&2
printf 'authenticating... using cached subscription session\n' >&2
exit 0
EOF
  chmod +x "$noise"
  local jid rc out
  jid="$(REV_HARNESS_RUN_DIR="$rd" REV_HARNESS_JOB_WRAPPER="$noise" bash "$CODEX_JOB" start 'x' 2>/dev/null)"
  out="$(REV_HARNESS_RUN_DIR="$rd" REV_HARNESS_JOB_WRAPPER="$noise" bash "$CODEX_JOB" wait "$jid" --timeout 15 2>/dev/null)"; rc=$?
  [[ "$rc" -eq 0 ]] || bad "noise: wait rc=$rc expected 0"
  case "$out" in *'"state":"completed"'*) ok "noise/no-output: clean terminal receipt (exit 0)" ;; *) bad "noise: not completed -> $out" ;; esac
}

# 11) concurrent same-cwd + 80-way stress: unique ids, all reach terminal.
case_stress_80() {
  local rd="$TMP_DIR/stress"; new_run "$rd"
  local ids="$TMP_DIR/stress.ids"; : > "$ids"
  local n=80 i pids=()
  for ((i=1; i<=n; i++)); do
    ( cj "$rd" start "job-$i" 2>/dev/null >> "$ids" ) &
    pids+=("$!")
  done
  wait "${pids[@]}" 2>/dev/null || true
  local started unique
  started="$(grep -c . "$ids" 2>/dev/null | tr -d ' ')"
  unique="$(sort -u "$ids" | grep -c . | tr -d ' ')"
  [[ "$started" -eq "$n" ]] || bad "stress: started=$started expected $n"
  [[ "$unique" -eq "$n" ]] || bad "stress: unique=$unique expected $n (id collision)"
  local jid completed=0
  while IFS= read -r jid; do
    [[ -n "$jid" ]] || continue
    cj "$rd" wait "$jid" --timeout 20 >/dev/null 2>&1
    [[ "$(jget "$rd/jobs/$jid/status.json" state)" == "completed" ]] && completed=$((completed + 1))
  done < "$ids"
  [[ "$completed" -eq "$n" ]] || bad "stress: completed=$completed expected $n"
  # processes-report must be empty once all terminal.
  local pr; pr="$(cj "$rd" processes-report 2>/dev/null)"
  [[ -z "$pr" ]] || bad "stress: processes-report not empty after all complete"
  ok "stress: ${n}-way concurrent unique ids, all completed, processes-report empty"
}

# ---- run --------------------------------------------------------------------

note "== codex-job.sh adversarial lifecycle matrix =="
[[ -x "$CODEX_JOB" ]] || { printf 'FAIL: %s missing or not executable\n' "$CODEX_JOB" >&2; exit 1; }

case_success
case_nonzero_exit
case_timeout
case_forged_missing_receipt
case_forged_protected_mismatch
case_forged_garbage_exitcode
case_epipe_recovery
case_orphan_sigkill
case_pid_reuse
case_reap
case_path_traversal
case_noise_no_output
case_stress_80

if [[ "$FAILS" -eq 0 ]]; then
  printf 'PASS: codex_job_lifecycle_adversarial (all cases)\n'
  exit 0
fi
printf 'RESULT: %d assertion(s) failed\n' "$FAILS" >&2
exit 1
