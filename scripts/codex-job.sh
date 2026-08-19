#!/usr/bin/env bash
#
# codex-job.sh - Asynchronous job manager for codex-wrapper.sh
#
# Subcommands: start | status | wait | result | gc
#              runs-report | processes-report | stop | reap   (0.0.7 lifecycle)
#
# 目的:
#   codex-wrapper.sh を非同期に起動し、ジョブ ID を介して状態 / ログ /
#   exit code を後から取得可能にする。長時間ジョブを fire-and-forget で
#   発火し、ポーリングで結果を取得するワークフローを支える。
#
# 0.0.7 ライフサイクル堅牢化 (crossmodel_supervisor.py / crossmodel_runner.py の
# 証跡強度に合わせる):
#   - 予測不能な CSPRNG run-id + resolved-path containment。
#   - protected state: ターゲット外の ${RUN_DIR}/state/codex-job/protected/<id>
#     に 0700 + umask 077 で authoritative な terminal 証跡を複製保存。
#   - 二段階レシート: 即時 receipt.started.json + durable receipt.terminal.json。
#   - identity/start-token 記録 (supervisor/child PID・PGID・ps lstart トークン)
#     による PID 再利用検出。
#   - PGID を意識した TERM→grace→KILL (macOS は setsid 不在のため `set -m`
#     monitor mode で child を独立プロセスグループに配置する)。
#   - 信頼できる exit 証跡が無い/偽造/不整合なら fail-closed (成功と誤認しない)。
#   - EPIPE / status.json 消失後も receipt/exit_code から status/wait が復旧。
#   - retention/GC は active/未解決の run を絶対に削除しない。
#
# Layout (per job):
#   ${REV_HARNESS_RUN_DIR:-$HOME/.rev_harness}/jobs/<job-id>/
#     cmd                   - 実行コマンドライン (debug/audit)
#     prompt                - プロンプト本文 (完了時に削除、--keep-prompt で保持)
#     pid                   - supervisor (バックグラウンド) PID  ※legacy 互換
#     log                   - stdout + stderr マージ
#     exit_code             - 完了時に書かれる exit code (presence == terminal)
#     status.json           - { state, started_at, ended_at, exit_code, job_id, role, pid }
#     meta.json             - identity: supervisor pid/token, cwd, owner uid など
#     child.json            - child sidecar: child pid/pgid/start-token
#     receipt.started.json  - 即時 started レシート
#     receipt.terminal.json - durable terminal レシート (child が atomic 書込)
#   ${RUN_DIR}/state/codex-job/protected/<job-id>/terminal.json  - authoritative 複製
#
# 互換性: macOS bash 3.x (associative array 不使用)
# 関連: docs/plans/2026-05-reporting-reliability/plan-v4-final.md (PR#1)

set -euo pipefail

# 起動時に umask 077 で job artifact が他ユーザー読み取り不可に。
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Vendoring 防止 guard
# shellcheck source=scripts/_canonical-guard.sh
source "${SCRIPT_DIR}/_canonical-guard.sh"
rev_harness_assert_canonical_root codex-job

# Shim log (既存互換)
# shellcheck source=scripts/_shim-log.sh
source "${SCRIPT_DIR}/_shim-log.sh"

readonly RUN_DIR="${REV_HARNESS_RUN_DIR:-${HOME}/.rev_harness}"
readonly JOBS_DIR="${RUN_DIR}/jobs"
# protected state 名前空間 (codex-claude-caller の ~/.codex/state/.../protected 相当)。
readonly STATE_DIR="${RUN_DIR}/state/codex-job"
readonly PROTECTED_DIR="${STATE_DIR}/protected"
readonly DEFAULT_WAIT_TIMEOUT=900
readonly DEFAULT_GC_TTL_DAYS=7
readonly POLL_INTERVAL=2
# gc --ttl 上限 (1 年)。これ以上は誤入力扱い。
readonly GC_TTL_MAX_DAYS=365
# stop/reap の TERM→KILL 猶予 (秒)。
readonly DEFAULT_STOP_GRACE=5
readonly STOP_GRACE_MAX=120
# job-id 形式制約 (16〜32 桁 hex)。0.0.7 は 26 桁 hex を生成。
readonly JOB_ID_REGEX='^[0-9a-f]{16,32}$'

# Exit codes
readonly EX_OK=0
readonly EX_USAGE=64
readonly EX_TIMEOUT=124

# verify_terminal が設定するグローバル
VERIFIED_EXIT=""
VERIFY_REASON=""

log_err() {
  echo "[codex-job] ERROR: $*" >&2
}

log_warn() {
  echo "[codex-job] WARN: $*" >&2
}

# ---- helpers ----------------------------------------------------------------

