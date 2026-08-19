# Installation(インストール)

まず [Requirements](requirements.md) を読んでください——macOSではbashのバージョンが形式上の話ではなく、実際にインストールを止めるブロッカーになります。

English original: [docs/getting-started/installation.md](../../getting-started/installation.md)

---

## エントリポイントはただ1つ

```bash
bash scripts/rev-harness install
```

他のすべてはこれに委譲します。もし何らかのチュートリアルやスクリプト、コメントが別のコマンドを実行するよう案内していたら、その情報源は古くなっています。`setup/bootstrap.sh` は昔からの習慣で使う人のためにまだ存在しますが、今は上記のコマンドへ転送し非推奨(deprecation)の通知を出す以外、何もしません。

`install` は冪等(idempotent)です。2回実行しても安全であり、部分的にしか設定されていないチェックアウトを修復する通常の方法でもあります。

## メンタルモデル

RevHarnessは、クローンしてその中で作業する類の**プロジェクトテンプレートではありません**。既に持っているリポジトリ(あるいは新しい空のリポジトリ)に**インストールする**ハーネスです。

ハーネス自体は一度だけクローンします。そのクローンから、ハーネスをかけたい各プロジェクトに対して `install --target <path>` を実行します。`--target` を付けずに、RevHarnessのチェックアウト自体の中で `install` を実行することは意図的に拒否されます——自分自身のソースツリーにはインストールしません。

```bash
git clone https://github.com/sasuketorii/rev_harness_public.git
cd rev_harness_public

bash scripts/harness-doctor.sh                                  # 1. can this machine run it?
bash scripts/rev-harness install --target /path/to/your/project # 2. install
bash scripts/rev-harness status  --target /path/to/your/project # 3. confirm
```

ハーネスのクローンは、何かをインストールする前に自分自身の識別子(identity)を必要とします。まだ存在しなければ初回利用時に自動生成されるので、別途のブートストラップ手順は不要です。既に識別子が存在する場合、それを上書きすることは決してありません。

### 前提条件: ターゲットは既にgitリポジトリであること

`install --target <path>` は `<path>` が既にgitリポジトリであることを要求します——hooksフェーズが `pre-commit` フックをインストールしようとし、`.git` がまだ存在しないと `adopter-root is not a git repository: <path>` で失敗します。新規プロジェクトの場合は、先に `git init` してください。

```bash
mkdir -p /path/to/your/project && cd /path/to/your/project
git init
bash /path/to/rev_harness_public/scripts/rev-harness install --target .
```

`install` 自体は他の外部ツール(`gh` など)を必要としません。

### `install` が実際に行うこと

小さなステートマシンを実行します——`.rev-harness-state/state.json` に記録されるため、中断されたインストールは最初からではなく途中から再開されます。

1. **Identity** — このチェックアウトの不変の識別子である `.shared/project_id` を生成します。状態・キャッシュ・証拠(evidence)をリポジトリに紐づけるものはすべてこれをキーにします。一度だけ生成され、手で編集されることはありません。破損した値については、推測せずガードが拒否します。
2. **Hooks** — エージェントのライフサイクルフック(スナップショット取得、パスリーク警告、正常終了)をインストールします。
3. **Verification** — doctorを実行し、何が欠けているかを報告します。

### 使えるフラグ

| フラグ | 効果 |
|---|---|
| `--dry-run` | 何が変わるかだけ表示し、何も変更しない |
| `--json` | スクリプト向けの機械可読な出力 |
| `--strict` | 警告を失敗として扱う |
| `--target <path>` | カレントディレクトリの代わりに別のチェックアウトを操作対象にする |

## 既存リポジトリへの導入

あなたのコードはそのままの場所にとどまります。ハーネスリポジトリ内の `src/` はグリーンフィールド利用のためのプレースホルダーにすぎず、既存プロジェクトは自身のレイアウトを保ったまま、ハーネスはその上に層として乗ります。

```bash
bash /path/to/rev_harness_public/scripts/rev-harness install --target /path/to/your/project
```

インストールが成功したら、結果を確認します。

```bash
bash /path/to/rev_harness_public/scripts/rev-harness doctor --target /path/to/your/project
```

