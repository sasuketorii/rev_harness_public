---
name: orchestrator-bootstrap
description: Session-start routine for orchestrator. Raw-read the required session context first. Never block on absent context.
---

# Skill: Orchestrator Bootstrap

## When to use
- orchestrator role で session を新規開始する直後
- 既存 handover を受けて bootstrap する直後

## Goal
session-open の必須 context は raw-read で取得する。

## Steps
1. Raw-read required session context:
   a. `AGENTS.md` と `.agent_rules/RULES.md` の applicable bootstrap / invariant sections。
   b. 現 active plan（例: `.agent/active/plan_*.md`）と current handover / worker packet。
   c. task-local acceptance / evidence instructions。
2. Active lineage:
   `.agent/active/sow/task-lineage-ledger.md` の該当 lineage entry を raw-read する。
3. Auto-memory consult: family-native memory path (`~/.claude/projects/<project>/memory/MEMORY.md` for Claude, `~/.Codex/projects/<project>/memory/MEMORY.md` for Codex) の index を読み、`baseline-protection`、`Option D`、`plan-lgtm`、`codex-two-stage` など関連 pattern を identify する。
4. User meta-goal 再確認: user の session-start message と `.agent/PROJECT_CONTEXT.md` の meta-goal section を参照し、orchestrator の意思決定をそこへ align する。
5. Truth read order 検証: AGENTS.md §Read Order の numbered read order（step 3 = .agent_rules/RULES.md と incorporated shared modules）に従い authority を確認する。role 固有の詳細は docs/roles/orchestrator.md を参照する。

## Exit criteria
- 上記 5 step が完了している
- session-open context が `~30k token` 以内に収まっている
- 超過時は compression または fork を検討する
