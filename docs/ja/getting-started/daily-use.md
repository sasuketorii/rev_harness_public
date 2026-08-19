# Daily use(日常運用)

English original: [docs/getting-started/daily-use.md](../../getting-started/daily-use.md)

[First run](first-run.md) では1つのタスクを最初から最後まで通しました。このページは、RevHarnessが普段のワークフローの一部になった後に立ち返るリファレンスです。どのコマンドを使うか、タスクが単発のラッパー呼び出し以上の手続きを必要とするのはいつか、「完了」の証拠が実際にどこにあるか、そしてただ作業するのではなくExecPlanを書くべきタイミングです。

このページを通して、`$HARNESS` はRevHarnessをクローンした場所を指します——見慣れない場合は [First run → 0. `$HARNESS` を設定する](first-run.md#0-harness-を設定する) を参照してください。

---

## 実際に打つことになるコマンド

| コマンド | 使うタイミング |
|---|---|
| `bash "$HARNESS/scripts/rev-harness" status` | セッション開始時——ここで識別子とhooksは配線済みか |
| `bash "$HARNESS/scripts/harness-doctor.sh"` | いつでも実行できる非破壊的なヘルスチェック |
| `bash "$HARNESS/scripts/rev-harness-task-classifier.sh" classify --intent <intent> --files <path...> --json` | 非自明なタスクを始める前に |
| `bash "$HARNESS/scripts/codex-wrapper.sh" --role <role> --stdin` | Codexへ作業やレビューを委譲する |
| `bash "$HARNESS/scripts/claude-wrapper.sh" --output <file> "prompt"` | Claudeへ委譲する——下記の注意点を参照 |
| `bash "$HARNESS/scripts/dual-lgtm-validate.sh" --plan-id <id> --round <n>` | フェーズを進める前に、2つの独立したLGTMがディスク上に実在することを確認する |
| `bash "$HARNESS/.claude/commands/auto_orchestrate.sh" --plan <plan> --phase <phase> --run-coder` | 実装→レビュー→修正のループを手作業でなく自動で回す |
| `bash "$HARNESS/scripts/hydra" new <task-name>` | タスク用に隔離されたワークツリー+ブランチを切る |
| `bash "$HARNESS/scripts/project-id.sh" artifact-path` | このプロジェクトの識別子ファイルはどこにあるか |

以下は、それぞれをいつ・なぜ使うかを掘り下げたものです。

## ロール、そしてどれを使うか

`scripts/codex-wrapper.sh --help` は現在のロールマップを表示します。短いのでそのまま読んでしまうのが早いです。

```text
Role map:
  standard  -> medium + cached
  research  -> high + live
  coder     -> medium + cached
  high-coder -> high + cached
  reviewer  -> xhigh + cached
```

- **`coder`** — 通常の実装作業。medium reasoning effort、cachedなweb search。ほとんどの変更にはこれを使います。
- **`high-coder`** — 同じロールですが、reasoning effortをより高くしたもの。レビューではなく、あくまでコーダーの仕事だが特に手強いスライス向けです。
- **`reviewer`** — 常に `xhigh` effortです。ロールが固定するのはeffortとweb-searchモードであり、これは呼び出しごとに設定できるものではありません(`.agent/registry/model_policy.json` 参照)。裏側のモデルidそのものはロールごとに変わりません——`codex-wrapper.sh --role reviewer` も `--role coder` も、上書きしない限り同じ `current_model` に解決されます。レビューにおいて本当に異なるモデル*ファミリー*を使う(READMEが述べているcross-familyの非対称性)のは、ロールそのものではなく**誰に委譲するか**次第です——たとえばCodexが変更を書き、Claude Codeのreviewerが判定する、あるいはその逆です。非対称性(reviewerがcoderより多くの推論予算を持つこと)は意図的ですが、cross-familyの分離はラッパーが強制するものではなく、ワークフロー上の選択です。
- **`research`** — ライブのweb search、`high` effort。「Xを調べてきて」というタスクに使い、実装には使いません。
- **`standard`** — より具体的なものが当てはまらない場合のデフォルトです。

これらのどれについても、コマンドラインから別のサンドボックス・承認モード・モデル・reasoning effortを要求することはできません——ラッパーのソースコメントは明示的にこう述べています。「プロファイル、モデル、reasoning effort、サンドボックス、承認、web-search、workspace-expansionの制御に対する呼び出し元からの上書きは、CLIフラグ経由でブロックされる」。ポリシーのデフォルトとは異なるモデルが必要な場合、正規の上書き方法はフラグではなく環境変数です。

```bash
REV_HARNESS_CODEX_MODEL=<model-id> bash "$HARNESS/scripts/codex-wrapper.sh" --role coder --stdin < prompt.md
```

最低モデルのゲートはその上書きにも引き続き適用されます——`.agent/registry/model_policy.json` の `minimum_allowed_model` を下回るモデルを要求すると、より弱いモデルへ静かにフォールバックするのではなく、明示的なエラーでfail-closedになります。これが実際にどう見えるかは
[Troubleshooting](troubleshooting.md#ラッパー呼び出しがモデルの上書きを拒否する) を参照してください。

**Claude Codeへの系統をまたいだ呼び出しは非推奨です。** `scripts/claude-wrapper.sh` 自身が、呼び出しのたびにこれを表示します。Claude Codeへの系統をまたいだ呼び出しは、Claude Agent SDK / Claude Codeサブスクリプションの利用枠を消費し、ハーネスのデフォルトのオーケストレーションフローからは除外されています。Claude Codeの中からRevHarnessを操縦している場合は、このラッパー経由でシェルアウトするより、ネイティブなClaude Codeのサブエージェント(`Task` ツール)を優先してください。ラッパーは互換性シムとして引き続き機能します——詳細が必要なら `docs/agent-sdk-policy.md` を参照してください。

## タスククラス: light、standard、heavy

作業を始める前に分類します。始めた後ではありません。

```bash
bash "$HARNESS/scripts/rev-harness-task-classifier.sh" classify \
  --intent <intent> --files <path...> --json
```

有効な `--intent` の値: `typo`、`reference-cleanup`、`admin`、`prompt-wording`、`docs`、`implementation`、`test`、`policy`、`security`、`release`、`live-orchestration`。

| クラス | ゲート階層 | レビュー要否 | 最終ゲート要否 | 典型的な作業 |
|---|---|---|---|---|
| `light` | `quick` | 不要 | 不要 | typo修正、参照のクリーンアップ、文言調整 |
| `standard` | `local` | 必要(スコープ限定) | 不要 | 通常の実装、テスト、ドキュメント |
| `heavy` | `full` | 必要 | 必要 | リリース、セキュリティ、ラッパー/ロールの変更、受け入れ判定のmatrix自体に触れるもの全般 |

`heavy` のフルの手続きを `light` のtypo修正に適用しないでください。また、`heavy` な変更を、分類が手軽だったからという理由でレビューなしに通さないでください。分類器の `reasons` フィールドがその結果になった理由を教えてくれます——結果に驚いたときはそこを読んでください。

完全な受け入れ判定の権威——invariantごとの必須チェック、`heavy` の完全なスキーマフィールド、判定のマッピング——は
[`docs/manual/verification-truth-matrix.md`](../../manual/verification-truth-matrix.md) にあります。両者が食い違った場合は、このページではなくそちらが勝ちます。このページはあくまで日々の要約であり、それの代替物ではありません。

## レビューループ

小さな変更1つであれば、[First run](first-run.md) が手作業で行ったことをそのまま行います——`coder` が変更を書き、あなたが実際のプロジェクトのチェックを実行し、`reviewer` がステージされた差分を判定し、`LGTM` と言われるまで修正・再提出を繰り返します。

複数回のレビューが見込まれる作業では、`auto_orchestrate.sh` が同じループを代わりに回してくれます。

```bash
bash "$HARNESS/.claude/commands/auto_orchestrate.sh" \
  --plan <plan-path> --phase impl \
  --run-coder --coder-engine codex \
  --reviewers safety,perf,consistency \
  --gate levelA
```

主なフラグ(それ自身の `--help` より):

- `--run-coder` — このフェーズについて、既に出力が存在することを期待するのではなく、実際にcoderエンジン(`claude` または `codex`、デフォルトは `codex`)を呼び出す。
- `--reviewers` — カンマ区切りのレビュワーレンズ。デフォルトは `safety,perf,consistency`。
- `--max-iterations N` — 修正→再レビューのラウンド数の上限(デフォルト5)。`N=1` は「1回レビューして、何か指摘があればループせず即座に失敗させる」ことを意味します。
- `--gate levelA|levelB|levelC` — レビュー通過後に品質ゲートを実行する。
- `--resume <state-file>` — 中断された実行を最初からではなく続きから再開する。`--continue-session` / `--fork-session` は予約済みであり、ここでは常にfail-closedです——オーケストレーションされた実行は設計上非対話型であり、継続すべきライブなセッションが存在しないためです。
- `--status` — 何かを実行する代わりに、既存の `state.json` の要約を出力する。

1回の実行の状態は `.claude/tmp/<task>/state.json` にあります。coderが何を渡し、reviewerが何を返すかの契約は
`docs/prompts/reviewer_batch.md`(英語) です。

### 独立した2つのLGTMが本当に存在することの確認

`heavy` クラスの変更を「受け入れられた」ものとして扱う前に、両方のレビューが行われたと誰かの言葉を信じるのではなく、成果物そのものを確認してください。

```bash
bash "$HARNESS/scripts/dual-lgtm-validate.sh" \
  --plan-id <plan-id> --round <round-int> \
  --expected-reviewers opus,codex --strict
```

これはチャットの履歴ではなく、ディスク上の証拠を読みます。`--strict` は、いずれかの判定が欠けている・不正な形式・想定と異なるレビュワーの識別子である場合にfail-closedします。

## Evidence(証拠)

重要な場所は2つあります。

- **`.claude/tmp/<task>/`** — オーケストレーションされたタスクの実行ローカルな状態: `task-contract.json`、`state.json`、ラウンドごとのレビュワー出力、そして生のラッパーstderrを保持する `stderr/` ディレクトリ([First run](first-run.md#3-coderに作業させる) で見た `REV_HARNESS_DELEGATION_METRIC` の行はここに、ラッパー呼び出し1回につき1行ずつ着地します——ラッパー自身はそれを出力するだけで、それを捕捉するのは呼び出し元の責任です)。ユーザー向けの出力の近くにはポインタファイル(`*.stderr-pointer.txt`)だけを置き、生のstderrは自分自身のサブディレクトリに残してください。
- **`.agent/active/`** — 永続的な、プランに紐づいた状態: `plan_*.md` のExecPlan、タスク系譜台帳(task lineage ledger)である
  `.agent/active/sow/task-lineage-ledger.md`、そしてSOW/引き継ぎ文書。

タスクが完了したら、`.claude/tmp/**` のスクラッチJSONを永続的な真実として扱わないでください——重要なものは `.agent/active/` かあなたのプロジェクト自身のドキュメントへ昇格させてください。そうしなければ、そのスクラッチ領域が次に掃除された時点で消えてしまいます。

## ExecPlanをいつ書くか

すべてのタスクに必要なわけではありません。作業が1セッションを超えて続く場合、複数のスライスがある場合、あるいは後で参照するリリース境界が必要な場合にExecPlanを書きます。テンプレートから始めてください。

```bash
cp "$HARNESS/.agent/templates/execplan_checklist_template.md" \
   .agent/active/plan_$(date +%Y%m%d_%H%M)_<task-name>.md
```

必須セクション: `Objective`、`Status Board`、`Slice Board`、`In Scope`、`Out Of Scope`、`Required Deterministic Checks`、`Completion Boundary`。使うのは `[x]` / `[ ]` だけです——スライスがブロックされている、あるいは先送りされている場合は、3つ目のチェックボックス状態を発明するのではなく、チェックを外したまま理由をその場に書いてください。指定された専門分野(specialty)を使うスライス向けの条件付きフィールドを含む完全な契約は
[`docs/manual/execplan-checklist-standard.md`](../../manual/execplan-checklist-standard.md)(英語) にあります。

## ワークツリーでの作業の隔離

メインのチェックアウトから完全に隔離したい作業——無人で走らせるコーダーや、ロールバックするかもしれない作業——には、`hydra` が `git worktree` とPRフローをラップします。

```bash
"$HARNESS/scripts/hydra" new my-task       # new worktree + branch
"$HARNESS/scripts/hydra" list              # see active worktrees
"$HARNESS/scripts/hydra" preflight my-task # check for merge conflicts with base
"$HARNESS/scripts/hydra" close my-task     # push, open a PR via gh, remove the worktree
```

`hydra rollback --last --dry-run` は、直近のマージを取り消したらどうなるかをプレビューします。実際に取り消すには `--dry-run` を外してください。`hydra merge-order` は、複数のワークツリーが並行して進んでいて正しい順序で着地させる必要がある場合に、依存関係を分析します。

## ドキュメント同士が食い違うとき、何を信じるか

`docs/manual/end-user-guide.md` より、心に留めておく価値のある内容です。

信じるべきもの:

- `docs/manual/verification-truth-matrix.md`
- `docs/manual/harness-release-gate.md`(英語)
- 現行のプラン、現行のSOW、最新のゲート成果物

信じるべきでないもの:

- 古い引き継ぎ文書を、あたかも現在の真実であるかのように扱うこと
- `.claude/tmp/**` 配下のスクラッチJSONを永続的な権威として扱うこと
- ロードマップの項目を、あたかも既に実装済みであるかのように扱うこと
- README上の要約だけを、変更を受け入れる根拠として扱うこと

---

次へ: [Troubleshooting](troubleshooting.md)——日々のループの中で、このページの説明通りに動かないことがあった場合に。
