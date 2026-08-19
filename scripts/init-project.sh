#!/bin/bash
# ==============================================================================
# init-project.sh - プロジェクト初期化スクリプト
# ==============================================================================
# 用途: rev_harnessを新しいプロジェクトにクローンした後、
#       プロジェクト固有の設定を初期化する
#
# 使用法:
#   ./scripts/init-project.sh [project_name]
#
# 実行内容:
#   1. 必要なディレクトリ構造の作成
#   2. repo-local immutable project_id artifact の生成
#   3. テンプレートファイルの生成
#   4. .gitignoreの更新
#   5. 初期化完了メッセージの表示
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
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ログ関数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

write_literal_file() {
    local path="$1"
    shift

    printf '%s\n' "$@" > "$path" || {
        log_error "Failed to write file: $path"
        exit 1
    }
}

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ID_TOOL="${SCRIPT_DIR}/project-id.sh"

usage() {
    cat >&2 <<'USAGE'
usage: scripts/init-project.sh [project_name] [--self-test --target <dir>]
USAGE
}

SELF_TEST=0
TARGET_DIR=""
PROJECT_NAME_ARG=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --self-test)
            SELF_TEST=1
            shift
            ;;
        --target)
            if [[ "$#" -lt 2 ]]; then
                log_error "--target requires a value"
                exit 2
            fi
            TARGET_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            log_error "Unknown option: $1"
            usage
            exit 2
            ;;
        *)
            if [[ -n "$PROJECT_NAME_ARG" ]]; then
                log_error "Only one project name may be specified"
                usage
                exit 2
            fi
            PROJECT_NAME_ARG="$1"
            shift
            ;;
    esac
done

if [[ "$SELF_TEST" == "1" && -z "$TARGET_DIR" ]]; then
    log_error "--self-test requires --target <dir>"
    exit 2
fi

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
if [[ -n "$TARGET_DIR" ]]; then
    mkdir -p "$TARGET_DIR" || {
        log_error "Cannot create target directory: $TARGET_DIR"
        exit 1
    }
    PROJECT_ROOT="$(cd "$TARGET_DIR" && pwd -P)"
fi

# プロジェクト名を取得（引数または現在のディレクトリ名）
PROJECT_NAME="${PROJECT_NAME_ARG:-$(basename "$PROJECT_ROOT")}"

