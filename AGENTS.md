# RevHarness invariants

This file is the vendor-neutral instruction source for any agent reading this
repository. Cursor, Codex, Claude, and future agent clients may all read it, so
it contains only project-wide invariants and cross-agent responsibilities.

Vendor-specific operating rules belong elsewhere:

- Claude Code: `.claude/CLAUDE-LOCAL.md`
- Cursor: `.cursor/rules/`
- Codex: `.codex/config.toml`, `.codex/agents/`, and the relevant wrapper docs

## Purpose

RevHarness is a multi-agent development harness for building systems with high
accuracy, deterministic verification, low resource overhead, and clear review
boundaries. Every agent is responsible for preserving those invariants even when
it is only editing documentation or orchestration metadata.

This file is the root-level invariant contract. It is not a replacement for role
definitions, vendor-specific rules, or task-local slice contracts.

## Read Order

Use this order when deciding what controls a task:

1. The user's current instruction and explicit task scope.
2. This `AGENTS.md` file for vendor-neutral repo invariants.
3. `.agent_rules/RULES.md` plus the shared modules it incorporates by reference.
4. `docs/canonical-invariants.md` for the canonical invariant set on-disk source.
5. `docs/manual/verification-truth-matrix.md` for acceptance authority.
6. `docs/manual/self-defense-architecture.md` for the release-invariant
   four-layer model.
7. The applicable role definitions under `docs/roles/`.
8. Operator manuals under `docs/manual/*.md` (lifecycle, smoke gate,
   release binary privacy, safe-dispatch, state-transition guard,
   snapshot hooks, path-leak soft layer).
9. Vendor-specific rules only for the agent family actually operating.

If two sources conflict, do not silently choose a convenient rule. Prefer the
newer and more specific user instruction unless it weakens safety, evidence,
secrets handling, or deterministic acceptance requirements.

Shared operating rules live under `.agent_rules/` and are incorporated by
reference via the index `.agent_rules/RULES.md`; read that literal path and the
shared modules it incorporates before acting on any surface they govern.

## Session Start (Orchestrator session)

When this harness is driven by an orchestrator session — whether Claude Code or
Codex — the orchestrator **must** invoke the `orchestrator-bootstrap` skill at
session start, before the first substantive action (planning, delegating,
editing, reviewing, or reporting). Both families expose Skills; use the
family-native skill invocation (Claude Code: `Skill` tool; Codex: its native
skill mechanism).

`orchestrator-bootstrap` is the canonical session-start routine that raw-reads
required context, consults memory, user meta-goal, and truth read order in one
pass. It is raw-read only; this harness is semantic-free and the routine does
not load any semantic capsule. Skip only when the user explicitly says to skip.

Cursor agents are not orchestrators in this harness and follow `.cursor/rules/`
instead.

## Acceptance Authority

`docs/manual/verification-truth-matrix.md` is the acceptance authority for this
repository. A wrapper setting, model setting, agent response, or reviewer note
does not by itself prove completion.

Before reporting a task as accepted or ready for the next gate, the responsible
agent must preserve the exact required checks, their results, the covered scope,
and an artifact pointer or explicit no-artifact reason.

If required checks, results, scope, or artifact integrity are missing, fail
closed instead of using completion, acceptance, release-readiness, or LGTM
language.

## Evidence Convention

Task evidence should be written under `.claude/tmp/<task>/` or `.agent/active/`
unless a slice contract names a more specific destination. Evidence includes
command logs, review packets, smoke-test outputs, migration notes, and block
reports.

The reader's responsibility is to keep evidence traceable. Do not replace a
machine-check result with reasoning-only confidence, and do not cite volatile
terminal output as the sole evidence when the slice requires a durable artifact.

## Project Identity

`.shared/project_id` is immutable project identity. Agents may read it when they
need to bind state, cache, or evidence to this checkout.

Do not rewrite, normalize, or regenerate `.shared/project_id` as part of routine
cleanup. If it is malformed or missing, fail closed and report the blocker.

## Secret Redaction

