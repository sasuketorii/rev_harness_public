# Project Context / プロジェクトコンテキスト

このファイルは、プロジェクト固有の情報をエージェントに伝えるためのコンテキストファイルです。
`.agent_rules/RULES.md` の汎用ルールを補完し、本プロジェクト固有の設定を定義します。

---

## プロジェクト概要

**Revharness** は、Claude（Coder）と Codex（Reviewer）が人間の介入なしに自律的に協調し、
コード品質を担保するマルチベンダーAI協調開発基盤です。canonical display name は `Revharness`、canonical machine name は `rev_harness` です。

Revharness の上位 identity は、世界最高峰の orchestration harness として、速度、精度、低メモリ/低CPU/低トークン負荷、潜在バグの少なさ、拡張性/保守性/アップデート容易性を同時に満たすことです。モデル進化により prompt が短くなる場合でも、この identity は durable docs、machine-checkable contracts、deterministic checks、fail-closed guard に移して保持します。

User-facing communication from the orchestrator is Japanese by default. Worker-to-worker communication, handoff prompts, reviewer prompts, internal artifacts, and cross-agent coordination packets are English by default to reduce token/context footprint and keep provider-to-provider exchanges compact.

---

## Canonical Operating Model

Revharness は「その中で開発するプロジェクトテンプレート」ではありません。既に対象リポジトリを持っている（または空の新規リポジトリを持っている）状態で、そこへ harness を **install する** ツールです。`docs/getting-started/installation.md` が唯一の正本手順です:

```bash
git clone https://github.com/sasuketorii/rev_harness_public.git
cd rev_harness_public
bash scripts/rev-harness install --target /path/to/your/project
```

harness 自身のチェックアウトへの self-install（`--target` を指定しない、または `--target .` を harness チェックアウト自身に対して実行する）は `scripts/_canonical-guard.sh` の canonical root guard により **exit code 72 で拒否されます**。この `.agent/PROJECT_CONTEXT.md` は、install 後に **adopter 側のリポジトリ** に置かれる `.agent/PROJECT_CONTEXT.md` のひな形であり、harness リポジトリ自身の中で読者が開発することを想定した文書ではありません。

install 後の adopter リポジトリでは、運用境界を次の 3 層で整理します。

| Layer | 役割 | 代表パス |
|------|------|---------|
| `Framework / Core Harness` | wrapper、commands、policy docs、CI gate、integration surface | `AGENTS.md`, `.agent_rules/`, `.claude/`, `.codex/`, `docs/`, `scripts/`, `test/integration/` |
| `Project State` | project-local context、active plan / SOW / prompt、archive、evidence pointer | `.agent/**` |
| `Product Code` | 実際の app / service / library codebase | greenfield（空リポジトリへの install）では `src/` がプレースホルダとして用意されます。既存 adopted project は compatibility / overlay path として `apps/`, `packages/`, `services/` などを維持可 |

greenfield install の default workspace は `src/` です。adopted / existing projects は explicit compatibility / overlay path として native layout を維持でき、`src/` への rehousing を強制しません。`src/` はあくまで **adopter 側リポジトリに作られるプロダクトコード置き場のプレースホルダ**であり、harness リポジトリ自身の `src/` で開発する話ではありません。

---

## 技術スタック

| カテゴリ | 技術 | バージョン/備考 |
|---------|------|----------------|
| 言語 | Bash (Shell Script) | POSIX互換 |
| CLI | Claude Code CLI | Anthropic |
| CLI | Codex CLI | OpenAI |
| JSON処理 | jq | 必須依存 |
| バージョン管理 | Git | Worktree対応 |
| Rust支援 | Rust / RustSkills | backend / runtime / control-plane / lease registry / artifact index / process supervisor / validation runner / semantic index で合理的な箇所は Rust-first。RustSkills の知見パックは `.claude/skills/rust-skills-knowledge-pack/`、`.agents/skills/rust-skills-knowledge-pack/` に配置済み。既存 shell / Node compatibility surface の全面移行を意味しない |