# 予測不能な job-id: 10 進 timestamp(秒) を 10桁hex + CSPRNG 8 バイト(16桁hex)
# = 26 文字。/dev/urandom が使えない環境では RANDOM×3 にフォールバック。
gen_job_id() {
  local ts hex
  ts=$(date -u +%s)
  hex="$(head -c 8 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
  if [[ -n "$hex" && ${#hex} -ge 16 ]]; then
    printf '%010x%s\n' "$ts" "${hex:0:16}"
  else
    printf '%010x%04x%04x%04x\n' "$ts" "$RANDOM" "$RANDOM" "$RANDOM"
  fi
}

iso8601_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# JSON 文字列の minimal エスケープ (バックスラッシュとダブルクォートのみ)
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# atomic write: tmp に書いて mv
atomic_write() {
  local target="$1"
  local content="$2"
  local tmp="${target}.tmp.$$"
  printf '%s' "$content" > "$tmp"
  mv -f "$tmp" "$target"
}

sha256_file() {
  local path="$1"
  [[ -f "$path" ]] || { printf ''; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" 2>/dev/null | cut -d' ' -f1
  else
    shasum -a 256 "$path" 2>/dev/null | cut -d' ' -f1
  fi
}

# プロセス start-token (ps lstart)。PID 再利用検出に用いる。存在しなければ空。
proc_identity() {
  local pid="$1"
  [[ -n "$pid" && "$pid" != "0" ]] || { printf ''; return 0; }
  ps -o lstart= -p "$pid" 2>/dev/null || printf ''
}

# job-id を検証して run dir 配下の正規 path を返す。
# 違反は EX_USAGE で終了する。エコーは canonical job_dir。
resolve_job_dir() {
  local job_id="$1"
  if [[ -z "$job_id" ]]; then
    log_err "missing job-id"
    return $EX_USAGE
  fi
  if [[ ! "$job_id" =~ $JOB_ID_REGEX ]]; then
    log_err "invalid job-id format: ${job_id}"
    return $EX_USAGE
  fi
  # JOBS_DIR は内部生成 path のみで、外部入力は $job_id だけ。
  # `..` や `/` の混入は regex で既に排除済み。resolved-path containment を
  # 二重確認する。
  local candidate="${JOBS_DIR}/${job_id}"
  case "$candidate" in
    "${JOBS_DIR}/"*) : ;;
    *)
      log_err "path containment violation: ${job_id}"
      return $EX_USAGE
      ;;
  esac
  printf '%s' "$candidate"
}

# status.json を書き出す
# args: job_dir state role pid started_at ended_at exit_code
write_status() {
  local job_dir="$1"
  local state="$2"
  local role="$3"
  local pid="$4"
  local started_at="$5"
  local ended_at="$6"
  local exit_code="$7"
  local job_id
  job_id=$(basename "$job_dir")

  local ended_field exit_field
  if [[ -z "$ended_at" ]]; then
    ended_field='null'
  else
    ended_field=$(printf '"%s"' "$(json_escape "$ended_at")")
  fi
  if [[ -z "$exit_code" ]]; then
    exit_field='null'
  else
    exit_field="$exit_code"
  fi

  local json
  json=$(printf '{"job_id":"%s","state":"%s","role":"%s","pid":%d,"started_at":"%s","ended_at":%s,"exit_code":%s}\n' \
    "$(json_escape "$job_id")" \
    "$(json_escape "$state")" \
    "$(json_escape "$role")" \
    "$pid" \
    "$(json_escape "$started_at")" \
    "$ended_field" \
    "$exit_field")
  atomic_write "${job_dir}/status.json" "$json"
  chmod 600 "${job_dir}/status.json" 2>/dev/null || true
}

# status.json / *.json から特定 key の値を抽出する (一行 JSON 前提)。
json_get() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || { printf ''; return 0; }
  awk -v key="\"${key}\"" '
    {
      idx = index($0, key)
      if (idx == 0) next
      rest = substr($0, idx + length(key))
      sub(/^[ \t]*:[ \t]*/, "", rest)
      if (substr(rest, 1, 1) == "\"") {
        v = substr(rest, 2)
        end = index(v, "\"")
        if (end > 0) v = substr(v, 1, end - 1)
        print v
      } else {
        v = rest
        sub(/[,}].*/, "", v)
        gsub(/[ \t\r\n]/, "", v)
        print v
      }
      exit
    }
  ' "$file"
}

# PID が生きているかチェック (kill -0)
pid_alive() {
  local pid="$1"
  if [[ -z "$pid" || "$pid" == "0" ]]; then
    return 1
  fi
  kill -0 "$pid" 2>/dev/null
}

# プロセスグループが生きているか
group_alive() {
  local pgid="$1"
  [[ -n "$pgid" && "$pgid" -gt 1 ]] || return 1
  kill -0 -- "-${pgid}" 2>/dev/null
}

# 信頼できる terminal 証跡を検証する。
#   - exit_code ファイルが 0..255 の整数であること
#   - receipt.terminal.json が存在し job_id / exit_code が一致すること
#   - protected 複製があれば exit_code が一致すること
# 検証成功で VERIFIED_EXIT を設定し 0 を返す。失敗は VERIFY_REASON を設定し 1。
verify_terminal() {
  local job_dir="$1"
  VERIFIED_EXIT=""
  VERIFY_REASON=""
  local job_id
  job_id=$(basename "$job_dir")

  if [[ ! -f "${job_dir}/exit_code" ]]; then
    VERIFY_REASON="no_exit_code"
    return 1
  fi
  local ec
  ec=$(cat "${job_dir}/exit_code" 2>/dev/null | tr -d '[:space:]')
  if [[ ! "$ec" =~ ^[0-9]+$ ]] || [[ "$ec" -gt 255 ]]; then
    VERIFY_REASON="forged_exit_code"
    return 1
  fi

  local term="${job_dir}/receipt.terminal.json"
  if [[ ! -f "$term" ]]; then
    VERIFY_REASON="missing_terminal_receipt"
    return 1
  fi
  local rjob rec
  rjob=$(json_get "$term" job_id)
  rec=$(json_get "$term" exit_code)
  if [[ "$rjob" != "$job_id" ]]; then
    VERIFY_REASON="terminal_receipt_identity_mismatch"
    return 1
  fi
  if [[ "$rec" != "$ec" ]]; then
    VERIFY_REASON="terminal_receipt_exit_mismatch"
    return 1
  fi

  # protected authoritative 複製とのクロスチェック (存在すれば必須一致)。
  local prot="${PROTECTED_DIR}/${job_id}/terminal.json"
  if [[ -f "$prot" ]]; then
    local pjob pec
    pjob=$(json_get "$prot" job_id)
    pec=$(json_get "$prot" exit_code)
    if [[ "$pjob" != "$job_id" || "$pec" != "$ec" ]]; then
      VERIFY_REASON="protected_receipt_mismatch"
      return 1
    fi
  fi

  VERIFIED_EXIT="$ec"
  return 0
}

# child sidecar から現在の生存状態を判定。
#   0 = child は生存中でトークン一致 (本当に running)
#   1 = child は死亡 / トークン不一致 / sidecar 欠如 (running ではない)
child_running() {
  local job_dir="$1"
  local cs="${job_dir}/child.json"
  [[ -f "$cs" ]] || return 1
  local cpid ctok
  cpid=$(json_get "$cs" child_pid)
  ctok=$(json_get "$cs" child_start_token)
  [[ -n "$cpid" && "$cpid" =~ ^[0-9]+$ ]] || return 1
  pid_alive "$cpid" || return 1
  # start-token 検証: PID 再利用なら token が一致しない。
  if [[ -n "$ctok" ]]; then
    local cur
    cur=$(proc_identity "$cpid")
    [[ "$cur" == "$ctok" ]] || return 1
  fi
  return 0
}

