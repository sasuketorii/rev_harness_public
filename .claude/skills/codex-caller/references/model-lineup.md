# GPT-5.6 model lineup and subagent availability

Source: internal companion knowledge base (private, not part of this public tree). Verified on-device
2026-08-19 on `codex-cli 0.147.0` under ChatGPT subscription auth, Darwin
arm64. "On-device verified" below means `codex exec -c model=... -c
model_reasoning_effort=...` was actually run on that machine and produced a
response; anything else is reported second-hand and marked as such. This file
is a generalized adaptation for public distribution — machine-specific paths
and private-repo agent filenames have been removed or replaced with the
general pattern.

## Lineup (GA 2026-07-09, preview started 2026-06-26)

| tier | model id | positioning | subscription on-device verified |
| --- | --- | --- | --- |
| Sol | `gpt-5.6-sol` | flagship; this repo's `codex-wrapper.sh` pins to this model | yes (2026-07-13 migration) |
| Terra | `gpt-5.6-terra` | mid-tier, roughly half the cost of Sol | yes (2026-08-19) |
| Luna | `gpt-5.6-luna` | fastest/cheapest; suited to high-volume, clearly-scoped work | yes (2026-08-19, `model_reasoning_effort=max` accepted) |

All three tiers share a 2026-02-16 knowledge cutoff, 1M context, and a
published 128k output cap. Luna had an 80% price cut on 2026-07-30.

## "luna-max" is not a real model id

`gpt-5.6-luna-max` / `gpt-5.6-lunamax` are **not valid model ids**. Under
subscription auth they are rejected with "not supported when using Codex
with a ChatGPT account" (observed 2026-08-19 — the same rejection pattern
seen earlier with `gpt-5.5-codex`). What people informally call "Luna at
Max" is the *combination* of `model = "gpt-5.6-luna"` with
`model_reasoning_effort = "max"`, not a separate model.

## Calling Luna/Terra as a subagent

- **Custom agent definitions are the supported path.** On `codex-cli
  0.147.0`, Luna works as a native subagent when it is declared through a
  custom agent TOML (e.g. under `.codex/agents/*.toml` or
  `$CODEX_HOME/agents/*.toml`) rather than requested ad hoc. This repo's own
  `.codex/agents/` directory is the place to look for (or add) such
  definitions if you want a Luna- or Terra-backed role.
- **Direct `spawn_agent` model overrides need on-device confirmation
  first.** As of `codex-cli` 0.145.0, Luna was treated as "MultiAgent V1"
  and was rejected by the V2 `spawn_agent` API, which at the time only
  accepted Sol/Terra (tracked upstream as `openai/codex#35097`). Whether
  0.147.0 resolves this was not independently confirmed here — before
  passing a raw `model="gpt-5.6-luna"` to `spawn_agent`, verify on-device;
  if it is rejected, fall back to a custom agent definition instead.

## Relationship to `codex-wrapper.sh` / `codex_invoke.sh`-style wrappers

The canonical caller-facing wrapper in this repo (`scripts/codex-wrapper.sh`,
see `.claude/skills/codex-caller/SKILL.md`) pins its model to
`gpt-5.6-sol` (via `.agent/registry/model_policy.json`'s `current_model`,
changed only through a reviewed model-policy update, never by a caller
override at call time). Using Luna/Terra directly is a separate,
implementation-lane concern — native custom-agent definitions or a direct
`codex exec` call — not something the wrapper's role table exposes. A
reasonable division of labor: design/review work stays on Sol via the
wrapper; clearly-scoped implementation packets can use Luna at a higher
effort level. Either way, verification of the result is the orchestrator's
job — an agent's self-report (including Luna's) is never accepted as
completion evidence on its own.