---

## 採用モデル

**Revharness は greenfield install で `src/` を product workspace の既定プレースホルダとして採用します。**

greenfield(空 or 新規の対象リポジトリ)では、harness を clone した側から `install --target` を実行すると、対象リポジトリ側に `src/` が用意されます。

既存 project では product code を強制的に `src/` へ移設せず、compatibility / overlay path として project-native layout のまま harness layer を重ねる前提を明示できます。

```bash
# adopter 側の bootstrap 例。harness を clone し、別リポジトリ (my_project) へ install する。
git clone https://github.com/sasuketorii/rev_harness_public.git
cd rev_harness_public
bash scripts/rev-harness install --target /path/to/my_project
```

harness チェックアウト自身への self-install は exit code 72 で拒否されます。手順の詳細は `docs/getting-started/installation.md` を正本としてください。

---

## ディレクトリ構造

`my_project/` は harness チェックアウトとは別の、install 先の adopter リポジトリです（harness チェックアウト自身の中にこの構造ができるわけではありません）。

```
my_project/                  # install --target で harness を受け入れた別リポジトリ
│
├── src/                     # ← greenfield install の canonical Product Code workspace
├── apps/                    #    既存 adopted project の compatibility / overlay 例
├── packages/                #    既存 adopted project の compatibility / overlay 例
├── services/                #    既存 adopted project の compatibility / overlay 例
│
├── test/                    # テストコード
│
├── .agent/                  # エージェント駆動開発の中核
│   ├── requirements.md      # 要件定義書（ユーザー投下）
│   ├── PROJECT_CONTEXT.md   # このファイル
│   ├── active/              # 現在進行中のタスク
│   │   ├── plan_YYYYMMDD_HHMM_<task>.md  # ExecPlan
│   │   ├── sow/             # セッション別SOW
│   │   └── prompts/         # ハンドオーバー/レビュー用
│   └── archive/             # 完了した作業
│
├── .agent_rules/            # 汎用ルール（全エージェント共通）
│   └── RULES.md
│
├── .claude/                 # Claude CLI設定
│   ├── commands/            # CLIコマンド
│   ├── hooks/               # PostToolUseフック
│   ├── skills/              # Skillプラグイン
│   └── tmp/                 # 一時ファイル
│
├── .codex/                  # Codex CLI設定
│   └── config.toml
│
├── docs/                    # プロジェクトドキュメント
│   ├── requirements/        #    要件定義書、ユーザーストーリー
│   ├── design/              #    アーキテクチャ設計、DBスキーマ、API仕様
│   ├── manual/              #    運用マニュアル、セットアップガイド
│   │   └── verification-truth-matrix.md  # acceptance / truth placement の正本
│   ├── roles/               #    役割定義（Coder/Reviewer/Orchestrator）
│   ├── prompts/             #    レビュワープロンプトテンプレート
│   └── entitlements/        #    署名・公証用設定
│
├── scripts/                 # ビルド・ユーティリティ
├── setup/                   # セットアップ
│
└── workspace/               # Hydra worktree用（.gitignore済み）
```

### 重要: コード配置ルール

| ディレクトリ | 用途 | 備考 |
|-------------|------|------|
| `src/` | **Product Code** | 新規 Revharness project の canonical default workspace |
| `apps/`, `packages/`, `services/` など | **Product Code compatibility path** | 既存 adopted project では explicit compatibility / overlay path として project-native layout を維持可 |
| `test/` | **harness 所有** | root `test/` は harness 自己テスト。`test/unit/` + `test/integration/` は managed（sync で上書き）。製品テストはここに置かない |
| 製品テスト | **Product Test** | 製品コードと同居（`src/**` の `*.test.*`/`*.spec.*`/`__tests__`）または `test/product/**`（preserve-only） |
| `workspace/` | Hydra worktree作業用 | **恒久的コード配置禁止**（.gitignore）※Hydra worktree内の作業コードは可 |