# supervisor が生存中でトークン一致か。child 死亡直後の finalize レースを避け、
# supervisor がまだ terminal を書き込む余地があるうちは orphan 断定を保留する。
supervisor_alive() {
  local job_dir="$1"
  local spid stok
  spid=$(json_get "${job_dir}/meta.json" supervisor_pid)
  stok=$(json_get "${job_dir}/meta.json" supervisor_start_token)
  [[ "$spid" =~ ^[0-9]+$ ]] || return 1
  pid_alive "$spid" || return 1
  if [[ -n "$stok" ]]; then
    local cur
    cur=$(proc_identity "$spid")
    [[ "$cur" == "$stok" ]] || return 1
  fi
  return 0
}

# orphan (child+supervisor 双方死亡 & 信頼できる exit_code 無し) を durable に
# fail-closed 確定する。crossmodel_runner.finalize_orphan 相当。exit_code /
# receipt.terminal.json / protected 複製を internally-consistent に書き、以後
# terminal (gc 可能・processes-report から除外) にする。既に terminal なら
# status のみ更新する (冪等)。
finalize_failed_closed() {
  local job_dir="$1" role="$2" pid="$3" started_at="$4"
  local jid
  jid=$(basename "$job_dir")
  if [[ ! -f "${job_dir}/exit_code" ]]; then
    local now_epoch logsha term prot_dir receipt
    now_epoch=$(date -u +%s)
    logsha=$(sha256_file "${job_dir}/log")
    term="${job_dir}/receipt.terminal.json"
    receipt=$(printf '{"schema_version":1,"event":"orphan_finalized","job_id":"%s","exit_code":1,"completed_at_epoch":%s,"log_sha256":"%s","child_pgid":0}\n' \
      "$(json_escape "$jid")" "$now_epoch" "$(json_escape "$logsha")")
    atomic_write "$term" "$receipt"
    chmod 600 "$term" 2>/dev/null || true
    prot_dir="${PROTECTED_DIR}/${jid}"
    mkdir -p "$prot_dir" 2>/dev/null || true
    chmod 700 "$prot_dir" 2>/dev/null || true
    atomic_write "${prot_dir}/terminal.json" "$receipt"
    chmod 600 "${prot_dir}/terminal.json" 2>/dev/null || true
    # exit_code は最後に書く (存在時は必ず receipt が存在する順序 = fail-closed)。
    atomic_write "${job_dir}/exit_code" "1
"
    chmod 600 "${job_dir}/exit_code" 2>/dev/null || true
  fi
  write_status "$job_dir" "failed" "$role" "$pid" "$started_at" "$(iso8601_now)" "1"
}

# job_dir の現在状態を再計算し status.json を更新する。
# fail-closed: 信頼できる terminal 証跡が無ければ「成功」と誤認しない。
# EPIPE 等で status.json が消えていても receipt/exit_code から復旧する。
refresh_status() {
  local job_dir="$1"

  # --- status.json 消失時の復旧 (EPIPE / 直接レシート消失) ---
  if [[ ! -f "${job_dir}/status.json" ]]; then
    local role_r pid_r started_r
    role_r=$(json_get "${job_dir}/meta.json" role)
    pid_r=$(json_get "${job_dir}/meta.json" supervisor_pid)
    started_r=$(json_get "${job_dir}/receipt.started.json" started_at)
    [[ -n "$role_r" ]] || role_r="unknown"
    [[ "$pid_r" =~ ^[0-9]+$ ]] || pid_r=0
    [[ -n "$started_r" ]] || started_r="$(iso8601_now)"
    if verify_terminal "$job_dir"; then
      local st ended
      ended=$(iso8601_now)
      if [[ "$VERIFIED_EXIT" == "0" ]]; then st="completed"; else st="failed"; fi
      write_status "$job_dir" "$st" "$role_r" "$pid_r" "$started_r" "$ended" "$VERIFIED_EXIT"
      return 0
    fi
    if [[ -f "${job_dir}/exit_code" ]]; then
      # exit_code はあるが検証失敗 = 偽造/切り詰め → fail-closed。
      write_status "$job_dir" "failed" "$role_r" "$pid_r" "$started_r" "$(iso8601_now)" "1"
      return 0
    fi
    # まだ terminal 証跡なし。running を再構成 (child 生存確認)。
    if child_running "$job_dir"; then
      write_status "$job_dir" "running" "$role_r" "$pid_r" "$started_r" "" ""
    elif supervisor_alive "$job_dir"; then
      # supervisor がまだ terminal を書く可能性 → running のまま保留。
      write_status "$job_dir" "running" "$role_r" "$pid_r" "$started_r" "" ""
    else
      finalize_failed_closed "$job_dir" "$role_r" "$pid_r" "$started_r"
    fi
    return 0
  fi

  local state pid role started_at
  state=$(json_get "${job_dir}/status.json" state)
  pid=$(json_get "${job_dir}/status.json" pid)
  role=$(json_get "${job_dir}/status.json" role)
  started_at=$(json_get "${job_dir}/status.json" started_at)
  [[ -z "$pid" || "$pid" == "null" ]] && pid=0

  if [[ "$state" != "running" ]]; then
    return 0
  fi

  # 完了優先: exit_code があれば terminal 証跡を検証。
  if [[ -f "${job_dir}/exit_code" ]]; then
    local ended_at
    ended_at=$(iso8601_now)
    if verify_terminal "$job_dir"; then
      local new_state
      if [[ "$VERIFIED_EXIT" == "0" ]]; then new_state="completed"; else new_state="failed"; fi
      write_status "$job_dir" "$new_state" "$role" "$pid" "$started_at" "$ended_at" "$VERIFIED_EXIT"
    else
      # 偽造/不整合な terminal → fail-closed (forged success を拒否)。
      log_warn "job $(basename "$job_dir"): terminal evidence unverified (${VERIFY_REASON}); failing closed"
      write_status "$job_dir" "failed" "$role" "$pid" "$started_at" "$ended_at" "1"
    fi
    return 0
  fi

  # exit_code 未書込。child sidecar で生存を確認 (PID 再利用は token で排除)。
  if child_running "$job_dir"; then
    return 0
  fi

  # legacy fallback: child sidecar が無い旧ジョブは supervisor pid を見る。
  if [[ ! -f "${job_dir}/child.json" ]]; then
    if pid_alive "$pid"; then
      return 0
    fi
    write_status "$job_dir" "failed" "$role" "$pid" "$started_at" "$(iso8601_now)" "1"
    return 0
  fi

  # child は死亡だが supervisor が生きていれば terminal を書く余地がある →
  # running を維持し finalize レースを避ける。
  if supervisor_alive "$job_dir"; then
    return 0
  fi

  # exit_code 不在 + child/supervisor 双方死亡 = orphan → durable fail-closed。
  finalize_failed_closed "$job_dir" "$role" "$pid" "$started_at"
}

