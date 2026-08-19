# Troubleshooting(トラブルシューティング)

English original: [docs/getting-started/troubleshooting.md](../../getting-started/troubleshooting.md)

症状 → 原因 → 修正、の形式です。このページに引用されているメッセージはすべて、本書執筆中に実際のチェックアウトに対して再現させたものであり、記憶からの言い換えではありません。ここに載っていない何かに遭遇した場合は、該当するサブシステムについて `docs/manual/`(英語) を確認するか、関連スクリプトを `die(` やそのエラープレフィックスでgrepしてください。`scripts/` 内のほぼすべてのスクリプトは、スタックトレースではなく、短くgrepしやすいメッセージで失敗します。

---

## macOSで `declare: -A: invalid option` 等の構文エラーが出る

**症状:** スクリプトがほぼ即座に `declare: -A: invalid option` や `syntax error near unexpected token` のようなメッセージで死に、有用なメッセージを出すところまで到達しないことが多い。

**原因:** これがインストール失敗の原因として最も多いものです。macOSはライセンス上の理由(AppleはGPLv3を避けている)で `/bin/bash` をバージョン3.2のまま出荷しています。RevHarnessは複数のスクリプトでbash 4の機能——連想配列(`declare -A`)や `mapfile`——を使っています。bash 3.2上ではこれらは構文エラーになるため、スクリプトは理由を説明する前に死んでしまいます。

ほとんどのエントリーポイントスクリプト(`scripts/rev-harness`、`scripts/harness-doctor.sh`、`scripts/init-project.sh`、`setup/bootstrap.sh`)は、今では自分自身のbashバージョンを先にチェックし、上記の判読不能なエラーの代わりに明確なメッセージで失敗します。

```text
ERROR: this script requires bash >= 4.0 (detected: 3.2.57(1)-release).
macOS ships bash 3.2 by default (/bin/bash). Install a newer bash, e.g.:
  brew install bash
Then re-run this command with the new bash explicitly, e.g.:
  /opt/homebrew/opt/bash/bin/bash scripts/rev-harness ...
```

もし生の構文エラーが表示されている場合は、そのガードをまだ持っていない、さらに奥のスクリプトに到達しているということです。

**修正:**

```bash
brew install bash
```

