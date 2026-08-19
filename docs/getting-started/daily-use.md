# Daily use

日本語版: [docs/ja/getting-started/daily-use.md](../ja/getting-started/daily-use.md)

[First run](first-run.md) walked through one task end to end. This page is the
reference you come back to once RevHarness is part of your normal workflow:
which command to reach for, when a task needs more process than a single
wrapper call, where the evidence for "done" actually lives, and when to write
an ExecPlan instead of just doing the work.

Throughout this page, `$HARNESS` is wherever you cloned RevHarness — see
[First run → 0. Set `$HARNESS`](first-run.md#0-set-harness) if that's
unfamiliar.

---

## The commands you'll actually type

| Command | When |
|---|---|
| `bash "$HARNESS/scripts/rev-harness" status` | Start of a session — is identity/hooks wired here? |
| `bash "$HARNESS/scripts/harness-doctor.sh"` | Non-destructive health check, any time |
| `bash "$HARNESS/scripts/rev-harness-task-classifier.sh" classify --intent <intent> --files <path...> --json` | Before starting any non-trivial task |
| `bash "$HARNESS/scripts/codex-wrapper.sh" --role <role> --stdin` | Delegate work or review to Codex |
| `bash "$HARNESS/scripts/claude-wrapper.sh" --output <file> "prompt"` | Delegate to Claude — see the caveat below |
| `bash "$HARNESS/scripts/dual-lgtm-validate.sh" --plan-id <id> --round <n>` | Confirm two independent LGTMs exist on disk before advancing a phase |
| `bash "$HARNESS/.claude/commands/auto_orchestrate.sh" --plan <plan> --phase <phase> --run-coder` | Run an implement → review → fix loop automatically instead of by hand |
| `bash "$HARNESS/scripts/hydra" new <task-name>` | Cut an isolated worktree + branch for a task |
| `bash "$HARNESS/scripts/project-id.sh" artifact-path` | Where does this project's identity file live? |

Everything below expands on when and why you'd reach for each of these.

## Roles, and which one to use

`scripts/codex-wrapper.sh --help` prints the current role map; it's short
enough to just read directly:

```text
Role map:
  standard  -> medium + cached
  research  -> high + live
  coder     -> medium + cached
  high-coder -> high + cached
  reviewer  -> xhigh + cached
```

- **`coder`** — normal implementation work. Medium reasoning effort, cached
  web search. This is what you use for most changes.
- **`high-coder`** — the same role but with higher reasoning effort, for a
  slice that's unusually gnarly but still a coder's job (not a review).
- **`reviewer`** — always `xhigh` effort. Effort and web-search mode are what
  the role fixes and are not configurable per call (see
  `.agent/registry/model_policy.json`); the underlying model id is not
  role-specific — `codex-wrapper.sh --role reviewer` and `--role coder` both
  resolve to the same `current_model` unless overridden. A genuinely different
  model *family* for review (the cross-family asymmetry the README describes)
  comes from *who you delegate to*, not from the role itself — e.g. Codex
  wrote the change and a Claude Code reviewer judges it, or vice versa. The
  asymmetry (reviewer gets more reasoning budget than the coder) is
  intentional; the cross-family split is a workflow choice, not something the
  wrapper enforces.
- **`research`** — live web search, `high` effort. Use it for "go find out
  X" tasks, not implementation.
- **`standard`** — the default when nothing more specific applies.

You cannot request a different sandbox, approval mode, model, or reasoning
effort on the command line for any of these — the wrapper source comments
call this out explicitly: "Caller overrides for profile, model, reasoning
effort, sandbox, approval, web-search, and workspace-expansion controls are
blocked via CLI flags." If you need a different model than the policy
default, the sanctioned override is an environment variable, not a flag:

```bash
REV_HARNESS_CODEX_MODEL=<model-id> bash "$HARNESS/scripts/codex-wrapper.sh" --role coder --stdin < prompt.md
```

The minimum-model gate still applies to that override — asking for a model
ranked below `minimum_allowed_model` in `.agent/registry/model_policy.json`
fails closed with an explicit error rather than silently falling back to
something weaker. See
[Troubleshooting](troubleshooting.md#a-wrapper-call-rejects-my-model-override)
for exactly what that looks like.

**Claude Code cross-family calls are deprecated.** `scripts/claude-wrapper.sh`
itself prints this on every invocation: cross-family calls into Claude Code
consume Claude Agent SDK / Claude Code subscription usage and are excluded
from the harness's default orchestration flow. If you're driving RevHarness
from inside Claude Code, prefer a native Claude Code subagent (the `Task`
tool) over shelling out through this wrapper. The wrapper still works as a
compatibility shim — see `docs/agent-sdk-policy.md` if you need the detail.

## Task classes: light, standard, heavy

Classify before you start, not after:

```bash
bash "$HARNESS/scripts/rev-harness-task-classifier.sh" classify \
  --intent <intent> --files <path...> --json
```

Valid `--intent` values: `typo`, `reference-cleanup`, `admin`,
`prompt-wording`, `docs`, `implementation`, `test`, `policy`, `security`,
`release`, `live-orchestration`.

| Class | Gate tier | Review required | Final gate required | Typical work |
|---|---|---|---|---|
| `light` | `quick` | no | no | typo fixes, reference cleanup, wording |
| `standard` | `local` | yes, scoped | no | normal implementation, tests, docs |
| `heavy` | `full` | yes | yes | release, security, wrapper/role changes, anything touching the acceptance matrix itself |

Don't apply `heavy`'s full paperwork to a `light` typo fix, and don't let a
`heavy` change skip review because a quick classification felt convenient.
The classifier's `reasons` field tells you why it landed where it did — read
it when the result surprises you.

The full acceptance authority — exact required checks per invariant, the
complete `heavy` schema fields, verdict mapping — lives in
[`docs/manual/verification-truth-matrix.md`](../manual/verification-truth-matrix.md).
That document, not this page, wins if the two ever disagree; this page is a
day-to-day summary, not a replacement for it.

## The review loop

For a single small change, do what [First run](first-run.md) did by hand:
`coder` writes the change, you run your project's real check, `reviewer`
judges the staged diff, you fix and resubmit until it says `LGTM`.

For anything with more than one review round expected, `auto_orchestrate.sh`
runs that same loop for you:

```bash
bash "$HARNESS/.claude/commands/auto_orchestrate.sh" \
  --plan <plan-path> --phase impl \
  --run-coder --coder-engine codex \
  --reviewers safety,perf,consistency \
  --gate levelA
```

Key flags, from its own `--help`:

- `--run-coder` — actually invoke the coder engine (`claude` or `codex`,
  default `codex`) for this phase, instead of expecting output to already
  exist.
- `--reviewers` — comma-separated reviewer lenses; default is
  `safety,perf,consistency`.
- `--max-iterations N` — cap on fix → re-review rounds (default 5). `N=1`
  means "review once, fail immediately on any finding" rather than looping.
- `--gate levelA|levelB|levelC` — run a quality gate after review passes.
- `--resume <state-file>` — continue an interrupted run instead of restarting
  it. `--continue-session` / `--fork-session` are reserved and always
  fail-closed here — orchestrated runs are non-interactive by design, so
  there is no live session to continue.
- `--status` — print a summary of an existing `state.json` instead of running
  anything.

State for a run lives in `.claude/tmp/<task>/state.json`; the contract for
what a coder hands off and what a reviewer sends back is
`docs/prompts/reviewer_batch.md`.

### Confirming two independent LGTMs actually exist

Before you treat a `heavy`-class change as accepted, don't take anyone's word
that both reviews happened — check the artifacts:

```bash
bash "$HARNESS/scripts/dual-lgtm-validate.sh" \
  --plan-id <plan-id> --round <round-int> \
  --expected-reviewers opus,codex --strict
```

This reads on-disk evidence, not chat history. `--strict` fails closed if
either verdict is missing, malformed, or from the wrong reviewer identity.

## Evidence

Two places matter:

- **`.claude/tmp/<task>/`** — run-local state for an orchestrated task:
  `task-contract.json`, `state.json`, per-round reviewer output, and
  `stderr/` directories holding raw wrapper stderr (the
  `REV_HARNESS_DELEGATION_METRIC` line you saw in
  [First run](first-run.md#3-have-the-coder-do-the-work) lands here, one line
  per wrapper invocation — the wrapper itself only prints it; the caller is
  responsible for capturing it). Keep only pointer files
  (`*.stderr-pointer.txt`) near user-facing outputs; the raw stderr stays in
  its own subdirectory.
- **`.agent/active/`** — durable, plan-scoped state: `plan_*.md` ExecPlans,
  the task lineage ledger at
  `.agent/active/sow/task-lineage-ledger.md`, and SOW/handoff documents.

Do not treat `.claude/tmp/**` scratch JSON as durable truth once a task is
closed out — promote whatever matters into `.agent/active/` or your project's
own docs, or it disappears the next time that scratch space is swept.

## When to write an ExecPlan

Not every task needs one. Write an ExecPlan when work spans more than one
session, has more than one slice, or needs a release-boundary you'll refer
back to later. Start from the template:

```bash
cp "$HARNESS/.agent/templates/execplan_checklist_template.md" \
   .agent/active/plan_$(date +%Y%m%d_%H%M)_<task-name>.md
```

Required sections: `Objective`, `Status Board`, `Slice Board`, `In Scope`,
`Out Of Scope`, `Required Deterministic Checks`, `Completion Boundary`. Use
`[x]` / `[ ]` only — if a slice is blocked or deferred, leave it unchecked and
say why inline rather than inventing a third checkbox state. The full
contract, including the conditional fields for slices that use a named
specialty, is
[`docs/manual/execplan-checklist-standard.md`](../manual/execplan-checklist-standard.md).

## Isolating work in a worktree

For a task you want fully isolated from your main checkout — a coder running
unattended, or work you might roll back — `hydra` wraps `git worktree` plus a
PR flow:

```bash
"$HARNESS/scripts/hydra" new my-task       # new worktree + branch
"$HARNESS/scripts/hydra" list              # see active worktrees
"$HARNESS/scripts/hydra" preflight my-task # check for merge conflicts with base
"$HARNESS/scripts/hydra" close my-task     # push, open a PR via gh, remove the worktree
```

`hydra rollback --last --dry-run` previews undoing the most recent merge;
drop `--dry-run` to actually do it. `hydra merge-order` analyzes dependencies
across active worktrees when you have several in flight and need to land them
in the right sequence.

## What to trust when docs disagree

From `docs/manual/end-user-guide.md`, and worth internalizing:

Trust:

- `docs/manual/verification-truth-matrix.md`
- `docs/manual/harness-release-gate.md`
- the current plan, the current SOW, the latest gate artifact

Don't trust:

- a dated handover document as if it were current truth
- scratch JSON under `.claude/tmp/**` as durable authority
- a roadmap entry as if it were already implemented
- a README summary alone as grounds for accepting a change

---

Next: [Troubleshooting](troubleshooting.md) if something in your day-to-day
loop isn't behaving the way this page describes.
