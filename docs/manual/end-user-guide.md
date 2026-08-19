# Audience Guides (End User / Harness Developer / Maintainer)

This file combines three previously separate reader-persona guides — the end
user guide, the developer customization guide, and the agent maintainer guide
— because they share one subject (how to get oriented in Revharness, keyed
off who is reading) and previously duplicated the same section pattern
(`誰向けか` / `最初に読む文書` / daily flow / commands) three times. Pick the
part that matches your role; each part is self-contained.

- Part 1 — for people who use this harness to build applications or features.
- Part 2 — for people who customize or extend the harness itself.
- Part 3 — for agents/maintainers reviewing, upgrading, or re-entering this
  repository with zero prior context.

---

## Part 1 — End User Guide

### 誰向けか

この文書は、このハーネスを使ってアプリケーションや機能を生み出すユーザー向けです。ハーネス自体を改造するのではなく、正しい入口を使って成果物を作ることが目的です。

### 最初に読む文書

1. `README.md`
2. `docs/manual/rev-harness-lifecycle.md`（唯一の正規セットアップ入口である `bash scripts/rev-harness install` のリファレンス）
3. `docs/manual/harness-user-guide.md`
4. `docs/manual/harness-release-gate.md`
5. `docs/manual/verification-truth-matrix.md`

### 前提

- bash 4.0 以上が必須です。macOS 標準の `/bin/bash`（3.2系）では動きません。
  `brew install bash` で新しい bash を入れてから、そのパス（例: `/opt/homebrew/opt/bash/bin/bash`）
  経由で実行するか、シェルの `bash` を差し替えてください。この harness の全スクリプトは
  起動時にこの前提を検査し、満たさない場合は分かりやすいエラーで即座に停止します。
- 唯一の正規セットアップ入口は `bash scripts/rev-harness install`（facade）です。
  `setup/bootstrap.sh` は旧経路の名残で、現在は内部で `scripts/rev-harness` に委譲するだけの
  非推奨シムです。新しいドキュメントやスクリプトから `setup/bootstrap.sh` を直接叩くコードは
  書かないでください。

### 日常フロー

1. 目的に対応する ExecPlan を確認する
2. `bash scripts/rev-harness verify` で前提・状態を確認する（未インストールなら先に `bash scripts/rev-harness install` を実行する）
3. `bash scripts/project-id.sh artifact-path` で `project_id` 由来の artifact path を確認する
4. 必要なら `./scripts/hydra new <task-name>` で worktree を切る
5. `./.claude/commands/auto_orchestrate.sh --plan <plan> --phase impl --run-coder` を使う
6. `.claude/tmp/<task>/task-contract.json` と `.claude/tmp/<task>/state.json` を確認する
7. 最後に slice-local checks と `bash test/integration/harness_release_gate.sh` を回す

### よく使うコマンド

- `bash scripts/rev-harness install`（初回セットアップ。唯一の正規入口）
- `bash scripts/rev-harness verify`（= `harness-doctor.sh --quick`。非破壊の状態確認）
- `bash scripts/rev-harness status`
- `bash scripts/project-id.sh artifact-path`
- `./scripts/codex-wrapper.sh --role coder --stdin`
- `./scripts/claude-wrapper.sh --output <file> "prompt"`
- `./scripts/hydra new <task-name>`
- `./.claude/commands/auto_orchestrate.sh --plan <plan> --phase impl --run-coder`
- `bash test/integration/harness_release_gate.sh`

### 重要な artifact

- `.agent/active/plan_*.md`: current plan
- `.claude/tmp/<task>/task-contract.json`: current orchestrated run の contract
- `.claude/tmp/<task>/state.json`: current run state
- `.claude/tmp/harness-release-gate/runs/<run-id>/summary.md`: gate run evidence; latest pointer is `.claude/tmp/harness-release-gate/latest.json`
- wrapper / reviewer stderr: run-local `stderr/` directories under `.claude/tmp/**`, with only `*.stderr-pointer.txt` metadata near user-facing outputs

### 信じてよいもの / だめなもの

信じてよいもの:

