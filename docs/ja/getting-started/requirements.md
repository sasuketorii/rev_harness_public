# Requirements(必要要件)

English original: [docs/getting-started/requirements.md](../../getting-started/requirements.md)

このページに書かれている内容はすべて、想定ではなくソースツリーに対して検証済みです。コードによって強制されている要件については、自分で確認できるよう強制箇所を明記しています。

---

## 1. サポートされるOS

| OS | 状態 | 備考 |
|---|---|---|
| macOS (Apple Silicon / Intel) | サポート | システム標準より新しいbashが必要——§2参照 |
| Linux (Debian/Ubuntu, Fedora, Arch, …) | サポート | 追加作業なし。ディストリ標準のbashが既に4以上 |
| WSL2 (Ubuntu 等) | 動作するはずだが**未検証** | Linuxとして扱われる。WSL固有のコードパスは存在しない |
| Windows (cmd / PowerShell, ネイティブ) | **非サポート** | すべてのスクリプトがPOSIXシェルベース |

このハーネスには**macOS専用のコマンドは含まれていません**(`sw_vers`、`pbcopy`、`osascript` はツリー内のどこにも出てきません)。BSD版とGNU版でツールの挙動が異なる箇所——`stat`、`date`、`readlink`——では、すべての呼び出し箇所が `uname == Darwin` で分岐するか、`command -v` で存在確認してフォールバックするかのどちらかです。

## 2. bash 4.0以上——実際に足をすくう唯一の要件

**これがインストール失敗の原因として最も多く、影響するのはmacOSだけです。**

macOSはライセンス上の理由(AppleはGPLv3を避けている)で `/bin/bash` を **3.2** のまま凍結して出荷しています。このハーネスはbash 4の機能を使っています——`scripts/ci/index-map-check.sh` や `scripts/harness-active-artifact-pruner.sh` の連想配列(`declare -A`)、そして他の複数箇所の `mapfile` です。bash 3.2上ではこれらは**構文エラー**になるため、何か有用なメッセージを出す前にスクリプトが死にます。

手元の環境を確認してください。

```bash
bash --version
```

macOSで3.2と表示された場合は、新しいbashをインストールし、それを `PATH` の先頭に来るようにしてください。

```bash
brew install bash
```

スクリプトは `#!/usr/bin/env bash` を使っているので、`PATH` が最初に見つけたbashを拾います。ログインシェルを変更する必要は**なく**、`/bin/bash` を置き換える必要もありません。

Linuxディストリビューションはbash 4以上(通常5系)を出荷しているため、Linux側では対応不要です。

## 3. 必須のコマンドラインツール

以下の4つは必須(hard-required)です——1つでも欠けていると `scripts/harness-doctor.sh` がfail-closedになります。

| ツール | 用途 | 標準搭載か |
|---|---|---|
| `git` | 全体を通したリポジトリ操作 | macOS: Xcode CLTに付属。Linux: 通常はインストールが必要 |
| `jq` | すべてのJSON状態ファイルはこれを通して読み書きされる | **いいえ**——インストールしてください |
| `awk` | テキスト処理 | 両プラットフォームともあり |
| `sha256sum` **または** `shasum` | 証拠(evidence)とスナップショットのハッシュ検証 | Linuxには `sha256sum`、macOSには `shasum` |

それ以外はすべてオプションで `command -v` によってガードされているため、ツールが1つ欠けてもハーネス全体が壊れることはなく、1つの機能だけが低下します。

| ツール | 何に必要か | 欠けた場合 |
|---|---|---|
| `flock` | 並列dispatch中のロックファイル | ロックがスキップされる(macOSには標準で `flock` がない) |
| `setsid` | バックグラウンドワーカーのプロセスグループ分離 | 通常のspawnにフォールバック |
| `timeout` / `gtimeout` | ラッパーのタイムアウト | タイムアウトの強制がスキップされる |
| `python3` | 一部のヘルパースクリプト | 該当ヘルパーがスキップされる |
| `shellcheck` | 自分のコントリビューションのlint | lintステップがスキップされる |
| `ripgrep` (`rg`) | より高速な検索 | `grep` にフォールバック |
| `sqlite3` | シェル側でのデータベース調査 | 調査用スクリプトがスキップされる |

### 3a. `pytest`——ハーネス本体には不要、first-runチュートリアルには必須

ハーネス本体は `pytest` を一切import・実行しません。上記の必須リストには含まれておらず、`scripts/harness-doctor.sh` もチェックしません。

