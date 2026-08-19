# INDEX Map - Orchestration

See `docs/INDEX_MANIFEST.md` for the live enum, authority enum, update
obligation, exemption mechanism, and validator usage.

## Contract Header

- purpose: Navigate Revharness orchestration wrappers, roles, rules, workflow skills, dispatch helpers, and state surfaces.
- scope: AGENTS.md CLAUDE.md .agent_rules/** .claude/CLAUDE-LOCAL.md .claude/commands/** .codex/agents/** .codex/hooks.json .codex/hooks/** .cursor/rules/** .agents/skills/auto-orchestrator/SKILL.md .agents/skills/system-planner/SKILL.md .agents/skills/research-handoff/SKILL.md .agents/skills/review-workflow/SKILL.md .agents/skills/codex-caller/SKILL.md .agents/skills/cursor-caller/SKILL.md .agents/skills/orchestrator-bootstrap/SKILL.md .agents/skills/scope-guard/SKILL.md .agents/skills/slice-designer/SKILL.md .agents/skills/structured-mentor/SKILL.md .claude/skills/auto-orchestrator/SKILL.md .claude/skills/system-planner/SKILL.md .claude/skills/research-handoff/SKILL.md .claude/skills/review-workflow/SKILL.md .claude/skills/codex-caller/SKILL.md .claude/skills/cursor-caller/SKILL.md .claude/skills/orchestrator-bootstrap/SKILL.md .claude/skills/scope-guard/SKILL.md .claude/skills/slice-designer/SKILL.md .claude/skills/structured-mentor/SKILL.md docs/roles/** scripts/claude-wrapper.sh scripts/codex-wrapper*.sh scripts/codex-job.sh scripts/cursor-wrapper.sh scripts/hydra scripts/safe-dispatch.sh scripts/snapshot-dispatch.sh scripts/harness-block-router.sh scripts/rev-harness-worker-lifecycle.sh scripts/validate-orchestration-packet.sh scripts/model-policy.sh scripts/rev-harness-dirty-surface.sh scripts/collect-delegation-metrics.sh scripts/compute-completion-delta.sh scripts/harness-active-artifact-pruner.sh scripts/harness-bg-spawn.sh scripts/harness-check-planner.sh scripts/harness-governance-classifier.sh scripts/harness-projection-preflight.sh scripts/rev-harness-admission.sh scripts/rev-harness-dual-native-check.sh scripts/rev-harness-evidence-manifest.sh scripts/rev-harness-skill-projection.sh scripts/rev-harness-skill-routing-check.sh
- out-of-scope: .agent/archive/** .agent/active/** .agent/metrics/** docs/archive/** docs/INDEX_MAP-*.md
- row-granularity: surface
- last-updated: 2026-06-29
- last-verified-commit: f0beb9e
- related-invariants: I-3 I-5 I-6 I-7 I-8 I-9 I-10 I-11 I-12
- validation: scripts/ci/index-map-check.sh
- update-triggers: wrapper change, role-boundary change, dispatch change, rule change, workflow skill change, orchestration state change
- exceptions: .codex/config.toml .claude/settings.json .mcp.json.template
- unknown-budget: 3

## Critical Summary

This map is navigation only. Wrapper, role, and skill rows point to the surfaces
that control orchestration behavior; they do not prove that a slice is accepted
or that a delegated agent used the correct runtime path.

## Rows

| path | kind | purpose | live | authority | checks | notes |
|---|---|---|---|---|---|---|
| AGENTS.md | md | Vendor-neutral root invariant contract and cross-family boundaries. | default-live | contract | I-1 I-3 I-12 | Read before repo-wide orchestration decisions. |
| CLAUDE.md | md | Claude entrypoint that points at Claude-local operating rules. | default-live | contract | I-3 I-12 | Claude-family bootstrap surface. |
| .agent_rules/RULES.md | md | Shared-rule index that incorporates binding modules under `.agent_rules/shared-*.md`. | default-live | contract | I-3 I-12 | Read-order step 3 from AGENTS.md points here. |
| .agent_rules/shared-language.md | md | Shared language and canonical vocabulary rules. | default-live | contract | I-3 I-12 | Incorporated by `.agent_rules/RULES.md`. |
| .agent_rules/shared-safety.md | md | Shared safety, project identity, redaction, destructive opt-in, and fail-closed rules. | default-live | contract | I-1 I-3 I-11 I-12 | Incorporated by `.agent_rules/RULES.md`. |
| .agent_rules/shared-workflow.md | md | Shared workflow, ExecPlan, worktree, SOW, and folder-map rules. | default-live | contract | I-3 I-6 I-12 | Incorporated by `.agent_rules/RULES.md`. |
| .agent_rules/shared-acceptance.md | md | Shared acceptance language guard and evidence pointer rules. | default-live | contract | I-3 I-12 | Incorporated by `.agent_rules/RULES.md`; matrix owns detailed state machines. |
| .agent_rules/shared-delegation.md | md | Shared wrapper role map and native-vs-cross-family delegation rules. | default-live | contract | I-3 I-5 I-12 | Incorporated by `.agent_rules/RULES.md`. |
| .claude/CLAUDE-LOCAL.md | md | Claude-specific orchestration, wrapper, and state-management rules. | default-live | contract | I-3 I-12 | Vendor-specific boundary excluded from root AGENTS.md. |
| docs/roles/orchestrator.md | md | Orchestrator role responsibilities; defers read order to AGENTS.md. | default-live | contract | I-3 I-12 | Read order is owned by AGENTS.md §Read Order (not redefined here). |
| docs/roles/coder.md | md | Coder role responsibilities and implementation report expectations. | live-when-invoked | contract | I-3 | Used by delegated coder slices. |
| docs/roles/reviewer.md | md | Reviewer role criteria and findings-first report posture. | live-when-invoked | contract | I-3 I-12 | Review verdicts are not final acceptance alone. |
| docs/roles/*/specialties/*.md | md | Specialty role lenses for focused coder, reviewer, and orchestrator work. | live-when-invoked | contract | I-3 | Projected specialty surfaces; not standalone acceptance. |
| .claude/commands/auto_orchestrate.sh | bash | Claude-side orchestration entrypoint for plan-driven coder and reviewer flow. | live-when-invoked | tool | I-3 I-6 I-12 | Emits and validates task contracts before worker launch. |
| .claude/commands/lib/*.sh | bash | Shared Claude command library for sessions, packets, coder, and reviewer launch. | live-when-invoked | tool | I-3 I-5 I-12 | Supports auto_orchestrate and session flows. |
| scripts/claude-wrapper.sh | bash | Canonical Claude CLI wrapper and role normalization path. | live-when-invoked | tool | I-5 scripts/ci/check-wrapper-help-parity.sh | Caller-facing Claude execution surface. |
| scripts/codex-wrapper.sh | bash | Canonical Codex CLI wrapper and role normalization path. | live-when-invoked | tool | I-5 scripts/ci/check-wrapper-help-parity.sh | Caller-facing Codex execution surface. |
| scripts/codex-wrapper-high.sh | bash | Legacy high shim into canonical Codex role handling. | live-when-invoked | tool | I-5 scripts/ci/check-wrapper-help-parity.sh | Compatibility shim, not source of role truth. |
| scripts/codex-wrapper-medium.sh | bash | Legacy medium shim into canonical Codex role handling. | live-when-invoked | tool | I-5 scripts/ci/check-wrapper-help-parity.sh | Compatibility shim, not source of role truth. |
| scripts/codex-wrapper-xhigh.sh | bash | Legacy xhigh shim into canonical Codex role handling. | live-when-invoked | tool | I-5 scripts/ci/check-wrapper-help-parity.sh | Compatibility shim, not source of role truth. |
| scripts/codex-job.sh | bash | Codex job helper for managed non-interactive invocations. | live-when-invoked | tool | I-3 I-5 | Used behind wrapper-orchestrated Codex work. |
| scripts/cursor-wrapper.sh | bash | Cursor-family wrapper entrypoint. | live-when-invoked | tool | I-3 | Cursor agents do not cross-delegate unless a Cursor rule permits it. |
| .codex/agents/*.toml | config | Codex native subagent presets for planner, coder, and reviewer roles. | default-live | config | I-3 I-12 | Native Codex subagents stay inside Codex. |
| .codex/hooks.json | config | Codex hook configuration surface. | default-live | config | I-3 | Hook script path is `.codex/hooks/codex-review-hook.sh`. |
| .codex/hooks/codex-review-hook.sh | bash | Codex review hook integration point. | default-live | tool | I-3 I-12 | Shell-only PostToolUse pre-filter; cargo-free on all paths; pins core review queue backend (mirrors .claude hook, P3). Distinct from Claude PostToolUse hook. |
| .cursor/rules/*.mdc | md | Cursor-specific rules for attachment and CLI behavior. | default-live | contract | I-3 | Cursor follows these rather than orchestrator-bootstrap. |
| .agents/skills/orchestrator-bootstrap/SKILL.md | skill | Codex-side required session-start raw-read routine. | default-live | contract | I-3 I-12 | Must run before substantive orchestrator action unless explicitly skipped. |
| .claude/skills/orchestrator-bootstrap/SKILL.md | skill | Claude-side required session-start raw-read routine. | default-live | contract | I-3 I-12 | Family-native mirror of the bootstrap workflow. |
| .agents/skills/auto-orchestrator/SKILL.md | skill | Codex-side router for Phase 2 orchestration workflows. | live-when-invoked | tool | I-3 I-12 | Thin routing skill, not the reusable workflow owner. |
| .claude/skills/auto-orchestrator/SKILL.md | skill | Claude-side router for Phase 2 orchestration workflows. | live-when-invoked | tool | I-3 I-12 | Mirrors the Codex skill. |
| .agents/skills/system-planner/SKILL.md | skill | Codex-side reusable planning workflow. | live-when-invoked | contract | I-3 I-12 | Owns ExecPlan generation workflow. |
| .claude/skills/system-planner/SKILL.md | skill | Claude-side reusable planning workflow. | live-when-invoked | contract | I-3 I-12 | Mirrors the Codex skill. |
| .agents/skills/research-handoff/SKILL.md | skill | Codex-side external research and handoff workflow. | live-when-invoked | contract | I-3 | Produces durable research context. |
| .claude/skills/research-handoff/SKILL.md | skill | Claude-side external research and handoff workflow. | live-when-invoked | contract | I-3 | Mirrors the Codex skill. |
| .agents/skills/review-workflow/SKILL.md | skill | Codex-side review and fix loop workflow. | live-when-invoked | contract | I-3 I-12 | Reviewer intake owner; verdicts remain matrix-bound. |
| .claude/skills/review-workflow/SKILL.md | skill | Claude-side review and fix loop workflow. | live-when-invoked | contract | I-3 I-12 | Mirrors the Codex skill. |
| .agents/skills/codex-caller/SKILL.md | skill | Codex-side cross-Codex caller workflow. | live-when-invoked | tool | I-3 I-5 | Uses canonical wrapper discipline for external Codex calls. |
| .claude/skills/codex-caller/SKILL.md | skill | Claude-side Codex caller workflow. | live-when-invoked | tool | I-3 I-5 | Claude-to-Codex crossing requires durable packet discipline. |
| scripts/hydra | bash | Worktree creation helper for isolated implementation flow. | live-when-invoked | tool | I-3 I-11 | Supports worktree-first development. |
| scripts/safe-dispatch.sh | bash | Parallel dispatch wrapper with ownership and snapshot guardrails. | live-when-invoked | tool | I-6 I-7 I-8 I-9 scripts/ci/check-execplan-topology.sh | Paired with snapshot hooks that are mapped in GATES. |
| scripts/snapshot-dispatch.sh | bash | Snapshot-oriented dispatch helper. | live-when-invoked | tool | I-8 I-9 | Records dispatch boundary evidence. |
| scripts/harness-block-router.sh | bash | Routes block reports to the appropriate owner path. | live-when-invoked | tool | I-3 I-12 | Used when fail-closed routing is required. |
| scripts/rev-harness-worker-lifecycle.sh | bash | Worker lease and lifecycle helper. | live-when-invoked | tool | I-3 I-6 | Coordinates worker lifecycle states. |
| scripts/validate-orchestration-packet.sh | bash | Validates orchestration packet shape before worker launch. | live-when-invoked | gate | I-3 I-12 | Orchestration-local deterministic validation. |
| scripts/model-policy.sh | bash | Reads and applies model-policy registry decisions. | live-when-invoked | tool | I-3 | Prevents ad hoc role/model drift. |
| scripts/rev-harness-dirty-surface.sh | bash | Captures and compares dirty-surface baseline state. | live-when-invoked | tool | I-3 | Used by baseline-protection workflows. |
| scripts/collect-delegation-metrics.sh | bash | Collects delegation metrics into durable metrics surfaces. | live-when-invoked | evidence | I-3 | Metric schemas are validated separately in GATES. |
| scripts/rev-harness-evidence-manifest.sh | bash | Builds evidence manifests for review and release packets. | live-when-invoked | evidence | I-3 I-12 | Artifact integrity support surface. |
