# Cursor CLI Integration (round 5)

date: 2026-05-21

RevHarness は Claude Code と Codex に加え、**Cursor CLI** (binary: `agent`) を 3 つ目の orchestration target としてサポートします。本ドキュメントは Cursor 統合の正本です。

## 立ち位置

| Vendor | Wrapper | 主用途 | Default model surface |
|---|---|---|---|
| Claude Code | `scripts/claude-wrapper.sh` (deprecated 2026-07-14) | top-level orchestrator (Claude native) | claude opus/sonnet |
| **Codex** | `scripts/codex-wrapper.sh` | mid/heavy coder + reviewer 固定 | gpt-5.6-sol (effort: medium/high/xhigh) |
| **Cursor (新)** | `scripts/cursor-wrapper.sh` | **read-only Q&A / 軽量 edit / 自動化 lane** (role: ask / agent / yolo) | composer-2.5 などの Cursor 提供モデル (model 選択は Cursor 側) |

Cursor は **軽量タスクのためのコスト/速度最適 lane** として位置付け、Codex の coder/high-coder/reviewer/research を置き換えるものではありません。"composer" は Cursor が内部で選ぶ model 名の一つであって wrapper の role 名ではありません (role は `ask` / `agent` / `yolo` の 3 種)。

## Safety model (Cursor 公式 docs に基づく — round 1 で誤認していた点)

`https://cursor.com/docs/cli/reference/parameters` に基づく Cursor CLI の実際の semantic:

- **`agent -p` (default agent mode)** は "**Has access to all tools, including write and shell**"。proposal-only ではない。デフォルトで write/shell ツールにフルアクセス。
- **`--force` / `--yolo`** は "**Force allow commands unless explicitly denied**"。これは **command auto-approval** であり、file-write の gate ではない。
- **`--mode ask`** が Cursor が公式に保証する唯一の **true read-only** モード。

Round 1 では `composer` role を proposal-only と主張していたが、これは誤り。Round 2 で role 名を Cursor 公式 mode 用語に align し、false advertising を排除した。

## Round 5 integration with Cursor official rules system

Round 5 adds the Cursor rules layer to the existing wrapper contract without replacing the wrapper safety model.

Cursor official docs state that project rules live under `.cursor/rules`, and the Cursor CLI also reads project-root `AGENTS.md` and `CLAUDE.md` when present and applies them alongside `.cursor/rules`:

- https://docs.cursor.com/en/cli/using
- https://docs.cursor.com/en/context/rules

RevHarness uses a two-layer attach model:

| File | Attach role | Responsibility |
|---|---|---|
| `AGENTS.md` | vendor-neutral root instruction | Cross-agent invariants only: acceptance authority, evidence, secret redaction, delegation boundaries, change discipline |
| `.cursor/rules/revharness-critical.mdc` | always-attached Cursor project rule | Fail-closed invariants Cursor must not miss: truth matrix authority, scope discipline, no secret leakage, wrapper boundaries |
| `.cursor/rules/revharness-detailed.mdc` | description-based Cursor project rule | Operational guidance that should be attached when Cursor is working on RevHarness orchestration, docs, wrappers, tests, or rules |

`revharness-critical.mdc` is intentionally small and strict. `revharness-detailed.mdc` can carry longer operational guidance without making every Cursor context heavier. `CLAUDE.md` remains the vendor-neutral bootstrap for Claude-compatible readers, while `.claude/CLAUDE-LOCAL.md` remains the Claude-specific rule surface.

Round 5 also adds dual telemetry to cursor wrapper invocations:

- `cursor_rules_files_present`: wrapper-time check that the expected root/rules inputs are present (`AGENTS.md` and `.cursor/rules/revharness-critical.mdc` in the current wrapper implementation).
- `cursor_rules_selfcheck_status`: reserved enum self-check field. Round 5 emits `"unimplemented"`; future probes may emit `"passed"` or `"failed"`. The deterministic `.mdc` frontmatter validation remains in `test/unit/test-cursor-rules-frontmatter.sh`.