スクリプトは `#!/usr/bin/env bash` を使っているので、bash 4以上が `PATH` の先頭に来れば自動的にそれが使われます——ログインシェルを変更したり `/bin/bash` を置き換えたりする必要はありません。続行する前に `bash --version` で確認してください。完全な説明は
[Requirements §2](requirements.md#2-bash-40以上実際に足をすくう唯一の要件) を参照してください。

## テストスイートがbash起因の構文エラー、または `FAIL: no bash >= 4.0 found` で失敗する

**症状:** `CONTRIBUTING.md` に載っているコマンド
(`bash test/integration/harness_release_gate.sh --tier quick`、または
`test/integration/harness_release_gate*.sh` / `harness_doctor_quick_test.sh`
/ `native_reviewer_surface_smoke.sh` を直接実行した場合)が、呼び出し先のスクリプトでbash 3.2の構文エラーを起こして死ぬか、あるいは以下のメッセージで失敗する。

```text
FAIL: no bash >= 4.0 found for test execution.
This test suite requires bash 4+ (associative arrays / mapfile
used deeper in the install/doctor/review chain). macOS ships
bash 3.2 as /bin/bash, which cannot run those scripts.
Fix: brew install bash
Or set HARNESS_TEST_BASH=/path/to/bash4+ to point at one explicitly, e.g.:
  HARNESS_TEST_BASH=/opt/homebrew/bin/bash bash test/integration/harness_doctor_quick_test.sh
```

**原因:** これら4つのテストエントリーポイントは、bash 4以上を必要とする別のスクリプトを内部で呼び出します(上の構文エラーの項目と同じ根本原因です)。これらは呼び出し先用のbash 4以上のバイナリを自動検出するため(現在実行中のbash → `PATH` 上の `bash` → よくあるHomebrewのインストール場所、の順に探します)、`/bin/bash` が3.2のままでも、マシンのどこかに新しいbashさえあれば何もしなくても動きます。上記のメッセージは、bash 4以上のバイナリがどこにも見つからなかった場合にのみ表示されます。

**修正:**

```bash
brew install bash
```

インストール後もこのメッセージが出る場合(インストール先が標準的でない場合など)は、`HARNESS_RELEASE_GATE_BASH`(`harness_release_gate.sh` と
`harness_release_gate_tiering_test.sh` 用)または `HARNESS_TEST_BASH`
(`harness_doctor_quick_test.sh` と `native_reviewer_surface_smoke.sh` 用)で明示的に指定してください。

```bash
HARNESS_TEST_BASH=/path/to/bash4+ bash test/integration/harness_doctor_quick_test.sh
```

## `harness-doctor: required command not found: jq`

**症状:** `harness-doctor.sh`(または `rev-harness verify`/`status`)がこの行だけを出してすぐ終了する。

**原因:** `jq` は必須要件です——このリポジトリのすべてのJSON状態ファイルはこれを通して読み書きされます——そしてほとんどのオプションのツールとは違い、macOSでもほとんどのLinuxディストリビューションでも標準搭載ではありません。

**修正:**

```bash
brew install jq        # macOS
sudo apt install jq    # Debian/Ubuntu
```

その後、失敗したコマンドを再実行してください。

## エージェントCLIがログインしていない

**症状:** ラッパー呼び出し(`codex-wrapper.sh`、`claude-wrapper.sh`)が開始し、ロール/モデルのバナーを表示した後、何も出力しないまま、その先のCLI自体が認証エラーやログインエラーで失敗する。

**原因:** RevHarnessはあなたの代わりに認証情報を保存・管理することは一切なく、各ベンダーCLI自身のログイン状態に完全に依存します([Installation → エージェントCLIの接続](installation.md#エージェントcliの接続) 参照)。このマシンでそのCLIにログインしていない場合、ラッパーはそれを呼び出すところまでは進みますが、その先でCLI自体が拒否します。

**修正:** CLIで直接ログインし、ラッパー呼び出しを再試行してください。

```bash
claude    # follow its login flow
codex     # follow its login flow
```

`bash scripts/harness-doctor.sh` はログイン状態を検証しません——ツールとリポジトリの状態をチェックするのであって、認証情報はチェックしません——そのためdoctorがクリーンに通っても、あなたのCLIが認証済みとは限りません。

## `--target` の取り違え: 間違ったチェックアウト、あるいはターゲットなし

関連する2つの症状があります。

**A. `ERROR: refusing self-install (TARGET_ROOT == HARNESS_ROOT == ...)`**

これは、最初のインストール前に知っておくべき最も重要なことです。**現時点の仕様では、クローンしたばかりのそのチェックアウトの中から `--target` なしで `bash scripts/rev-harness install` を実行すると、必ずこのエラーで失敗します**——そのチェックアウトの `scripts/` ディレクトリ自体が、`install` がまさにこれから操作しようとしているディレクトリであり、ハーネスは自分自身をインストール対象として扱うことを明示的に拒否するからです。つまり、Quick Startの3番目のコマンドを、書かれている通り一切変更せずに新規クローンで実行すると、文字通り毎回このエラーが再現します——あなたのマシン固有の問題ではありません。

**修正:** [Installation → 既存リポジトリへの導入](installation.md#既存リポジトリへの導入) にあるパターンを使い、RevHarnessのチェックアウト自体ではないプロジェクトディレクトリを `install` の対象に指定してください。

```bash
cd /path/to/your-project
bash /path/to/rev_harness_public/scripts/rev-harness install --target .
```

本当にRevHarnessとプロダクトコードを同じチェックアウトに置きたい場合は、ハーネスのチェックアウト自体ではなく、空のディレクトリで `git init` してからそのディレクトリに対して `install --target` を実行してください——[First run § 0](first-run.md#0-harness-を設定する) を参照してください。`install` を省略してハーネスのクローン自身の `src/` の中で直接作業する、というサポートされた構成は存在しません。`.shared/project_id` が存在するまで、すべてのラッパー呼び出しは終了コード `70` でfail-closeします。`install` だけがそれを作成します。

**B. 別のチェックアウトにインストールするつもりが、意図しない結果になった**

`--target` が意図した場所を指していない場合——よくあるのは、間違ったカレントディレクトリから解決された相対パスです——`rev-harness` はその意図しない場所に喜んで識別子とhooksをセットアップしてしまいます。これに専用のエラーはありません。修正は、実際に何が起きたかを確認することです。

```bash
bash /path/to/rev_harness_public/scripts/rev-harness status --target /path/you/meant
cat /path/you/meant/.shared/project_id
```

もし識別子が間違った場所に生成されてしまった場合は、そのディレクトリから `.shared/project_id`、`.rev-harness-state/`、そしてそこにインストールされた `pre-commit` フックを削除し、絶対パスで `install --target` を再実行してください。

## `install` が実際に何を作るのか

**症状:** ドキュメントは `install` を抽象的に説明しており(「identity」「hooks」「verification」)、実際にディスク上に何が、どれくらいの量できるのか分かりにくい。

**実測値**: 空のgitリポジトリに対して実際に `install --target <empty-git-repo>` を実行して直接数えた結果、`.git/` を除いて合計26ファイルでした。うち6つが、このページの他の箇所で言及している本質的な成果物です——initフェーズが書く2つ(`.gitignore`、`.shared/project_id`)と、hooksフェーズが書く4つ(`.claude/settings.local.json`、`.git/hooks/pre-commit`、`.agent/registry/model_policy.json`、`.agent/generated/codex_model_policy.runtime.json`)です。残りの約20はほとんどが空の `.gitkeep` プレースホルダーで、`.agent/active/`・`.agent/archive/`・`docs/manual/`・`docs/design/`・`docs/requirements/`・`src/` のディレクトリ骨格を作るものです。加えて、いくつかの生成された初期ドキュメント(`.agent/PROJECT_CONTEXT.md`、`.agent/requirements.md`、`docs/requirements/README.md`)と `.rev-harness-state/` の帳簿があります。一度見てしまえば、この足場は特に大きくも意外でもありません——自分で数を再現したければ、新規インストール後に `find <target> -type f -not -path '*/.git/*' | wc -l` を実行してください。

## プロジェクト内でmodel-policyのランタイム成果物が見つからずdoctorがblockする

**症状:** `install --target <your-project>` の後、そのプロジェクトに対して `harness-doctor.sh` を実行すると次のように報告される。

```text
Blocks:
- generated model policy runtime artifact is missing or unsafe: .agent/generated/codex_model_policy.runtime.json
```

**原因:** `install` は `.agent/registry/model_policy.json` を新規プロジェクトへコピーし、派生したランタイム成果物をローカルで再生成しようとしますが、その再生成ステップ(`scripts/model-policy.sh generate`)自体が `.codex/config.toml` を必要とし、それは軽量なアダプターセットアップには含まれていません。ハーネスが所有するファイル(`scripts/`、`.codex/`、`.agent_rules/`、配布マニフェストの残り)を丸ごと完全同期するのは `rev-harness upgrade` の仕事ですが、この版ではその `apply` アクションは「この土台にはまだ実装されていない(intentionally not implemented in this foundation)」と報告します(`scripts/rev-harness-upgrade.sh --help`)。`upgrade` の `inspect` アクションは読み取り専用で、ターゲット内にどのトップレベルのハーネスパス(`AGENTS.md`、`.agent`、`.claude`、`.codex`、`.shared/project_id`)が存在するかを報告するだけです——ファイル単位の完全なコピー計画までは列挙しません。

**これが何に影響し、何に影響しないか:** ラッパーのロール呼び出し(`codex-wrapper.sh --role ...`)は、デフォルトでRevHarnessのチェックアウト自身からモデルポリシーを読みます(`PROJECT_ROOT` はデフォルトで、あなたのカレントディレクトリではなくラッパースクリプト自身が存在する場所になります)。そのため、あなたのプロジェクト自身のdoctor実行がこのblockを示している間も、これらは引き続き動作します。古い/欠けているのはあなたのプロジェクト*自身*のポリシーのコピーであって、ラッパーが実際に使っているものではありません。

**修正(プロジェクト自身のdoctor実行をきれいにしたい場合):** RevHarnessのチェックアウトから `.codex/config.toml` をあなたのプロジェクトへコピーし、再生成してください。

```bash
cp "$HARNESS/.codex/config.toml" .codex/config.toml
PROJECT_ROOT="$(pwd)" bash "$HARNESS/scripts/model-policy.sh" generate
```

それ以外の場合は、このblockをそのままにして作業を続けても問題ありません——これはあなたのプロジェクトのローカルなハーネス帳簿(bookkeeping)のコピーにおけるギャップを示しているのであって、あなた自身の決定論的チェックが生成する受け入れ証拠のギャップではありません。

## ラッパー呼び出しがモデルの上書きを拒否する

**症状:**

```text
[codex-wrapper] ERROR: REV_HARNESS_CODEX_MODEL=gpt-3.5 is below minimum allowed model gpt-5.5
```

**原因:** これは意図的な、fail-closedの挙動であり、バグではありません。`.agent/registry/model_policy.json` の `minimum_allowed_model` にある最低モデルゲートは、ポリシーのデフォルトに対してと同じように `REV_HARNESS_CODEX_MODEL` の上書きにも適用されます——単に頼まれたからといって、ハーネスがより弱いモデルへ静かに格下げすることはありません。

**修正:** 上書きをやめてポリシーのデフォルトを使うか、`REV_HARNESS_CODEX_MODEL` を `minimum_allowed_model` 以上のモデルに設定してください。現在のfloorを確認するには次のようにします。

```bash
jq -r '.minimum_allowed_model' "$HARNESS/.agent/registry/model_policy.json"
```

ローカルでの反復作業のために本当に弱い/安価なモデルが必要な場合、それは呼び出しごとの上書きではなくポリシー変更です(
[Installation → エージェントCLIの接続](installation.md#エージェントcliの接続) の通り、`model_policy.json` を意図的に編集してください)。

## `flock unavailable; using advisory sentinel lock`

**症状:** `scripts/rev-harness`(または同様の `setsid` に関する警告)からstderrにこの行が表示され、何か壊れているのではないかと思う。

**原因:** 何も壊れていません。macOSは標準では `flock` も `setsid` も搭載していません。RevHarnessはこれを検知して自動的にフォールバックします——`flock` の代わりにアドバイザリなセンチネルロック、`setsid` のプロセスグループ分離の代わりに通常のプロセスspawnです。これはmacOSでの、通常の単一オペレーター利用において劣化した/安全でない状態ではなく、文書化された想定通りの挙動です。

**修正:** 不要です。もし本当に本物の `flock`/`setsid`(たとえばより重い並列dispatchのシナリオ)が欲しい場合は、`brew install util-linux` を実行してその `bin` ディレクトリを `PATH` に追加できますが、これはオプションです。

## pre-commitフックが、触れるとは思っていなかったコミットを拒否する

**症状:** `install` がRevHarnessのpre-commitフックを配線した後、何も機微なところに触れていないように見えるコミットで `git commit` が失敗する。

**原因:** インストールされたフックは、あなたが「チェックしてほしい」と思ったファイルに限定されず、ステージされた差分すべてに対して、毎回のコミットでパスリークガードとシークレットガードを実行します。

**修正:** フックが出力した具体的な却下メッセージを読んでください。問題のあるパスやパターンが名指しされます。もし本当に誤検知(false positive)であれば、フック自身が出す案内に従って `git commit --no-verify` を控えめに使ってください——習慣にはしないでください。同じゲートが、実際に漏れた絶対パスやシークレットも捕まえているからです。コミットせずにフックの状態を確認するには次のようにします。

```bash
bash "$HARNESS/scripts/install-rev-harness-hooks.sh" --status
```

---

それでも解決しない場合は、このページが前提とする内容について [Requirements](requirements.md) と [Installation](installation.md) を読み直すか、言い換えではなく実行した正確なコマンドと出力全体を添えてissueを立ててください。再現できるようにするためです。
