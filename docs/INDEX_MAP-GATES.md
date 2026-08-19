# INDEX Map - Gates

See `docs/INDEX_MANIFEST.md` for the live enum, authority enum, update
obligation, exemption mechanism, and validator usage.

## Contract Header

- purpose: Navigate deterministic gates, CI checks, invariant anchors, smoke checks, and privacy guards.
- scope: scripts/ci/** scripts/quality_gate.sh scripts/rev-harness-path-leak-guard.sh scripts/rev-harness-secret-guard.sh scripts/state-transition-guard.sh scripts/rev-harness-task-classifier.sh scripts/dual-lgtm-validate.sh scripts/rev-harness-lease-guard.sh scripts/rev-harness-model-io-guard.sh test/integration/harness_release_gate.sh .claude/hooks/agent-graceful-shutdown.sh .claude/hooks/path-leak-advise.sh .claude/hooks/snapshot-pre.sh .claude/hooks/snapshot-post.sh .claude/hooks/snapshot-stop.sh docs/canonical-invariants.md docs/manual/verification-truth-matrix.md docs/manual/harness-release-gate.md docs/manual/phase-done-smoke.md docs/manual/release-binary-privacy.md docs/manual/safe-dispatch.md docs/manual/snapshot-hooks.md docs/manual/state-transition-guard.md docs/manual/path-leak-soft-layer.md docs/SHIPPED_ARTIFACTS.md .agent/metrics/path_leak_events.jsonl .agent/metrics/release_binary_privacy_scan.jsonl .agent/metrics/settings_merge_wire_events.jsonl .agent/metrics/review_queue_events.jsonl
- out-of-scope: docs/INDEX_MAP-*.md
- row-granularity: file
- last-updated: 2026-06-29
- last-verified-commit: 072b827
- related-invariants: I-1 I-2 I-2b I-3 I-4 I-5 I-6 I-7 I-8 I-9 I-10 I-11 I-12 I-13 Addon-I-2 Addon-I-2b Addon-I-13
- validation: scripts/ci/index-map-check.sh
- update-triggers: gate add/move/remove, invariant change, truth-matrix check change, privacy check change, smoke check change
- exceptions: -
- unknown-budget: 0

## Critical Summary

Every row in this file has a non-empty checks cell. `unknown` is not allowed
here because a gate with unknown liveness would be release-sensitive debt.

## Rows

| path | kind | purpose | live | authority | checks | notes |
|---|---|---|---|---|---|---|
| docs/canonical-invariants.md | md | Canonical invariant source and gate mapping. | default-live | contract | I-1 I-2 I-2b I-3 I-4 I-5 I-6 I-7 I-8 I-9 I-10 I-11 I-12 I-13 Addon-I-2 Addon-I-2b Addon-I-13 | Source for invariant IDs referenced by checks cells. |
| docs/manual/verification-truth-matrix.md | md | Acceptance authority and truth placement matrix. | default-live | contract | I-3 I-12 | Contains INDEX necessary-not-sufficient row. |
| docs/SHIPPED_ARTIFACTS.md | md | Manifest for shipped executable and archive privacy scanning. | default-live | contract | I-2b scripts/ci/shipped-artifact-privacy-scan.sh | Empty implicit success is forbidden. |
| scripts/ci/index-map-check.sh | bash | Validates INDEX map shape, freshness, references, and budgets. | live-when-invoked | gate | scripts/ci/index-map-check.sh | P4 validator; navigation/freshness only. |
| scripts/ci/phase-done-smoke.sh | bash | Smoke gate required before final phase advance. | live-when-invoked | gate | I-12 scripts/ci/phase-done-smoke.sh | Core smoke keeps build/config/state/privacy coverage. |
| scripts/ci/smoke-list-diff-check.sh | bash | RETIRED tombstone for the one-time P7 core-smoke-retargeting proof; now exits 0 and points to the durable P7 evidence. | deprecated | tool | scripts/ci/smoke-list-diff-check.sh | RETIRED (D1, idxfirst-followups-20260615): its one-shot baseline auto-repin became a permanent false-FAIL once the P7 removal was buried under later phase-done-smoke.sh edits (P7 reviewer predicted this). Not wired into any release-gate tier, so retiring breaks no pipeline. Durable P7 proof preserved at `.agent/active/idxfirst-20260611/p1/smoke-migration-table.md` (signoff p7/review_{fable,codex}_r1.md; P11 re-proof p11/review_fable_r1.md). Ongoing coverage: phase-done-smoke.sh (core), shipped-artifact-privacy-scan.sh (privacy). |
| test/integration/harness_release_gate.sh | bash | Authoritative harness release gate. | live-when-invoked | gate | bash test/integration/harness_release_gate.sh | Core-only gate; the semantic addon tier was retired in the semantic-free harness. |
| scripts/state-transition-guard.sh | bash | Guards phase state transitions and final LGTM stage. | live-when-invoked | gate | I-3 I-12 scripts/state-transition-guard.sh | Enforces final-stage state movement. |
| scripts/dual-lgtm-validate.sh | bash | Validates dual reviewer evidence state. | live-when-invoked | gate | I-3 scripts/dual-lgtm-validate.sh | Agent-based dual LGTM remains provisional until smoke. |
| scripts/quality_gate.sh | bash | Aggregated quality gate entrypoint. | live-when-invoked | gate | scripts/quality_gate.sh | Broad local quality gate. |
| scripts/rev-harness-path-leak-guard.sh | bash | Hard privacy guard for raw path leak prevention. | default-live | gate | I-1 scripts/rev-harness-path-leak-guard.sh | Blocks commit paths where configured. |
| scripts/rev-harness-secret-guard.sh | bash | Secret guard for staged and explicit file scans. | default-live | gate | I-1 scripts/rev-harness-secret-guard.sh | Companion to path-leak privacy gate. |
| scripts/rev-harness-model-io-guard.sh | bash | Model I/O guard for prompt budget and marker scans. | live-when-invoked | gate | I-3 scripts/rev-harness-model-io-guard.sh | Protects model transport boundaries. |
| scripts/rev-harness-lease-guard.sh | bash | Lease guard for worker ownership and lifecycle checks. | live-when-invoked | gate | I-6 | Script is invoked through bash in existing flows. |
| scripts/rev-harness-task-classifier.sh | bash | Canonical light, standard, heavy classifier. | live-when-invoked | gate | I-3 I-12 scripts/rev-harness-task-classifier.sh | Determines acceptance envelope. |
| scripts/ci/invariant-sync-check.sh | bash | Checks invariant IDs stay synchronized across sources. | live-when-invoked | gate | I-2 I-2b I-13 scripts/ci/invariant-sync-check.sh | Required regression for P1 migration. |
| scripts/ci/shipped-artifact-privacy-scan.sh | bash | Scans shipped core executables and archives for privacy leaks. | live-when-invoked | gate | I-2b scripts/ci/shipped-artifact-privacy-scan.sh | Uses `docs/SHIPPED_ARTIFACTS.md`. |
| scripts/ci/release-binary-privacy-scan.sh | bash | Core release binary privacy scan (agent-core; binary-agnostic via --binary). | live-when-invoked | gate | I-2b scripts/ci/release-binary-privacy-scan.sh | Addon-I-2b RETIRED; now a live core privacy gate over agent-core. |
| scripts/ci/check-execplan-topology.sh | bash | Lints parallel dispatch topology and file-owner tokens. | live-when-invoked | gate | I-6 I-9 scripts/ci/check-execplan-topology.sh | Dispatch topology lint. |
| scripts/ci/check-wrapper-help-parity.sh | bash | Checks wrapper help and behavior parity. | live-when-invoked | gate | I-5 scripts/ci/check-wrapper-help-parity.sh | Wrapper parity gate. |
| scripts/ci/review-queue-backend-smoke.sh | bash | Smokes semantic-free core review queue backend. | live-when-invoked | gate | I-3 scripts/ci/review-queue-backend-smoke.sh | P2 replacement backend proof. |
| scripts/ci/hook-fail-behavior-test.sh | bash | Tests hook fail-open behavior without semantic build dependency. | live-when-invoked | gate | I-4 I-7 scripts/ci/hook-fail-behavior-test.sh | P3 PostToolUse decoupling proof. |
| .claude/hooks/agent-graceful-shutdown.sh | bash | Graceful shutdown hook that fails open. | live-when-invoked | gate | I-4 I-7 .claude/hooks/agent-graceful-shutdown.sh | Candidate follow-up: settings.json Stop currently wires only snapshot-stop.sh. |
| .claude/hooks/path-leak-advise.sh | bash | Soft path-leak advisory layer. | default-live | gate | I-1 .claude/hooks/path-leak-advise.sh | Advisory companion to hard privacy gate. |
| .claude/hooks/snapshot-pre.sh | bash | Pre-dispatch snapshot hook. | default-live | gate | I-8 .claude/hooks/snapshot-pre.sh | Paired with ORCHESTRATION safe-dispatch row. |
| .claude/hooks/snapshot-post.sh | bash | Post-dispatch snapshot hook. | default-live | gate | I-8 .claude/hooks/snapshot-post.sh | Paired with ORCHESTRATION safe-dispatch row. |
| .claude/hooks/snapshot-stop.sh | bash | Stop-time snapshot hook. | default-live | gate | I-8 .claude/hooks/snapshot-stop.sh | Paired with ORCHESTRATION safe-dispatch row. |
| .agent/metrics/path_leak_events.jsonl | jsonl | Path-leak event evidence stream. | live-when-invoked | evidence | I-1 scripts/ci/check-metric-schemas.sh | Runtime event file may be dirty; this map does not edit it. |
| .agent/metrics/release_binary_privacy_scan.jsonl | jsonl | Release binary privacy scan evidence stream. | live-when-invoked | evidence | I-2b scripts/ci/check-metric-schemas.sh | Runtime event file may be dirty; this map does not edit it. |
| .agent/metrics/settings_merge_wire_events.jsonl | jsonl | Settings-merge wire runtime event stream. | live-when-invoked | evidence | I-3 scripts/ci/check-metric-schemas.sh | Untracked append-only runtime metric; ignored by P11 because it is regenerated locally and not tracked release evidence. |
| .agent/metrics/review_queue_events.jsonl | jsonl | Review-queue runtime event stream emitted by hook/backend checks. | live-when-invoked | evidence | I-3 scripts/ci/check-metric-schemas.sh | Untracked append-only runtime metric; ignored by P11 because durable slice evidence lives under `.claude/tmp/**`. |