These fields prove local rule-file availability and preserve a metric slot for self-check status. They do not prove that a live Cursor model honored the instructions; that remains a residual risk and requires a live smoke.

Outbound deny is a separate hardening layer in `_outbound-deny.sh`. It is sourced by Codex/Claude wrapper paths and uses a parent-process walk to reject calls that originate from Cursor before they can invoke those other wrappers. Cursor itself is not blocked from running; the guard prevents Cursor from escalating into Codex/Claude wrapper lanes.

For `--role ask`, the wrapper records a pre/post git snapshot and fails if the read-only ask path changes the worktree. This ask diff gate is a wrapper-level defense because the Cursor CLI flag alone is not treated as sufficient evidence of write enforcement.

## Cursor Agent Skills Integration

Cursor Agent Skills are a separate official mechanism from always-attached rules. Rules are best for session-wide invariants and operational guidance; Skills are task-specific capability bundles that an agent can discover or invoke when the skill's `name` / `description` matches the work.

RevHarness already has a Cursor-visible skill asset base:

| Path | Role in RevHarness | Cursor relevance |
|---|---|---|
| `.agents/skills/<slug>/SKILL.md` | Cross-platform project-level skill projection | Project-level Agent Skills discovery path |
| `.claude/skills/<slug>/SKILL.md` | Claude Code provider projection | Cursor legacy compatibility path per the docs cited for this slice |
| `.cursor/skills/` | Cursor canonical project-level path | Reserved for direct Cursor provider projection or parity copies |

The current checkout contains 32 `SKILL.md` files in `.agents/skills/` and the matching 32 files in `.claude/skills/`, including `cursor-caller`, `production-function-implementer`, and `staff-code-reviewer`. Their frontmatter follows Cursor's skill shape: a fenced YAML block with `name:` and `description:`. `test/unit/test-cursor-skills-compliance.sh` deterministically checks both provider trees for frontmatter fences, required fields, parent-folder name parity or documented compatibility aliases, lowercase names, and non-empty descriptions.

`.cursor/skills/` is intentionally present even though it is not yet populated with direct skill copies. If a future round writes `SKILL.md` files there, it must preserve provider parity with `.agents/skills/` and pass the same frontmatter compliance checks. This avoids creating a Cursor-only skill drift path.

Rules and Skills are split by attachment semantics:

| Surface | Use for |
|---|---|
| `AGENTS.md` + `.cursor/rules/*.mdc` | Fail-closed invariants, root read order, wrapper boundaries, secret redaction, evidence discipline |
| `.agents/skills/` / `.claude/skills/` / `.cursor/skills/` | Specialized workflows such as `cursor-caller`, `production-function-implementer`, `staff-code-reviewer`, deployment guards, and language knowledge packs |

This PR does not prove that `cursor-agent -p` injects project skills in every live Cursor runtime. That remains a live-smoke residual because official docs and current public reports distinguish deterministic file format support from runtime slash-menu / print-mode behavior.

## Roles (Cursor 公式 mode に align)

| Role | wrapper が agent に渡す argv | 実挙動 |
|---|---|---|
| `ask` (default) | `-p --output-format text --mode ask` | **真の read-only**。file write / shell exec しない |
| `agent` | `-p --output-format text` | default agent mode。write/shell 可。各 command は Cursor 側で個別承認 prompt |
| `yolo` | `-p --output-format text --force` | agent + command auto-approval。**書き込み制御ではない**、危険、明示 opt-in 専用 |

`ask` を default にした理由: 唯一 hard-guaranteed な read-only path のため、保守的 default は安全側。書きたい場合は explicit opt-in (`--role agent` or `--role yolo`) を要求。

## Invocation contract

