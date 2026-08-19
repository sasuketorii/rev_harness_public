# Path-Leak Regex Intent Fixtures

Phase D T-D-3 records the canonical intent for the RevHarness path-leak warning
and pre-commit guard layers. These fixtures are deliberately small, stable, and
safe to stage: concrete positive examples use the opt-in marker on the same line
so they document the pattern without tripping the hard reject path.

## Machine-readable spec

```text
spec_id: rev-harness.path-leak.patterns
phase: Phase D
task: T-D-3
version: 1
warning_layer: .claude/hooks/path-leak-advise.sh
hard_reject_layer: scripts/rev-harness-path-leak-guard.sh
allow_marker: # rev-harness-path-leak-guard: allow
default_positive_regex_1: /Users/[A-Za-z0-9_.-]+/dev/
default_positive_regex_2: /home/[A-Za-z0-9_.-]+/dev/
fixture_positive_file: test/golden/path-leak/positive.txt
fixture_negative_file: test/golden/path-leak/negative.txt
```
> Related: RFC R6 failure mode F4 (path leak) primary cover via this hook + fixture set.
> Issue ref: Phase D / F4.

## Positive patterns (must match -> emit warning)

| ID | Regex | Description | Example |
| --- | --- | --- | --- |
| P1 | `/Users/[A-Za-z0-9_.-]+/dev/` | macOS user development directory rooted under a concrete home path. | `open /Users/alice/dev/rev_harness/src/lib.rs # rev-harness-path-leak-guard: allow` |
| P2 | `/home/[A-Za-z0-9_.-]+/dev/` | Linux user development directory rooted under a concrete home path. | `cat /home/alice/dev/rev_harness/src/lib.rs # rev-harness-path-leak-guard: allow` |
| P3 | `/Users/[A-Za-z0-9_.-]+/dev/` plus a concrete project suffix | Host-specific user-home literals are unsafe when committed as real local names; this fixture uses a non-local sample user and never writes the current host user literal. | `host sample /Users/sample-user/dev/rev_harness/AGENTS.md # rev-harness-path-leak-guard: allow` |
| P4 | `/Users/[A-Za-z0-9_.-]+/dev/` inside Cargo output | Cargo and Rust build output can include absolute package paths in parentheses. | `Compiling rev_harness v0.1.0 (/Users/alice/dev/rev_harness/crates/harness) # rev-harness-path-leak-guard: allow` |
| P5 | `/home/[A-Za-z0-9_.-]+/dev/` inside a runtime error line | Runtime, panic, trace, and error lines can leak absolute source paths. | `ERROR failed to read /home/alice/dev/rev_harness/tmp/state.json # rev-harness-path-leak-guard: allow` |

## Negative patterns (should NOT match)

| ID | Pattern | Description | Example |
| --- | --- | --- | --- |
| N1 | `~/dev/` | Tilde notation is user-relative and does not expose the concrete account name. | `~/dev/rev_harness/src/lib.rs` |
| N2 | `<user>/dev/` | Placeholder notation is suitable for documentation and handoffs. | `<user>/dev/rev_harness/src/lib.rs` |
| N3 | `# rev-harness-path-leak-guard: allow` without a real path | Meta-discussion of the allow marker is permitted when it does not contain a concrete home path. | `Use # rev-harness-path-leak-guard: allow only for intentional fixture examples.` |

## Detection scope

Positive matches should emit a warning in the soft layer. The soft layer is the
Claude hook at `.claude/hooks/path-leak-advise.sh`; it records warning metrics
for concrete `/Users/<name>/dev/` and `/home/<name>/dev/` style paths.

The pre-commit hard reject is narrower. `scripts/rev-harness-path-leak-guard.sh`
only inspects staged diff lines, and only the newly added or modified `+` lines
from `git diff --cached --unified=0` are eligible for blocking.

Existing repository text is not retroactively rejected by this guard unless a
change stages that line again. This keeps the guard useful for preventing new
leaks without forcing unrelated history cleanup during narrow tasks.

Meta discussion is allowed with the explicit opt-in marker:
`# rev-harness-path-leak-guard: allow`. The marker must be on the same physical
line as the intentional positive example when a staged line contains a concrete
home-development path.

The marker is for fixture and documentation intent, not for normal source code.
Prefer `$HOME`, `$REPO_ROOT`, relative paths, or placeholders such as
`/Users/<user>/dev/rev_harness` in ordinary docs and scripts.

## Fixture expectations

The positive fixture covers P1 through P5 with one line per intent category. Each
positive line contains a non-local sample concrete path plus the allow marker,
and none use the current host user literal contiguously.

The negative fixture covers N1 through N3 with examples that should not produce a
path-leak warning. It intentionally avoids concrete `/Users/<name>/dev/` and
`/home/<name>/dev/` substrings.

Consumers should treat this document as the canonical pattern collection for
Phase D path-leak fixture intent. Tests may parse the machine-readable block or
the tables, but behavior must remain aligned with the detection scope above.

## Maintenance notes

When the guard regex changes, update this collection and both text fixtures in
the same task slice. Keep examples short, deterministic, and safe to stage.
