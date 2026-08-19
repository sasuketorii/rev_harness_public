---
name: shared-client-wrapper-safety
description: 共有クライアント(DBクライアント、SQLビルダー、tagged template関数など)をラップ・全面変更する前、または横断的な設定値(CSP allowlist、ルーティング規則、権限マトリクス等)をコンポーネントのデフォルト値や代表例だけから設計しようとする前、あるいは本番/デモで理由不明の空表示・サイレント失敗が起きた時に使う。呼び出し箇所の非典型パターン(部分式/断片生成/条件分岐埋め込み/props override)を見逃した一律の変更が引き起こす障害を防止・診断する。
---

# Shared Client Wrapper Safety

共有・横断的に使われる低レベルユーティリティ(DBクライアント、tagged template関数、SQLビルダー、ロガー、fetchラッパーなど)を「関数レベルで一律ラップ」しようとする時、横断的な設定値(CSP allowlist、ルーティング規則、権限マトリクス等)をコンポーネントのデフォルト値だけから設計しようとする時、または本番/デモ環境で原因不明の空表示・サイレント失敗が起きた時に使う。

## 絶対ルール

- **共有ユーティリティを変更する前に、全呼び出し箇所を必ずgrepし、「トップレベル実行」以外の使い方(部分式生成・断片埋め込み・条件分岐埋め込み)がないか確認する。** 1箇所でもそのような非典型パターンがあれば、関数レベルの一律ラップは原理的に安全に実現できないと疑う。
- **横断的な設定値(allowlist、CSPディレクティブ、ルーティング規則等)を、その値を消費するコンポーネントの「デフォルト値」や「代表的な1画面」だけから設計しない。** 実際にその値へ到達する全呼び出し箇所を洗い出し、各呼び出し箇所が渡す実引数(props override、環境変数、条件分岐で選ばれる値)を個別に確認してから設計する。コンポーネント定義側のデフォルト値は「呼び出し側が何も指定しなかった場合の値」に過ぎず、実際に到達可能な画面がそのデフォルトを使っているとは限らない。
- タグ付きテンプレート関数やビルダー/DSLパターンを持つ共有クライアントは、見た目(呼び出しのshape)だけでは「トップレベル実行」と「部分式/断片生成」を区別できないことが多い、という前提で調査する。
- 単体テスト(例: 1パターンの動作確認)が通っても「安全である」の証明にはならない。コードベース全体の非典型的な使用パターンを見逃せば本番障害を防げない。
- デプロイ後はUIスポットチェックだけに頼らず、必ず実サーバー/コンテナの生ログを能動的に確認する。「空表示」「サイレント失敗」はUI上にエラーが出ないため、ログ確認が最も確実な一次情報源。
- 原理的に安全に実現できないと判明した機能追加は、無理に部分適用で残さず安全側(全面撤回)に倒す。ただし撤回した理由・既知の制約は必ずコード内コメントに残す。

## 起動条件

- postgres.js の `sql` のような tagged template 関数、SQLビルダー、ORMのクエリオブジェクト、GraphQLクライアントなど「共有クライアント」をラップ・デコレート・monkey-patchしようとしている。
- `statement_timeout` 強制、リトライ、ロギング、トレーシングなど横断的関心事を、共有クライアントの呼び出し全体に一律適用しようとしている。
- **CSPのconnect-src/img-src、CORS allowlist、ルーティングテーブル、権限マトリクスなど、複数の呼び出し箇所が共有する「許可リスト」や「設定値」を設計・変更しようとしている。** 特に、その値がコンポーネントの「デフォルトprops」から逆算できると考えている時ほど、実際の呼び出し箇所を疑う。
- 本番/デモ環境で、DBアクセスを伴う特定のロール・ページ・一覧画面だけが空表示になる、エラーは出ないがデータが返らない、といったサイレント失敗を調査している。
- デプロイ後の動作確認をUIのスポットチェックだけで済まそうとしている。

## 危険パターンの具体例その1: SQL fragment embedding

postgres.js(porsager)の `sql` タグ付きテンプレートには二重用途がある。

