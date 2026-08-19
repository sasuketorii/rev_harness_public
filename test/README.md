# Tests

Two different things live under `test/`, and confusing them is the most common
mistake:

- **`test/unit/` and `test/integration/` are the harness's own tests.** They are
  harness-owned and get replaced wholesale on upgrade. Do not put your product's
  tests here — they will be overwritten.
- **`test/product/` is yours.** It is preserve-only; the harness never writes to
  it. Product tests can also live next to product code, which is usually better.

## Running them

The authoritative entry point is the release gate, not the individual files:

```bash
bash test/integration/harness_release_gate.sh --tier quick   # fast subset
bash test/integration/harness_release_gate.sh --tier local   # what you run before a PR
bash test/integration/harness_release_gate.sh --tier full    # what CI runs
```

It resolves a bash 4+ interpreter itself (macOS ships 3.2, which cannot parse
these scripts). Override with `HARNESS_RELEASE_GATE_BASH=/path/to/bash` if the
detection picks the wrong one. Individual tests run standalone too:

```bash
bash test/unit/test-settings-merge.sh
```

Results and evidence land under `.claude/tmp/harness-release-gate/runs/`.

## Writing a harness test

Harness tests are bash. The house style, visible in any existing file:

- `set -euo pipefail`, and resolve paths from `BASH_SOURCE` rather than assuming
  a working directory.
- Build fixtures in `mktemp -d` and clean them up in a `trap ... EXIT`. Several
  harness scripts refuse to operate outside a git repository, so a temp adopter
  root usually needs `git init -q`.
- Print one `PASS:` or `FAIL:` line per assertion and exit non-zero on any
  failure. The gate aggregates those lines; it does not parse anything else.
- Assert on observable behavior — exit codes, emitted JSONL rows, files created —
  not on log prose, which changes.

**Prove the test can fail.** A test that passes against a deliberately broken
input is not a test. When you add one, break the thing it guards, watch it go
red, then restore. Several checks in this repository exist specifically because
a passing test turned out to be asserting nothing.

Register the test in the gate's step table so it actually runs in CI. A test
file that nothing invokes provides no protection.

## Writing product tests

Use whatever your stack uses. The harness does not impose a framework on your
code; it only cares that the check you name as acceptance evidence is
deterministic, exits non-zero on failure, and leaves an artifact behind. See
[the verification truth matrix](../docs/manual/verification-truth-matrix.md) for
what makes a check citable as acceptance evidence.
