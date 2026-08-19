# Canonical Invariants

`Revharness` の正規不変条件。各 invariant は `AGENTS.md` (inline anchor) と
`docs/manual/verification-truth-matrix.md` (row-level enforce) に対応する
表現が存在し、`scripts/`/`scripts/ci/` 配下の deterministic check command で
機械検証される。

本書は AGENTS.md inline section + verification-truth-matrix の散在 row を
**1 箇所に統合する on-disk canonical anchor** であり、reviewer / orchestrator /
adopter が canonical invariant set を 1 read で得るための index として機能する。

- Numbering policy: retired core IDs are tombstoned and never reused.
- Cross-references to retired IDs keep resolving to tombstone sections.
- New, retired, and addon invariants update (1) AGENTS.md invariant index,
  (2) `docs/manual/verification-truth-matrix.md` row, and (3) this document in
  one slice.
- Missing synchronization is a structural inconsistency rejected by
  `scripts/ci/invariant-sync-check.sh --strict`.
- Current split clause: core semantic demotion is complete. Core release smoke
  uses shipped-artifact privacy scanning; semantic Tier 1, binary privacy, and
  MCP wiring checks are addon or compatibility gates.

## Index

| ID | 名前 | canonical surface | deterministic check | severity |
|---|---|---|---|---|
| I-1 | Privacy hard gate (pre-commit) | `scripts/rev-harness-path-leak-guard.sh` | `bash scripts/rev-harness-path-leak-guard.sh` exit 0 | blocks commit |
| I-2 | Tombstone: retired semantic capsule core invariant | tombstone section below | core release gate does not require semantic capsule guard coverage; this harness ships no semantic `tier1-scope-guard.sh` guard | core release not blocked by semantic capsule guard |
| I-2b | Shipped-artifact privacy stable | `docs/SHIPPED_ARTIFACTS.md` | `bash scripts/ci/shipped-artifact-privacy-scan.sh --manifest docs/SHIPPED_ARTIFACTS.md` exit 0 | blocks release tag |
| I-3 | Dual LGTM on-disk evidence | `<evidence-dir>/review-<reviewer>-r<round>.md` | `bash scripts/dual-lgtm-validate.sh --strict` exit 0 | blocks phase_advance |
| I-4 | Graceful-shutdown fail-open | `.claude/hooks/agent-graceful-shutdown.sh` | `bash .claude/hooks/agent-graceful-shutdown.sh --self-test` exit 0 | runtime safety |
| I-5 | Wrapper help / behavior parity | `test/golden/{codex,claude}-wrapper-help.txt` | `bash scripts/ci/check-wrapper-help-parity.sh` exit 0 | blocks tag |
| I-6 | file_owner_token exclusivity | ExecPlan `dispatch_topology` + lint | `bash scripts/ci/check-execplan-topology.sh --strict` exit 0 | blocks dispatch |
| I-7 | PARALLEL_QUIESCE sweep gate | `agent-graceful-shutdown.sh` 6 関数 + janitor + safe-dispatch | hook env-gating test exit 0 | runtime safety |
| I-8 | Pre/Post SHA256 snapshot | `scripts/safe-dispatch.sh` + 3 snapshot hooks | snapshot test exit 0 | runtime safety |
| I-9 | Dispatch-topology lint | `scripts/ci/check-execplan-topology.sh` | (= I-6 と同 command) | blocks dispatch |
| I-10 | Call out, never absorb | `scripts/rev-harness` facade + adopter lifecycle | sha256 immutable check (4 child untouched) | governance |
| I-11 | Destructive opt-in | `--apply --ack-rebuild-cost` 等 explicit flag | janitor build-cleanup test exit 0 | runtime safety |
| I-12 | Smoke-gated dual-LGTM | `scripts/state-transition-guard.sh` joint axis | `phase-done-smoke.sh --phase <X>` exit 0 → `lgtm_stage=final` allow | blocks phase_advance |
| I-13 | Tombstone: retired mandatory semantic MCP core wiring | tombstone section below | core requires no semantic MCP wiring; this harness ships no semantic `mcp-wire-contract-check.sh` / `addon-absent-or-compliant-check.sh` guards | core release not blocked by semantic MCP wiring |