---

## 開発ワークフロー

### 1. 要件定義
```bash
# ユーザーが .agent/requirements.md に要件を記載
```

### 2. プラン生成
```bash
# system-planner skill が .agent/active/plan_YYYYMMDD_HHMM_<task>.md を生成/更新
```

### 3. 実装（Coder）
```bash
# auto-orchestrator skill は薄い router として動き、
# 詳細 workflow は system-planner / review-workflow / research-handoff が所有する
# current orchestrated flow は内部で task contract を emit / validate してから coder を起動する
# task contract の emit / validate が通らない場合、coder は fail-closed で起動しない
./.claude/commands/auto_orchestrate.sh \
  --plan .agent/active/plan_YYYYMMDD_HHMM_<task>.md \
  --phase impl \
  --run-coder
```

### 4. レビュー（Reviewer）
```bash
# auto_orchestrate.sh が自動でCodexレビューを実行
```

### 5. required checks / gate
```bash
# slice-local required checks と authoritative release gate を実行
bash test/integration/harness_release_gate.sh
```

### 6. 完了・アーカイブ
```bash
# タスク完了後、プランは `.agent_rules/RULES.md` の完了処理に従って `.agent/archive/plans/` へ移動する
```

---

## テスト実行

```bash
# authoritative release gate
bash test/integration/harness_release_gate.sh

# 補助 gate / subset checks
./scripts/quality_gate.sh
```

---

## コミット規約

```
<type>: <subject>

Types:
- feat: 新機能
- fix: バグ修正
- docs: ドキュメント
- refactor: リファクタリング
- test: テスト追加/修正
- chore: 雑務（ビルド、CI等）
```

---

## 注意事項

1. **mainブランチ直接編集は原則禁止**: Worktreeを使用。例外は `.agent_rules/RULES.md` Phase 1.8 に従う
2. **Codex呼び出し**: caller-facing / manual / external な Codex 起動は `scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>` を使う。Reviewer は `--role reviewer` 固定。legacy shim（`medium/high/xhigh`）は互換レイヤであり source of truth ではない。native Codex multi-agent / subagent orchestration は wrapper 非経由で Codex 内部に留める
3. **Workflow ownership**: 再利用可能な運用手順は `.claude/skills/*.md` が所有し、command は実行入口に留める
4. **Claude effort 既定値**: `medium`。caller-facing effort は `low|medium|high|xhigh` のみ許可し、`max` は使わない
5. **Wrapper ガード**: Codex wrapper は `--cd` / `--add-dir` を警告して strip し、shim 固定 role に対する role escape は fail-closed で拒否する
6. **Verification / truth placement**: `docs/manual/verification-truth-matrix.md` を現行正本とする。repo-wide hard rule は `.agent_rules/RULES.md`、slice 固有の required checks と completion boundary は active plan / SOW / handoff prompt に置く
7. **セッション継続**: 手動の session continuation は利用できるが、自動 / オーケストレーション経路では fail-closed。`--manual-session` 付きの real TTY 実行だけを許可する
8. **Session helper の入口**: `session.sh` の Claude 実行は canonical `scripts/claude-wrapper.sh` に固定し、`CLAUDE_WRAPPER` は caller 制御の escape hatch として扱わず canonical path 以外なら fail-closed で拒否する
9. **semantic-free harness**: RevHarness は semantic MCP / semantic capsule を持たない。context は `rg` / raw-read と `INDEX_MAP` で取得する。semantic addon の opt-in 配線（旧 Addon-I-13）は撤去済みで、再導入しない
10. **common task contract**: current orchestrated coder run は `.claude/tmp/<task>/task-contract.json` を emit / validate してから継続する。contract は runtime envelope であり、acceptance 正本は `docs/manual/verification-truth-matrix.md`
