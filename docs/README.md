# Documentation

Stable documentation for RevHarness. Dated run results, handovers, and other
volatile evidence do not live here — they belong under `.claude/tmp/` or
`.agent/active/`. This directory holds rules that outlive a single task.

日本語版は [`ja/`](ja/) 配下にあります。

---

## Language: what is actually translated, and what is not

Be aware of this before you clone and start reading:

- This README and `getting-started/` are written in English.
- Most of the normative documents this harness actually points you to are
  written in Japanese and have **not** been translated, including the
  document this README calls the acceptance authority
  ([`manual/verification-truth-matrix.md`](manual/verification-truth-matrix.md)),
  the three role definitions under [`roles/`](roles/), `.claude/CLAUDE-LOCAL.md`,
  and the large majority of other files outside `docs/ja/` (hundreds of them,
  spanning skills, scripts, and internal docs — the exact count drifts as
  files are added or removed, so it is not tracked here).
- Agents driven by this harness respond to the user in Japanese by default.
  This comes from `.agent_rules/shared-language.md` rules `RS-LANG-01` and
  `RS-LANG-03`. It is a default, not a fixed requirement — edit those two
  rules in that file to change the default response language for your
  deployment.
- Console output from setup scripts such as `scripts/init-project.sh` is also
  in Japanese.

If you need an English-only operating experience, expect to either work
through the Japanese normative documents (a translator or LLM can help) or
edit `.agent_rules/shared-language.md` and translate the documents you rely
on most, starting with the verification truth matrix and the role
definitions.

## Start here

If you have never used this harness, read these in order. They are written to be
read straight through.

1. [Requirements](getting-started/requirements.md) — what your machine needs.
   The bash version matters on macOS.
2. [Installation](getting-started/installation.md) — one entry point, and what
   it actually does to your repository.
3. [First run](getting-started/first-run.md) — a worked tutorial: give an agent
   a task, verify the result yourself, run it through review.
4. [Daily use](getting-started/daily-use.md) — roles, task classification, the
   review loop, where evidence lands.
5. [Troubleshooting](getting-started/troubleshooting.md) — symptom, cause, fix.

## Understanding the design

| Document | What it answers |
|---|---|
| [Canonical invariants](canonical-invariants.md) | The twelve rules the harness will not bend, and how strongly each is actually enforced |
| [Verification truth matrix](manual/verification-truth-matrix.md) | **The acceptance authority.** What "done" means, which checks are blocking, what evidence must exist |
| [Why there is no semantic index](architecture/why-no-semantic-index.md) | Why the tree-sitter and semantic-MCP layer was built, then removed |
| [Self-defense architecture](manual/self-defense-architecture.md) | How the harness protects itself from the agents operating it |
| [Operating model](manual/worldclass-harness-operating-model.md) | The reasoning behind the role and ceremony structure |

## Roles

Three canonical roles, each with a written contract:

- [Orchestrator](roles/orchestrator.md) — plans, delegates, verifies. Does not implement.
- [Coder](roles/coder.md) — implements inside an accepted slice.
- [Reviewer](roles/reviewer.md) — reviews independently. Does not implement.

## Operator reference

| Topic | Document |
|---|---|
| Install, upgrade, repair, uninstall | [rev-harness lifecycle](manual/rev-harness-lifecycle.md) |
| Running the full check suite | [Release gate](manual/harness-release-gate.md) |
| The install smoke gate | [Phase-done smoke](manual/phase-done-smoke.md) |
| Phase transitions and their guard | [State transition guard](manual/state-transition-guard.md) |
| Parallel dispatch and snapshots | [Safe dispatch](manual/safe-dispatch.md), [Snapshot hooks](manual/snapshot-hooks.md) |
| Keeping secrets out of commits | [Secret guard](manual/secret-guard-usage.md), [Path-leak layer](manual/path-leak-soft-layer.md) |
| Subscription-based agent auth | [Subscription orchestration](manual/subscription-orchestration.md) |
| MCP process hygiene | [MCP zombie lifecycle](manual/mcp-zombie-lifecycle-hygiene.md) |
| Skills: routing, integration | [Skill integration](manual/skill-integration.md), [Skill routing](manual/skill-routing-matrix.md) |
| Cursor CLI | [Cursor integration](manual/cursor-cli-integration.md#cursor-rules-residual-risks) (includes residual risks) |
| Reader-specific orientation (end user, harness developer, maintainer) | [Audience guides](manual/end-user-guide.md) |

## Customizing it for your project

The harness ships with the mechanisms and a deliberately generic set of gates.
Making it useful for your stack means adding your own checks.

- [Developer customization guide](manual/end-user-guide.md#part-2--developer-customization-guide)
  — same file as the end-user / audience guides below, Part 2
- [ExecPlan checklist standard](manual/execplan-checklist-standard.md) — the
  format for planning non-trivial work
- [Common task contract](manual/common-task-contract.md)
- [Adoption guide](adoption-guide.md) — overlaying the harness on an existing
  repository

## Navigation maps

[`INDEX_MANIFEST.md`](INDEX_MANIFEST.md) and the `INDEX_MAP-*.md` files record
where authority lives in this repository — which file owns which decision.
They are a navigation aid, checked for drift by
`scripts/ci/index-map-check.sh`, and are explicitly **not** acceptance truth.