## Authority Map

各 normative fact の **単一正本 (canonical home)** はこの表で確定する。これより外の
surface（README, CLAUDE.md, role docs, INDEX_MAP 等）は対応する事実を **再定義せず、
この表で示す canonical home へのポインタ** として記述する。重複定義が発生したら、その
コピー側を本表のポインタへ降格する（normative meaning は変更しない）。

| Normative fact | 単一正本 (canonical home) | この surface 以外での扱い |
|---|---|---|
| Truth Read Order（9 ステップ） | `AGENTS.md §Read Order` | 他は再定義せずポインタのみ |
| Canonical invariant set（ID 体系・tombstone） | `docs/canonical-invariants.md`（本書 §Index + §Per-invariant detail） | AGENTS.md index / matrix row は同期表現、追加・改廃は本書経由 |
| Acceptance / LGTM / completion authority | `docs/manual/verification-truth-matrix.md` | 他は再定義せずポインタのみ |
| I-12 / dual-LGTM の normative prose | `docs/canonical-invariants.md §I-12` | AGENTS.md / README / matrix / guards は同期表現またはポインタ |
| Session start（`orchestrator-bootstrap` 必須起動） | `AGENTS.md §Session Start (Orchestrator session)` | CLAUDE.md / CLAUDE-LOCAL.md / role docs / lifecycle / INDEX_MAP はポインタ |

この表自体が「どの事実をどこで変えるか」の正本であり、`README.md §15.0` などは本表を
ポインタとして参照する。同期は `scripts/ci/invariant-sync-check.sh --strict` が
ID/literal anchor 単位で検知する。

## Per-invariant detail

### I-1 Privacy hard gate (pre-commit)
**Surface**: `scripts/rev-harness-path-leak-guard.sh` + `.git/hooks/pre-commit` symlink.
**Trigger**: every `git commit` (pre-commit hook).
**Check**: `bash scripts/rev-harness-path-leak-guard.sh` exit 0
(`scanned_files=N, findings=0`).
**Failure mode**: exit non-zero with literal patterns + line numbers; commit aborted.
**Soft layer companion**: I-12 inferred + `.claude/hooks/path-leak-advise.sh`
(advisory, JSONL row, fail-open). I-1 is the "hard" half of this 2-layer model.
**AC anchor**: AGENTS.md privacy section / verification-truth-matrix.md
"path leak / privacy" rows.

### I-2 Tombstone: retired semantic capsule core invariant
**State**: retired from the core invariant set; ID is tombstoned and never reused.
**Core replacement**: INDEX validation plus source reads and deterministic-check
evidence. Core acceptance must never depend on semantic capsule output.
**Cross-reference behavior**: existing references to I-2 resolve here.
**Current check**: core release gates do not require semantic Tier 1. This
harness ships no `tier1-scope-guard.sh` semantic guard; there is no remaining
semantic capsule blocker.
**Addon successor**: `Addon-I-2` is itself RETIRED; the semantic addon no
longer ships.
**Origin**: retired from core by the index-first migration.

### I-2b Shipped-artifact privacy stable
**Surface**: every shipped core executable/archive listed in
`docs/SHIPPED_ARTIFACTS.md`.
**Trigger**: every release tag candidate.
**Check**: `bash scripts/ci/shipped-artifact-privacy-scan.sh --manifest docs/SHIPPED_ARTIFACTS.md`
exit 0. The scan uses the same leak pattern class as
`scripts/ci/release-binary-privacy-scan.sh`: `/Users/`, `/home/`,
`.cargo/registry/src/`, and `.rustup/toolchains/`, plus any adopter-defined
in-house project markers supplied via `REV_HARNESS_PRIVACY_EXTRA_PATTERNS`
(see `docs/manual/release-binary-privacy.md`).
**Conditional activation**: if a release ships no core executable/archive, this
gate fails unless the manifest records `no shipped core artifact` with reviewer
evidence. Empty implicit success is forbidden.
**Failure mode**: source-level `path-leak-guard` (I-1) does NOT cover compiled
strings, debug symbols, panic-message line-info, or packaged archive contents.
I-2b closes that hole for shipped artifacts.
**Current check**: core shipped artifacts are scanned by
`bash scripts/ci/shipped-artifact-privacy-scan.sh --manifest docs/SHIPPED_ARTIFACTS.md`
(the same leak-pattern class as `scripts/ci/release-binary-privacy-scan.sh`).
**Addon companion**: `Addon-I-2b` is RETIRED; no `semantic-mcp` addon binary
ships, so there is no semantic addon binary scan.
**Origin**: generalized by the index-first migration.

