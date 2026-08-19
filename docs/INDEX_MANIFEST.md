# INDEX Manifest

INDEX is a navigation and freshness contract for mapped Revharness surfaces. It
is never acceptance truth, never liveness proof alone, and never a substitute for
source reads, diffs, deterministic checks, reviewer artifacts, or shipped
artifact privacy evidence. The acceptance authority remains
`docs/manual/verification-truth-matrix.md`, including its INDEX row that marks
INDEX validation as necessary but not sufficient for mapped freshness.

## Map Registry

| map | scope summary | owner surface | granularity | validation | update triggers |
|---|---|---|---|---|---|
| docs/INDEX_MAP-ORCHESTRATION.md | wrappers, dispatch, roles, rules, workflow skills, orchestration state helpers | orchestration | surface | scripts/ci/index-map-check.sh --strict | wrapper change, role-boundary change, dispatch change, rule change, workflow skill change, orchestration state change |
| docs/INDEX_MAP-GATES.md | deterministic gates, CI checks, invariant docs, verification matrix, privacy and smoke scripts | gates | file | scripts/ci/index-map-check.sh --strict | gate add/move/remove, invariant change, truth-matrix check change, privacy check change, smoke check change |

## Live Enum

The `live` column in every INDEX_MAP row uses exactly one of these values:

| value | operational meaning |
|---|---|
| default-live | Runs or is loaded in the default harness path without a user opt-in. |
| live-when-invoked | Dormant until a command, wrapper, hook, or documented operator action invokes it. |
| opt-in | Requires an explicit flag, config, environment variable, install step, or addon enablement. |
| advisory | Provides guidance or discovery only and cannot prove completion or correctness. |
| dev-only | Used for local development, diagnostics, scaffolding, or maintenance. |
| test-only | Used only by tests, fixtures, or validation harnesses. |
| deprecated | Retained for compatibility or migration history and scheduled for removal. |
| dead-code | Present or referenced but not reachable in the current supported flow. |
| unknown | Liveness is unresolved maintenance debt counted against the map budget. |

## Authority Enum

The `authority` column in every INDEX_MAP row uses exactly one of these values:

| value | operational meaning |
|---|---|
| gate | Deterministic check or acceptance-blocking gate pointed to by the row. |
| contract | Binding policy, role, invariant, or task contract text. |
| tool | Executable helper, wrapper, hook, CLI, or implementation surface. |
| config | Settings or wiring surface. |
| doc | Informative or operator-facing documentation. |
| evidence | Durable artifact, metric, state, queue, or evidence location. |

## Row Contract

Every `docs/INDEX_MAP-*.md` file has a `## Contract Header` followed by rows with
exactly seven columns:

| path | kind | purpose | live | authority | checks | notes |
|---|---|---|---|---|---|---|

Maps use surface-level rows by default. `docs/INDEX_MAP-GATES.md` is the only
initial file-level map because individual gates are independently load-bearing.
Each map is capped at 250 lines and 60 rows. Crossing either cap requires a new
manifest row and a disjoint map scope.

## Scope Rules

Map scopes are git pathspecs. A scope may include tracked paths plus newly
created files in the current slice. Manifest bijection is strict: every
`docs/INDEX_MAP-*.md` file on disk must have one registry row, and every registry
row must resolve to a map file. Header scopes must be pairwise disjoint so two
maps cannot become parallel catalogs for the same surface.

## Update Obligation

Any change that adds, moves, removes, rescopes, or changes the live state of a
mapped surface must update the matching INDEX_MAP in the same slice or commit.
Gate changes, invariant changes, role-boundary changes, wrapper behavior
changes, config wiring changes, and addon-core boundary changes are update
triggers. Typo-only, comment-only, and test-only edits are exempt when they do
not change a mapped surface's purpose, scope, liveness, or checks.

An agent that notices a stale row fixes it in-slice when it is inside scope, or
reports it as a blocker when it is outside scope. Reviewers treat a failing
strict INDEX validator as missing deterministic evidence for mapped freshness,
not as a correctness verdict.

## Exemption Mechanism

Use an `Index-Exempt: <reason>` commit trailer only when a committed change
matches a mapped scope but legitimately does not require an INDEX update, such
as mechanical formatting or comment-only churn. The trailer is an auditable
escape hatch, not silent permission. The validator recognizes trailers over the
committed diff range; reviewers still judge whether the reason is valid.

## Validator Usage

Run:

```bash
bash scripts/ci/index-map-check.sh --strict
```

Optional validator arguments:

```bash
bash scripts/ci/index-map-check.sh [--strict] [--map docs/INDEX_MAP-X.md] [--base <ref>] [--worktree] [--exempt <pathspec>]
```

Exit codes are `0` clean, `1` policy violation, `2` usage error, and `3`
environment failure. The validator checks manifest bijection and disjoint
scopes, header completeness and commit resolvability, seven-column row shape and
enum validity, path resolution, invariant and script references, committed-diff
freshness with `Index-Exempt:` trailer support, last-verified staleness, map
size caps, and unknown budgets.
