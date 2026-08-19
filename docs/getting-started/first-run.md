# First run

日本語版: [docs/ja/getting-started/first-run.md](../ja/getting-started/first-run.md)

This walkthrough assumes [Requirements](requirements.md) and
[Installation](installation.md) are done. You have RevHarness cloned
somewhere, and either it is already installed into a project or you are about
to install it. By the end of this page you will have made one role-pinned
agent call that wrote real code, checked that code yourself instead of taking
the agent's word for it, and sent it through an independent reviewer call that
initially rejected it and then approved it.

Nothing here is hypothetical. Every command and every quoted output on this
page was run against a real checkout, with real Codex CLI calls, while writing
this document.

---

## The shape of a RevHarness task

Every piece of work that goes through the harness follows the same shape,
regardless of size:

1. **Classify** the task (`light` / `standard` / `heavy`) so you know what
   evidence it needs.
2. **Delegate** to a role-pinned wrapper — `coder` to produce a change,
   `reviewer` to judge it. The wrapper fixes the sandbox, the approval mode,
   and the model; you cannot loosen these from the command line.
3. **Verify it yourself.** Run the actual test or check. An agent claiming
   "tests pass" is not evidence — the check's exit code is.
4. **Get an independent verdict.** A different model reviews the diff. If it
   says `CHANGES REQUESTED`, you fix and resubmit.

This page walks through all four with one tiny piece of real code.

## 0. Set `$HARNESS`