### I-3 Dual LGTM on-disk evidence
**Surface**: `<evidence-dir>/review-<reviewer>-r<round>.md` (default evidence
dir: `.agent/active/<plan-id>`), one file per expected reviewer (default
`opus,codex`).
**Trigger**: every reviewer verdict submission; every phase advance attempt.
**What this actually checks (and does not)**: `bash
scripts/dual-lgtm-validate.sh --strict` exit 0 checks, per expected reviewer,
that `review-<reviewer>-r<round>.md` exists and contains the literal string
`**Verdict**: ✅ LGTM (unconditional)`. It computes a sha256 of each present
file but **discards the value without comparing it to anything recorded** —
there is no stored "expected hash" this check validates against, so the
sha256 computation currently has no effect on the result. It does not parse
or validate any other part of the verdict markdown ("strict schema" here
means only "the literal LGTM string is present," not a structural schema
check), and it does not read or write `.agent/state/dual_lgtm_state.json` at
all — that file belongs to a separate mechanism
(`scripts/state-transition-guard.sh`, see I-12) which records provenance
sha256 for evidence paths it is told about, but does not itself re-verify
verdict content either. Do not conflate the two: passing
`dual-lgtm-validate.sh` does not update `dual_lgtm_state.json`, and a
`dual_lgtm_state.json` with `lgtm_stage=final` does not imply
`dual-lgtm-validate.sh` was ever run against the same evidence files.
**What this guards against**: an agent reporting "LGTM" in chat without
leaving the two on-disk files. **What this does not guard against**: the same
model writing both files, a human editing either file by hand, or either file
being edited after this check last passed (README.md "What this does not do"
states this plainly: "confirms that two designated files exist and contain a
verdict... does not verify that two different models produced them... or that
a human did not write both").
**Failure mode**: missing reviewer file → `result=pending` (exit 1); present
file without the literal LGTM string → `result=blocked` (exit 2).
**AC anchor**: `docs/roles/reviewer.md` verdict markdown contract;
verification-truth-matrix "dual LGTM" rows.

### I-4 Graceful-shutdown fail-open
**Surface**: `.claude/hooks/agent-graceful-shutdown.sh` (6 functions covering
PARALLEL_QUIESCE gate, snapshot-stash, owner_agent_id propagation, bail GC).
**Trigger**: every agent shutdown event (Stop hook).
**Check**: `bash .claude/hooks/agent-graceful-shutdown.sh --self-test` exit 0.
**Failure mode**: hook MUST fail open (exit 0 with warning JSONL row) when a
non-critical subsystem errors, so a buggy hook never blocks orchestration.
Critical assertion failures (e.g., quiesce-skip race) emit a `silent_bail.jsonl`
row but still return 0 to the harness.
**AC anchor**: AGENTS.md graceful-shutdown section.

### I-5 Wrapper help / behavior parity
**Surface**: byte-pinned golden files
`test/golden/{codex,claude}-wrapper-help.txt` + wrappers
`scripts/{codex,claude}-wrapper.sh` + 3 shims
`scripts/codex-wrapper-{xhigh,high,medium}.sh`.
**Trigger**: every wrapper-touching commit and every release tag candidate.
**Check**: `bash scripts/ci/check-wrapper-help-parity.sh` exit 0.
**Failure mode**: any drift in help text, role merge semantics, or shim role-hint
behavior (`CODEX_WRAPPER_SHIM_ROLE` env) fails the gate; tag blocked.
**AC anchor**: verification-truth-matrix wrapper-parity rows.

### I-6 file_owner_token exclusivity
**Surface**: ExecPlan `dispatch_topology` block + lint
`scripts/ci/check-execplan-topology.sh`.
**Trigger**: every parallel dispatch ExecPlan.
**Check**: `bash scripts/ci/check-execplan-topology.sh --strict` exit 0.
Enforces that no two concurrent agents declare overlapping
`file_owner_token` values.
**Failure mode**: overlapping tokens → REJECT before dispatch (no agent spawn).
**AC anchor**: AGENTS.md dispatch-topology section.

### I-7 PARALLEL_QUIESCE sweep gate
**Surface**: `agent-graceful-shutdown.sh` 6 functions +
`scripts/rev-harness-janitor.sh` + `scripts/safe-dispatch.sh`.
**Trigger**: every janitor sweep, every shutdown event, every safe-dispatch call.
**Check**: hook env-gating test exit 0 — under `REVHARNESS_PARALLEL_QUIESCE=1`,
the sweep MUST recognize quiesce state and skip destructive actions.
**Failure mode**: ignoring quiesce flag during parallel dispatch can GC a
sibling agent's stash → cascading bail. I-7 prevents that.

### I-8 Pre/Post SHA256 snapshot
**Surface**: `scripts/safe-dispatch.sh` + 3 hooks
`.claude/hooks/snapshot-{pre,post,stop}.sh` +
`scripts/snapshot-dispatch.sh`.
**Trigger**: every safe-dispatch invocation.
**What this actually checks (and does not)**: `safe-dispatch.sh` computes a
sha256 of every path listed in `--owner-tokens` before spawning the wrapper
child, and again after it exits, then writes both snapshots under
`.agent/state/locks/<task-id>.{before,after}.sha256` plus one JSONL row to
`.agent/metrics/dispatch_events.jsonl` recording `changed_paths` (the subset
whose hash differed). This is **observation, not enforcement**:
- It never computes or compares hashes for paths outside `--owner-tokens`. A
  child that writes to an undeclared path — including a sibling agent's
  owner-token files — is invisible to this mechanism entirely; nothing
  hashes, flags, or reports that write.
- It does not distinguish "declared NO-WRITE" from "declared WRITE" agents,
  and it never rejects, aborts, or blocks anything based on the diff. The
  script always exits with the wrapper child's exit code, regardless of what
  `changed_paths` contains.
- It does not emit `silent_bail.jsonl` (that file is owned by
  `.claude/hooks/agent-graceful-shutdown.sh`, unrelated to safe-dispatch) and
  nothing downstream automatically consumes `dispatch_events.jsonl` to act on
  a mismatch.
- The three snapshot hooks (`snapshot-{pre,post,stop}.sh`) are independent,
  fail-open Claude Code tool hooks that copy file state and log a sha256 per
  Edit/Write/MultiEdit/NotebookEdit call; they also only record, they do not
  compare or reject.
In short: I-8 gives a reviewer a hash trail to manually confirm, after the
fact, whether a dispatched task's actual writes matched its declared owner
set. It provides no runtime lock and no automatic rejection of drift — see
`docs/manual/safe-dispatch.md` §8 "Failure recovery" for the manual
reconciliation path this implies.
**Check**: `bash test/unit/test-safe-dispatch.sh` exit 0 — asserts that the
before/after snapshot files and the JSONL row are produced with the
documented shape; it does not assert any rejection behavior, because none
exists.

### I-9 Dispatch-topology lint
**Surface**: `scripts/ci/check-execplan-topology.sh`.
**Trigger**: every ExecPlan commit; runs in CI and pre-dispatch.
**Check**: shares command line with I-6 (same script). Validates structural
shape of `dispatch_topology` block including `file_owner_token`,
`worker_outcome` vocabulary, `evidence_destination` placement.
**Failure mode**: malformed or missing `dispatch_topology` block → REJECT.
**Origin**: complements I-6.

### I-10 Call out, never absorb
**Surface**: `scripts/rev-harness` facade +
`scripts/rev-harness-{install,uninstall,repair,adopter-setup,mcp-wire}.sh` +
adopter lifecycle.
**Trigger**: every adopter setup, every harness facade invocation.
**Check**: sha256 immutable check — the 4 child scripts (`install`, `verify`,
`repair`, `uninstall`) must NOT mutate the adopter project state during
inspect-only modes. Destructive operations require I-11 opt-in.
**Failure mode**: facade absorbing adopter state (e.g., overwriting an existing
project_id, deleting an adopter file without `--apply`) → REJECT.

### I-11 Destructive opt-in
**Surface**: every destructive command requires an explicit double-flag pair:
`--apply` + a domain-specific acknowledgement flag (e.g.,
`--ack-rebuild-cost` for `rev-harness clean`).
**Trigger**: every destructive subcommand (clean, uninstall, upgrade).
**Check**: janitor build-cleanup test exit 0 — invoking destructive command
without both flags must dry-run and exit 0; with both flags must apply and
log the action.
**Failure mode**: silent destructive default → REJECT (gate fails).
**Origin**: canonicalised across `rev-harness-janitor.sh`,
`rev-harness-uninstall.sh`, and `rev-harness-upgrade.sh`.

### I-12 Smoke-gated dual-LGTM
**Surface**: `scripts/state-transition-guard.sh` joint axis
`(provisional/confirmed) × (unverified/final)` over exactly one file:
`.agent/state/dual_lgtm_state.json` (or whatever path `--state-file` names).
This is the *only* state file this invariant governs. It is unrelated to,
and must not be conflated with, `.rev-harness-state/state.json` — a
different file with a different schema (`adopter_setup/v1`) written by
`scripts/rev-harness-adopter-setup.sh` to track that script's own
init/hooks/doctor install lifecycle. That file also has a field named
`phase` that can take the value `"done"` (meaning "adopter install
finished"), which is a coincidental name collision, not the same concept as
this invariant's `dual_lgtm_state.json` phase-advance gate. See "Adopter
setup and I-12" below.
**Trigger**: every phase advance driven through
`state-transition-guard.sh --require-lgtm-final <state-file>` against
`.agent/state/dual_lgtm_state.json`.
**Check**: `bash scripts/ci/phase-done-smoke.sh --phase <X>` exit 0 →
`lgtm_stage=final` allowed → `state-transition-guard --require-lgtm-final`
exit 0 → phase advance permitted.
**What `--require-lgtm-final` actually checks (and does not)**: it reads
`.lgtm_stage` from the given state file with `jq` and exits non-zero unless
the value is exactly `"final"`. It does not: validate the file's schema
beyond that one field being readable; check that `plan_id` or `round` match
the phase being advanced; recompute or verify the `sha256.opus` /
`sha256.codex` fields already recorded in the file; check the age or
provenance of the recorded `smoke_evidence_sha256`; or re-run
`dual-lgtm-validate.sh` against the evidence files the state file's
`evidence_paths` point to. It trusts whatever a prior
`state-transition-guard.sh --target-stage final --smoke-evidence-sha256 <sha>`
call wrote, and that prior call's own evidence requirement is: `--evidence-paths
opus=<path>,codex=<path>` is optional — if omitted, `sha256.opus` /
`sha256.codex` are recorded as empty strings, and no code path currently
requires them to be non-empty before allowing `lgtm_stage=final`. The joint
transition logic (`validate_joint_transition`) does require a syntactically
valid sha256 for `--smoke-evidence-sha256` and that it is sourced from a
`phase_done_smoke.jsonl` summary row with `exit_code=0`, which is real and
tested — the gap is specifically that reviewer-evidence identity/freshness is
not re-verified at the final `--require-lgtm-final` read.
**Failure mode**: agent-based 9+/10 dual-LGTM is *provisional* only.
Without a successful `phase-done-smoke.sh` run sourcing
`smoke_evidence_sha256` from a JSONL row, `lgtm_stage` stays `unverified`
(actually: stays whatever it was — `provisional` is the schema default) and
the guarded phase advance is refused.
**Adopter setup and I-12 (intentional separation, not a loophole)**:
`scripts/rev-harness-adopter-setup.sh` writes `phase: "done"` directly to
`.rev-harness-state/state.json` when its own `doctor` phase succeeds
(`state_update_phase`, no call through `state-transition-guard.sh`). This is
by design: adopter setup tracks "did this repo's one-time install finish,"
which has no dual-LGTM review associated with it and was never intended to
be gated by I-12. It is not a bypass of the ExecPlan/dual-LGTM phase-advance
gate because it never touches `.agent/state/dual_lgtm_state.json`. The risk
this creates is purely a documentation/terminology one — prose that says
"every `state.json.phase = done` write is guarded" reads, out of context, as
covering this file too. It does not, and this document no longer uses that
unqualified phrasing.
**Origin**: closes a structural gap observed across an earlier
release-hardening effort, where several rounds of agent-based dual-LGTM
missed production smoke failures despite 9+/10 verdicts.
**AC anchor**: AGENTS.md §I-12; `docs/manual/verification-truth-matrix.md` row 2.

### I-13 Tombstone: retired mandatory semantic MCP core wiring

**State**: retired from the core invariant set; ID is tombstoned and never reused.
**Core rule**: normal core operation requires no mandatory semantic autostart,
launcher path, MCP server config, semantic-mcp key, or project_id sentinel.
**Core proof direction**: core-only smoke coverage must prove representative
docs, wrapper, and gate tasks can run with semantic MCP absent or disabled.
**Cross-reference behavior**: existing references to I-13 resolve here.
**Current check**: none required. This harness ships no
`mcp-wire-contract-check.sh` / `addon-absent-or-compliant-check.sh`
semantic wiring guards. Absent semantic MCP wiring is the only supported core
state.
**Addon successor**: `Addon-I-13` is itself RETIRED; the opt-in semantic addon
wiring no longer ships.

## Addon invariants (semantic addon)

All semantic addon invariants are RETIRED. The semantic addon (crate, capsule,
MCP wiring, gates) no longer ships. The IDs are kept tombstoned (never
reused).

### Addon-I-2 Semantic capsule byte-stability
**State**: RETIRED.
**Rationale**: the semantic capsule and its `tier1-scope-guard.sh` byte-stability
gate were removed with the semantic addon; no capsule output ships.

### Addon-I-2b Semantic-mcp binary privacy stable
**State**: RETIRED.
**Rationale**: no `semantic-mcp` addon binary ships, so the semantic addon binary
privacy scan (`release-binary-privacy-scan.sh` via the removed
`semantic-addon-gate.sh`) no longer applies. Core artifacts remain covered by
I-2b (`shipped-artifact-privacy-scan.sh`).

### Addon-I-13 Opt-in semantic MCP wiring governance
**State**: RETIRED.
**Rationale**: the opt-in semantic MCP wiring and its
`mcp-wire-contract-check.sh` / `addon-absent-or-compliant-check.sh` guards were
removed with the semantic addon. No `semantic-mcp` MCP config ships.

## Cross-references

- `AGENTS.md` — invariant index and addon invariant reference table.
- `docs/manual/verification-truth-matrix.md` — row-level enforce table.
- `scripts/state-transition-guard.sh` — I-3 + I-12 joint enforcement.
- `scripts/ci/shipped-artifact-privacy-scan.sh` — I-2b shipped-artifact gate.
- `scripts/ci/release-binary-privacy-scan.sh` — shared leak-pattern scan reused by I-2b.
- `scripts/ci/phase-done-smoke.sh` — I-12 smoke gate.
- `scripts/ci/check-execplan-topology.sh` — I-6 + I-9 (shared).
- `scripts/dual-lgtm-validate.sh` — I-3 reviewer artifact validator.
- `.claude/hooks/agent-graceful-shutdown.sh` — I-4 + I-7 runtime hook.
- `.claude/hooks/snapshot-{pre,post,stop}.sh` + `scripts/safe-dispatch.sh` — I-8 snapshot.
- `scripts/rev-harness` facade — I-10 + I-11 adopter lifecycle.
- `scripts/rev-harness-path-leak-guard.sh` + `.claude/hooks/path-leak-advise.sh` —
  I-1 (hard) + soft companion layer.

## Update protocol

新規 invariant、addon invariant、または tombstone を追加するときは、必ず同一
commit 内で:

1. `AGENTS.md` の invariant index または addon invariant reference table を更新する。
2. `docs/manual/verification-truth-matrix.md` の Invariant Acceptance Gates
   table に対応 row を追加する。
3. 本書の §Index と §Per-invariant detail に新規 section を追加する。

3 か所の同期は `scripts/ci/invariant-sync-check.sh --strict` で検知する。
