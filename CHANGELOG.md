# Changelog

Notable changes to RevHarness, from the initial public release onward.

## 0.0.3

Adds a second CI target and fixes three portability defects that only a
different runner could expose.

### Fixed

- **`scripts/harness-runtime-baseline.sh` launched measured commands through a
  login shell** (`bash -lc`). Running as root, Debian's `/etc/profile`
  unconditionally overwrites `PATH`, discarding the shim directory the
  measurement depends on. The environment is already passed explicitly via
  `env`, so login-shell semantics were never needed.
- **`test/integration/harness_doctor_quick_test.sh` probed file mtime with
  `stat -f` before `stat -c`.** On GNU coreutils `-f` means *filesystem*
  status, not format: it prints a free-space dump and exits non-zero *after*
  writing to stdout, so the dump landed inside a command substitution and the
  before/after comparison reported a phantom mutation. The BSD-first ordering
  is now GNU-first.
- **`test/unit/test-shim-log-privacy.sh` assumed a non-root user.** It creates
  an unwritable directory with `chmod 500` and expects `mkdir` to fail; root
  ignores permission bits, so the assertion could not hold. The test is
  correct — the CI configuration was wrong, and now runs the gate as an
  unprivileged user.

### Added

- `.woodpecker/check.yaml` — runs the same authoritative release gate on a
  self-hosted Woodpecker runner. Keeping two CI targets is deliberate: a
  container and a hosted VM disagree about enough (preinstalled toolchain,
  privilege level, shell startup) that either one alone leaves blind spots.
  All three defects above were invisible on GitHub Actions and surfaced
  immediately on the container.
- `docs/getting-started/requirements.md` §8 (and its Japanese mirror) — what a
  CI runner needs beyond a developer machine. Hosted runners supply Rust,
  Python, Node, shellcheck and a full coreutils implicitly; a minimal image
  does not, and a missing interpreter surfaces as exit 127 in a step whose
  name has nothing to do with it.

## 0.0.2

Makes the release gate pass on Linux, and corrects two places where the
distribution described itself inaccurately.

### Fixed

- **The release gate now passes on a real Linux runner.** The 0.0.1 gate scored
  53 pass / 9 fail on ubuntu-latest. Four were genuine portability defects, not
  environment noise:
  - `test-path-leak-advise.sh` hardcoded `mktemp -d /private/tmp/...`, a macOS-only
    path. On Linux the temp root came back empty and the test tried to write to
    `/`, taking all 34 of its assertions down.
  - `harness_benchmark_contract_test.sh` matched on `\t` inside `grep -E`, which
    BSD grep interprets as a tab and GNU grep does not. The measured data was
    always correct; only the assertion was unportable.
  - The model-policy candidate check used a plain substring match, so `gpt-5.6`
    could match inside `gpt-5.6-sol`. It is now boundary-anchored.
  - The wrapper help golden fixtures were stale.
  The remaining five needed tooling the runner lacks (`ripgrep`, `/usr/bin/time`)
  or repository-external state (a bootstrapped project identity, an installed
  Codex skill tree). Those are now provisioned in CI or skip explicitly and say
  so, rather than failing silently or being weakened.

### Changed

- **"thin harness" is now "mid-weight harness."** 0.0.1 called itself thin while
  shipping 77 scripts, 103 tests, and a three-crate Rust core. The README now
  states the surface area up front and says plainly who this is not for, so that
  judgement happens before adoption instead of after.
- `test/README.md` rewritten. It documented a TypeScript testing convention,
  complete with a `UserService` example, in a repository whose tests are entirely
  bash. It now describes the actual house style, how to run the gate, and the
  rule that a test which still passes against deliberately broken input is not a
  test.

Neither change under "Changed" alters behavior. Both were the distribution
misdescribing itself.

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
