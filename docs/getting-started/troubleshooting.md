# Troubleshooting

日本語版: [docs/ja/getting-started/troubleshooting.md](../ja/getting-started/troubleshooting.md)

Symptom → cause → fix. Every message quoted on this page was reproduced
against a real checkout while writing this document — none of it is
paraphrased from memory. If you hit something not listed here, check
`docs/manual/` for the subsystem involved, or grep the relevant script for
`die(` / its error prefix; nearly every script in `scripts/` fails with a
short, greppable message rather than a stack trace.

---

## `declare: -A: invalid option` or similar syntax errors on macOS

**Symptom:** a script dies almost immediately with something like
`declare: -A: invalid option` or `syntax error near unexpected token`,
often without getting far enough to print a useful message.

**Cause:** this is the single most common installation failure. macOS ships
`/bin/bash` frozen at version 3.2 (Apple avoids GPLv3 licensing). RevHarness
uses bash 4 features — associative arrays (`declare -A`) and `mapfile` — in
several scripts. On bash 3.2 these are syntax errors, so the script dies
before it can explain why.

Most entry-point scripts (`scripts/rev-harness`, `scripts/harness-doctor.sh`,
`scripts/init-project.sh`, `setup/bootstrap.sh`) now check their own bash
version first and fail with a clear message instead of the cryptic one above:

```text
ERROR: this script requires bash >= 4.0 (detected: 3.2.57(1)-release).
macOS ships bash 3.2 by default (/bin/bash). Install a newer bash, e.g.:
  brew install bash
Then re-run this command with the new bash explicitly, e.g.:
  /opt/homebrew/opt/bash/bin/bash scripts/rev-harness ...
```

If you're seeing the raw syntax error instead, you've reached a script
further down the chain that doesn't yet have that guard.

**Fix:**

```bash
brew install bash
```

