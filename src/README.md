# src/ — product code

> **This file lives inside the RevHarness checkout itself, but it is not
> describing that checkout.** `src/` here is a template: `bash
> scripts/rev-harness install --target <path>` copies it into the *adopter*
> project you're installing into. Do not develop inside this `src/` — the
> harness checkout has no project identity of its own
> (`.shared/project_id` is only created by `install`, and `install` refuses
> to run against its own source tree), so wrapper calls made from here fail
> closed. See [First run](../docs/getting-started/first-run.md) for the one
> supported workflow: clone the harness, then `install --target
> <your-project>`.

This is the canonical default workspace for **product code** in an *installed*
Revharness project — i.e. the target you ran `install --target` against, not
this checkout.

## Harness↔product boundary

- Root `test/` is **harness-owned**: `test/unit/` + `test/integration/` are the
  harness self-test gate and are managed (blind-overwritten) on harness sync.
- **Product code** lives under `src/**` (or, for adopted projects, the
  compatibility paths `apps/**`, `packages/**`, `services/**`, `crates/**`).
- **Product tests** colocate with product code under `src/**` (e.g.
  `*.test.*` / `*.spec.*` / `__tests__/`) or live under `test/product/**`.
  Both are preserve-only and are never blind-overwritten by a harness sync.

Do not place product tests in `test/unit/**` or `test/integration/**`: those are
harness-managed and a sync would overwrite them.