# プロジェクト名の入力検証（コマンドインジェクション防止）
if [[ ! "$PROJECT_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    log_error "Invalid project name: $PROJECT_NAME"
    log_error "Must start with a letter and contain only letters, digits, hyphens, or underscores"
    exit 1
fi

# ==============================================================================
# ディレクトリ作成
# ==============================================================================
create_directories() {
    log_info "Creating directory structure..."

    local dirs=(
        ".agent/active/sow"
        ".agent/active/prompts"
        ".agent/archive/plans"
        ".agent/archive/sow"
        ".agent/archive/prompts"
        ".agent/archive/feedback"
        ".agent/archive/test"
        ".agent/archive/docs"
        ".claude/tmp"
        "docs/requirements"
        "docs/design"
        "docs/manual"
        "src"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "${PROJECT_ROOT}/${dir}"
        # .gitkeepを追加（空ディレクトリをgitに追跡させる）
        touch "${PROJECT_ROOT}/${dir}/.gitkeep"
    done

    log_success "Directory structure created"
}

# ==============================================================================
# repo-local immutable project_id artifact
# ==============================================================================
bootstrap_project_id() {
    local resolve_artifact_path="${1:-1}"
    if [[ ! -x "$PROJECT_ID_TOOL" ]]; then
        log_error "project_id helper not found or not executable: $PROJECT_ID_TOOL"
        exit 1
    fi

    log_info "Initializing repo-local project_id artifact..."

    local project_id=""
    project_id="$(PROJECT_ID_REPO_ROOT="$PROJECT_ROOT" bash "$PROJECT_ID_TOOL" bootstrap "$PROJECT_NAME")" || {
        log_error "Failed to generate project_id artifact"
        exit 1
    }

    if [[ "$resolve_artifact_path" != "1" ]]; then
        log_success "project_id artifact ready: ${project_id}"
        return 0
    fi

    local artifact_path=""
    artifact_path="$(PROJECT_ID_REPO_ROOT="$PROJECT_ROOT" bash "$PROJECT_ID_TOOL" artifact-path)" || {
        log_error "Failed to resolve project_id artifact path"
        exit 1
    }

    log_success "project_id artifact ready: ${project_id} (${artifact_path})"
}

# ==============================================================================
# 要件定義テンプレート生成
# ==============================================================================
create_requirements_template() {
    local target="${PROJECT_ROOT}/.agent/requirements.md"

    if [[ -f "$target" ]] && [[ -s "$target" ]]; then
        log_warn "requirements.md already exists. Skipping."
        return
    fi

    log_info "Generating requirements.md template (content in Japanese, the project's default language)..."

    write_literal_file "$target" \
        '# Requirements / 要件定義書' \
        '' \
        'このファイルは、エージェント駆動開発の「入り口」です。' \
        '新しいプロジェクトや機能を開始する際、ユーザーはこのファイルに要件を記載してください。' \
        '' \
        '---' \
        '' \
        '## 使い方' \
        '' \
        '1. 以下のテンプレートを参考に、要件を記載' \
        '2. エージェントが `.agent/active/plan_YYYYMMDD_*.md` にExecPlanを生成' \
        '3. 開発完了後、プランは自動的に `archive/plans/` へ移動' \
        '' \
        '---' \
        '' \
        '## テンプレート' \
        '' \
        '### プロジェクト名' \
        '(例: My Awesome Project)' \
        '' \
        '### ゴール' \
        '(例: ユーザーがログインして売上データを確認できるダッシュボードを作成する)' \
        '' \
        '### 機能要件' \
        '1. (例: ユーザー認証機能)' \
        '2. (例: データ可視化ダッシュボード)' \
        '3. ...' \
        '' \
        '### 非機能要件' \
        '- (例: レスポンス時間 500ms以内)' \
        '- (例: 99.9%の可用性)' \
        '' \
        '### 技術スタック' \
        '- Language: (例: TypeScript)' \
        '- Framework: (例: Next.js 14)' \
        '- DB: (例: PostgreSQL)' \
        '- ...' \
        '' \
        '### 制約事項' \
        '- (例: 既存のAPI仕様との互換性維持)' \
        '- (例: モバイルファースト設計)' \
        '' \
        '### 成功条件' \
        '- (例: 全テストケース通過)' \
        '- (例: パフォーマンス基準達成)' \
        '' \
        '---' \
        '' \
        '## 現在の要件' \
        '' \
        '<!-- ここにユーザーの要件を記載 -->' \
        '' \
        '(まだ要件が記載されていません。上記テンプレートを参考に要件を追加してください。)'

    log_success "requirements.md generated"
}

# ==============================================================================
# プロジェクトコンテキスト生成
# ==============================================================================
create_project_context() {
    local target="${PROJECT_ROOT}/.agent/PROJECT_CONTEXT.md"

    if [[ -f "$target" ]] && [[ -s "$target" ]]; then
        log_warn "PROJECT_CONTEXT.md already exists. Skipping."
        return
    fi

    log_info "Generating PROJECT_CONTEXT.md (content in Japanese, the project's default language)..."

    write_literal_file "$target" \
        '# Project Context / プロジェクトコンテキスト' \
        '' \
        'このファイルは、プロジェクト固有の情報をエージェントに伝えるためのコンテキストファイルです。' \
        '`.agent_rules/RULES.md` の汎用ルールを補完し、本プロジェクト固有の設定を定義します。' \
        '' \
        '---' \
        '' \
        '## プロジェクト概要' \
        '' \
        "**${PROJECT_NAME}**" \
        '' \
        '<!-- プロジェクトの概要を記載 -->' \
        '' \
        '---' \
        '' \
        '## 技術スタック' \
        '' \
        '| カテゴリ | 技術 | バージョン/備考 |' \
        '|---------|------|----------------|' \
        '| 言語 | <!-- 例: TypeScript --> | <!-- 例: 5.0+ --> |' \
        '| フレームワーク | <!-- 例: Next.js --> | <!-- 例: 14 --> |' \
        '| DB | <!-- 例: PostgreSQL --> | <!-- 例: 15 --> |' \
        '| CLI | Claude Code CLI | Anthropic |' \
        '| CLI | Codex CLI | OpenAI |' \
        '' \
        '---' \
        '' \
        '## ディレクトリ構造' \
        '' \
        '```' \
        "${PROJECT_NAME}/" \
        '├── .agent/                  # エージェント駆動開発の中核' \
        '│   ├── requirements.md      # 要件定義書' \
        '│   ├── PROJECT_CONTEXT.md   # このファイル' \
        '│   ├── active/              # 現在進行中のタスク' \
        '│   └── archive/             # 完了した作業' \
        '│' \
        '├── .agent_rules/            # 汎用ルール' \
        '├── .claude/                 # Claude CLI設定' \
        '├── .codex/                  # Codex CLI設定' \
        '├── docs/                    # プロジェクトドキュメント' \
        '├── scripts/                 # ビルド・ユーティリティ' \
        '├── src/                     # Product Code（製品コード + 同居する製品テスト）' \
        '├── test/                    # harness 所有（test/unit + test/integration）' \
        '└── ...' \
        '```' \
        '' \
        '### コード配置ルール（harness↔product 境界）' \
        '' \
        '| レイヤ | ディレクトリ | 用途 |' \
        '|--------|-------------|------|' \
        '| Product Code | `src/**`（または `apps/`/`packages/`/`services/`/`crates/`） | 製品コードを置く canonical workspace |' \
        '| Product Test | `src/**` 同居（`*.test.*`/`*.spec.*`/`__tests__`）または `test/product/**` | 製品テスト（preserve-only / sync で上書きされない） |' \
        '| Harness | `test/unit/`・`test/integration/` | harness 自己テスト（managed / sync で上書きされる）。製品テストを置かない |' \
        '' \
        '---' \
        '' \
        '## 開発ワークフロー' \
        '' \
        '### 1. 要件定義' \
        '```bash' \
        '# ユーザーが .agent/requirements.md に要件を記載' \
        '```' \
        '' \
        '### 2. プラン生成' \
        '```bash' \
        '# エージェントが .agent/active/plan_YYYYMMDD_*.md を生成' \
        '```' \
        '' \
        '### 3. 実装（Coder）' \
        '```bash' \
        './.claude/commands/auto_orchestrate.sh \' \
        '  --plan .agent/active/plan_*.md \' \
        '  --phase impl \' \
        '  --run-coder' \
        '```' \
        '' \
        '### 4. レビュー（Reviewer）' \
        '```bash' \
        '# auto_orchestrate.sh が自動でCodexレビューを実行' \
        '```' \
        '' \
        '---' \
        '' \
        '## テスト実行' \
        '' \
        '```bash' \
        '# テストコマンドを記載' \
        '# 例: npm test' \
        '```' \
        '' \
        '---' \
        '' \
        '## コミット規約' \
        '' \
        '```' \
        '<type>: <subject>' \
        '' \
        'Types:' \
        '- feat: 新機能' \
        '- fix: バグ修正' \
        '- docs: ドキュメント' \
        '- refactor: リファクタリング' \
        '- test: テスト追加/修正' \
        '- chore: 雑務' \
        '```' \
        '' \
        '---' \
        '' \
        '## 注意事項' \
        '' \
        '1. **mainブランチ直接編集禁止**: 必ずWorktreeを使用' \
        '2. **Codex呼び出し**: `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>` を使う（Reviewer は `--role reviewer` 固定、legacy shim は互換用）' \
        '3. **Claude effort 既定値**: `medium`。caller-facing effort は `low|medium|high|xhigh` のみ許可し、`max` は使わない' \
        '4. **Wrapper ガード**: Codex wrapper は `--cd` / `--add-dir` を警告して strip し、shim 固定 role に対する role escape は fail-closed で拒否する' \
        '5. **セッション継続**: API課金なしでコンテキスト保持可能' \
        '6. **Session helper の入口**: Claude 実行は canonical `scripts/claude-wrapper.sh` を使い、`CLAUDE_WRAPPER` は caller 制御の escape hatch として扱わず canonical path 以外なら fail-closed で拒否する'

    log_success "PROJECT_CONTEXT.md generated"
}

# ==============================================================================
# .gitignore更新
# ==============================================================================
update_gitignore() {
    local gitignore="${PROJECT_ROOT}/.gitignore"

    log_info "Checking .gitignore..."

    local entries=(
        ".claude/tmp/"
        "workspace/"
        "*.log"
        ".DS_Store"
        ".rev_harness/"
        "semantic.db"
        "semantic.db-wal"
        "semantic.db-shm"
        ".migration.lock"
    )

    for entry in "${entries[@]}"; do
        if ! grep -qF "$entry" "$gitignore" 2>/dev/null; then
            echo "$entry" >> "$gitignore"
            log_info "  added: $entry"
        fi
    done

    log_success ".gitignore updated"
}

# ==============================================================================
# docs/requirements テンプレート
# ==============================================================================
create_docs_template() {
    local target="${PROJECT_ROOT}/docs/requirements/README.md"

    if [[ -f "$target" ]]; then
        log_warn "docs/requirements/README.md already exists. Skipping."
        return
    fi

    log_info "Generating docs/requirements template (content in Japanese, the project's default language)..."

    write_literal_file "$target" \
        '# Requirements Documentation' \
        '' \
        'このディレクトリには、プロジェクトの要件定義ドキュメントを配置します。' \
        '' \
        '## ファイル構成' \
        '' \
        '- `features.md` - 機能要件' \
        '- `constraints.md` - 制約条件' \
        '- `api-spec.md` - API仕様' \
        '' \
        '## 関連ファイル' \
        '' \
        '- `.agent/requirements.md` - エージェント駆動開発の入り口' \
        '- `.agent/PROJECT_CONTEXT.md` - プロジェクト固有コンテキスト'

    log_success "docs/requirements template generated"
}

# ==============================================================================
# メイン処理
# ==============================================================================
main() {
    # NOTE: the "adopter" positional argument documented in
    # docs/manual/rev-harness-lifecycle.md is consumed above as
    # PROJECT_NAME_ARG (see the option-parsing loop near the top of this
    # file), so it never reaches main() as "$1" -- do not try to read the
    # invocation mode from a positional argument here. Instead,
    # scripts/rev-harness-adopter-setup.sh sets
    # REVHARNESS_INIT_PHASE_OF_SETUP=1 when it runs this script as the
    # "init" phase of `scripts/rev-harness install`; that is the only
    # reliable signal that the remaining phases (hooks, doctor) are about
    # to run automatically in the same invocation.
    local invoked_by_setup="${REVHARNESS_INIT_PHASE_OF_SETUP:-0}"

    echo ""
    echo "=============================================="
    echo "  Revharness Project Initialization"
    echo "=============================================="
    echo "  Project: ${PROJECT_NAME}"
    echo "  Root: ${PROJECT_ROOT}"
    echo "=============================================="
    echo ""

    if [[ "$SELF_TEST" == "1" ]]; then
        bootstrap_project_id 0
        create_directories
        return 0
    fi

    bootstrap_project_id
    create_directories
    create_requirements_template
    create_project_context
    update_gitignore
    create_docs_template

    echo ""
    echo "=============================================="
    log_success "Initialization complete"
    echo "=============================================="
    echo ""
    if [[ "$invoked_by_setup" == "1" ]]; then
        # Invoked as the "init" phase inside scripts/rev-harness-adopter-setup.sh.
        # The remaining phases (hooks, doctor) run automatically as part of the
        # same `scripts/rev-harness install` invocation the caller already
        # started, so do not tell the user to re-run install here.
        echo "Next steps:"
        echo "  1. Fill in your requirements in .agent/requirements.md (template is in Japanese; edit or replace freely)"
        echo "  2. Edit .agent/PROJECT_CONTEXT.md (template is in Japanese; edit or replace freely)"
        echo "  3. Wait for the remaining hooks / doctor setup to finish (runs automatically)"
        echo ""
    else
        echo "Next steps:"
        echo "  1. Fill in your requirements in .agent/requirements.md (template is in Japanese; edit or replace freely)"
        echo "  2. Edit .agent/PROJECT_CONTEXT.md (template is in Japanese; edit or replace freely)"
        echo "  3. Complete setup with: bash scripts/rev-harness install --target ${PROJECT_ROOT}"
        echo ""
    fi
}

main "$@"