# PGID を意識して child プロセスグループを TERM→grace→KILL で停止する。
# 証明済み (token 一致) の child のみを対象とし、無関係/再利用 PID は触らない。
# echo: 実施したアクション文字列。
stop_child_group() {
  local job_dir="$1"
  local grace="$2"
  local cs="${job_dir}/child.json"
  if [[ ! -f "$cs" ]]; then
    printf 'no-child-sidecar'
    return 0
  fi
  local cpid cpgid ctok
  cpid=$(json_get "$cs" child_pid)
  cpgid=$(json_get "$cs" child_pgid)
  ctok=$(json_get "$cs" child_start_token)

  if [[ ! "$cpid" =~ ^[0-9]+$ ]] || ! pid_alive "$cpid"; then
    printf 'already-dead'
    return 0
  fi
  # start-token 検証。不一致は PID 再利用の可能性 → 絶対に signal しない。
  if [[ -n "$ctok" ]]; then
    local cur
    cur=$(proc_identity "$cpid")
    if [[ "$cur" != "$ctok" ]]; then
      printf 'refused-token-mismatch'
      return 0
    fi
  fi
  # 自分自身のプロセスグループは絶対に対象にしない。
  local mypgid
  mypgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
  if [[ -n "$cpgid" && "$cpgid" == "$mypgid" ]]; then
    printf 'refused-self-group'
    return 0
  fi

  local target_desc=""
  if [[ "$cpgid" =~ ^[0-9]+$ && "$cpgid" -gt 1 ]]; then
    kill -TERM -- "-${cpgid}" 2>/dev/null || kill -TERM "$cpid" 2>/dev/null || true
    target_desc="pgid ${cpgid}"
  else
    kill -TERM "$cpid" 2>/dev/null || true
    target_desc="pid ${cpid}"
  fi

  local waited=0
  while [[ "$waited" -lt "$grace" ]]; do
    if ! pid_alive "$cpid"; then
      printf 'term-stopped %s' "$target_desc"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if pid_alive "$cpid"; then
    if [[ "$cpgid" =~ ^[0-9]+$ && "$cpgid" -gt 1 ]]; then
      kill -KILL -- "-${cpgid}" 2>/dev/null || kill -KILL "$cpid" 2>/dev/null || true
    else
      kill -KILL "$cpid" 2>/dev/null || true
    fi
    printf 'kill-forced %s' "$target_desc"
  else
    printf 'term-stopped %s' "$target_desc"
  fi
}

# ---- subcommands ------------------------------------------------------------