Never include raw secrets, credentials, API keys, tokens, private cookies, or
unredacted sensitive payloads in agent output, logs, handoffs, tests, fixtures,
or screenshots. Use a redacted preview that preserves only enough shape for
debugging.

When a command might print secrets, redirect or filter the output before it
becomes evidence. If safe redaction is not possible, stop and ask for a safer
inspection path.

## Destructive Opt-In

Destructive actions require explicit opt-in flags or explicit user instruction.
Do not infer destructive approval from adjacent cleanup, migration, or
maintenance requests.

## Cross-Family Delegation

When an agent delegates work to another agent family, it must use the canonical
wrapper or documented entrypoint in `scripts/` for that family and role. Direct
binary calls are not completion evidence and may bypass safety guards.

Cursor agents must not delegate to other agent families unless a later
Cursor-specific rule explicitly permits it. Claude and Codex orchestration must
keep same-family native delegation inside the current agent family, and use
durable artifact packets when crossing families.

## Dual-native orchestration boundary

Codex native subagents are configured through `.codex/config.toml` and
`.codex/agents/*.toml`; Claude-native agents use their own Claude-local
configuration. Native subagents must not recursively invoke cross-family
wrapper scripts. Cross-family handoffs use wrapper entrypoints and durable
artifact packets so reviewer evidence, task scope, and acceptance state remain
auditable across agent families.

The root Codex model-policy mirror is intentionally minimal and mirrors the
registry-backed baseline:

```toml
model = "gpt-5.6-sol"
model_reasoning_effort = "medium"
web_search = "cached"

[features]
multi_agent = true
```

## Vendor-Specific Boundaries

Do not put Claude-only, Codex-only, or Cursor-only operating rules in this file.
Root instructions are shared context, so vendor-specific rules here can cause
another agent to follow the wrong runtime contract.

Claude-specific orchestration, role switching, wrapper, and state-management
rules live in `.claude/CLAUDE-LOCAL.md`. Cursor-specific attachment and CLI
rules live under `.cursor/rules/`. Codex-specific runtime configuration lives in
`.codex/` and the canonical wrapper documentation.

## Change Discipline

Keep edits inside the approved slice surface. Do not reformat, rename, archive,
or clean unrelated files while handling a narrow task.

If the worktree already contains changes outside the slice, treat them as
someone else's work. Read around them when necessary, but do not revert or
normalize them unless the user explicitly asks.

## Deterministic Checks

Each task must name the exact checks that matter for its surface. A docs-only
migration may use targeted grep and smoke tests; runtime or security-sensitive
changes need the relevant unit, integration, release, or gate checks.

If a required check cannot run, record the exact command attempted, why it could
not run, and what evidence is needed to unblock it. Do not downscope a required
check after implementation just to produce a cleaner report.

## Governance Lessons

These lessons are reusable orchestration discipline derived from this
harness's release-hardening history. They are not phase-specific and apply to
every future phase.

- **Reviewer findings are hypotheses, not verdicts.** Orchestrators own
  production-reachability analysis before absorbing any reviewer
  recommendation. A reviewer can be highly confident and still be wrong about
  what the change actually breaks in production; test the finding against the
  actual command path before absorbing it.
- **Agent-based dual-LGTM is provisional.** A 9+/10 verdict from both Opus
  xhigh and Codex xhigh is a strong signal but is not by itself a final
  verdict. The mechanism (smoke gate, `lgtm_stage`, phase-advance) is owned by
  I-12; read `docs/canonical-invariants.md §I-12` for the authoritative rule and
  do not restate it here.
- **Defense-in-depth can disable the primary function.** A safety helper
  inserted to harden one surface can silently break the surface it was
  meant to protect. Cross-check every defense-in-depth change against the
  primary user-visible flow before merging.

## Deferred Work

Work consciously deferred past the current release is recorded here and in the
matching `CHANGELOG.md` deferral notes. Do not silently expand a current slice
to absorb deferred items.

Currently deferred:

- `rev-harness upgrade --apply` — the inspect/dry-run path is implemented; the
  path that actually mutates an adopter tree is not.
- `rev-harness uninstall --apply` — `uninstall` reports what would be removed;
  it does not remove it.
