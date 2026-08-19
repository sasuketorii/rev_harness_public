#!/bin/bash
# ==============================================================================
# bootstrap.sh - DEPRECATED thin delegate to the canonical entry point
# ==============================================================================
# This script used to be an independent, parallel setup path that called
# scripts/init-project.sh directly and duplicated checks that
# scripts/harness-doctor.sh already performs (CLI presence, model-policy
# freshness, .claude/settings.json hooks). RevHarness has a single canonical
# entry point: `bash scripts/rev-harness install` (see
# docs/manual/rev-harness-lifecycle.md and docs/manual/end-user-guide.md).
#
# This file is kept for backward compatibility with anyone who still invokes
# it directly. It now only translates its historical flags into the
# equivalent scripts/rev-harness subcommand and delegates:
#
#   ./setup/bootstrap.sh                 -> bash scripts/rev-harness install
#   ./setup/bootstrap.sh --check-only    -> bash scripts/rev-harness verify
#
# It does not run any setup logic of its own anymore.
#
# 使用法:
#   ./setup/bootstrap.sh [--check-only] [--skip-interactive]
#
# オプション:
#   --check-only       変更を行わず、canonical entry の verify (doctor --quick)
#                       に委譲する
#   --skip-interactive 後方互換のために受理されるが、no-op（元々このスクリプト
#                       は対話的入力を要求していなかった）
# ==============================================================================

set -euo pipefail

# --- bash-version gate (macOS ships bash 3.2; this codebase requires bash >= 4 for
#     associative-array support used deeper in the install/doctor chain). Fail fast
#     with a clear message instead of a cryptic "declare: -A: invalid option" later. ---
if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  printf 'ERROR: this script requires bash >= 4.0 (detected: %s).\n' "${BASH_VERSION:-unknown}" >&2
  printf 'macOS ships bash 3.2 by default (/bin/bash). Install a newer bash, e.g.:\n' >&2
  printf '  brew install bash\n' >&2
  printf 'Then re-run this command with the new bash explicitly, e.g.:\n' >&2
  printf '  %s/bin/bash %s ...\n' "$(brew --prefix bash 2>/dev/null || printf '/opt/homebrew')" "$0" >&2
  exit 1
fi

# カラー定義
readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1" >&2; }

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REV_HARNESS_FACADE="${PROJECT_ROOT}/scripts/rev-harness"

# オプション
CHECK_ONLY=false
SKIP_INTERACTIVE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        --skip-interactive)
            SKIP_INTERACTIVE=true
            shift
            ;;
        *)
            log_error "不明なオプション: $1"
            exit 1
            ;;
    esac
done

if [[ "$SKIP_INTERACTIVE" == "true" ]]; then
    log_warn "--skip-interactive は後方互換のために受理されていますが no-op です（このスクリプトは対話的入力を要求しません）"
fi

log_warn "setup/bootstrap.sh は非推奨です。正規の入口は 'bash scripts/rev-harness install' です。"
log_warn "詳細: docs/manual/rev-harness-lifecycle.md / docs/manual/end-user-guide.md"

if [[ ! -x "$REV_HARNESS_FACADE" ]]; then
    log_error "canonical entry point が見つかりません: $REV_HARNESS_FACADE"
    exit 1
fi

if [[ "$CHECK_ONLY" == "true" ]]; then
    log_step "委譲先: bash scripts/rev-harness verify"
    exec bash "$REV_HARNESS_FACADE" verify
fi

log_step "委譲先: bash scripts/rev-harness install"
exec bash "$REV_HARNESS_FACADE" install
