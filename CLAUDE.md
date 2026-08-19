# RevHarness Vendor-Neutral Bootstrap

This file is auto-read by both Claude Code and Cursor CLI. It is intentionally
vendor-neutral and contains only shared RevHarness bootstrap instructions.
Vendor-specific operational rules are kept out of this file so that one agent
family does not accidentally follow another family's runtime contract.

Read `AGENTS.md` first for repository-wide RevHarness invariants. Claude Code
orchestrators must then read `.claude/CLAUDE-LOCAL.md` before operating, because
Claude-specific wrapper, delegation, state, and role-switching rules live there.
Cursor-specific rules live under `.cursor/rules/`.
Shared operating rules live under `.agent_rules/` and are incorporated by
reference via `.agent_rules/RULES.md`; read that literal path as part of the
root contract.

## Scope

This file is the root bootstrap for agents that auto-read `CLAUDE.md`. It points
to the authoritative instruction locations and defines only the shared read
order for this repository.

It is not the source of truth for Claude-only orchestration, Codex-only runtime
policy, Cursor project rules, reviewer verdicts, or acceptance closure.

## Shared Sources

- `AGENTS.md`: vendor-neutral RevHarness invariants for every agent family.
- `.agent_rules/RULES.md`: shared-rule index and incorporation point for the
  shared modules under `.agent_rules/`.
- `docs/canonical-invariants.md`: on-disk canonical anchor for the invariant
  set; read this for the full current invariant set rather than rediscovering
  rows from root summaries.
- `.claude/CLAUDE-LOCAL.md`: Claude Code orchestrator-specific operating rules.
- `.cursor/rules/`: Cursor-specific project rules and attachment behavior.
- `docs/roles/*.md`: canonical role definitions.
- `docs/manual/verification-truth-matrix.md`: acceptance and evidence authority.
- `.agent/PROJECT_CONTEXT.md`: project-specific context.
- `.shared/project_id`: immutable project identity.

## Truth Read Order

Use the numbered read order in `AGENTS.md` §Read Order for shared,
vendor-neutral decisions. This file intentionally does not restate that list.

Vendor-specific rules may narrow how an agent acts, but they do not override the
truth matrix's deterministic acceptance requirements.

For the shared release-invariant gates, the following references apply
regardless of operating agent family:

- Read `docs/canonical-invariants.md` for the canonical invariant set.
- For phase advance, I-12 (smoke-gated dual-LGTM) governs the
  `state-transition-guard --require-lgtm-final` gate. The mechanism's normative
  prose is owned by `docs/canonical-invariants.md §I-12` — read it there; this
  file does not restate the smoke / `lgtm_stage` / phase-advance details.
- Vendor-family-specific delegation, wrapper, or role-switching guidance for
  these release gates belongs in `.claude/CLAUDE-LOCAL.md` (Claude Code) or
  under `.cursor/rules/` (Cursor) — not in this file.

## Claude Bootstrap

When the current operator is Claude Code, read `.claude/CLAUDE-LOCAL.md` at
session start before planning, delegating, editing, reviewing, or reporting. The
root file is intentionally too small to carry Claude orchestration details.

In addition, the session-start rule (invoke the `orchestrator-bootstrap` skill
before the first substantive action) has a single canonical home:
`AGENTS.md §Session Start (Orchestrator session)`. Read that section for the
authoritative rule; this file does not restate it. The only Claude-specific
delta is the invocation mechanism: a Claude Code orchestrator invokes
`orchestrator-bootstrap` via the `Skill` tool (Codex uses its native skill
mechanism). The session-start rule itself is identical across families. See the
Authority Map in `docs/canonical-invariants.md §Authority Map`.

If `.claude/CLAUDE-LOCAL.md` is missing or unreadable during a Claude Code
orchestrator session, fail closed and report that the Claude-specific operating
contract is unavailable.

## Cursor Bootstrap

Cursor agents should treat this file as shared context only. Cursor-specific
rules, including rule attachment and mode-specific behavior, belong in
`.cursor/rules/` and must not be inferred from Claude or Codex documents.

If Cursor-specific rules are absent, do not invent delegation, wrapper, or
runtime behavior from this file. Follow the user instruction, `AGENTS.md`, and
the truth matrix.

## Codex Bootstrap

Codex agents should treat this file as shared context only. Codex runtime
configuration and native subagent presets live under `.codex/`; external
caller-facing execution contracts are documented with the canonical wrappers in
`scripts/`.

This bootstrap does not redefine Codex model policy, sandbox policy, or reviewer
authority.

Shared mirror for dual-native orchestration: Claude top-level sessions use
Claude-native subagents, Codex top-level sessions use Codex native subagents,
and cross-family handoffs use artifact packets. The shared wrapper role map and
compatibility shim mapping are owned by `.agent_rules/shared-delegation.md`.

## Acceptance

`docs/manual/verification-truth-matrix.md` is the authority for acceptance,
worker outcome, evidence placement, reviewer verdict validity, and completion
language. A response, wrapper invocation, or local convention is not enough to
claim acceptance.

Every agent must preserve required deterministic checks, command results,
covered scope, and evidence pointers according to the active slice contract.

## Evidence And Secrets

Use `.claude/tmp/<task>/` or `.agent/active/` for task evidence unless the slice
contract names another destination. Keep artifacts traceable enough for a later
reviewer to replay the decision.

Do not write raw secrets, credentials, tokens, cookies, or unredacted sensitive
payloads into prompts, logs, artifacts, tests, screenshots, or reports. Prefer
redacted previews and record when raw output was intentionally withheld.

## Project Identity

`.shared/project_id` is immutable project identity. Do not regenerate or edit it
during routine instruction, wrapper, or rule migrations.

If project identity is missing or malformed, stop and report the blocker instead
of creating a new identity opportunistically.

## Maintenance Rule

Keep this file short and vendor-neutral. If an update adds agent-family-specific
commands, wrapper details, role-switching obligations, state schemas, or
delegation mechanics, move that content to the vendor-specific location and
leave only a pointer here.
