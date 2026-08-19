# Skill Integration

This document is the stable index for Revharness skill packages. It does not
mirror skill internals. Operational checklists, risk matrices, source
registries, prompts, and scripts stay inside each skill package so agents load
them only when the skill is relevant.

## Installed Skill Packages

Canonical source in this distribution:

- `.claude/skills/*` is the source of truth for every shipped skill package
  below. Adopters that maintain a separate internal skill-authoring repo may
  mirror changes into their own repo per their own workflow, but that repo is
  not part of this public tree and this document does not depend on one
  existing.

Install targets:

- `.claude/skills/*`
- `${CODEX_HOME:-$HOME/.codex}/skills/*`

Installed packages:

| Package | Skill name | Use |
|---|---|---|
| `client-distribution-readiness` | `client-distribution-readiness` | Client handoff / clean distribution readiness audit for stale archive refs, local paths, semantic DB regeneration, skill sync, and doctor assumptions |
| `cloudflare-deploy-guard` | `cloudflare-deploy-guard` | Cloudflare deploy / settings / billing / security GO/NO-GO gate |
| `codex-app-server-guard` | `codex-app-server-guard` | Codex app-server transport / auth / approval / sandbox / tool-side-effect GO/NO-GO gate |
| `go-skills-knowledge-pack` | `go-skills-knowledge-pack` | Go architecture, review, implementation, and dependency governance |
| `naming-normalization-guard` | `naming-normalization-guard` | Skill / knowledge pack addition, import, rename, and stale-path hygiene |
| `payload-cms-deploy-guard` | `payload-cms-deploy-guard` | Payload CMS production deploy / schema / access / uploads / jobs / migration GO/NO-GO gate |
| `rust-skills-knowledge-pack` | `rust-skills-knowledge-pack` | Rust architecture, implementation, benchmarking, and dependency governance |
| `self-growth-proposal-triage` | `self-growth-proposal-triage` | Self-growth, proposal triage, skill promotion, and cleanup evolution without autonomous mutation |
| `supabase-deploy-guard` | `supabase-deploy-guard` | Supabase deploy / migration / Auth / Storage / Realtime / MCP/API GO/NO-GO gate |
| `typescript-skills-knowledge-pack` | `typescript-skills-knowledge-pack` | TypeScript / Node / frontend / edge / agent architecture and governance |

## Authority Boundary

- `SKILL.md`: trigger metadata, mandatory workflow, output contract, and core rules.
- `references/`: skill-local supporting details. Load only when the triggered
  task needs that reference.
- `scripts/`: deterministic scans, estimators, probes, and local checks.
- `prompts/`: reusable worker or reviewer prompts.
- `README.md`: package-local usage notes. Do not treat it as a repo-wide stable
  operating rule unless this document or another manual explicitly promotes it.
- `provenance.json`: required for new or imported workflow skills after the
  routing-matrix policy. Records source, allowed tools, network policy, MCP
  exposure, and mutation policy.
- `docs/`: stable navigation, routing policy, and update protocol only.

## No Mirror Rule

Do not copy skill-local checklists, risk matrices, source manifests, prompts,
scripts, master packs, or audit reports into `docs/` as standalone content.

If a skill-local artifact is useful, link to it by path instead of duplicating
it. The skill package remains the authority for its bundled materials.

## Freshness Rule

Treat bundled references and source registries as snapshots. For
provider-specific deployment, billing, security, version, or usage-limit
decisions, re-check current official docs, MCP output, dashboards, package
registries, or local CLI output before returning `DEPLOY: GO`, `LGTM`, or
`pending acceptance`.

Official docs and current runtime facts outrank stale bundled references.

## Routing Summary

- Pre-deploy provider changes trigger the matching deploy guard.
- Codex app-server product exposure or proxying triggers `codex-app-server-guard`.
- Go architecture, dependency, performance, or release work triggers
  `go-skills-knowledge-pack`.
- Rust architecture, hot-path, dependency, benchmark, or release work triggers
  `rust-skills-knowledge-pack`.
- TypeScript, Node, frontend, edge, AI-agent, and package governance work
  triggers `typescript-skills-knowledge-pack`.
- RevHarness does not ship a frontend-specific skill. Projects that adopt
  shadcn/ui, React, or Next.js should follow those projects' own official
  docs and CLI directly rather than a RevHarness-provided workflow.
- Skill package addition, import, rename, or reorganization triggers
  `naming-normalization-guard`.
- Self-growth, skill promotion, proposal triage, and HermesAgent-inspired
  workflow evolution trigger `self-growth-proposal-triage`.
- Deploy guards are release gates, not general implementation guides. Use them
  together with the relevant official platform skill when available.

The orchestrator routing table lives in:

- `.claude/skills/auto-orchestrator/SKILL.md`

The machine-checkable task-class to skill routing matrix lives in:

- `.agent/registry/skill_routing_matrix.json`
- `docs/manual/skill-routing-matrix.md`

## Update Protocol

1. Update the package directly under `.claude/skills/<package>` — that is the
   canonical source in this distribution.
2. Validate each changed package with
   `python3 ${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py .claude/skills/<package>`
   when the skill-creator system skill is installed at `$CODEX_HOME`.
3. Sync the whole skill directory to `.agents/skills/<package>` (this repo's
   Codex-native mirror) and `${CODEX_HOME:-$HOME/.codex}/skills/<package>`.
   For shadcn projects, the target product repo should also install or refresh
   the official shadcn skill with `pnpm dlx skills add shadcn/ui` when that
   repo uses agent-managed shadcn UI work.
4. For new or imported skills, add provenance and validate routing with
   `bash scripts/rev-harness-skill-routing-check.sh --json`.
5. Do not hand-edit installed mirrored copies (`.agents/skills/*` or
   `${CODEX_HOME:-$HOME/.codex}/skills/*`) except for emergency repair.
   Follow up by applying the same repair to the canonical `.claude/skills/*`
   copy and re-syncing.
6. Keep `docs/` as an index and policy layer. Do not turn it into a second
   source of truth for skill internals.
7. Skill sharing/projection helpers may remain Python when they are
   low-frequency file projection or validation tasks. Rust-first still applies
   to runtime/control-plane hot paths where performance, safety, and process
   supervision matter.
8. Validate shared Claude/Codex skill parity with:

   ```bash
   bash scripts/rev-harness-skill-projection.sh --check --json
   ```

   The manifest at `.agent/registry/skill_projection_manifest.json` contains
   `shared_skill_sync` entries for shared `.claude/skills/*` packages and their
   installed `${CODEX_HOME:-$HOME/.codex}/skills/*` projections. Local
   `provenance.json` metadata is excluded from byte-for-byte payload comparison.

## semantic-mcp tool surface (存在しない)

semantic MCP の tool surface (`sem.context.top_k` / `sem.capsule` / `sem.search`
/ `sem.admin.gc` など) は、このハーネスには**存在しません**。semantic MCP
runtime、tree-sitter index、semantic capsule、`semantic.db` 配置はもう存在しないため、
これらの tool を前提にした skill 連携は維持しないでください。
