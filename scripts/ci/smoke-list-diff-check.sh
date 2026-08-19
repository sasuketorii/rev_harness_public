#!/usr/bin/env bash
set -euo pipefail

# RETIRED (D1, idxfirst-followups-20260615).
#
# This script was a ONE-TIME P7 migration proof for the index-first core
# refactor (index-first-core-refactor-20260611). Its sole job was to prove that
# exactly three steps -- `semantic_db`, `rust_binary`, `strings_privacy_scan` --
# moved OUT of core `scripts/ci/phase-done-smoke.sh` during the P7 smoke/release
# split, and that each moved step stayed covered by the signed migration table
# plus the addon gate. That one-time proof landed and was independently
# re-verified at P11 against the pre-P7 baseline.
#
# Why retired rather than repinned:
#   The checker computed its baseline as the parent of the latest commit
#   touching phase-done-smoke.sh (or HEAD on a worktree diff). Post-P7 that
#   parent always already lacks the removed steps -- once any later, unrelated
#   edit touches phase-done-smoke.sh, the baseline it picks is itself post-P7,
#   so the baseline-vs-current diff shows ZERO removed steps and the checker can
#   never again reproduce the expected {semantic_db, rust_binary,
#   strings_privacy_scan} removed set -- it is a permanent false-FAIL on
#   plain/documented invocation. The P7 reviewer
#   predicted this exact one-shot behavior
#   (.agent/active/idxfirst-20260611/p7/review_fable_r1.md finding 3). Repinning
#   would only freeze a historical SHA as baseline for a migration that is now
#   established fact and carries no ongoing forward coverage value. The script
#   is NOT wired into any release-gate tier (FULL/LOCAL/ADDON), so retiring it
#   breaks no live pipeline.
#
# Durable P7 evidence preserved (do NOT delete):
#   - Signed migration table:
#       .agent/active/idxfirst-20260611/p1/smoke-migration-table.md
#   - Dual-family P7 signoff:
#       .agent/active/idxfirst-20260611/p7/review_fable_r1.md
#       .agent/active/idxfirst-20260611/p7/review_codex_r1.md
#   - P11 re-proof against the pre-P7 baseline:
#       .agent/active/idxfirst-20260611/p11/review_fable_r1.md
#
# Ongoing forward coverage that the moved steps now live under:
#   - core surface: scripts/ci/phase-done-smoke.sh (core-only steps)
#   - shipped-artifact privacy: scripts/ci/shipped-artifact-privacy-scan.sh
# (The former semantic addon gate no longer exists; no addon surface ships.)
#
# This tombstone exits 0 and consumes (ignores) any legacy --core/--addon args
# so that historical plain/documented invocations no longer false-FAIL.

printf 'smoke-list-diff-check: RETIRED one-time P7 migration proof; the P7 core smoke retargeting is established history.\n'
printf 'smoke-list-diff-check: durable P7 evidence: .agent/active/idxfirst-20260611/p1/smoke-migration-table.md (signoff: p7/review_{fable,codex}_r1.md; P11 re-proof: p11/review_fable_r1.md).\n'
printf 'smoke-list-diff-check: ongoing coverage lives in phase-done-smoke.sh (core), shipped-artifact-privacy-scan.sh (privacy). The semantic addon gate no longer exists.\n'
exit 0