- A typed orchestrator built on the shell facade — exploratory, not scheduled.

Both `--apply` paths are deliberately absent rather than half-built: they are
destructive, and shipping them without rollback and double opt-in would violate
the destructive-opt-in invariant.

## Reporting

Reports should distinguish worker outcome from acceptance state. Coder-style
work can report `DIFF`, `NO-CHANGE`, or `BLOCK`; final acceptance belongs to the
configured gate and reviewer/orchestrator process.

User-facing summaries should be concise, evidence-backed, and explicit about
tests run or not run. Avoid claiming LGTM, completed, or accepted unless the
truth matrix conditions for those words are satisfied.

## Index of canonical invariants (canonical anchor: `docs/canonical-invariants.md`)

| ID | Reference summary |
|---|---|
| I-1 | Privacy hard gate blocks raw path/secret leaks before commit. |
| I-2 | Tombstone: semantic capsule byte-stability retired from core; see `Addon-I-2`. |
| I-2b | Every shipped core executable/archive in `docs/SHIPPED_ARTIFACTS.md` must scan privacy-clean. |
| I-3 | Dual-LGTM requires two on-disk verdict files with a literal LGTM string (sha256 is computed but not compared against anything recorded). |
| I-4 | Graceful-shutdown hook fails open instead of blocking work. |
| I-5 | Wrapper help and behavior remain byte-pinned and parity-checked. |
| I-6 | Parallel dispatch requires exclusive `file_owner_token` ownership. |
| I-7 | `PARALLEL_QUIESCE` is scoped to the dispatch window only. |
| I-8 | Safe dispatch records pre/post SHA256 snapshots. |
| I-9 | ExecPlan dispatch topology is linted before parallel work. |
| I-10 | Facades call child scripts; they do not absorb implementation. |
| I-11 | Destructive actions require explicit opt-in flags. |
| I-12 | Final phase advance requires smoke-gated dual-LGTM. |
| I-13 | Tombstone: mandatory semantic MCP core wiring is retired; the opt-in successor `Addon-I-13` is itself RETIRED and no semantic MCP wiring ships. |

### Addon invariant references

| ID | Reference summary |
|---|---|
| Addon-I-2 | RETIRED: semantic addon capsule byte-stability no longer ships. |
| Addon-I-2b | RETIRED: `semantic-mcp` addon binary no longer ships. |
| Addon-I-13 | RETIRED: opt-in semantic MCP wiring no longer ships. |

### I-2b (Shipped-artifact privacy stable)
Every shipped core executable/archive listed in `docs/SHIPPED_ARTIFACTS.md`
MUST scan clean with the shipped-artifact privacy scan. If no core
executable/archive ships, the manifest must record `no shipped core artifact`
with reviewer evidence; empty implicit success is forbidden.

Core semantic demotion is complete: this harness ships no semantic MCP, and
the semantic `tier1-scope-guard.sh` and `mcp-wire-contract-check.sh` gate
scripts do not exist, along with the semantic addon invariants (`Addon-I-2` /
`Addon-I-2b` / `Addon-I-13`, all RETIRED). The shipped-artifact privacy scan
(`release-binary-privacy-scan.sh` / `shipped-artifact-privacy-scan.sh`) remains
the live blocking gate for any core executable/archive.

### I-12 (Smoke-gated dual-LGTM)
The normative prose for I-12 (smoke-gated dual-LGTM) has a single canonical home:
`docs/canonical-invariants.md §I-12`. Do not restate the mechanism here — read
that section for the authoritative `provisional → final` rule, the
`phase-done-smoke.sh` exit-0 + `smoke_evidence_sha256` requirement, and the
`.agent/state/dual_lgtm_state.json` `lgtm_stage = final` advance gate
(`scripts/state-transition-guard.sh --require-lgtm-final`) — that gate covers
only that one state file, not every file that happens to have a `phase`
field. The matrix row
(`docs/manual/verification-truth-matrix.md` I-12) is the acceptance-gate
expression. See the Authority Map in `docs/canonical-invariants.md §Authority Map`.
