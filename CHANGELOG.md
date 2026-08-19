# Changelog

Notable changes to RevHarness, from the initial public release onward.

## 0.0.1 — Initial public release

The first public release of RevHarness. Everything before this point was
developed privately and is not reconstructible from this repository, so it is
not itemized here — a version-by-version account of changes you cannot inspect
would be noise rather than history. What that development produced is described
in [README.md](README.md); the design decisions worth carrying forward are
documented where they apply, not in this file.

The release contains:

- **Agent invocation wrappers** for Codex, Claude, and Cursor, pinning reasoning
  effort, web-search policy, and a minimum model per role, and rejecting or
  stripping caller attempts to widen those settings.
- **A deterministic acceptance model.** `docs/manual/verification-truth-matrix.md`
  is the acceptance authority: completion language requires a named check, its
  result, the scope it covered, and a durable artifact.
- **A review evidence contract.** Advancing a phase requires review artifacts on
  disk plus an install smoke run that exited zero.
- **An install smoke gate** that creates a throwaway checkout, installs into it,
  and exercises the lifecycle — catching breakage that passes code review.
- **Twelve invariants** expressed as executable checks, in
  `docs/canonical-invariants.md`, with their enforcement strength stated
  individually.
- **A lifecycle facade** — `rev-harness install / verify / repair / status /
  clean / upgrade / uninstall` — with a resumable install state machine.
- **A three-crate Rust core** (`agent-core`, `harness-cache`, `shared`) pinned to
  Rust 1.87.0, providing ExecPlan and envelope linting and deterministic task
  stamps.
- **Privacy and safety guards**: a pre-commit path-leak hard gate, a soft
  advisory hook, a secret guard, snapshot hashing around dispatch, and explicit
  opt-in for every destructive action.
- **Skills** for delegation discipline, scope guarding, deploy review on several
  platforms, and language-specific knowledge, maintained in `.claude/skills/`
  and mirrored for vendor-neutral consumers.
- **Documentation** covering requirements, installation, a worked first run,
  daily use, troubleshooting, and uninstall, in English with a Japanese mirror
  under `docs/ja/`.

Known limitations are stated in [README.md](README.md#what-this-does-not-do)
rather than discovered later. Deferred work is listed in `AGENTS.md`.

Licensed under Apache-2.0.