```bash
# Default (read-only)
cat prompt.md | scripts/cursor-wrapper.sh --role ask --stdin > answer.md

# Standard write-capable
cat prompt.md | scripts/cursor-wrapper.sh --role agent --stdin > output.md

# Full automation (command auto-approval、書き込み可)
cat prompt.md | scripts/cursor-wrapper.sh --role yolo --stdin > output.md

# 0-cost validation
scripts/cursor-wrapper.sh --role ask --dry-run
```

`--stdin` は必須 (argv-prompt mode はサポート外)。wrapper は内部で `agent -p ... "$(cat -)"` に置き換えます。

`--role` を 2 回以上指定すると **role escape 拒否** で fail-closed。

## Delegation metric

各 invocation で `REV_HARNESS_DELEGATION_METRIC` JSONL を stderr に 1 行 emit:

```json
{
  "schema_version": 1,
  "delegation_id": "<uuid>",
  "timestamp": "2026-05-21T...",
  "wrapper_role": "cursor-ask",
  "vendor": "cursor",
  "specialty": null,
  "canonical_role": null,
  "manifest_hash": null,
  "exit_code": 0,
  "duration_ms": 1234,
  "tokens_in": null,
  "tokens_out": null,
  "total_tokens": null,
  "dry_run": false,
  "specialty_status": "none",
  "cursor_force_flag": "",
  "cursor_mode": "ask",
  "cursor_rules_files_present": true,
  "cursor_rules_selfcheck_status": "unimplemented"
}
```

- `vendor: "cursor"` で Codex / Claude metrics と区別
- `cursor_mode`: `"ask"` for `role=ask`、その他 empty
- `cursor_force_flag`: `"--force"` for `role=yolo`、その他 empty。**command 承認動作の記録であり、write permission の記録ではない**
- `cursor_rules_files_present`: expected root/rules inputs の存在確認結果
- `cursor_rules_selfcheck_status`: self-check enum slot。round 5 では `"unimplemented"`、future probe は `"passed"` / `"failed"`
- `tokens_*` は null (Cursor stderr の token report 仕様が公式 docs で未確立、parser は将来追加)
- `scripts/collect-delegation-metrics.sh` は既存 schema 互換のまま aggregate 可能 (新 field は ignored)

## Auth / 認証

Cursor CLI 認証は **wrapper 外で完結** します。

```bash
# 初回 (interactive)
~/.local/bin/agent login
```

wrapper は authentication を駆動せず、不認証時は Cursor 側の error を素通しします (fail-closed 経路には載せません)。

## Fail-closed conditions

- `agent` binary 不在: `$HOME/.local/bin/agent` → `/usr/local/bin/agent` → `$PATH` を順に探索、全て不在で exit non-zero
- 未知 role: `ask | agent | yolo` のみ受理
- `--role` 2 回以上指定: role escape として reject
- `--stdin` 不在の non-dry-run invocation: reject
- SIGINT / SIGTERM 受信時: child agent process に signal forward + exit 130
- vendoring 検出: canonical guard が `REV_HARNESS_CANONICAL_ROOT` 不一致で exit 70 (Codex/Claude wrapper と同じ)
- `--role ask` の pre/post git snapshot で worktree diff を検出: read-only violation として reject
- Cursor rules files missing: expected root/rules inputs の presence metric を false として emit
- Cursor-origin process が Codex/Claude wrapper を呼ぼうとした場合: `_outbound-deny.sh` が parent-process check で reject

## Tests

`test/unit/test-cursor-wrapper.sh` (**30 件 PASS、round 5**):

Role resolution:
1. help renders
2. default role ask
3. ask / agent / yolo dry-run validates (×3)
6. unknown role rejected
7. **duplicate `--role` rejected** (role escape guard、Codex round 1 amendment)

Metric schema:
8. exactly 1 metric per invocation
9. `REV_HARNESS_METRICS_DISABLE=1` suppresses
10. ask metric: `cursor_mode=ask`
11. yolo metric: `cursor_force_flag=--force`, `cursor_mode=""`
12. agent metric: no `--force`, no `--mode` (default agent mode)