- `docs/manual/verification-truth-matrix.md`
- `docs/manual/harness-release-gate.md`
- current plan / current SOW / latest gate artifact

信じてはいけないもの:

- 古い dated handover を current truth だと思うこと
- `.claude/tmp/**` の scratch JSON を durable authority だと思うこと
- roadmap 上の planned feature を current implementation だと思うこと
- `README.md` の summary だけで acceptance を判断すること

---

## Part 2 — Developer Customization Guide

### 誰向けか

この文書は、このハーネス自体をカスタム、拡張、改修する開発者向けです。成果物を作るユーザーではなく、Revharness / `rev_harness` の behavior を変える側を対象にします。

### Canonical Operating Model

この guide の読者（harness 自体を改修する開発者）は、この harness チェックアウトの中で直接作業します。これは、harness を **利用する側**（対象リポジトリへ `bash scripts/rev-harness install --target <path>` で install する adopter、`docs/getting-started/installation.md` が正本）とは別の立場です。harness 開発者が編集するのは主に `Framework / Core Harness` 層であり、`src/` は関係しません。harness リポジトリにも `src/` は存在しますが、中身は `README.md` と `.gitkeep` だけのプレースホルダで、install 時に adopter 側リポジトリへ複製される雛形です。harness チェックアウト自身の `src/` の中でプロダクトコードを書くことは想定していません（自己 install はガードが拒否するため、その経路では wrapper が動きません）。

変更判断は次の 3 層で切り分けます。

1. `Framework / Core Harness`
   - wrapper、commands、policy docs、CI gate、integration surface（harness 開発者が主に触る層）
2. `Project State`
   - `.agent/**`、project-local context、active plans、SOW、prompt、evidence pointer
3. `Product Code`（adopter 側の概念。harness 開発では扱わない）
   - greenfield install の既定配置は adopter リポジトリの `src/`。adopted / existing projects は compatibility / overlay path として project-native layout を維持してよい

配布元 (`https://github.com/sasuketorii/rev_harness_public`) 以外の release tag、package coordinates、追加 distribution channel は `TBD` です。この guide が扱うのは harness framework の変更手順までであり、installer / upgrader tooling の実装、publish、tag、package release は含みません。

### 最初に読む文書

1. `README.md`
2. `docs/README.md`
3. `AGENTS.md`
4. `.agent_rules/RULES.md`
5. `.agent/PROJECT_CONTEXT.md`
6. `docs/manual/common-task-contract.md`
7. `docs/manual/verification-truth-matrix.md`

### 日常フロー

1. change surface を narrow slice に分解する
2. ExecPlan を切る
3. required checks と completion boundary を先に固定する
4. docs / scripts / tests を current truth に合わせて更新する
5. `git diff --check` と relevant deterministic checks を回す
6. reviewer evidence を揃えて closeout する

### 公式ドキュメント起点の更新

Codex / Claude Code / prompting / subagent / skill / hook / wrapper / Goal workflow に関わる Revharness behavior を変える場合、実装前に `.claude/skills/harness-official-docs-update/SKILL.md` を通す。

基本順序:

1. `docs/official-docs-links.md` の OpenAI / Anthropic 公式リンクから該当ページを確認する。
2. plan / SOW / research handoff に、参照した公式ページと適用判断を記録する。
3. 公式推奨をそのまま runtime truth にせず、Revharness の local authority へ割り当てる。
4. wrapper / role / skill / common task contract / acceptance matrix のどの層を変えるかを明示する。
5. `docs/manual/verification-truth-matrix.md` の acceptance / LGTM / completion truth を upstream workflow 機能で上書きしない。

Codex Goal、Claude Code subagents、OpenAI prompt guidance のような upstream workflow 機能は、まず Contract Envelope / durable artifact / deterministic evidence のどこへ写像するかを決めてから実装する。

### よく見る設計文書

- `docs/design/harness-plugin-boundary.md`
- `docs/design/harness-plugin-mcp-trust-matrix.md`
- `docs/design/safe-merge-protocol.md`

### 重要な current behavior

