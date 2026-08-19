# Rust Skills Pack Packaging

- **Document ID**: `rustskills-skill-packaging`
- **Status**: durable repo packaging policy

## Decision

The Rust skills content ships as `rust-skills-knowledge-pack`, self-contained
under the skill bundle:

- canonical source: `.claude/skills/rust-skills-knowledge-pack`
- derived provider projection: `.agents/skills/rust-skills-knowledge-pack`
  (byte-for-byte, regenerated from the canonical source; never hand-edited)
- installed Codex projection: `${CODEX_HOME:-$HOME/.codex}/skills/rust-skills-knowledge-pack`

The canonical source is projected byte-for-byte to every provider/runtime target named above.

## Why References Stay In The Skill

The topic-scoped reference files under `references/` (e.g. `async-io.md`,
`extreme-io-linux.md`, `memory-performance.md`, `leptos-wasm-builder.md`, and
the other narrow-lane guides in that directory) are intentionally packaged
with the skill.

Reasons:

- Installed Codex skills must work outside this repository.
- Claude and Codex projections are checked byte-for-byte.
- The projection manifest currently models skill-tree parity, not external docs dependencies.
- Source traceability and update workflows are part of what the skill may need during maintenance tasks.

`SKILL.md` points routine work to narrow lane references so the full reference set is not loaded by default.

## What Belongs In Docs

Repo-operational placement policy belongs here in `docs/rustskills/`.

This docs file is the durable place for:

- why the skill is self-contained
- why root skill `README.md` and `AGENTS.md` are not allowed
- why detailed maintenance materials remain in `references/`
- how byte-for-byte projection parity is verified

This docs file is not part of the installed skill payload and must not be required for ordinary use of the skill.

## Root Skill Directory Contract

The root of `rust-skills-knowledge-pack` may contain only loader-supported entries:

- `SKILL.md`
- `agents/`
- `assets/`
- `references/`
- `scripts/`

Do not add root `README.md`, `AGENTS.md`, changelog, installation guide, or other auxiliary root docs to the skill bundle. Put repo-operational docs under `docs/rustskills/` and skill-use details under `references/`.

## Required Verification

Run the skill projection checks after any canonical skill edit:

```bash
jq empty .agent/registry/skill_projection_manifest.json
bash -n scripts/rev-harness-skill-projection.sh test/integration/rev_harness_skill_projection_test.sh
python3 ${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py .claude/skills/rust-skills-knowledge-pack
python3 ${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py .agents/skills/rust-skills-knowledge-pack
python3 ${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py "${CODEX_HOME:-$HOME/.codex}/skills/rust-skills-knowledge-pack"
bash scripts/rev-harness-skill-projection.sh --check --json
bash test/integration/rev_harness_skill_projection_test.sh
diff -qr .claude/skills/rust-skills-knowledge-pack .agents/skills/rust-skills-knowledge-pack
diff -qr .claude/skills/rust-skills-knowledge-pack "${CODEX_HOME:-$HOME/.codex}/skills/rust-skills-knowledge-pack"
test ! -e rustskills
git diff --check
```