**Argv assertions** (Codex round 1 amendment、fake fixture が argv をログして検証):
13. ask passes `--mode ask`, no `--force`
14. agent has neither `--mode` nor `--force`
15. yolo passes `--force`, no `--mode`
16. `-p` and `--output-format text` are always passed
17. stdin prompt is forwarded as the positional arg to agent

Process semantics:
18. real fake-agent invocation succeeds
19. wrapper propagates fake-agent exit code 3
20. missing agent binary fail-closed
21. `--stdin` omitted on real invocation rejected

Signal + vendoring (round 3 で追加):
22. SIGINT/SIGTERM trap が wrapper source 上に登録され、`exit 130` まで wired (trap registration regression、real-signal の OS/bash version 依存 timing を避ける)
23. `forward_signal` が受信 signal を `METRICS_CHILD_PID` へ propagate (signal forwarding wiring 確認)
24. vendoring guard が non-canonical `REV_HARNESS_CANONICAL_ROOT` で `VENDOR GUARD` を出して exit non-zero (cursor wrapper 固有の dedicated case)

Round 5 rules + ask hardening:
25. Cursor rules files present metric is emitted
26. Cursor rules self-check metric is emitted as `"unimplemented"` for round 5
27. missing `AGENTS.md` emits `cursor_rules_files_present=false`
28. `--role ask --dry-run` skips the read-only diff gate
29. `--role ask` pre/post git snapshot rejects write drift
30. `--role agent` does not trigger the ask-only diff gate

Additional round 5 regression:

- `test/unit/test-outbound-deny.sh` (**13 件 PASS**) validates Cursor-origin outbound denial for Codex/Claude wrapper paths, non-Cursor allowance, and that generic `agent` process names do not false-positive.
- `test/unit/test-cursor-rules-frontmatter.sh` (**18 件 PASS**) validates deterministic `.mdc` frontmatter shape for RevHarness Cursor rules.
- `test/unit/test-cursor-skills-compliance.sh` validates Cursor Agent Skills frontmatter compliance for `.agents/skills/` and `.claude/skills/`.
- `test/integration/root_instructions_test.sh` validates the root instruction split across `AGENTS.md`, `CLAUDE.md`, and vendor-specific local files.

Fake fixture `test/fixtures/fake-cursor/agent` は CI 0-cost で wrapper の挙動を検証するため。**Cursor 公式 semantic に正しく align**: default print mode は write/shell capable、`--mode ask` だけが read-only、`--force` は command auto-approval。Test hooks: `FAKE_CURSOR_EXIT_CODE`, `FAKE_CURSOR_EMIT_STDERR=1`, `FAKE_CURSOR_ARGV_LOG=<path>` (argv 記録)。

`test/integration/harness_release_gate.sh` の **LOCAL + FULL** tier に `cursor_rules_root`、`cursor_rules_frontmatter`、`cursor_outbound_deny`、`cursor_skills_compliance`、および既存 `cursor_wrapper` step が wire-in されており、これらの tier で Cursor rules / skills / wrapper regression を catch。`quick` tier は cursor wrapper を含みません (quick は metrics smoke + harness doctor 程度の最小スコープ)。

## Round 5 で意図的 out-of-scope