```ts
// (a) トップレベル実行: これは実際にクエリとして実行される
const rows = await sql`select * from clients where id = ${id}`;

// (b) 断片生成: これは実行されない。外側の sql`...` に埋め込むための
//     Fragmentオブジェクトを作るためだけに sql`` を呼んでいる
const rows = await sql`
  select * from clients c
  where ${isAdmin ? sql`true` : sql`c.id = any(${assignedClientIds}::uuid[])`}
`;
```

`sql\`true\`` や `sql\`c.id = any(...)\`` はそれ自体が実行されるクエリではなく、外側のテンプレートリテラルの `${}` に埋め込まれるための軽量なFragmentを作るためだけに呼ばれている。

もし `sql` を関数レベルで一律ラップし、「呼ばれたら独立トランザクションでトップレベル実行する」実装(例: `sql.begin(async tx => { await tx.unsafe('SET LOCAL statement_timeout = ...'); return tx(strings, ...values); })`)にすると、内側の `sql\`true\`` 呼び出しまでもが「独立した完全なクエリ」として実行されようとし、`"true"` という文字列を単独のSQL文として実行してPostgres構文エラー(`syntax error at or near "true"`, error code 42601)になる。

この二重用途は postgres.js に限らない。SQLビルダーのフラグメント合成、GraphQLクエリの部分式合成、テンプレートエンジンの部分テンプレートなど、共有クライアント/DSLパターンには一般的にありうる注意点として扱う。他のDSL/SQLビルダー/GraphQLクライアントでも、断片生成メソッド呼び出しを探す一般形のgrepパターンで同種の非典型パターンを洗い出せる。

```bash
# <client変数名>を対象の共有クライアント名に置き換えて、断片生成っぽい呼び出しを洗い出す
grep -rn '\${.*<client変数名>`\|<client変数名>\.\(fragment\|raw\|gql\)' src
```

### 変更前に必ず行う調査コマンド例

```bash
# 対象の共有クライアント変数(例: sql)への全呼び出しを洗い出す
grep -rn '\bsql`' src --include='*.ts'

# 「他のsqlテンプレートの${}の中で使われている」= 断片生成パターンの疑いがある箇所を絞り込む
grep -rn '\${.*sql`' src --include='*.ts'

# 条件分岐で異なるsql`...`断片を切り替えている箇所(最も危険)
grep -rn '?\s*sql`\|:\s*sql`' src --include='*.ts'
```

1ファイルだけ特殊な使い方をしているケースもあるため、grep結果は1件ずつ「トップレベル実行かどうか」を目視確認する。

## 危険パターンの具体例その2: コンポーネントのデフォルト値だけを見た横断設定値の設計

共有コンポーネント(例: 地図コンポーネント、リッチテキストエディタ、決済ウィジェット)が「デフォルトのprops」を持っていると、そのデフォルト値だけを見て「このコンポーネントが到達する外部originはこれだ」と判断してしまいがちだが、実際に各画面がそのデフォルトを上書きしていないかは、コンポーネント定義を読むだけではわからない。

```tsx
// map.tsx: デフォルトstyleを持つ共有コンポーネント
export function Map({ styles = { light: DEFAULT_LIGHT, dark: DEFAULT_DARK }, ...props }) { ... }

// order-detail-1.tsx: デフォルトを明示的にoverrideしている
<Map styles={{ light: "https://tiles.openfreemap.org/styles/liberty", dark: "..." }} />
```

CSPの `connect-src` をこのコンポーネントのために設計する際、`map.tsx` のデフォルト値(`DEFAULT_LIGHT`/`DEFAULT_DARK` のorigin)だけを見て allowlist を組むと、実際にブラウザが到達する `tiles.openfreemap.org` が漏れる。デフォルト値は「呼び出し側が指定しなかった場合の値」であって、「実際に到達可能な画面が使う値」ではない。

### 変更前に必ず行う調査コマンド例

```bash
# 対象コンポーネントへの全呼び出し箇所を洗い出す
grep -rln '<Map\b' src --include='*.tsx'

# 各呼び出し箇所がpropsをoverrideしているかを個別に確認する
grep -n 'styles=' src/components/**/*.tsx