cmd_start() {
  local role="standard"
  local prompt=""
  local prompt_from_stdin=true
  local keep_prompt=false
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        role="${2:?--role requires a value}"
        shift 2
        ;;
      --keep-prompt)
        keep_prompt=true
        shift
        ;;
      -h|--help)
        usage; return 0
        ;;
      --)
        shift; break
        ;;
      -*)
        log_err "unknown option: $1"
        return $EX_USAGE
        ;;
      *)
        positional+=("$1"); shift
        ;;
    esac
  done

  if [[ ${#positional[@]} -gt 0 ]]; then
    prompt="${positional[*]}"
    prompt_from_stdin=false
  fi

  mkdir -p "$JOBS_DIR"
  chmod 700 "$JOBS_DIR" 2>/dev/null || true
  mkdir -p "$PROTECTED_DIR"
  chmod 700 "$STATE_DIR" "$PROTECTED_DIR" 2>/dev/null || true

  local job_id job_dir
  # 衝突回避ループ (max 5 回)
  local _i
  for _i in 1 2 3 4 5; do
    job_id=$(gen_job_id)
    job_dir="${JOBS_DIR}/${job_id}"
    if mkdir "$job_dir" 2>/dev/null; then
      break
    fi
    job_id=""
  done
  if [[ -z "$job_id" ]]; then
    log_err "failed to allocate unique job_id"
    return 1
  fi
  chmod 700 "$job_dir" 2>/dev/null || true
  local prot_dir="${PROTECTED_DIR}/${job_id}"

  # prompt を tmp に書き出す (stdin / 引数いずれも)
  local prompt_file="${job_dir}/prompt"
  if $prompt_from_stdin; then
    cat > "$prompt_file"
  else
    printf '%s' "$prompt" > "$prompt_file"
  fi
  chmod 600 "$prompt_file" 2>/dev/null || true

  # 実行コマンドライン (codex-wrapper.sh を唯一の入口とする)。
  # REV_HARNESS_JOB_WRAPPER はテスト/上級用途の seam (実行可能な代替 wrapper)。
  local wrapper="${SCRIPT_DIR}/codex-wrapper.sh"
  if [[ -n "${REV_HARNESS_JOB_WRAPPER:-}" ]]; then
    if [[ -x "${REV_HARNESS_JOB_WRAPPER}" ]]; then
      wrapper="${REV_HARNESS_JOB_WRAPPER}"
      log_warn "using REV_HARNESS_JOB_WRAPPER override: ${wrapper}"
    else
      log_warn "REV_HARNESS_JOB_WRAPPER not executable; ignoring: ${REV_HARNESS_JOB_WRAPPER}"
    fi
  fi
  local cmd_line="${wrapper} --role ${role} --stdin"
  printf '%s\n' "$cmd_line" > "${job_dir}/cmd"
  chmod 600 "${job_dir}/cmd" 2>/dev/null || true

  local started_at
  started_at=$(iso8601_now)

  # shim log 互換 (PII なし)。job_id を紐付ける。
  REV_HARNESS_SHIM_JOB_ID="$job_id" \
    shim_log_hit "codex-job-start" "role=${role}" "job_id=${job_id}" || true

  # バックグラウンド supervisor 起動。
  #   - supervisor は child を `set -m` monitor mode 下で `&` 起動し、child を
  #     独立プロセスグループ (pgid == child pid) に配置する (macOS setsid 代替)。
  #   - child sidecar (pid/pgid/start-token) を atomic 書込。
  #   - 完了時、log の sha256 を含む durable terminal レシートを atomic 書込し、
  #     protected 複製を作成してから、最後に legacy exit_code を書く
  #     (exit_code 存在時に terminal レシートが必ず存在する順序 = fail-closed)。
  local cleanup_prompt_cmd=""
  if ! $keep_prompt; then
    cleanup_prompt_cmd='/bin/rm -f "$3" 2>/dev/null || true;'
  fi
  (
    nohup bash -c '
      umask 077
      set -m
      "$1" --role "$2" --stdin < "$3" >> "$4/log" 2>&1 &
      child=$!
      cpgid=$(ps -o pgid= -p "$child" 2>/dev/null | tr -d " ")
      [ -n "$cpgid" ] || cpgid="$child"
      ctok=$(ps -o lstart= -p "$child" 2>/dev/null)
      jid=$(basename "$4")
      now=$(date -u +%s)
      cs="$4/child.json"
      printf "{\"schema_version\":1,\"job_id\":\"%s\",\"child_pid\":%s,\"child_pgid\":%s,\"child_start_token\":\"%s\",\"started_at_epoch\":%s}\n" "$jid" "$child" "$cpgid" "$ctok" "$now" > "$cs.tmp.$$" && mv -f "$cs.tmp.$$" "$cs"
      chmod 600 "$cs" 2>/dev/null || true
      wait "$child"
      rc=$?
      if command -v sha256sum >/dev/null 2>&1; then
        logsha=$(sha256sum "$4/log" 2>/dev/null | cut -d" " -f1)
      else
        logsha=$(shasum -a 256 "$4/log" 2>/dev/null | cut -d" " -f1)
      fi
      cend=$(date -u +%s)
      term="$4/receipt.terminal.json"
      printf "{\"schema_version\":1,\"event\":\"finished\",\"job_id\":\"%s\",\"exit_code\":%d,\"completed_at_epoch\":%s,\"log_sha256\":\"%s\",\"child_pgid\":%s}\n" "$jid" "$rc" "$cend" "$logsha" "$cpgid" > "$term.tmp.$$" && mv -f "$term.tmp.$$" "$term"
      chmod 600 "$term" 2>/dev/null || true
      mkdir -p "$5" 2>/dev/null || true
      chmod 700 "$5" 2>/dev/null || true
      cp -f "$term" "$5/terminal.json.tmp.$$" 2>/dev/null && mv -f "$5/terminal.json.tmp.$$" "$5/terminal.json" 2>/dev/null || true
      chmod 600 "$5/terminal.json" 2>/dev/null || true
      printf "%d\n" "$rc" > "$4/exit_code.tmp.$$" && mv -f "$4/exit_code.tmp.$$" "$4/exit_code"
      chmod 600 "$4/exit_code" 2>/dev/null || true
      '"$cleanup_prompt_cmd"'
    ' _ "$wrapper" "$role" "$prompt_file" "$job_dir" "$prot_dir" \
      >/dev/null 2>&1 &
    echo $! > "${job_dir}/pid"
  )

  # pid file の確定を一瞬待つ
  local bg_pid=""
  local tries=0
  while [[ $tries -lt 20 ]]; do
    if [[ -s "${job_dir}/pid" ]]; then
      bg_pid=$(cat "${job_dir}/pid")
      break
    fi
    tries=$((tries + 1))
    sleep 0.1 2>/dev/null || sleep 1
  done
  if [[ -z "$bg_pid" ]]; then
    bg_pid=0
  fi
  chmod 600 "${job_dir}/pid" 2>/dev/null || true
  chmod 600 "${job_dir}/log" 2>/dev/null || true

  # identity meta (supervisor pid/token, cwd, owner)。
  local cwd owner sup_token cwd_sha
  cwd="$(pwd)"
  owner="$(id -u 2>/dev/null || echo 0)"
  sup_token="$(proc_identity "$bg_pid")"
  cwd_sha="$(printf '%s' "$cwd" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } 2>/dev/null | cut -d' ' -f1)"
  local meta_json
  meta_json=$(printf '{"schema_version":1,"job_id":"%s","role":"%s","cmd":"%s","cwd":"%s","cwd_sha256":"%s","owner_uid":%s,"supervisor_pid":%d,"supervisor_start_token":"%s","created_at":"%s"}\n' \
    "$(json_escape "$job_id")" "$(json_escape "$role")" "$(json_escape "$cmd_line")" \
    "$(json_escape "$cwd")" "$(json_escape "$cwd_sha")" "$owner" "$bg_pid" \
    "$(json_escape "$sup_token")" "$(json_escape "$started_at")")
  atomic_write "${job_dir}/meta.json" "$meta_json"
  chmod 600 "${job_dir}/meta.json" 2>/dev/null || true

  # 即時 started レシート (durable, 二段階レシートの第一段)。
  local started_receipt
  started_receipt=$(printf '{"schema_version":1,"event":"started","job_id":"%s","role":"%s","supervisor_pid":%d,"started_at":"%s","cwd":"%s"}\n' \
    "$(json_escape "$job_id")" "$(json_escape "$role")" "$bg_pid" \
    "$(json_escape "$started_at")" "$(json_escape "$cwd")")
  atomic_write "${job_dir}/receipt.started.json" "$started_receipt"
  chmod 600 "${job_dir}/receipt.started.json" 2>/dev/null || true

  write_status "$job_dir" "running" "$role" "$bg_pid" "$started_at" "" ""

  printf '%s\n' "$job_id"
  return $EX_OK
}

cmd_status() {
  local job_id="${1:-}"
  if [[ -z "$job_id" ]]; then
    log_err "status requires a job-id"
    return $EX_USAGE
  fi
  local job_dir
  job_dir=$(resolve_job_dir "$job_id") || return $?
  if [[ ! -d "$job_dir" ]]; then
    log_err "job not found: ${job_id}"
    return 1
  fi
  refresh_status "$job_dir" || true
  cat "${job_dir}/status.json"
  return $EX_OK
}

cmd_wait() {
  local job_id=""
  local timeout=$DEFAULT_WAIT_TIMEOUT
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)
        timeout="${2:?--timeout requires a value}"
        shift 2
        ;;
      -h|--help)
        usage; return 0
        ;;
      -*)
        log_err "unknown option: $1"; return $EX_USAGE
        ;;
      *)
        if [[ -z "$job_id" ]]; then
          job_id="$1"
        else
          log_err "unexpected arg: $1"; return $EX_USAGE
        fi
        shift
        ;;
    esac
  done
  if [[ -z "$job_id" ]]; then
    log_err "wait requires a job-id"; return $EX_USAGE
  fi
  if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
    log_err "invalid --timeout value: ${timeout} (must be non-negative integer seconds)"
    return $EX_USAGE
  fi
  local job_dir
  job_dir=$(resolve_job_dir "$job_id") || return $?
  if [[ ! -d "$job_dir" ]]; then
    log_err "job not found: ${job_id}"; return 1
  fi

  local elapsed=0
  while :; do
    if [[ -f "${job_dir}/exit_code" ]]; then
      refresh_status "$job_dir" || true
      cat "${job_dir}/status.json"
      local ec
      ec=$(json_get "${job_dir}/status.json" exit_code)
      [[ "$ec" =~ ^[0-9]+$ ]] || ec=1
      return "$ec"
    fi
    if [[ "$elapsed" -ge "$timeout" ]]; then
      break
    fi
    local remaining=$((timeout - elapsed))
    local sleep_for=$POLL_INTERVAL
    if [[ "$remaining" -lt "$sleep_for" ]]; then
      sleep_for=$remaining
    fi
    if [[ "$sleep_for" -le 0 ]]; then
      break
    fi
    sleep "$sleep_for"
    elapsed=$((elapsed + sleep_for))
  done

  if [[ -f "${job_dir}/exit_code" ]]; then
    refresh_status "$job_dir" || true
    cat "${job_dir}/status.json"
    local ec
    ec=$(json_get "${job_dir}/status.json" exit_code)
    [[ "$ec" =~ ^[0-9]+$ ]] || ec=1
    return "$ec"
  fi

  refresh_status "$job_dir" || true
  if [[ -f "${job_dir}/exit_code" ]]; then
    cat "${job_dir}/status.json"
    local ec
    ec=$(json_get "${job_dir}/status.json" exit_code)
    [[ "$ec" =~ ^[0-9]+$ ]] || ec=1
    return "$ec"
  fi

  local state status_ec
  state=$(json_get "${job_dir}/status.json" state)
  if [[ "$state" != "running" ]]; then
    cat "${job_dir}/status.json"
    status_ec=$(json_get "${job_dir}/status.json" exit_code)
    if [[ "$status_ec" =~ ^[0-9]+$ ]]; then
      return "$status_ec"
    fi
    return 1
  fi

  cat "${job_dir}/status.json"
  return $EX_TIMEOUT
}