- **live cursor smoke**: 実機 Cursor CLI が `.cursor/rules/` / `AGENTS.md` / `CLAUDE.md` を honor することの検証は orchestrator が別途実行する。
- **Enterprise Hooks beforeShellCommand allowlist**: Cursor Enterprise plan 必須機能のため base contract には含めない。sample / opt-in は後続 round。
- **token metrics parsing**: Cursor stderr の token report 形式が公式 docs で未確立。後続 round で追加。
- **live Cursor skills smoke**: local `SKILL.md` compliance は検証済みだが、`cursor-agent -p` で Skills が context injection される live behavior は未検証。
- **specialty 統合**: Codex の specialty (production-function-implementer 等) と同等の wrapper flag lens system は cursor wrapper には未導入。ただし Agent Skills としての projection は Cursor discovery path に載る。
- **classifier auto-routing への 3-vendor 追加**: `scripts/rev-harness-task-classifier.sh` への 3-vendor routing 追加は別 PR。orchestrator が `--role` を明示的に選ぶ運用。
- **`--output-format json|stream-json`**: wrapper は `text` 固定。
- **`--sandbox enabled|disabled`** 制御: wrapper は cursor default に任せる (`--sandbox` の明示制御は後続)。

## Round 1 → Round 2 → Round 3 → Round 5 修正履歴

### Round 1 → Round 2 (Codex BLOCK 7.5/10 → LGTM 9.0/10)

Round 1 の grading で Codex (reviewer role, `xhigh` reasoning effort) が **BLOCK** verdict + 5 amendment を出し、それを全て取り込んで round 2 を構築:

1. **Role rename**: `composer/coder/ask` → `ask/agent/yolo` (Cursor 公式 mode 用語に align)
2. **`composer` proposal-only 主張削除**: `agent -p` は default で write/shell 可能なので false advertising だった
3. **`--allow-edits` 廃止**: `--force` は file-write gate ではなく command auto-approval。混同を避けるため flag そのものを廃止
4. **`yolo` role 明示**: `--force` を明示 opt-in する形に再設計
5. **duplicate `--role` reject**: codex-wrapper.sh と同じ role-escape guard
6. **Argv assertion test 追加**: fake fixture が argv をログ、test が `--mode ask` / `--force` / `-p` の経路を実確認
7. **Fake fixture を Cursor 真 semantic に修正**: `--force` を command auto-approve として扱い、`--mode ask` を read-only として扱う
8. **Signal handling**: SIGINT/SIGTERM の child forward + exit 130 (codex-wrapper.sh と整合)
9. **Release gate に wire-in**: `harness_release_gate.sh` で cursor wrapper test の regression catch

### Round 2 → Round 3 (Codex BLOCK 9.0/10 docs axis 8.4 → LGTM 9.0+/10 target)

Round 2 で Codex は 4/5 axis ≥9.0 PASS、docs axis のみ 8.4/10 で BLOCK。指摘された stale residue + 追加 regression を round 3 で解消:

1. Title `(round 1)` → `(round 2)`、date `2026-05-20` → `2026-05-21`
2. Vendor table cell の `lightweight composer / ask` → `read-only Q&A / 軽量 edit / 自動化 lane (role: ask / agent / yolo)`。"composer" は Cursor 内部 model 名であって wrapper role 名ではない、と明記
3. Metric sample の `wrapper_role: "cursor-composer"` → `"cursor-ask"`、`cursor_mode: ""` → `"ask"`、timestamp も round 3 日付に更新
4. Release gate 記述の "全 tier (quick / local / full)" → "LOCAL + FULL のみ"
5. Decision table に "Reviewer LGTM / deterministic checks が必要な場合は Codex coder + production-function-implementer に戻す" 行を追加
6. **Binary name portability note** 新規 (公式 `cursor-agent` vs alias `agent` + `CURSOR_WRAPPER_AGENT_BIN` 明示)
7. **Signal forwarding regression test** + **vendoring guard dedicated test** を追加 (21 → 24 PASS)
8. 本セクション (round 3 履歴 + test 22-24 documentation) を追加

### Round 3 → Round 5 (Cursor rules integration + residual risks officialization)

Round 5 は Cursor CLI wrapper の既存 role semantic を維持したまま、公式 rules system と RevHarness の root instruction contract を接続:

