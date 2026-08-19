# Contributing to Revharness

Thank you for considering a contribution. This repository is a development
harness for agent-driven coding workflows (Claude Code, Codex, Cursor), and
it is built around two non-negotiable design principles:

- **Deterministic verification.** A claim of "this works" is only accepted
  when it is backed by a command you can re-run and that produces the same
  pass/fail result every time. Manual eyeballing, screenshots, or "it looked
  fine" are not evidence.
- **Fail-closed.** When a check cannot determine whether something is safe
  (a policy file is missing, a hash does not match, a model id is below the
  configured minimum), the harness stops rather than guessing or falling
  back silently. Contributions must preserve this property; do not add
  fallback paths that turn a `die`/hard-stop into a soft warning.

Every pull request must include the **output of the deterministic check(s)
relevant to your change** — not just a description of what you did. See
"What to run" below for the actual entry points.

## Before you start

- Search open issues and pull requests to avoid duplicate work.
- For anything beyond a small, self-contained fix, open an issue first to
  discuss the approach. This is especially important for changes to:
  - `scripts/codex-wrapper.sh`, `scripts/claude-wrapper.sh`,
    `scripts/cursor-wrapper.sh`, `scripts/model-policy.sh` — these are
    fail-closed security/policy surfaces (sandbox mode, approval policy,
    minimum-model gates). Changes here get the most scrutiny.
  - `.agent/registry/*.json` — machine-read policy files with strict schema
    validation; a change that isn't paired with the corresponding validator
    update will fail CI.
  - `harness-rust/` — see the Rust section below for the MSRV contract.

## What to run

The authoritative entry point for the harness's own self-tests is:

```bash
bash test/integration/harness_release_gate.sh --tier quick   # fastest, doctor-only sanity pass
bash test/integration/harness_release_gate.sh --tier local   # focused local subset
bash test/integration/harness_release_gate.sh --tier full    # full gate (default, what CI runs)
```

Run these with whatever `bash` is on your `PATH` — the entrypoint and the
other `HARNESS_*_BASH`-aware scripts below auto-detect a bash 4+ binary for
the sub-scripts they invoke (associative arrays / `mapfile` are used further
down the chain, and macOS's stock `/bin/bash` is 3.2; see
[Requirements §2](docs/getting-started/requirements.md#2-bash-40-or-newer--the-one-requirement-that-actually-bites)).
If the auto-detection can't find one (no Homebrew bash, nothing on `PATH`),
it fails immediately with a message telling you what to install or which
variable to set — it will never silently fall back to 3.2 and produce a
cryptic syntax error later. To point at a specific bash yourself instead of
relying on auto-detection, set `HARNESS_RELEASE_GATE_BASH` (for
`harness_release_gate.sh` and `harness_release_gate_tiering_test.sh`) or
`HARNESS_TEST_BASH` (for `harness_doctor_quick_test.sh` and
`native_reviewer_surface_smoke.sh`), e.g.:

```bash
HARNESS_RELEASE_GATE_BASH=/opt/homebrew/bin/bash HARNESS_TEST_BASH=/opt/homebrew/bin/bash \
  bash test/integration/harness_release_gate.sh --tier quick
```

This is the same command CI (`.github/workflows/ci.yml`) runs on every push
and pull request. Run at least the tier that covers your change before
opening a PR, and paste the command and its output (or a summary of
pass/fail per step) into the PR description. If a step legitimately does not
apply to your change (e.g. you only touched documentation), say so
explicitly rather than omitting the run.

Individual test scripts under `test/unit/` and `test/integration/` are also
directly executable, e.g.:

```bash
bash test/unit/test-wrapper-help-parity.sh
```

Use this when iterating on a single behavior; still run the release gate
before submitting.

### Policy/registry changes

If you touch `.agent/registry/model_policy.json` or
`.agent/registry/dependency_policy.json`, also run:

```bash
bash scripts/model-policy.sh validate
bash scripts/model-policy.sh generate --check
```

Both must pass. `generate --check` fails if the generated runtime artifact
(`.agent/generated/codex_model_policy.runtime.json`) is stale relative to
the source policy; run `scripts/model-policy.sh generate` (without
`--check`) to regenerate it and commit the result alongside your policy
change.

### Rust (`harness-rust/`)

The workspace pins its toolchain via `harness-rust/rust-toolchain.toml` and
declares `rust-version` in each crate's `Cargo.toml`. If your change raises
the effective MSRV (e.g. by using a newer standard-library API or a
dependency bump that raises its own `rust-version`), you must:

1. Verify the new minimum by actually checking with that toolchain
   (`rustup toolchain install <version> && cargo +<version> check --workspace`)
   — do not guess a version from a changelog without compiling.
2. Update `rust-toolchain.toml` and every crate's `rust-version` together,
   with a comment explaining the evidence (which dependency/API forced the
   bump).

Standard checks:

```bash
cd harness-rust
cargo check --workspace
cargo test --workspace
cargo clippy --workspace -- -D warnings
```

## Shell script conventions

Nearly all of this harness's control-plane logic is bash. Every script under
`scripts/`, `.claude/`, `.codex/`, and `test/` must follow these rules:

- Start with `set -euo pipefail` (or `set -eu` for `#!/bin/sh` scripts,
  which must avoid bashisms entirely).
- Prefer `#!/usr/bin/env bash` over a hardcoded interpreter path.
- Before opening a PR, run both of the following against every shell file
  you added or modified:

  ```bash
  bash -n path/to/script.sh          # syntax check
  shellcheck path/to/script.sh       # static analysis
  ```

  A `shellcheck` warning you intentionally leave in place should be
  suppressed with a targeted `# shellcheck disable=SC____` comment on the
  specific line, with a short reason — not a blanket disable at the top of
  the file.
- New wrapper scripts (anything that shells out to `codex`, `claude`, or
  `cursor`) must go through the same fail-closed pattern as the existing
  wrappers: fixed sandbox/approval settings that cannot be overridden by
  caller-supplied flags, and an explicit `die` on any unexpected state
  rather than a silent default.
- Avoid macOS-only or Linux-only commands unless guarded by
  `command -v <tool>` with a working fallback; this repo intentionally
  supports both. See existing patterns in `scripts/harness-doctor.sh` for
  the `stat -f` / `stat -c` double-check idiom.

## Commit and PR expectations

- Keep changes scoped to one concern per PR; unrelated cleanups belong in a
  separate PR.
- Write commit messages that explain *why*, not just *what*.
- In the PR description, include:
  1. What changed and why.
  2. The exact deterministic check command(s) you ran and their result
     (pass/fail, with output for failures).
  3. Any scope you deliberately did not cover, and why.
- Do not commit generated artifacts that are supposed to be produced by a
  script at setup/build time (see `.gitignore` and
  `.agent/registry/rev_harness_distribution_manifest.json` for what is
  managed vs. adopter-local).

## License

By contributing, you agree that your contributions are licensed under the
Apache License, Version 2.0 (see `LICENSE`), consistent with the rest of
this project.