cmd_result() {
  local job_id=""
  local field=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --field)
        field="${2:?--field requires a value}"
        shift 2
        ;;
      -h|--help)
        usage; return 0
        ;;
      -*)
        log_err "unknown option: $1"; return $EX_USAGE
        ;;
      *)
        if [[ -z "$job_id" ]]; then
          job_id="$1"
        else
          log_err "unexpected arg: $1"; return $EX_USAGE
        fi
        shift
        ;;
    esac
  done
  if [[ -z "$job_id" ]]; then
    log_err "result requires a job-id"; return $EX_USAGE
  fi
  local job_dir
  job_dir=$(resolve_job_dir "$job_id") || return $?
  if [[ ! -d "$job_dir" ]]; then
    log_err "job not found: ${job_id}"; return 1
  fi
  refresh_status "$job_dir" || true
  if [[ ! -f "${job_dir}/exit_code" ]]; then
    log_err "job not completed: ${job_id}"
    return 1
  fi
  if [[ -z "$field" ]]; then
    cat "${job_dir}/status.json"
    return $EX_OK
  fi
  local val
  val=$(json_get "${job_dir}/status.json" "$field")
  if [[ -z "$val" ]]; then
    log_err "field not found: ${field}"
    return 1
  fi
  printf '%s\n' "$val"
  return $EX_OK
}

# ジョブが終端 (完了/失敗/検証失敗) かどうか。0=terminal 1=active/unresolved。
job_is_terminal() {
  local job_dir="$1"
  [[ -f "${job_dir}/exit_code" ]]
}