1. Title を `(round 5)` に更新し、`AGENTS.md` + `.cursor/rules/revharness-critical.mdc` + `.cursor/rules/revharness-detailed.mdc` の二段 attach を明文化
2. Cursor CLI が `AGENTS.md` / `CLAUDE.md` / `.cursor/rules` を読む公式 docs link を追加
3. critical rule と detailed rule の責務分担を fail-closed invariant / operational guidance として固定
4. delegation metric に `cursor_rules_files_present` と `cursor_rules_selfcheck_status` を追加
5. `_outbound-deny.sh` の scope を明文化: Codex/Claude wrapper 側の parent-process check、Cursor 自身は対象外
6. `--role ask` の pre/post git snapshot diff gate を wrapper-level read-only defense として記録
7. Cursor rules residual risks を新設し（当時は別ファイル、2026-08-19 に本ファイルの
   `## Cursor Rules Residual Risks` section へ統合）、公式 docs で未保証な領域と本 PR の対応範囲を固定

### Round 5 → Round 2 BLOCK fix (Cursor Agent Skills + hardening amendments)

Codex r1 grading は wrapper enforcement / tests / docs residual risk を BLOCK。Round 2 fix では user critique の核心だった Cursor Agent Skills を明文化し、同時に wrapper/test hardening を追加:

1. nullable bool self-check field を `cursor_rules_selfcheck_status: "unimplemented"` enum に変更し、pseudo-pass に見える nullable bool を排除
2. `_outbound-deny.sh` の match を `cursor-agent` のみに tighten し、generic `agent` process name の false positive を防止
3. ask diff gate の write-simulation cleanup を top-level `trap` で保護
4. `.cursor/skills/` canonical directory を追加し、`.agents/skills/` / `.claude/skills/` が Cursor Agent Skills discovery 対象であることを docs に明記
5. `test/unit/test-cursor-skills-compliance.sh` を追加し、`SKILL.md` frontmatter compliance と sample skill の precise parent/name parity を deterministic check 化
6. LOCAL + FULL release gate に `cursor_rules_root`、`cursor_rules_frontmatter`、`cursor_outbound_deny`、`cursor_skills_compliance` を wire-in

## Cursor Rules Residual Risks

date: 2026-05-21
task id: `cursor-rules-integration-20260521`
slice id: `c5-D-docs-grading`

This section fixes the known residual risks for the round 5 Cursor rules
integration described above. It separates what Cursor official docs state
from what RevHarness can enforce deterministically in this PR. (Formerly a
standalone `cursor-rules-residual-risks.md` file; folded in here on
2026-08-19 because it is the same subject as the integration doc above, split
only by which PR round wrote it.)

### 1. Precedence opacity

**状況**: User Rules / Team Rules / Project Rules / `AGENTS.md` / `CLAUDE.md` の conflict precedence は Cursor official docs で deterministic acceptance contract として未保証。

**本 PR の対応**: `AGENTS.md` は vendor-neutral invariant のみに制限し、Cursor-specific operational guidance は `.cursor/rules/` に置いた。critical rule は fail-closed invariant、detailed rule は operational guidance に分離。

**Residual**: User Rules や Team Rules が conflicting instruction を持つ環境では、Cursor 側の実適用順が RevHarness の deterministic check だけでは証明できない。

**Future round 候補**: live Cursor smoke で conflict fixture を用意し、User / Team / Project / root markdown の precedence observation artifact を保存する。

### 2. Live rules honoring opacity

**状況**: fake fixture は wrapper argv と local self-check を検証できるが、実 Cursor model が rules を honor したことは証明できない。

**本 PR の対応**: wrapper metric に `cursor_rules_files_present` と enum `cursor_rules_selfcheck_status` を追加し、rules inputs の存在確認と self-check slot を記録。Round 5 の deterministic frontmatter validation は `test/unit/test-cursor-rules-frontmatter.sh` に固定。

**Residual**: model behavior の遵守は deterministic unit test ではなく live smoke 領域。Cursor service-side behavior や model routing 変更の影響を受ける。

**Future round 候補**: opt-in live smoke を追加し、rule-specific sentinel instruction を Cursor CLI に確認させる。