しかし [first-runチュートリアル](first-run.md) はPythonのテストを書いて実行する手順(ステップ4、`python3 -m pytest -q test_greet.py`)を含みます。このチュートリアルを最後まで実施するつもりなら、`python3` と `pytest` の両方を事前にインストールしてください。

```bash
python3 -m pip install pytest
```

Pythonプロジェクトでハーネスを使わないなら不要ですが、その場合チュートリアルはステップ4で失敗する点に注意してください。

## 4. エージェントCLI

どちらも**インストールはオプション**ですが、実際にエージェント駆動の開発を行うには少なくとも1つが必要です——どちらも入っていない場合、セットアップ時にハーネスが警告します(`setup/bootstrap.sh`)。

| CLI | インストール | 役割 |
|---|---|---|
| Claude Code | `npm install -g @anthropic-ai/claude-code` | オーケストレーターおよびコーダー |
| Codex CLI | `npm install -g @openai/codex` | 独立レビュワー、系統をまたいだ委譲 |
| Cursor CLI | Cursorのドキュメント参照 | 完全にオプション。ラッパーは存在するが依存しているものはない |

ハーネスは認証情報を一切保存しません。各CLI自身のログイン状態、またはそのCLIが読むプロバイダの環境変数に完全に依存しています。このリポジトリのどこにもAPIキーはハードコードされておらず、追加すべきでもありません。

2つの異なるモデルファミリーを使うことは飾りではありません——レビューゲートは、レビュワーが実装者とは*別の*モデルであることを前提に組まれています。すべてを1つのファミリーで済ませると、そのゲートは弱くなりますが、それでも動作はします。

## 5. Rustツールチェーン(オプション)

`harness-rust/` をビルドする場合にのみ必要です。シェル層はこれなしでも動作します。

- 3クレート構成のワークスペース: `agent-core`、`harness-cache`、`shared`
- 固定されたツールチェーンは `harness-rust/rust-toolchain.toml` に記載
- **Cコンパイラが必要**——`rusqlite` は `bundled` 機能を使い、SQLiteをソースからコンパイルするため、macOSではXcode Command Line Tools、Debian/Ubuntuでは `build-essential` が必要

```bash
curl https://sh.rustup.rs -sSf | sh
```

## 6. ディスク、メモリ、ネットワーク

| リソース | 要件 |
|---|---|
| ディスク(チェックアウトのみ) | 約9MB |
| ディスク(Rustのフルリリースビルド込み) | 約1.5GBを見込む——リリースプロファイルはfat LTOを使う |
| メモリ | 明確な下限の実測値なし。通常の開発機であれば問題なし |
| ネットワーク | `git` と、使用するエージェントCLIに必要。ハーネス自身のスクリプトがネットワークに出るのは1箇所だけ: `scripts/model-policy.sh` は、model-policyの変更を公式の裏付けと照合したいと頼んだときにプロバイダのドキュメントを取得する。それ以外は何も外部呼び出ししない |

## 7. ワンショットインストールコマンド

### macOS

```bash
xcode-select --install
brew install bash jq git coreutils ripgrep shellcheck
npm install -g @anthropic-ai/claude-code @openai/codex
```

`coreutils` が `timeout`/`gtimeout` を提供します。`flock` と `setsid` はmacOSでは引き続き欠けたままですが、ハーネスはそれを設計として処理するので、それらを追いかける必要はありません。

### Debian / Ubuntu

```bash
sudo apt update
sudo apt install -y bash jq git build-essential util-linux coreutils ripgrep shellcheck
npm install -g @anthropic-ai/claude-code @openai/codex
```

## 8. 続行前の確認

```bash
bash scripts/harness-doctor.sh
```

これは上記の必須要件をチェックし、何が欠けているかを報告します。非破壊的で、いつ実行しても安全です。

## 9. 言語について、これ以上読み進める前に

このREADMEと `getting-started/` 配下は英語です。ハーネスの規範文書の大半——受け入れ権威である
`docs/manual/verification-truth-matrix.md`、`docs/roles/` 配下のロール定義、
`.claude/CLAUDE-LOCAL.md`、`docs/ja/` 以外の大半のファイル(数百ファイル規模——ファイルの追加・削除で数が変動するため、ここでは正確な数を追跡していません)——は日本語であり、翻訳されていません。
エージェントは既定でユーザーに日本語で応答します(`.agent_rules/shared-language.md` の
`RS-LANG-01` / `RS-LANG-03`)。既定を変えるにはこの2つのルールを編集してください。
セットアップスクリプト(例: `scripts/init-project.sh`)のコンソール出力も日本語です。
全体像は `docs/README.md` を参照してください。

次へ: [Adoption Guide](../../adoption-guide.md)