# 実際に到達するoriginを、コードのgrepだけでなく実測でも確認する
# (例: 発見したstyle.jsonを実際にfetchし、そのsources/glyphs/spriteが
#  想定と同じoriginに収まるかを確認する)
curl -s https://tiles.openfreemap.org/styles/liberty | jq '.sources, .glyphs, .sprite'
```

grepで見つけた「呼び出し箇所の実引数」は、可能な限り実測(実際のレスポンス取得、実際のブラウザでの動作確認)で裏取りする。コード上の文字列一致だけでは、そのURLが実際に到達可能かまでは保証できない。

## デプロイ後の必須手順

UIのスポットチェックだけでは不十分。以下を必ず実施する。

```bash
# 本番/デモコンテナの生ログを直接確認する
ssh <host> 'docker logs <container> --since 30m'

# エラーコードやキーワードで絞り込む(Postgres構文エラーの例)
ssh <host> 'docker logs <container> --since 30m' | grep -i 'syntax error\|42601\|error'
```

「空表示だがUIにエラーは出ない」系の障害は、アプリ側で例外を握りつぶしていることが多く、ログ確認だけが確実な一次情報源になる。CSPのような「壊れるとブラウザのコンソールにしかエラーが出ない」変更も同様に、デプロイ後は実際に `curl -I` でヘッダーを確認し、可能ならブラウザのコンソールエラーも確認する。

## 空表示/サイレント失敗の診断手順(この順序で行う)

1. **データロスの確認**: DBに直接クエリして、そもそもデータ自体が消えていないかを確認する。
2. **クエリロジックの単体検証**: 疑わしいクエリ/関数を単体で(実際の認証情報を使うスタンドアロンスクリプトなどで)個別に再現テストする。ここで問題なさそうに見えても、まだ安全とは判断しない。
3. **実ログの確認(決定打)**: 本番/デモコンテナの生ログを確認し、実際に何が実行されエラーになっているかを確認する。UIのスポットチェックだけでは原因特定に至らないことが多く、ログ確認が最終的な決定打になる。

## 必須アウトプット

共有クライアントのラップ/変更、または横断的な設定値の設計を提案・実装する際は、以下を明示する。

```text
変更対象: <共有クライアント/関数名、または横断的設定値(allowlist等)>
grep結果: <全呼び出し箇所の件数と、非典型パターン(断片生成/条件分岐埋め込み/props override)の有無>
安全性判定: <一律適用可能 / 不可(理由) / 部分適用のみ可能(適用範囲を明記)>
検証方法: <単体テストの内容と、それが「安全」を証明しないことの認識。設定値の場合は実測(curl等)で裏取りしたか>
デプロイ後確認: <ログ確認コマンドとチェックしたエラーパターン、またはヘッダー実測コマンド>
既知の制約: <安全に実現できず撤回した場合、コード内コメントに残す内容>
```

## ケーススタディ: Supavisor statement_timeout 撤回インシデント

- **症状**: Next.js + postgres.js(porsager) + Supabase(Supavisorプーラー)構成の本番デモ環境で、`/clients` 一覧がAdmin/Editor/Viewer全ロールで空表示になった。
- **背景**: Supavisor(トランザクションモードpooler)は `statement_timeout` などStartupMessageの追加パラメータを後段の物理接続へ伝播しない制約がある(`current_setting('application_name')` が常に `'Supavisor'` を返すことで実測済み)。この対策として `getSql()` の `sql` を `wrapWithStatementTimeout()` でラップし、全呼び出しを `sql.begin(async tx => { await tx.unsafe('SET LOCAL statement_timeout = ...'); return tx(strings, ...values); })` という独立トランザクションに包んだ。`pg_sleep(12)` が10秒でキャンセルされることを確認し、単体では正しく機能した。
- **根本原因**: `get-client-directory.ts` だけが `where ${isAdmin ? sql\`true\` : sql\`c.id = any(${session.assignedClientIds}::uuid[])\`}` というSQL fragment embeddingパターンを使っていた。`wrapWithStatementTimeout` は `sql` へのあらゆる呼び出しをトップレベル実行として扱うため、`sql\`true\`` が独立トランザクションを開始し、`"true"` を単独のSQL文として実行しようとして構文エラー(42601)になった。
- **診断の決定打**: `ssh <vps> 'docker logs <container> --since 30m'` で `syntax error at or near "true"`/`"c"` (error code 42601)のログを大量に発見し、そこから逆算して原因を特定した。UIのスポットチェックだけでは特定できなかった。
- **修正**: postgres.js内部では、トップレベル実行用の呼び出しと断片生成用の呼び出しを区別する方法がなく、同一の `sql` を両方の用途で使うコードが1箇所でも存在する限り関数レベルの一律ラップは安全に実現できないと判断し、`wrapWithStatementTimeout` を完全に撤回した(コミット `ea3fd6b`)。修正後は実際の認証情報を使ったスタンドアロン検証スクリプトでadmin/非adminの両分岐を再現テストし、dual-reviewerのLGTMを得てデプロイ、デプロイ後に再度VPSログで構文エラー0件、ブラウザで `/clients` が正しく表示されることを確認して完了とした。
- **教訓**: 「動くことを確認した」は「安全である」の証明にならない。共有ユーティリティの全呼び出し箇所を事前にgrepしていれば、この事故は未然に防げた可能性が高い。

## ケーススタディ: CSP connect-src のMapLibreデフォルトorigin誤り(2ラウンドにわたる見落とし)

- **状況**: Next.js + Cloudflare Workers(OpenNext)構成のアプリに、初めてContent-Security-Policyを追加する作業。共有地図コンポーネント `src/components/ui/map.tsx` は `basemaps.cartocdn.com` をデフォルトstyleとして持っていた。
- **1回目の見落とし(Codexレビュー1回目で発覚)**: `connect-src` の設計時、`map.tsx` のデフォルトstyleのorigin(CARTO)だけを見てallowlistを組んだが、MapLibre GL JSがタイルデコード用に `blob:` Web Workerを生成する点(`worker-src`)を見落とし、実際にマウントされる3画面(`order-detail-1`/`customer-detail-1`/`shipment-detail-1`)でMapLibreが機能しなくなるはずだった。
- **2回目の見落とし(Codexレビュー2回目で発覚、より本質的)**: 1回目の指摘を受けて`connect-src`/`worker-src`を修正したが、依然として `map.tsx` のデフォルトstyle(`basemaps.cartocdn.com`)だけを根拠にoriginを設計していた。実際には、地図を使う3画面はすべて `styles={{ light: "https://tiles.openfreemap.org/styles/liberty", dark: "..." }}` という明示的なprops overrideを持っており、ブラウザが実際に到達するoriginは `tiles.openfreemap.org` であって `basemaps.cartocdn.com` ではなかった。この事実は、コンポーネント定義(`map.tsx`)を読むだけでは絶対にわからず、3画面それぞれの呼び出し箇所を実際に`grep`して初めて判明した。
- **修正**: `grep`で3画面の`styles=`propsを確認し、さらに実際に`https://tiles.openfreemap.org/styles/liberty`を`curl`で取得して、その`sources`/`glyphs`/`sprite`がすべて同一origin(`tiles.openfreemap.org`)に収まることを実測確認してから、`connect-src`に正しいoriginを追加した。`map.tsx`自身のデフォルト(CARTO)は「将来呼び出し側がoverrideを省略した場合の安全網」として維持しつつ、ワイルドカードではなく確認済みの2ホストに絞った。
- **教訓**: 「共有コンポーネントのデフォルト値」は「実際に到達可能な画面が使う値」の代理にならない。横断的な設定値(allowlist、CSP等)を設計する際は、その値を消費する全呼び出し箇所を`grep -rln`で列挙し、各呼び出し箇所の実引数(propsのoverride)を個別に確認してから設計する。可能なら実際のレスポンス(この場合はstyle.json)を取得して実測で裏取りする。この失敗はSQL fragment embeddingのケーススタディと構造的に同型(「代表例/デフォルトだけ見て、全呼び出し箇所を見ていない」)であり、共有クライアントに限らずコンポーネントのprops設計や設定値設計全般に適用される教訓として扱う。
