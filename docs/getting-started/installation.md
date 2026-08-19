# Installation

Read [Requirements](requirements.md) first — on macOS the bash version is a real
blocker, not a formality.

日本語版: [docs/ja/getting-started/installation.md](../ja/getting-started/installation.md)

---

## There is exactly one entry point

```bash
bash scripts/rev-harness install
```

Everything else delegates to it. If you find a tutorial, a script, or a comment
telling you to run something else, that source is out of date. `setup/bootstrap.sh`
still exists for people who have it in muscle memory, but it now does nothing
except forward to the command above and print a deprecation notice.

`install` is idempotent. Running it twice is safe and is the normal way to
repair a partially-configured checkout.

## The mental model

RevHarness is **not** a project template you clone and then work inside. It is a
harness you install **into** a repository you already have (or a new empty one).

You clone the harness once. From that clone you run `install --target <path>`
against each project you want harnessed. Running `install` with no `--target`,
inside the harness checkout, is refused on purpose — it will not install into
its own source tree.

```bash
git clone https://github.com/sasuketorii/rev_harness_public.git
cd rev_harness_public

bash scripts/harness-doctor.sh                                  # 1. can this machine run it?
bash scripts/rev-harness install --target /path/to/your/project # 2. install
bash scripts/rev-harness status  --target /path/to/your/project # 3. confirm
```

The harness clone needs its own identity before it can install anything. It
creates one automatically on first use if none exists, so there is no separate
bootstrap step. It will never overwrite an identity that is already there.

### Prerequisite: the target must already be a git repository

`install --target <path>` requires `<path>` to already be a git repository —
the hooks phase installs a `pre-commit` hook and fails with `adopter-root is
not a git repository: <path>` if `.git` doesn't exist yet. For a brand-new
project, `git init` first:

```bash
mkdir -p /path/to/your/project && cd /path/to/your/project
git init
bash /path/to/rev_harness_public/scripts/rev-harness install --target .
```

No other external tool (e.g. `gh`) is required by `install` itself.

### What `install` actually does

It runs a small state machine — recorded in `.rev-harness-state/state.json`, so
an interrupted install resumes rather than restarting:

1. **Identity** — generates `.shared/project_id`, this checkout's immutable
   identity. Everything that binds state, cache, or evidence to a repository
   keys off it. It is generated once and never edited by hand; a guard rejects
   a corrupted value rather than guessing.
2. **Hooks** — installs the agent lifecycle hooks (snapshotting, path-leak
   advisory, graceful shutdown).
3. **Verification** — runs the doctor and reports what is missing.

### Useful flags

| Flag | Effect |
|---|---|
| `--dry-run` | Show what would change, change nothing |
| `--json` | Machine-readable output, for scripting |
| `--strict` | Treat warnings as failures |
| `--target <path>` | Operate on another checkout instead of the current directory |

## Adopting into an existing repository

Your code stays where it is. `src/` in the harness repo is only a placeholder
for greenfield use; an existing project keeps its own layout and the harness
layers on top.

```bash
bash /path/to/rev_harness_public/scripts/rev-harness install --target /path/to/your/project
```

After a successful install, check the result:

```bash
bash /path/to/rev_harness_public/scripts/rev-harness doctor --target /path/to/your/project
```

A brand-new adopter reports `WARN` with an empty `blocks` list. Warnings about a
dirty worktree, a missing task-lineage ledger, and a missing release-gate
pointer are expected on a fresh install — those artifacts appear once you start
doing work. A non-empty `blocks` list is a real problem; see
[Troubleshooting](troubleshooting.md).

### What it will and will not touch

`.agent/registry/rev_harness_distribution_manifest.json` is the contract:

- **Harness-owned** — `scripts/`, `docs/`, `.agent_rules/`, skills, hooks.
  Replaced wholesale on upgrade. Do not hand-edit; your changes will be lost.
- **Yours, never overwritten** — `src/`, `apps/`, `packages/`, `services/`,
  `crates/`, your product tests, your project context and requirements.
- **Merged, never copied** — `.codex/config.toml`, `.claude/settings.json`,
  `AGENTS.md`, `CLAUDE.md`, `.mcp.json`. These carry per-project state that a
  blind copy would destroy, so upgrades merge structurally.

If you are unsure what an upgrade would do to your checkout, ask it — but note
that `upgrade`'s top-level `--dry-run` flag does not combine with its default
`inspect` action (`rev-harness-upgrade: unknown inspect option: --dry-run`,
reproduced against a real checkout); the working form omits it:

```bash
bash scripts/rev-harness upgrade   # defaults to the `inspect` action; read-only
```

`inspect` only reports which top-level harness paths exist in the target
(`AGENTS.md`, `.agent`, `.claude`, `.codex`, `.shared/project_id`) — it is not
a file-by-file diff, and its `apply` action is not implemented in this build
(`bash scripts/rev-harness-upgrade.sh --help`), so there is no preview of an
actual upgrade to run, only this existence check.

## Building the Rust core (optional)

The shell layer works without it. Build only if you want the `agent-core`
subcommands (ExecPlan linting, envelope linting, deterministic task stamps):

```bash
cd harness-rust
cargo build --release
```

The toolchain is pinned in `harness-rust/rust-toolchain.toml` (Rust 1.87.0 —
`agent-core` uses `u32::is_multiple_of`, stabilized in that release). You also
need a C compiler, because `rusqlite` compiles SQLite from source.

## Connecting your agent CLIs

The harness does not manage credentials. Log in with each vendor's own CLI:

```bash
claude    # follow its login flow
codex     # follow its login flow
```

Then confirm the harness can see them:

```bash
bash scripts/harness-doctor.sh
```

Model selection is policy-driven rather than per-call. `.agent/registry/model_policy.json`
routes heavy judgment (planning, review, release gating) to the strongest model
and implementation or documentation work to a faster one. The shipped defaults
were current at release; override per invocation without editing the file:

```bash
REV_HARNESS_CODEX_MODEL=<model-id> bash scripts/codex-wrapper.sh --role coder --stdin < prompt.md
```

The minimum-model gate still applies to overrides — setting a model below the
floor fails closed rather than silently downgrading.

## Uninstalling

```bash
bash scripts/rev-harness clean        # remove runtime residue, keep the install
bash scripts/rev-harness uninstall    # reports what would be removed
```

`uninstall` is currently report-only; removal is deliberately not automated.
See [Uninstall](uninstall.md).

Next: [First run](first-run.md)