### 3. `--print` mode + rules behavior unverified

**状況**: `-p` / print mode で `.cursor/rules/` がどのタイミング・粒度で attach されるかは official docs の acceptance-level detail として未明示。

**本 PR の対応**: wrapper は `-p --output-format text` の argv contract を維持し、rules self-check metric を出す。

**Residual**: print mode の live context attachment は wrapper self-check だけでは証明できない。

**Future round 候補**: `agent -p` live smoke で `.cursor/rules` sentinel を観測し、interactive mode との差分を記録する。

### 4. `--mode ask` write enforcement weakness

**状況**: Cursor CLI docs は ask mode を read-only と説明するが、RevHarness acceptance としては CLI flag だけで write 完全 block を証明しない。

**本 PR の対応**: Slice C3 で `--role ask` 実行前後に git snapshot を取り、worktree diff が発生したら wrapper-level read-only violation として fail-closed。

**Residual**: git 不在、`.git` 外、または git が追跡しない外部 side effect は diff gate では検出できない。

**Future round 候補**: sandboxed temp workspace smoke と filesystem watch を組み合わせ、untracked / ignored file drift の観測範囲を拡張する。

### 5. Sandbox Mode is not shell-exec deterrent

**状況**: Cursor Sandbox Mode docs は network/file restriction の surface であり、shell exec 自体を確実に block する deterrent としては未明示。

**本 PR の対応**: sandbox flag に依存せず、Cursor-origin process が Codex/Claude wrappers を呼ぶ経路を `_outbound-deny.sh` で hardening。

**Residual**: Cursor 自身の shell tool behavior と sandbox policy の実 enforcement は local environment と Cursor implementation に依存する。

**Future round 候補**: Enterprise Hooks sample と local sandbox live probe を追加し、shell command attempt の audit artifact を残す。

### 6. Enterprise Hooks gating is plan-locked

**状況**: `beforeShellCommand` allowlist は Cursor Enterprise plan 必須で、base RevHarness contract には含められない。

**本 PR の対応**: Enterprise Hooks を mandatory gate にせず、wrapper-level outbound deny と ask diff gate を baseline hardening とした。

**Residual**: Enterprise plan のない環境では Cursor shell command allowlist を Cursor-native hook として強制できない。

**Future round 候補**: Enterprise Hooks sample policy を docs/examples に置き、plan available environment で opt-in verification する。

### 7. `AGENTS.md` cross-vendor leakage

**状況**: Cursor CLI が `AGENTS.md` を読む公式 docs はあるが、Codex / Claude が同じ semantics で `AGENTS.md` を読むことは Cursor docs では保証されない。

**本 PR の対応**: `AGENTS.md` には vendor-neutral content だけを置き、Claude-specific rules は `.claude/CLAUDE-LOCAL.md`、Cursor-specific rules は `.cursor/rules/` に分離。

**Residual**: vendor ごとの root instruction reading behavior は異なるため、`AGENTS.md` だけに vendor-specific safety rule を置くと漏れる可能性がある。

**Future round 候補**: root instruction integration test を vendor family ごとに拡張し、read-order drift を検出する。

### 8. MDC frontmatter syntax

**状況**: `.mdc` frontmatter の正確な grammar と future-compatible field set は深掘りしていない。

**本 PR の対応**: `test/unit/test-cursor-rules-frontmatter.sh` で RevHarness が使う deterministic subset を固定し、18 checks で expected fields と basic shape を検証。

**Residual**: Cursor 側が `.mdc` grammar を変更した場合、local lint が pass しても live Cursor attach が変わる可能性がある。

**Future round 候補**: official docs の `.mdc` examples と local lint rule の sync check を追加する。

### 9. Outbound deny scope

**状況**: `_outbound-deny.sh` は `ps -o comm=` と PPID walk depth 16 による parent-process check で実装している。container / chroot / abnormal PPID context では process tree visibility が環境依存。