cmd_gc() {
  local ttl_days=$DEFAULT_GC_TTL_DAYS
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ttl)
        ttl_days="${2:?--ttl requires a value}"
        shift 2
        ;;
      -h|--help)
        usage; return 0
        ;;
      *)
        log_err "unknown arg: $1"; return $EX_USAGE
        ;;
    esac
  done

  if [[ ! "$ttl_days" =~ ^[0-9]+$ ]]; then
    log_err "invalid --ttl value: ${ttl_days} (must be non-negative integer days)"
    return $EX_USAGE
  fi
  if [[ "$ttl_days" -gt "$GC_TTL_MAX_DAYS" ]]; then
    log_err "--ttl ${ttl_days} exceeds max ${GC_TTL_MAX_DAYS} days"
    return $EX_USAGE
  fi

  if [[ ! -d "$JOBS_DIR" ]]; then
    printf 'deleted=0 failed=0\n'
    return $EX_OK
  fi

  local ttl_secs
  ttl_secs=$((ttl_days * 86400))
  local now
  now=$(date -u +%s)
  local cutoff=$((now - ttl_secs))

  local deleted=0
  local failed=0
  local skipped=0
  local d
  for d in "$JOBS_DIR"/*; do
    [[ -d "$d" ]] || continue
    if [[ ! -f "${d}/status.json" ]]; then
      continue
    fi
    refresh_status "$d" || true

    # active/未解決の run は絶対に削除しない (fail-closed retention)。
    if ! job_is_terminal "$d"; then
      skipped=$((skipped + 1))
      continue
    fi
    if child_running "$d"; then
      skipped=$((skipped + 1))
      continue
    fi

    local ended_at ended_secs
    ended_at=$(json_get "${d}/status.json" ended_at)
    if [[ -z "$ended_at" || "$ended_at" == "null" ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    if ended_secs=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ended_at" +%s 2>/dev/null); then
      :
    elif ended_secs=$(date -u -d "$ended_at" +%s 2>/dev/null); then
      :
    else
      continue
    fi
    if [[ "$ended_secs" -le "$cutoff" ]]; then
      local jid
      jid=$(basename "$d")
      if /bin/rm -rf "$d"; then
        # protected 複製も同時に掃除 (空展開ガードで / 誤削除を防止)。
        if [[ -n "$jid" ]]; then
          /bin/rm -rf "${PROTECTED_DIR:?}/${jid:?}" 2>/dev/null || true
        fi
        deleted=$((deleted + 1))
      else
        failed=$((failed + 1))
        printf '[gc] WARN: failed to remove %s\n' "$d" >&2
      fi
    fi
  done

  printf 'deleted=%d failed=%d\n' "$deleted" "$failed"
  return $EX_OK
}

# cwd-scoped runs report。global-latest 探索は不可 (必ず cwd に束縛)。
cmd_runs_report() {
  local cwd_arg=""
  local latest=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cwd) cwd_arg="${2:?--cwd requires a value}"; shift 2 ;;
      --latest) latest=true; shift ;;
      -h|--help) usage; return 0 ;;
      *) log_err "unknown arg: $1"; return $EX_USAGE ;;
    esac
  done
  [[ -n "$cwd_arg" ]] || cwd_arg="$(pwd)"
  local want_sha
  want_sha="$(printf '%s' "$cwd_arg" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } 2>/dev/null | cut -d' ' -f1)"

  if [[ ! -d "$JOBS_DIR" ]]; then
    return $EX_OK
  fi

  local best_dir="" best_created=""
  local d
  for d in "$JOBS_DIR"/*; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}/meta.json" ]] || continue
    local jsha
    jsha=$(json_get "${d}/meta.json" cwd_sha256)
    [[ "$jsha" == "$want_sha" ]] || continue
    refresh_status "$d" || true
    if $latest; then
      local created
      created=$(json_get "${d}/meta.json" created_at)
      if [[ -z "$best_created" || "$created" > "$best_created" ]]; then
        best_created="$created"
        best_dir="$d"
      fi
    else
      local jid state ec created
      jid=$(basename "$d")
      state=$(json_get "${d}/status.json" state)
      ec=$(json_get "${d}/status.json" exit_code)
      created=$(json_get "${d}/meta.json" created_at)
      printf '{"job_id":"%s","state":"%s","exit_code":%s,"created_at":"%s","cwd":"%s"}\n' \
        "$jid" "$state" "${ec:-null}" "$created" "$(json_escape "$cwd_arg")"
    fi
  done

  if $latest && [[ -n "$best_dir" ]]; then
    local jid state ec created
    jid=$(basename "$best_dir")
    state=$(json_get "${best_dir}/status.json" state)
    ec=$(json_get "${best_dir}/status.json" exit_code)
    created=$(json_get "${best_dir}/meta.json" created_at)
    printf '{"job_id":"%s","state":"%s","exit_code":%s,"created_at":"%s","cwd":"%s"}\n' \
      "$jid" "$state" "${ec:-null}" "$created" "$(json_escape "$cwd_arg")"
  fi
  return $EX_OK
}

# アクティブ/未解決の run に紐づく生存 child を read-only で列挙する。
cmd_processes_report() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      *) log_err "unknown arg: $1"; return $EX_USAGE ;;
    esac
  done
  [[ -d "$JOBS_DIR" ]] || return $EX_OK
  local d
  for d in "$JOBS_DIR"/*; do
    [[ -d "$d" ]] || continue
    refresh_status "$d" || true
    # terminal に達したものは報告しない。
    if job_is_terminal "$d"; then
      continue
    fi
    [[ -f "${d}/child.json" ]] || continue
    local jid cpid cpgid owned
    jid=$(basename "$d")
    cpid=$(json_get "${d}/child.json" child_pid)
    cpgid=$(json_get "${d}/child.json" child_pgid)
    if child_running "$d"; then owned="true"; else owned="false"; fi
    printf '{"job_id":"%s","child_pid":%s,"child_pgid":%s,"proven_alive":%s}\n' \
      "$jid" "${cpid:-null}" "${cpgid:-null}" "$owned"
  done
  return $EX_OK
}

cmd_stop() {
  local job_id=""
  local grace=$DEFAULT_STOP_GRACE
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --grace) grace="${2:?--grace requires a value}"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      -*) log_err "unknown option: $1"; return $EX_USAGE ;;
      *)
        if [[ -z "$job_id" ]]; then job_id="$1"; else log_err "unexpected arg: $1"; return $EX_USAGE; fi
        shift
        ;;
    esac
  done
  if [[ -z "$job_id" ]]; then
    log_err "stop requires a job-id"; return $EX_USAGE
  fi
  if [[ ! "$grace" =~ ^[0-9]+$ ]] || [[ "$grace" -gt "$STOP_GRACE_MAX" ]]; then
    log_err "invalid --grace value: ${grace} (0..${STOP_GRACE_MAX})"
    return $EX_USAGE
  fi
  local job_dir
  job_dir=$(resolve_job_dir "$job_id") || return $?
  if [[ ! -d "$job_dir" ]]; then
    log_err "job not found: ${job_id}"; return 1
  fi

  refresh_status "$job_dir" || true
  local action="already-terminal"
  if ! job_is_terminal "$job_dir"; then
    action="$(stop_child_group "$job_dir" "$grace")"
    refresh_status "$job_dir" || true
  fi
  local state ec
  state=$(json_get "${job_dir}/status.json" state)
  ec=$(json_get "${job_dir}/status.json" exit_code)
  printf '{"job_id":"%s","action":"%s","state":"%s","exit_code":%s}\n' \
    "$job_id" "$(json_escape "$action")" "$state" "${ec:-null}"
  return $EX_OK
}

# 未解決 run を掃除する。証明済みの child のみ停止し、無関係 PID は触らない。
# terminal 証跡の無い死亡 child は fail-closed で failed に確定する。
cmd_reap() {
  local grace=$DEFAULT_STOP_GRACE
  local cwd_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --grace) grace="${2:?--grace requires a value}"; shift 2 ;;
      --cwd) cwd_arg="${2:?--cwd requires a value}"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) log_err "unknown arg: $1"; return $EX_USAGE ;;
    esac
  done
  if [[ ! "$grace" =~ ^[0-9]+$ ]] || [[ "$grace" -gt "$STOP_GRACE_MAX" ]]; then
    log_err "invalid --grace value: ${grace} (0..${STOP_GRACE_MAX})"
    return $EX_USAGE
  fi
  local want_sha=""
  if [[ -n "$cwd_arg" ]]; then
    want_sha="$(printf '%s' "$cwd_arg" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } 2>/dev/null | cut -d' ' -f1)"
  fi

  [[ -d "$JOBS_DIR" ]] || { printf 'stopped=0 finalized=0 skipped=0\n'; return $EX_OK; }
  local stopped=0 finalized=0 skipped=0
  local d
  for d in "$JOBS_DIR"/*; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}/status.json" ]] || continue
    if [[ -n "$want_sha" ]]; then
      local jsha
      jsha=$(json_get "${d}/meta.json" cwd_sha256)
      [[ "$jsha" == "$want_sha" ]] || continue
    fi
    refresh_status "$d" || true
    if job_is_terminal "$d"; then
      skipped=$((skipped + 1))
      continue
    fi
    if child_running "$d"; then
      local action
      action="$(stop_child_group "$d" "$grace")"
      case "$action" in
        term-stopped*|kill-forced*) stopped=$((stopped + 1)) ;;
        *) skipped=$((skipped + 1)) ;;
      esac
      refresh_status "$d" || true
    else
      # child は死亡だが terminal 証跡なし → fail-closed で確定。
      refresh_status "$d" || true
      finalized=$((finalized + 1))
    fi
  done
  printf 'stopped=%d finalized=%d skipped=%d\n' "$stopped" "$finalized" "$skipped"
  return $EX_OK
}

usage() {
  cat <<'EOF'
codex-job.sh - Async job manager for codex-wrapper.sh

USAGE:
  codex-job.sh <subcommand> [options]

SUBCOMMANDS:
  start [--role <role>] [--keep-prompt] [<prompt>]
      Launch codex-wrapper.sh in background. Prompt is read from stdin
      unless a positional <prompt> is given. Prints the new job-id on
      stdout and returns immediately. Prompt file is removed on
      completion unless --keep-prompt is given.

  status <job-id>
      Print the current status.json to stdout.

  wait <job-id> [--timeout <sec>]
      Block until the job completes or <sec> elapses (default 900s).
      --timeout 0 returns immediately: the job's own exit code if
      already completed, or 124 if still running. Returns the job's own
      exit code, or 124 on timeout.

  result <job-id> [--field <name>]
      Print status.json (or a single field's value) for a completed
      job. Fails if the job is still running.

  gc [--ttl <days>]
      Delete terminal job directories whose ended_at is older than
      <days> (default 7, max 365). Active/unresolved runs are never
      deleted. Prints "deleted=N failed=M" on stdout.

  runs-report [--cwd <path>] [--latest]
      List durable run records bound to the resolved cwd (default: the
      current directory). --latest prints only the newest record.
      Global-latest discovery is intentionally unsupported.

  processes-report
      Read-only list of unresolved runs whose child process group is
      still proven-alive (identity/start-token verified). Empty once all
      jobs reach a terminal receipt.

  stop <job-id> [--grace <sec>]
      PGID-aware TERM -> grace -> KILL of a job's proven child process
      group. Refuses to signal on start-token mismatch (PID reuse) or on
      the caller's own process group. Default grace 5s (max 120).

  reap [--grace <sec>] [--cwd <path>]
      Sweep unresolved runs: stop proven-alive children and fail-close
      finalize dead children that never produced a trusted terminal
      receipt. Never touches unrelated PIDs.

EXAMPLES:
  jid=$(echo "say hi" | scripts/codex-job.sh start --role reviewer)
  scripts/codex-job.sh status "$jid"
  scripts/codex-job.sh wait "$jid" --timeout 60
  scripts/codex-job.sh result "$jid" --field exit_code
  scripts/codex-job.sh runs-report --cwd "$PWD" --latest
  scripts/codex-job.sh processes-report
  scripts/codex-job.sh stop "$jid" --grace 5
  scripts/codex-job.sh gc --ttl 3

EXIT CODES:
   0  success
   1  generic error (e.g. job not found, not completed)
  64  invalid argument / usage error (incl. bad job-id, bad --ttl)
  70  canonical-guard refuse (vendored copy)
 124  wait timeout
EOF
}

# ---- dispatcher -------------------------------------------------------------

main() {
  if [[ $# -lt 1 ]]; then
    usage
    return $EX_USAGE
  fi
  local sub="$1"
  shift
  case "$sub" in
    start)            cmd_start  "$@" ;;
    status)           cmd_status "$@" ;;
    wait)             cmd_wait   "$@" ;;
    result)           cmd_result "$@" ;;
    gc)               cmd_gc     "$@" ;;
    runs-report)      cmd_runs_report "$@" ;;
    processes-report) cmd_processes_report "$@" ;;
    stop)             cmd_stop   "$@" ;;
    reap)             cmd_reap   "$@" ;;
    -h|--help|help)   usage ;;
    *)
      log_err "unknown subcommand: ${sub}"
      usage >&2
      return $EX_USAGE
      ;;
  esac
}

main "$@"