新規のアダプター(adopter)は、`blocks` が空の状態で `WARN` を報告します。汚れたワークツリー、タスク系譜台帳(task-lineage ledger)の欠如、リリースゲートのポインタ欠如についての警告は、新規インストールでは想定内です——これらの成果物は、実際に作業を始めると現れます。`blocks` が空でない場合は本当の問題です。詳しくは [Troubleshooting](troubleshooting.md) を参照してください。

### 何を触り、何を触らないか

`.agent/registry/rev_harness_distribution_manifest.json` が契約です。

- **ハーネスが所有する** — `scripts/`、`docs/`、`.agent_rules/`、skills、hooks。アップグレード時に丸ごと置き換えられます。手で編集しないでください。あなたの変更は失われます。
- **あなたのもの、決して上書きされない** — `src/`、`apps/`、`packages/`、`services/`、`crates/`、あなたのプロダクトのテスト、あなたのプロジェクトの文脈と要件。
- **マージされる、コピーはされない** — `.codex/config.toml`、`.claude/settings.json`、`AGENTS.md`、`CLAUDE.md`、`.mcp.json`。これらはプロジェクトごとの状態を保持しており、単純な上書きコピーだとそれを壊してしまうため、アップグレードは構造的にマージします。

アップグレードがあなたのチェックアウトに何をするか分からない場合は、聞いてみてください——ただし `upgrade` のトップレベル `--dry-run` フラグは、デフォルトの `inspect` アクションと組み合わせられません(実際のチェックアウトで再現: `rev-harness-upgrade: unknown inspect option: --dry-run`)。動く形は次のように `--dry-run` を付けないものです。

```bash
bash scripts/rev-harness upgrade   # defaults to the `inspect` action; read-only
```

`inspect` はターゲット内にどのトップレベルのハーネスパス(`AGENTS.md`、`.agent`、`.claude`、`.codex`、`.shared/project_id`)が存在するかを報告するだけで、ファイル単位の差分ではありません。また `apply` アクションはこのビルドでは未実装なので(`bash scripts/rev-harness-upgrade.sh --help`)、実際のアップグレードのプレビューは存在せず、この存在チェックだけです。

## Rustコアのビルド(オプション)

シェル層はこれなしでも動作します。`agent-core` のサブコマンド(ExecPlanのlint、envelopeのlint、決定論的なタスクスタンプ)が欲しい場合のみビルドしてください。

```bash
cd harness-rust
cargo build --release
```

ツールチェーンは `harness-rust/rust-toolchain.toml` に固定されています(Rust 1.87.0 ——`agent-core` はそのリリースで安定化された `u32::is_multiple_of` を使用)。Cコンパイラも必要です。`rusqlite` がSQLiteをソースからコンパイルするためです。

## エージェントCLIの接続

ハーネスは認証情報を管理しません。各ベンダーのCLI自身でログインしてください。

```bash
claude    # follow its login flow
codex     # follow its login flow
```

その後、ハーネスがそれらを認識できているか確認します。

```bash
bash scripts/harness-doctor.sh
```

モデル選択は呼び出しごとではなく、ポリシー駆動です。`.agent/registry/model_policy.json` が、重い判断(計画立案、レビュー、リリースゲート)を最強モデルへ、実装やドキュメント作業をより速いモデルへ振り分けます。出荷時のデフォルトはリリース時点で最新のものでしたが、ファイルを編集せずに呼び出しごとに上書きできます。

```bash
REV_HARNESS_CODEX_MODEL=<model-id> bash scripts/codex-wrapper.sh --role coder --stdin < prompt.md
```

最低モデルのゲートは上書き時にも引き続き適用されます——floorを下回るモデルを設定すると、静かに格下げされるのではなくfail-closedになります。

## アンインストール

```bash
bash scripts/rev-harness clean        # remove runtime residue, keep the install
bash scripts/rev-harness uninstall    # reports what would be removed
```

`uninstall` は現時点ではレポートのみです。削除は意図的に自動化されていません。詳しくは [Uninstall](uninstall.md) を参照してください。

次へ: [First run](first-run.md)