**本 PR の対応**: unit test で normal Cursor-origin path と non-Cursor path を固定し、Codex/Claude wrapper 側で hardening を適用。

**Residual**: process ancestry が見えない runtime や wrapper を経由しない direct binary invocation は対象外。

**Future round 候補**: process tree unavailable case の explicit metric と, wrapper bypass detection の advisory guard を追加する。

### 10. Ask diff gate boundary

**状況**: git command 不在 / `.git` 外 invocation では ask diff gate は skip され、advisory log のみになる。CI container compatibility のための trade-off。

**本 PR の対応**: git repository 内では pre/post snapshot を比較し、diff があれば read-only violation として fail-closed。

**Residual**: git unavailable environment では ask mode read-only enforcement が Cursor CLI semantics と logs に依存する。

**Future round 候補**: git unavailable mode を explicit blocked mode にする opt-in strict flag、または portable directory snapshot fallback を追加する。

### 11. Cursor Skills discovery in `--print` mode unverified

**状況**: Cursor Agent Skills の file layout と `SKILL.md` frontmatter は documented standard だが、`cursor-agent -p` / print mode で project skills がどのタイミングで agent context に注入されるかは acceptance-level detail として未検証。

**本 PR の対応**: `.cursor/skills/` canonical path を確保し、既存 `.agents/skills/` / `.claude/skills/` projection が Cursor-visible skill asset であることを docs に明記。`test/unit/test-cursor-skills-compliance.sh` で両 provider tree の `name:` / `description:` / frontmatter fence / folder-name parity or documented compatibility alias / lowercase / non-empty description を deterministic check 化。

**Residual**: live Cursor runtime、slash menu、`--print` context injection は local file-format test だけでは証明できない。Cursor CLI version、runtime mode、settings、service-side behavior の影響を受ける可能性がある。

**Future round 候補**: opt-in live smoke で `cursor-agent -p` に skill sentinel を問い合わせ、`.agents/skills/`、`.claude/skills/`、`.cursor/skills/` の discovery 差分を evidence artifact として保存する。

## 公式 Cursor docs 参照

- https://cursor.com/cli
- https://cursor.com/docs/cli/overview
- https://cursor.com/docs/cli/installation
- https://cursor.com/docs/cli/headless
- https://cursor.com/docs/cli/shell-mode
- https://cursor.com/docs/cli/github-actions
- **https://cursor.com/docs/cli/reference/parameters** ← flag の正確な semantic はここに
- **https://docs.cursor.com/en/cli/using** ← CLI が `.cursor/rules` と root `AGENTS.md` / `CLAUDE.md` を読む根拠
- **https://docs.cursor.com/en/context/rules** ← `.cursor/rules/*.mdc` project rules の根拠
- **https://cursor.com/docs/skills** ← Agent Skills の `SKILL.md` packaging と project-level discovery path の根拠

公式 docs では「Claude Code / Codex から Cursor CLI を wrapper として呼ぶ三者連携」は記述されていません。本統合は Cursor CLI の公式 automation surface を RevHarness の wrapper 規約に合わせて利用する自前オーケストレーションです。flag semantic は常に公式 reference parameters page を一次情報源とすること。

### Binary name portability note

公式 docs では CLI invocation を **`cursor-agent`** と表記することが多く、`agent` は短縮 alias として install script (`curl https://cursor.com/install | bash`) が `~/.local/bin/agent` を作る形で提供されます。wrapper は `$HOME/.local/bin/agent` → `/usr/local/bin/agent` → `$PATH` の順で探索しますが、環境によっては `cursor-agent` のみ存在する場合があるため、その際は `CURSOR_WRAPPER_AGENT_BIN=$(command -v cursor-agent)` を明示指定してください。`agent` という汎用名は他ツールとの衝突可能性もあるため、portability を最大化したい environment では `cursor-agent` を直接指定する運用が安全です。