- external / manual Codex runs は `scripts/codex-wrapper.sh --role ...` が canonical
- automatic flow は non-interactive invariant を守る
- current orchestrated coder run は `task-contract.json` を emit / validate してから進む
- semantic MCP はこのハーネスには**存在しない**。有効化・検証すべき semantic addon は存在せず、`semantic.db` / semantic capsule / tree-sitter index もない

### 触る前に注意すること

- `verification-truth-matrix` を wrapper 契約で上書きしない
- roadmap と implemented state を混同しない
- role docs と README の summary が衝突したら、authority 側から直す

### 主要コマンド

- `git diff --check -- <files...>`
- `bash test/integration/harness_release_gate.sh`
- `bash test/integration/common_task_contract_smoke.sh`

---

## Part 3 — Agent Maintainer Guide

### 誰向けか

この文書は、このハーネスを見直し、保守し、アップグレードする次のエージェント向けです。ゼロコンテキストで再着任しても current truth に戻れることを目的にします。

### 最初に読む文書

1. `AGENTS.md`
2. `.agent_rules/RULES.md`
3. `.agent/PROJECT_CONTEXT.md`
4. `docs/roles/orchestrator.md`
5. `docs/manual/verification-truth-matrix.md`
6. `docs/manual/harness-release-gate.md`
7. `docs/manual/common-task-contract.md`
8. `docs/manual/harness-user-guide.md`

### 再開時の確認ポイント

1. `git status --short --branch` で dirty state を確認する
2. `.agent/active/plan_*.md`、`.agent/active/sow/`、`.agent/active/prompts/` を確認する
3. `.claude/tmp/harness-release-gate/latest.json` から `.claude/tmp/harness-release-gate/runs/<run-id>/summary.md` の latest gate evidence を確認する
4. `.claude/tmp/<task>/state.json` と `.claude/tmp/<task>/task-contract.json` を current run artifact として読む
5. `docs/README.md` から stable docs の authority を辿る

### どこを trust するか

trust する:

- `AGENTS.md`
- `.agent_rules/RULES.md`
- `.agent/PROJECT_CONTEXT.md`
- `docs/manual/verification-truth-matrix.md`
- current ExecPlan / current SOW / current handover
- current gate artifact
- run-local `stderr/` directories pointed to by wrapper / reviewer `*.stderr-pointer.txt`

trust しない:

- 古い dated plan を current authority と見なすこと
- `.claude/tmp/**` の export を durable authority と見なすこと
- `README.md` の summary だけで acceptance を判断すること

### current implemented state

- common task contract Slice A は implemented
- non-interactive automatic flow の session continuation は fail-closed
- semantic MCP はこのハーネスには存在しない。Core も addon も semantic MCP を起動せず、`addon-absent-or-compliant-check.sh` を含む semantic addon gate / config 検証も存在しない
- semantic preflight / capsule / registry protections も存在しない。コンテキスト取得は `rg` / raw-read + `INDEX_MAP`
- Claude/Opus review の `--bare` は API-key auth (`ANTHROPIC_API_KEY` / `apiKeyHelper`) が明示された場合だけ許可する。OAuth/keychain 認証の非対話 review では `--bare` を省き、`--no-session-persistence`、明示 tools、`--permission-mode dontAsk`、budget を使う
- browser stack rollout は roadmap 段階であり、current stable flow ではない

### 主要コマンド

- `git status --short --branch`
- `git diff --check -- <files...>`
- `bash test/integration/harness_release_gate.sh`
- `bash test/integration/common_task_contract_smoke.sh`
- `scripts/codex-wrapper.sh --help`
- `scripts/claude-wrapper.sh --help`
- `.claude/commands/lib/reviewer.sh`

### semantic-mcp tool surface (存在しない)

semantic MCP の tool surface (`sem.context.top_k` / `sem.capsule` / `sem.search`
/ `sem.admin.gc` など) は、このハーネスには**存在しません**。
harness-rust/crates/semantic-mcp crate、tree-sitter index、semantic capsule、
`semantic.db` 配置はもう存在しません。semantic MCP を前提にした tool 呼び出し・
skill・config は維持しないでください。
