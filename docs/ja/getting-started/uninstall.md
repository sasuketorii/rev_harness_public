# Uninstall(アンインストール)

English original: [docs/getting-started/uninstall.md](../../getting-started/uninstall.md)

自動化された削除経路はまだ存在しません。`scripts/rev-harness uninstall` は助言的なチェックリストを表示して止まるだけで、それ自体が何かを削除することは決してありません。このページは、`install` が実際にアダプター(adopted)プロジェクトの中に何を作るのか、そしてそれを手作業で取り除く手順を記載しています。本書執筆にあたり、使い捨てのgitチェックアウトに対して実際に `install`・`clean`・`uninstall` を実行して確認した内容であり、以下の出力はどれも記憶からの言い換えではありません。

## `clean` と `uninstall`——どちらもハーネスを削除しない

```bash
bash scripts/rev-harness clean        # remove runtime residue, keep the install
bash scripts/rev-harness uninstall    # reports what would be removed
```

この2つのコマンドは、2ステップのアンインストールだと読み違えやすいものです。そうではありません。

- `clean` はCargoのビルド成果物用の掃除役(janitor)を実行します(出力中の `janitor_command: build-cleanup`)。対象は `harness-rust/target` とローカルのCargoレジストリキャッシュであり、それも**正本(canonical)のハーネスのクローン側**が対象であって、アダプター(adopted)プロジェクト側ではありません。Rustのビルド成果物を持たないプロジェクトに対して実行すると、`target_count: 1`、`freed_bytes: 0` と報告され、何も変わりません。`.agent/`、`.claude/`、`.shared/`、`.rev-harness-state/` には一切触れません。
- `uninstall` はレポート専用(report-only)です。実際にアダプター済みのプロジェクトに対して実行すると、正確に次のように表示されます(パスだけが環境ごとに異なります)。

  ```
  RevHarness uninstall checklist (advisory only)

  1. Remove canonical PATH export line from shell rc files. This checkout's
     scripts directory is:
       /path/to/your/rev_harness_public/scripts
     Find the matching line first (it may differ if you renamed the checkout):
       grep -n '/path/to/your/rev_harness_public/scripts' "${HOME}/.zshrc" "${HOME}/.bashrc" 2>/dev/null
     Then remove it, e.g.:
       sed -i.bak "\|/path/to/your/rev_harness_public/scripts|d" "${HOME}/.zshrc"
       sed -i.bak "\|/path/to/your/rev_harness_public/scripts|d" "${HOME}/.bashrc"

  2. Delete adopter state:
     rm -f .agent/registry/rev_harness_adoption_state.json

  3. Inspect installed links or dirs before removal:
     .claude/
     .agent/active/
     Remove only symlinks or directories created by the RevHarness install.

  4. Restore .git/hooks/pre-commit if needed.
     Expected backup: .git/hooks/pre-commit.rev-harness.bak (backup not detected)

  5. Decide what to do with .shared/project_id.
     This is immutable project identity; do not delete unless explicitly retiring the project.

  6. Cargo target cleanup is canonical-side only:
     /path/to/your/rev_harness_public/harness-rust/target
     This is not adopter-side uninstall state.
  ```

  このコマンドは、scripts ディレクトリと cargo target のパスを**実行時にこのチェックアウト自身の実際の場所**から解決します(`--json` を使えば各フィールドとして取得できます)。そのため上記のパスは、実際にどこへクローンしても常に一致します——`~/dev/rev_harness` のような固定の推測値ではありません。[Adoption Guide](../../adoption-guide.md) 記載のデフォルトのクローン手順に従った場合、その場所は `~/dev/rev_harness_public` になります。

  `uninstall` は `--apply` フラグを**受け付けますが、まだ実装されていません**。渡すと `uninstall --apply: deferred (not yet implemented)` を標準エラーに出力してexit status `2`で終了するだけで、何も削除しません。どちらにせよ得られるのは上の「アドバイザリのみ」のチェックリストです——ハーネスは、あなたのプロジェクトで何を安全に削除できるかを誤って推測するより、正確なリストをあなたに渡すことを選んでいます。**つまり、上のチェックリストを読んだだけでは何もアンインストールされていません。実際に消すのはあなた自身の作業です**——次の節が、その手順を1つずつ示します。

## `install` が実際に作るもの

新規のgitチェックアウトに対して `bash scripts/rev-harness install --target <project>` を実行すると、直接観測できた範囲で以下が作られます。

