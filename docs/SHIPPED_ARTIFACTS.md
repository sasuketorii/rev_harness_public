# Shipped Artifacts

## Purpose

This manifest lists executable and archive artifacts whose shipped bytes must
scan clean before a release is tagged.

## Update obligation

Every release slice that adds, removes, renames, or changes a shipped
executable/archive must update this manifest in the same slice. Empty implicit
success is forbidden: if no core executable/archive ships, a row must explicitly
record `no shipped core artifact` with reviewer evidence.

## Reviewer evidence rule

Each `not-shipped` row must include an evidence pointer showing why the artifact
does not ship in the current release. A missing evidence pointer is a manifest
failure.

## Manifest

Allowed `kind` values: `executable`, `archive`.
Allowed `ships-in-release` values: `yes`, `not-shipped`.

| artifact path | kind | ships-in-release | privacy-scan command | status | evidence |
|---|---|---|---|---|---|
| n/a | n/a | not-shipped | `bash scripts/ci/shipped-artifact-privacy-scan.sh --manifest docs/SHIPPED_ARTIFACTS.md` | no shipped core artifact. This distribution's `harness-rust/` workspace (`harness-rust/Cargo.toml`, `members = ["crates/*"]`) contains three library crates (`agent-core`, `harness-cache`, `shared`); none declares a `[[bin]]` target, so no executable is produced by `cargo build --release` as this tree stands. `harness-rust/target/` is untracked (build output only) and does not exist in a fresh checkout. There is no archive artifact either. | Verified directly against this checkout: `harness-rust/Cargo.toml`, `harness-rust/crates/*/Cargo.toml` (no `[[bin]]` in any crate), and absence of `harness-rust/target/` in a clean clone. Earlier internal development history referenced a `semantic-mcp` binary and a planned `agent-core` binary; both are historical/retired and their supporting review notes were internal working artifacts that are not part of this public distribution. |