There is exactly one supported layout: you clone RevHarness once, then run
`install --target <path>` against each project you want to harness (see
[Installation → The mental model](installation.md#the-mental-model)). `$HARNESS`
is wherever you cloned RevHarness; your current directory is the project you
installed it into.

```bash
HARNESS=/path/to/rev_harness_public   # wherever you cloned it
cd /path/to/your-project              # the project you ran `install --target` against
```

Building directly inside the harness checkout's own `src/`, without ever
running `install`, is **not** a supported path — it looks like it should work,
but it doesn't. `install` refuses to run against its own checkout
(`ERROR: refusing self-install`), so `.shared/project_id` — the identity file
every wrapper call depends on — never gets created. Every wrapper call below
then fails closed:

```text
[rev-harness] identity-check (strict): repo identity is missing or malformed
              .shared/project_id could not be read as a valid RevHarness identity.
              [rev-harness] strict: refusing to continue.
```

exit code `70`, before Codex or Claude ever runs. If you want RevHarness and
your product code in the same checkout, `git init` an empty directory and
`install --target` that directory — do not skip `install`.

## 1. Confirm your setup

```bash
bash "$HARNESS/scripts/rev-harness" status
```

`phase: done` means identity and git hooks are wired for this directory. If
you get an error here instead of a status report, see
[Troubleshooting](troubleshooting.md) — the two most common causes at this
point are a stale bash and an install that was never run.

You can also run the full check:

```bash
bash "$HARNESS/scripts/harness-doctor.sh"
```

Doctor is advisory — read the `caveat` line in its own output. It is not the
authority on whether your work is accepted; the deterministic checks you run
in step 4 below are. A project directory that only received the lightweight
adopter setup (identity + git hooks) rather than a full RevHarness checkout
may still show one `BLOCK` about
`.agent/generated/codex_model_policy.runtime.json`. That does not stop the
wrapper calls below — see
[Troubleshooting](troubleshooting.md#doctor-blocks-on-a-missing-model-policy-runtime-artifact-in-my-project)
if you want to understand why.

## 2. Classify the task

Before delegating anything, decide how much process it needs:

```bash
bash "$HARNESS/scripts/rev-harness-task-classifier.sh" classify \
  --intent implementation --files src/greet.py --json
```

```json
{
  "schema_version": "rev-harness-task-classifier/v1",
  "task_class": "standard",
  "gate_tier": "local",
  "schema_profile": "standard-slice-contract",
  "review_required": true,
  "final_reviewer_gate_required": false,
  "reasons": [
    "standard intent: implementation",
    "standard surface: src/greet.py"
  ]
}
```

`standard` means: normal implementation work, a scoped reviewer signoff is
required, and you do not need the full release-gate ceremony. That matches
what we're about to do — write one small function and its test.

## 3. Have the coder do the work

Write the prompt to a file so it's easy to reread, then send it through the
`coder` role:

```bash
cat > /tmp/coder-prompt.txt <<'EOF'
Create src/greet.py with a function `greet(name: str) -> str` that returns
f"Hello, {name}!". Also create test_greet.py with one test using plain
assert (no pytest import needed) that checks greet("World") == "Hello, World!".
Keep it minimal. Do not add anything else.
EOF

bash "$HARNESS/scripts/codex-wrapper.sh" --role coder --stdin < /tmp/coder-prompt.txt
```

The wrapper announces the pinned parameters before it does anything:

```text
[codex-wrapper] INFO: Role: coder (--role)
[codex-wrapper] INFO: Model: gpt-5.6-sol
[codex-wrapper] INFO: Reasoning Effort: medium
[codex-wrapper] INFO: Web Search: cached
[codex-wrapper] INFO: Sandbox Mode: workspace-write
[codex-wrapper] INFO: Approval Policy: never
```

None of those five lines came from the prompt. `--role coder` fixed all of
them from `.agent/registry/model_policy.json` before Codex ever ran. Trying to
pass `--model` or `--sandbox` yourself on this wrapper is rejected — that's
the "role boundaries are hard" invariant from the README, not a suggestion.

Codex then does the work inside the sandbox and reports back. The tail of a
real run looked like this:

```text
codex
Created:

- `src/greet.py`
- `test_greet.py`

Test passes; reviewer LGTM.
tokens used
28,249
REV_HARNESS_DELEGATION_METRIC {"schema_version":1,"delegation_id":"df2e3473-...","timestamp":"...","wrapper_role":"coder","exit_code":0,"duration_ms":88916,"tokens_in":28249, ...}
```

Two things worth noticing here. First, `REV_HARNESS_DELEGATION_METRIC` on the
last line — every wrapper call emits exactly one of these on stderr,
independent of what the agent says. That's the record you'd store as evidence
in a real task (see [Daily use](daily-use.md#evidence)). Second: the agent's
own closing line — "Test passes; reviewer LGTM" — is not something you should
believe yet. Nothing has reviewed it, and nothing you've run yourself has
confirmed it. That's the next step.

## 4. Verify it yourself

Read what actually landed on disk:

```bash
cat src/greet.py
cat test_greet.py
```

```python
def greet(name: str) -> str:
    return f"Hello, {name}!"
```

```python
from src.greet import greet


def test_greet() -> None:
    assert greet("World") == "Hello, World!"
```

Now run it — not `python3 test_greet.py` (that only *defines* the test
function; it never calls it, so it exits 0 having tested nothing, which is
exactly the kind of false-positive check this harness exists to catch):

```bash
python3 -m pytest -q test_greet.py
```

```text
.                                                                        [100%]
1 passed in 0.00s
```

That exit code is your first real piece of evidence. The agent's claim was
true this time — but you now know that because a deterministic check said so,
not because it said so.

## 5. Get an independent review

Stage the change and ask a different reasoning lane — `reviewer`, pinned to
`xhigh` effort — to judge it:

```bash
git add -A
```

On a first pass, staging everything (`git add -A`) is a realistic mistake —
it also picks up harness scaffolding and any `__pycache__/*.pyc` files pytest
just created. Here is what happened when that unfiltered diff was reviewed
for real:

```bash
bash "$HARNESS/scripts/codex-wrapper.sh" --role reviewer --stdin <<'EOF'
Review the staged diff for correctness, test coverage, and style. Reply with
a verdict line "LGTM" or "CHANGES REQUESTED" plus one sentence of reasoning.
EOF
```

```text
codex
CHANGES REQUESTED

`.agent/metrics/settings_merge_wire_events.jsonl` contains machine-specific absolute
paths, while generated `__pycache__/*.pyc` files are staged and not ignored,
despite the test passing.
```

That's a real, correct finding — the reviewer is a different model from the
coder, and it caught something the coder's own closing message glossed over.
Fix it and resubmit, scoped to only the two files that matter:

```bash
git reset -q
echo "__pycache__/" >> .gitignore
git add src/greet.py test_greet.py .gitignore

bash "$HARNESS/scripts/codex-wrapper.sh" --role reviewer --stdin <<'EOF'
Review the staged diff (git diff --staged) for correctness, test coverage,
and style. Ignore anything under .agent/, .rev-harness-state/, .shared/,
docs/ — those are harness scaffolding, not part of this change. Reply with
a verdict line "LGTM" or "CHANGES REQUESTED" plus one sentence of reasoning.
EOF
```

```text
codex
LGTM

The implementation is correct, appropriately tested, stylistically clean,
and passes `pytest` and staged-diff checks.
```

That's a real fix → re-review → LGTM loop, the smallest one that exists. A
`standard`-class task like this one is done once you have that LGTM and the
passing test from step 4 — both of them, not either alone. Reviewer approval
without your own passing check is exactly the "confident-sounding work"
problem from the README; a passing check without any review skips the
cross-family review invariant. Recording both — the pytest output and the
LGTM transcript — under `.claude/tmp/<task>/` or wherever your workflow keeps
evidence is what makes the completion claim checkable later, by you or by
someone else. See [Daily use → Evidence](daily-use.md#evidence) for where
that normally lives for a real task instead of this one-off walkthrough.

## What you just proved to yourself

- A role-pinned wrapper call cannot be talked out of its sandbox, model, or
  approval mode from the command line.
- The agent's own "tests pass" claim was, in this run, true — but you only
  know that because you ran `pytest` yourself and read the exit status.
- A second, independent model caught a real problem (`__pycache__` and a
  machine-specific path staged for commit) that the first model's own summary
  did not mention.
- One `REV_HARNESS_DELEGATION_METRIC` line exists per wrapper call, so this
  entire exchange is reconstructable from stderr alone.

Next: [Daily use](daily-use.md) covers the same loop at real-task scale —
task classes beyond `standard`, the automated review loop, ExecPlans for
multi-session work, and where evidence is expected to live. If anything above
didn't work the way this page describes, check
[Troubleshooting](troubleshooting.md) before assuming your setup is broken —
several of the rough edges here are known and have exact fixes.