| パス | 内容 |
|---|---|
| `.shared/project_id` | 不変のプロジェクト識別子(identity)。それ以外のすべてはこれをキーにする。 |
| `.shared/rev-harness-adopter-setup.state.json` | アダプターセットアップのフェーズ追跡用の状態。 |
| `.rev-harness-state/state.json` | `install`/`clean`/`uninstall` のステートマシンとコマンド履歴。 |
| `.rev-harness-state/snapshots/<run-id>/` | インストール実行前に取得された変更前スナップショット。 |
| `.agent/PROJECT_CONTEXT.md`、`.agent/requirements.md` | 生成されたプロジェクトテンプレート。 |
| `.agent/registry/model_policy.json` | コピーされたモデルルーティングポリシー。 |
| `.agent/registry/rev_harness_adoption_state.json` | `.rev-harness-state/state.json` への**シンボリックリンク**であり、別ファイルではない。 |
| `.agent/generated/`、`.agent/active/`、`.agent/archive/`、`.agent/metrics/` | 後のランタイム出力用の空のスキャフォールドディレクトリ。 |
| `.claude/settings.local.json` | インストーラーによってマージされたClaude Codeのローカル設定。 |
| `.claude/settings.local.json.bak.<timestamp>-<pid>` | フックのマージ直前に毎回書き出される `settings.local.json` のバックアップ——`settings.local.json` がまだ存在しない場合も対象で、その場合インストーラーはまず空の `{}` を書き込み、マネージドフックをマージする前にその空ファイルをバックアップする。事前に `.claude/` が存在しないプロジェクトへインストーラーを実際に実行して検証済み: `.bak.*` ファイルは(中身 `{}` で)作成された。 |
| `.claude/tmp/.gitkeep` | スクラッチディレクトリをgitに保持させるためのプレースホルダー。 |
| `.git/hooks/pre-commit` | RevHarnessのガードフック。既にpre-commitフックが存在していた場合は、先に `.git/hooks/pre-commit.rev-harness.bak` へバックアップされる(これが `uninstall` のチェックリスト項目4が探しているバックアップパス)。 |
| `docs/design/.gitkeep`、`docs/manual/.gitkeep`、`docs/requirements/.gitkeep`、`docs/requirements/README.md` | `docs/` 配下の空のスキャフォールドディレクトリ/テンプレート。 |
| `.gitignore` | `.claude/tmp/`、`workspace/`、`*.log`、`.DS_Store`、`.rev_harness/`、`semantic.db`、`semantic.db-wal`、`semantic.db-shm`、`.migration.lock` が追記される(まだ存在しない行のみ)。 |

## 手作業での削除

単一のコマンドはありません。次の順序で行ってください。

1. **ハーネスのスキャフォールドディレクトリとファイルを削除する。** ただし、あなたが既に実コンテンツを書き込んだものは残してください。

   ```bash
   rm -rf .shared .rev-harness-state
   rm -rf .agent/generated .agent/active .agent/archive .agent/metrics
   rm -f .agent/registry/rev_harness_adoption_state.json .agent/registry/model_policy.json
   rm -f .agent/PROJECT_CONTEXT.md .agent/requirements.md
   rm -rf .claude/tmp
   rm -f .claude/settings.local.json.bak.*
   find docs -name '.gitkeep' -delete
   ```

   削除する前に `.agent/PROJECT_CONTEXT.md` と `.agent/requirements.md` の中身を確認してください——実際のプロジェクト内容を書き込んでいた場合は、削除せずに残してください。

2. **pre-commitフックを復元または削除する。**

   ```bash
   if [ -f .git/hooks/pre-commit.rev-harness.bak ]; then
     mv .git/hooks/pre-commit.rev-harness.bak .git/hooks/pre-commit
   else
     rm -f .git/hooks/pre-commit
   fi
   ```

3. **インストーラーが行った `.gitignore` への追記を取り消す。** もう不要なら(ほとんどのプロジェクトにとって単に有用なデフォルトでもあるため、残しておいても問題はありません)。

   ```bash
   sed -i.bak '/^\.claude\/tmp\/$/d;/^workspace\/$/d;/^\*\.log$/d;/^\.DS_Store$/d;/^\.rev_harness\/$/d;/^semantic\.db$/d;/^semantic\.db-wal$/d;/^semantic\.db-shm$/d;/^\.migration\.lock$/d' .gitignore
   ```

4. **`.claude/settings.local.json`** には、プロジェクトごとのClaude Codeの状態が保持されており、インストール後にあなた自身が追加した設定が含まれている場合があります。削除する前に差分を確認してください。

   ```bash
   git diff -- .claude/settings.local.json
   ```

   必要なものが含まれていないと確認できてから、削除するか手で編集してください。

5. **`.shared/project_id`** は、ステップ1を実行済みであれば既に削除されています。同じプロジェクトに対して後で再インストールする予定があり、同じ識別子に状態を紐づけたい場合にのみ、削除をスキップしてください。

6. **CLIを接続する際にシェルのrcファイルへ追加した場合は、ハーネス自身のPATHエクスポートを削除してください。** 固定の推測値ではなく、実際にクローンしたパスに一致させてください([Adoption Guide](../../adoption-guide.md) 記載のデフォルトは `~/dev/rev_harness_public/scripts`)。まず該当行を見つけてから削除してください。

   ```bash
   scripts_dir="$HOME/dev/rev_harness_public/scripts"   # 別の場所にクローンした場合は調整
   grep -n "$scripts_dir" "${HOME}/.zshrc" "${HOME}/.bashrc" 2>/dev/null
   sed -i.bak "\|$scripts_dir|d" "${HOME}/.zshrc"
   sed -i.bak "\|$scripts_dir|d" "${HOME}/.bashrc"
   ```

7. **Cargoのビルド成果物**(`harness-rust/target`、Cargoレジストリキャッシュ)は、アダプター済みプロジェクトのものではなく、あなたのローカルにあるハーネス自身のクローンに属します。ハーネスのクローンごと完全に削除する場合は、通常の方法(`harness-rust/` の中で `cargo clean`、または `rm -rf harness-rust/target`)で削除してください。

`git status` で完了を確認してください。ハーネスが追加したものはすべて、消えているか意図的に残されているかのどちらかになっており、上記のパス以外に変更が生じていないはずです。

次へ: 上記があなた自身のプロジェクトで観測した内容と一致しなかった場合は [Troubleshooting](troubleshooting.md) を参照してください。