Scripts use `#!/usr/bin/env bash`, so once a bash 4+ is first on `PATH` they
pick it up automatically — you do not need to change your login shell or
replace `/bin/bash`. Check with `bash --version` before continuing. See
[Requirements §2](requirements.md#2-bash-40-or-newer--the-one-requirement-that-actually-bites)
for the full explanation.

## The test suite fails with a bash syntax error, or with `FAIL: no bash >= 4.0 found`

**Symptom:** running the commands from `CONTRIBUTING.md`
(`bash test/integration/harness_release_gate.sh --tier quick`, or one of the
other `test/integration/harness_release_gate*.sh` / `harness_doctor_quick_test.sh`
/ `native_reviewer_surface_smoke.sh` scripts directly) dies with a bash 3.2
syntax error in a script it invokes, or with:

```text
FAIL: no bash >= 4.0 found for test execution.
This test suite requires bash 4+ (associative arrays / mapfile
used deeper in the install/doctor/review chain). macOS ships
bash 3.2 as /bin/bash, which cannot run those scripts.
Fix: brew install bash
Or set HARNESS_TEST_BASH=/path/to/bash4+ to point at one explicitly, e.g.:
  HARNESS_TEST_BASH=/opt/homebrew/bin/bash bash test/integration/harness_doctor_quick_test.sh
```

**Cause:** these four test entrypoints invoke other scripts that need bash 4+
(same root cause as the syntax-error entry above). They auto-detect a bash 4+
binary for you (checking the running `bash`, then `PATH`, then common
Homebrew install locations), so on a machine that already has a current bash
somewhere — even if `/bin/bash` is still 3.2 — you don't need to do anything.
The message above only appears when no bash 4+ binary can be found anywhere.

**Fix:**

```bash
brew install bash
```

If you still see the message after installing (e.g. a non-standard install
prefix), point at it explicitly with `HARNESS_RELEASE_GATE_BASH` (for
`harness_release_gate.sh` and `harness_release_gate_tiering_test.sh`) or
`HARNESS_TEST_BASH` (for `harness_doctor_quick_test.sh` and
`native_reviewer_surface_smoke.sh`):

```bash
HARNESS_TEST_BASH=/path/to/bash4+ bash test/integration/harness_doctor_quick_test.sh
```

## `harness-doctor: required command not found: jq`

**Symptom:** `harness-doctor.sh` (or `rev-harness verify`/`status`) exits
immediately with this line and nothing else.

**Cause:** `jq` is a hard requirement — every JSON state file in this
repository is read and written through it — and unlike most optional tools it
is not preinstalled on either macOS or most Linux distributions.

**Fix:**

```bash
brew install jq        # macOS
sudo apt install jq    # Debian/Ubuntu
```

Then re-run the command that failed.

## The agent CLI isn't logged in

**Symptom:** a wrapper call (`codex-wrapper.sh`, `claude-wrapper.sh`) starts,
prints its role/model banner, then the underlying CLI itself fails with an
authentication or login error before producing any output.

**Cause:** RevHarness never stores or manages credentials for you — it relies
entirely on each vendor CLI's own login state (see
[Installation → Connecting your agent CLIs](installation.md#connecting-your-agent-clis)).
If you haven't logged in with that CLI on this machine, the wrapper gets as
far as invoking it and then the CLI itself refuses.

**Fix:** log in with the CLI directly, then retry the wrapper call:

```bash
claude    # follow its login flow
codex     # follow its login flow
```

`bash scripts/harness-doctor.sh` doesn't verify login state — it checks
tooling and repo state, not credentials — so a clean doctor run does not mean
your CLI is authenticated.

## `--target` confusion: wrong checkout, or none at all

Two related symptoms:

**A. `ERROR: refusing self-install (TARGET_ROOT == HARNESS_ROOT == ...)`**

This is the single most important thing to know before your first install.
**As shipped today, running `bash scripts/rev-harness install` with no
`--target`, from inside the very checkout you just cloned, always fails with
this error** — because that checkout's `scripts/` directory *is* the
directory `install` is about to operate on, and the harness explicitly
refuses to treat itself as the install target. This means literally following
the Quick Start's third command as written, unmodified, in a fresh clone,
reproduces this error every time — it is not something specific to your
machine.

**Fix:** point `install` at a project directory that is not the RevHarness
checkout itself, using the pattern from
[Installation → Adopting into an existing repository](installation.md#adopting-into-an-existing-repository):

```bash
cd /path/to/your-project
bash /path/to/rev_harness_public/scripts/rev-harness install --target .
```

If you genuinely want RevHarness and your product code in the same checkout,
`git init` an empty directory and `install --target` that directory instead of
the harness checkout itself — see [First run § 0](first-run.md#0-set-harness).
There is no supported layout where you skip `install` and work directly inside
the harness clone's own `src/`; every wrapper call fails closed with exit `70`
until `.shared/project_id` exists, and `install` is the only thing that
creates it.

**B. You meant to install into a different checkout and got a confusing
result instead**

If `--target` points somewhere you didn't intend — commonly, a relative path
resolved from the wrong current directory — `rev-harness` will happily set up
identity and hooks in that unintended location. There's no separate error for
this; the fix is to check what actually happened:

```bash
bash /path/to/rev_harness_public/scripts/rev-harness status --target /path/you/meant
cat /path/you/meant/.shared/project_id
```

If identity landed in the wrong place, remove `.shared/project_id`,
`.rev-harness-state/`, and the `pre-commit` hook it installed from that
directory, and re-run `install --target` with an absolute path.

## What `install` actually creates in a fresh project

**Symptom:** the docs describe `install` in the abstract ("identity", "hooks",
"verification") and it's not obvious how much actually lands on disk.

**Ground truth**, counted directly against a real `install --target
<empty-git-repo>` run: 26 files total, not counting `.git/`. Six of those are
the load-bearing artifacts referenced elsewhere on this page — the two the
init phase writes (`.gitignore`, `.shared/project_id`) and the four the hooks
phase writes (`.claude/settings.local.json`, `.git/hooks/pre-commit`,
`.agent/registry/model_policy.json`,
`.agent/generated/codex_model_policy.runtime.json`). The remaining ~20 are
mostly empty `.gitkeep` placeholders that establish the `.agent/active/`,
`.agent/archive/`, `docs/manual/`, `docs/design/`, `docs/requirements/`, and
`src/` directory scaffolding, plus a handful of generated starting-point docs
(`.agent/PROJECT_CONTEXT.md`, `.agent/requirements.md`,
`docs/requirements/README.md`) and `.rev-harness-state/` bookkeeping. None of
that scaffolding is large or surprising once you've seen it once — it's `find
<target> -type f -not -path '*/.git/*' | wc -l` after a fresh install if you
want to reproduce the count yourself.

## Doctor blocks on a missing model-policy runtime artifact in my project

**Symptom:** after `install --target <your-project>`, running
`harness-doctor.sh` against that project reports:

```text
Blocks:
- generated model policy runtime artifact is missing or unsafe: .agent/generated/codex_model_policy.runtime.json
```

**Cause:** `install` copies `.agent/registry/model_policy.json` into a new
project and tries to regenerate the derived runtime artifact locally, but
that regeneration step (`scripts/model-policy.sh generate`) itself needs
`.codex/config.toml`, which is not part of the lightweight adopter setup.
Full wholesale sync of harness-owned files (`scripts/`, `.codex/`,
`.agent_rules/`, and the rest of the distribution manifest) is the job of
`rev-harness upgrade`, whose `apply` action this build reports as
"intentionally not implemented in this foundation" (`scripts/rev-harness-upgrade.sh --help`).
`upgrade`'s `inspect` action is read-only and only reports which top-level
harness paths exist in the target (`AGENTS.md`, `.agent`, `.claude`, `.codex`,
`.shared/project_id`) — it does not enumerate a full file-by-file copy plan.

**What this does and doesn't affect:** wrapper role calls
(`codex-wrapper.sh --role ...`) read their model policy from the RevHarness
checkout by default (`PROJECT_ROOT` defaults to wherever the wrapper script
itself lives, not your current directory), so they keep working even while
your project's own doctor run shows this block. It's your project's *own*
copy of the policy that's stale/missing, not the one the wrapper actually
uses.

**Fix, if you want your project's own doctor run clean:** copy
`.codex/config.toml` from the RevHarness checkout into your project, then
regenerate:

```bash
cp "$HARNESS/.codex/config.toml" .codex/config.toml
PROJECT_ROOT="$(pwd)" bash "$HARNESS/scripts/model-policy.sh" generate
```

Otherwise, it's safe to leave this block in place and keep working — it
describes a gap in your project's local copy of harness bookkeeping, not a
gap in the acceptance evidence your own deterministic checks produce.

## A wrapper call rejects my model override

**Symptom:**

```text
[codex-wrapper] ERROR: REV_HARNESS_CODEX_MODEL=gpt-3.5 is below minimum allowed model gpt-5.5
```

**Cause:** this is intentional, fail-closed behavior, not a bug. The
minimum-model gate in `.agent/registry/model_policy.json`
(`minimum_allowed_model`) applies to `REV_HARNESS_CODEX_MODEL` overrides the
same way it applies to the policy default — the harness will not silently
downgrade to a weaker model just because you asked for one.

**Fix:** either drop the override and use the policy default, or set
`REV_HARNESS_CODEX_MODEL` to a model at or above `minimum_allowed_model`.
Check the current floor:

```bash
jq -r '.minimum_allowed_model' "$HARNESS/.agent/registry/model_policy.json"
```

If you genuinely need a weaker/cheaper model for local iteration, that's a
policy change (edit `model_policy.json` deliberately, per
[Installation → Connecting your agent CLIs](installation.md#connecting-your-agent-clis)),
not a per-call override.

## `flock unavailable; using advisory sentinel lock`

**Symptom:** you see this line on stderr from `scripts/rev-harness` (or a
similar warning about `setsid`) and wonder if something is broken.

**Cause:** nothing is broken. macOS does not ship `flock` or `setsid` by
default. RevHarness detects this and falls back automatically — an advisory
sentinel lock instead of `flock`, plain process spawn instead of `setsid`
process-group isolation. This is documented, expected behavior on macOS, not
a degraded or unsafe state for normal single-operator use.

**Fix:** none needed. If you specifically want real `flock`/`setsid` (for
example, heavier parallel-dispatch scenarios), `brew install util-linux` and
add its `bin` directory to `PATH`, but this is optional.

## Pre-commit hook rejects a commit you didn't expect it to touch

**Symptom:** `git commit` fails after `install` wired up RevHarness's
pre-commit hook, on a commit that looks unrelated to anything sensitive.

**Cause:** the installed hook runs a path-leak guard and a secret guard
against your staged diff on every commit — it's not scoped to files you
"meant" to check.

**Fix:** read the specific rejection message the hook printed; it names the
offending path or pattern. If it's a genuine false positive, use
`git commit --no-verify` sparingly, per the hook's own printed guidance —
don't make it a habit, since that's the same gate that catches real leaked
absolute paths and secrets. To confirm hook status without committing:

```bash
bash "$HARNESS/scripts/install-rev-harness-hooks.sh" --status
```

---

Still stuck? Re-read [Requirements](requirements.md) and
[Installation](installation.md) for the assumptions this page builds on, or
open an issue with the exact command and full output — not a paraphrase — so
it can be reproduced.
