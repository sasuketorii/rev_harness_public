# Harness Release Gate

Date: `2026-04-06`
Status: `authoritative harness release gate`

## 1. Purpose

This runbook defines the release gate for the current harness plan.

This document defines the stable gate contract only. Dated rerun results, latest artifact paths, and slice-specific closeout evidence belong in the current `.agent/active/sow/*.md`, matching `.agent/active/prompts/*.md`, and `.claude/tmp/harness-release-gate/runs/<run-id>/`.

The authoritative release gate remains `bash test/integration/harness_release_gate.sh`. Benchmark and memory evidence are a separate surface owned by `scripts/harness-benchmark.sh`; inspect `bash scripts/harness-benchmark.sh --help` for required args, then cite the fixed artifact paths from a valid benchmark run rather than inferring them from this runbook.

A boundary can be described as `full gate green` or `test-backed local sign-off` only when the release gate passes and the dated evidence matches the contracts below. Reviewer-accepted completion requires separate reviewer evidence and should not be inferred from this runbook alone.

## 2. Gate Commands

Run the full gate through:

```bash
bash test/integration/harness_release_gate.sh
```

For day-to-day operational visibility, use the tiered entrypoints:

```bash
bash scripts/harness-doctor.sh --quick
bash scripts/harness-doctor.sh --quick --json
bash test/integration/harness_release_gate.sh --tier quick
bash test/integration/harness_release_gate.sh --tier local --dry-run
bash test/integration/harness_release_gate.sh --tier full --dry-run
```

`--tier quick` delegates to `scripts/harness-doctor.sh --quick` before release-gate run initialization. It is read-only and advisory-only: it must not create release-gate run directories, refresh latest pointers, prune artifacts, perform network calls, perform deep scans, or claim acceptance, LGTM, completion, or release readiness. Quick may be cited as the gate tier for `light` tasks only when `scripts/rev-harness-task-classifier.sh` returns `task_class=light` and the light-change-record includes the relevant file-specific deterministic checks such as `git diff --check -- <files>`. Use `local` for `standard` scoped review evidence and `full` for `heavy` release/tag/merge-prep evidence.

`local` and `full` create normal run artifacts. Each step directory includes `elapsed_ms.txt`, the run root includes `step-timing.tsv`, and `summary.md` records `Tier`, `Total elapsed ms`, and per-step timing rows. `full` writes `.claude/tmp/harness-release-gate/latest.json`, `latest-success.json`, and `latest-failure.json`. `local` writes separate local pointers: `.claude/tmp/harness-release-gate/latest-local.json`, `latest-local-success.json`, and `latest-local-failure.json`. Pointer JSON and lifecycle manifests include the `tier` field. Dry-run modes list the planned steps and do not create run artifacts or update pointers.

The script writes artifacts under `.claude/tmp/harness-release-gate/runs/<run-id>/`, writes `artifact-lifecycle-manifest.json` inside each run root, and refreshes `.claude/tmp/harness-release-gate/latest.json`, `.claude/tmp/harness-release-gate/latest-success.json`, or `.claude/tmp/harness-release-gate/latest-failure.json`.

The gate currently executes these commands. `benchmark_surface_contract` is contract-only coverage for the benchmark CLI and artifact contract; it does not execute a full benchmark workload.

| Step | Command | Contract covered |
| --- | --- | --- |
| harness doctor quick | `bash test/integration/harness_doctor_quick_test.sh` | quick doctor JSON/timing/no-mutation/static and PATH-stub forbidden-call contract |
| harness release gate tiering | `HARNESS_RELEASE_GATE_TIERING_NESTED=1 bash test/integration/harness_release_gate_tiering_test.sh` | quick/local/full tier dispatch, no-mutation, and dry-run contract |
| delegation metrics smoke | `bash test/integration/harness_release_gate.sh --metrics-smoke` | delegation-metrics emission smoke for the release-gate runner |
| secret guard | `bash test/unit/test-secret-guard.sh` | secret / credential redaction guard contract |
| task classifier | `bash test/integration/rev_harness_task_classifier_test.sh` | light/standard/heavy mapping, schema profile selection, and final-gate isolation |
| skill routing | `bash test/integration/rev_harness_skill_routing_test.sh` | class-to-skill matrix, self-growth routing, provenance, and light-path non-escalation invariants |
| dual native | `bash test/integration/rev_harness_dual_native_check_test.sh` | Claude-native / Codex-native subagent split and cross-family artifact-handoff invariants |
| self-growth proposal cycle | `bash test/integration/self_growth_proposal_cycle_test.sh` | proposal-driven self-growth promotion cycle, untrusted evidence boundary, no autonomous mutation, and bounded cost contract |
| static asset check | `bash test/integration/rev_harness_static_asset_check_test.sh` | dependency-free static app smoke validation for disposable workspace HTML/CSS/JS/JSON artifacts |
| native reviewer smoke | `bash test/integration/native_reviewer_surface_smoke.sh` | reviewer packet / prompt rendering / review-report contract, fenced transport-payload rejection, invalid reviewer relay suppression |
| codex MCP zombie cleanup contract | `bash test/integration/codex_mcp_zombie_cleanup_contract_test.sh` | stale Playwright / Computer Use MCP helper detection, dry-run contract, and default age guard |
| codex MCP zombie cleanup live | `bash test/integration/codex_mcp_zombie_cleanup_live_test.sh` | explicit PID-confirmed stale-helper termination and fail-closed live cleanup contract |
| hook ingress smoke | `bash test/integration/hook_ingress_smoke.sh` | ingress hook enforcement and fail-closed runtime smoke |
| model policy validate | `bash scripts/model-policy.sh validate` | release-gate tier step-list coverage for model-policy validation; model-policy implementation remains separate task evidence |
| model policy generate check | `bash scripts/model-policy.sh generate --check` | release-gate tier step-list coverage for generated mirror drift; model-policy implementation remains separate task evidence |
| model policy stale refs | `bash scripts/model-policy.sh stale-refs` | full-tier stale reference visibility; model-policy implementation remains separate task evidence |
| model policy consistency | `bash test/integration/model_policy_consistency_test.sh` | release-gate tier step-list coverage for model-policy consistency; model-policy implementation remains separate task evidence |
| subscription auth guard | `bash test/integration/subscription_auth_guard_test.sh` | subscription-only auth fail-closed boundary and API-key fallback rejection |
| lease guard | `bash test/integration/rev_harness_lease_guard_test.sh` | closed worker lease registry acceptance and malformed / running / missing-artifact block behavior |
| lease lifecycle | `bash test/integration/rev_harness_lease_lifecycle_test.sh` | typed lease open / heartbeat / close / block / reap lifecycle authority |
| wrapper matrix | `bash test/integration/cross_agent_wrapper_matrix_test.sh` | wrapper role matrix and caller-boundary rules |
| cross-family artifact smoke | `bash test/integration/cross_family_artifact_smoke_test.sh` | deterministic Codex worker artifact -> Opus reviewer artifact -> orchestrator acceptance packet -> lease closeout contract; not a live CLI conversation claim |
| cross-family live smoke preflight | `bash test/integration/cross_family_live_smoke_preflight_test.sh` | read-only safety gate for whether a Codex / Opus live smoke may be attempted; it never starts model processes and never permits a completion claim |
| cross-family live artifact smoke | `bash test/integration/cross_family_live_artifact_smoke_test.sh` | stubbed contract test for the opt-in live Codex -> Opus artifact-smoke runner; default CI does not spend subscription quota |
| cursor rules root | `bash test/integration/root_instructions_test.sh` | root instruction / vendor-neutral bootstrap contract |
| cursor rules frontmatter | `bash test/unit/test-cursor-rules-frontmatter.sh` | Cursor rule frontmatter and attachment-behavior contract |
| cursor outbound deny | `bash test/unit/test-outbound-deny.sh` | Cursor outbound-deny / sandbox network boundary contract |
| cursor skills compliance | `bash test/unit/test-cursor-skills-compliance.sh` | Cursor skills compliance contract |
| cursor wrapper | `bash test/unit/test-cursor-wrapper.sh` | Cursor wrapper role / caller-boundary contract |
| janitor inspect | `bash scripts/rev-harness-janitor.sh inspect --json | jq -e '.schema_version == "rev-harness-janitor/v1" and .janitor_command == "inspect" and .delete_enabled == false and .archive_enabled == false and .apply_enabled == false' >/dev/null` | self-cleaning visibility stays wired into release-gate without deleting or moving evidence |
| benchmark surface contract | `bash test/integration/harness_benchmark_contract_test.sh` | benchmark CLI/artifact contract only; not full benchmark execution |
| runtime baseline contract | `bash test/integration/harness_runtime_baseline_test.sh` | runtime baseline manifest / drift contract |
| common task contract smoke | `bash test/integration/common_task_contract_smoke.sh` | stable task-contract emit/validate surface |
| coder engine truth | `bash test/integration/coder_engine_truth_test.sh` | coder engine selection truth and drift rejection |
| policy source consistency | `bash test/integration/policy_source_consistency_test.sh` | stable policy source manifest contract |
| orchestration packet validator | `bash test/integration/orchestration_packet_validator_test.sh` | compiled policy bundle / packet preflight validator contract |
| auto orchestrate packet preflight | `bash test/integration/auto_orchestrate_packet_preflight_test.sh` | coder-launch packet preflight integration for single explicit packet tuple plans |
| gate hook quiesce | `bash test/unit/test-hook-quiesce-gate.sh` | I-7 hook-quiesce invariant (re-homed) |
| gate execplan topology | `bash -n scripts/ci/check-execplan-topology.sh && bash test/unit/test-execplan-topology.sh` | ExecPlan DAG topology guard (re-homed) |
| gate safe dispatch | `bash -n scripts/safe-dispatch.sh && bash test/unit/test-safe-dispatch.sh` | I-8 safe-dispatch contract (re-homed) |
| gate snapshot hooks | `bash -n .claude/hooks/snapshot-pre.sh .claude/hooks/snapshot-post.sh .claude/hooks/snapshot-stop.sh scripts/snapshot-dispatch.sh && bash test/unit/test-snapshot-hooks.sh` | snapshot hook syntax + behavior (re-homed) |
| gate janitor quiesce | `bash test/unit/test-janitor-quiesce.sh` | janitor quiesce contract (re-homed) |
| gate janitor bail gc | `REVHARNESS_PARALLEL_QUIESCE=0 bash test/unit/test-janitor-bail-gc.sh` | janitor bail GC contract under serial quiesce (re-homed) |
| gate janitor build cleanup | `bash test/unit/test-janitor-build-cleanup.sh` | janitor build-cleanup contract (re-homed) |
| gate metric schemas | `bash scripts/ci/check-metric-schemas.sh` | metric JSONL schema gate (re-homed) |
| gate path leak advise | `bash .claude/hooks/path-leak-advise.sh --self-test && bash test/unit/test-path-leak-advise.sh` | I-1 path-leak soft layer (re-homed) |
| gate settings path leak wire | `bash test/unit/test-settings-path-leak-wire.sh` | I-1 settings path-leak wiring (re-homed) |
| gate dual lgtm validate | `bash scripts/dual-lgtm-validate.sh --self-test && bash test/unit/test-dual-lgtm-validate.sh` | I-3 dual-LGTM validator (re-homed) |
| gate dual lgtm gap emit | `bash test/unit/test-dual-lgtm-gap-emit.sh` | I-3 dual-LGTM gap-emit contract (re-homed) |
| gate state transition guard | `bash scripts/state-transition-guard.sh --self-test && bash test/unit/test-state-transition-guard.sh` | state-transition guard self-test + unit (re-homed; distinct from the I-12 static spec check in the release phase-done gate) |
| gate wrapper help parity | `bash scripts/ci/check-wrapper-help-parity.sh && bash test/unit/test-wrapper-help-parity.sh` | I-5 wrapper-help parity (re-homed) |
| gate wrapper role merge | `bash test/unit/test-wrapper-role-merge.sh` | I-5 wrapper role-merge (re-homed) |
| gate shim log privacy | `bash test/unit/test-shim-log-privacy.sh` | shim-log privacy contract (re-homed) |
| gate graceful shutdown unit | `bash test/unit/test-graceful-shutdown-self-test.sh` | graceful-shutdown unit (re-homed; the hook self-test also runs in the release phase-done gate) |
| gate harness bg spawn | `bash test/unit/test-harness-bg-spawn.sh` | background-spawn reaper contract (re-homed) |
| gate adopter setup | `bash -n scripts/rev-harness-adopter-setup.sh && bash scripts/rev-harness-adopter-setup.sh --help && status smoke against a temp target` | adopter lifecycle (I-10/11) syntax + help + status smoke (re-homed; FULL tier only) |
| gate lifecycle syntax | `bash -n scripts/rev-harness scripts/rev-harness-install.sh scripts/rev-harness-uninstall.sh scripts/rev-harness-repair.sh` | lifecycle script syntax guard (re-homed) |
| gate install hooks fail closed | `bash test/integration/install_hooks_fail_closed_no_harness_root_test.sh` | fail-closed install-hooks guard (re-homed; FULL tier only) |
| gate wrapper help golden | golden codex/claude wrapper-help non-leak + wrapper syntax + shim-role greps | I-5 wrapper-help golden leak guard (re-homed) |
| gate role doc invariants | `grep` role-doc invariant strings in coder/reviewer/orchestrator role docs | role-doc invariant strings (re-homed) |

The `gate_*` steps above were re-homed in governance-diet S4 from a retired
per-phase aggregator chain. They were previously reachable only through
`release-phase-done-gate.sh` at phase-advance and were never in the CI release gate;
re-homing keeps these invariants release-blocking. The former per-phase
"continuity" recursion is dropped, not the underlying checks.
`release-phase-done-gate.sh` retains only the live I-12 phase-done smoke plus its own
acceptance steps.

This harness is semantic-free. The former `addon` tier carried only pure-semantic release checks (semantic Rust build, semantic CLI/MCP contract parity, semantic coordination / registry-export contracts, context-capsule and shadow-verify help, semantic sync-freshness contract). Every one targeted the deleted `semantic-mcp` / `tree-sitter-index` crates or the semantic capsule/shadow-verify surfaces, so the addon tier was removed in full; no `cargo test/check -p semantic-mcp`, `semantic_*` test, or capsule/shadow step is part of the current gate.

The `local` tier is intentionally narrower than `full`: it runs `harness_doctor_quick`, `harness_release_gate_tiering`, `delegation_metrics_smoke`, `secret_guard`, `rev_harness_task_classifier`, `rev_harness_skill_routing`, `rev_harness_dual_native`, `self_growth_proposal_cycle`, `rev_harness_static_asset_check`, `model_policy_validate`, `model_policy_generate_check`, `model_policy_consistency`, `subscription_auth_guard`, `rev_harness_lease_guard`, `rev_harness_lease_lifecycle`, `runtime_baseline_contract`, `cross_agent_wrapper_matrix`, `cross_family_artifact_smoke`, `cross_family_live_smoke_preflight`, `cross_family_live_artifact_smoke`, `cursor_rules_root`, `cursor_rules_frontmatter`, `cursor_outbound_deny`, `cursor_skills_compliance`, `cursor_wrapper`, `rev_harness_janitor_inspect`, `coder_engine_truth_test`, `policy_source_consistency`, and the re-homed fast checks `gate_hook_quiesce`, `gate_execplan_topology`, `gate_safe_dispatch`, `gate_snapshot_hooks`, `gate_janitor_quiesce`, `gate_janitor_bail_gc`, `gate_janitor_build_cleanup`, `gate_metric_schemas`, `gate_path_leak_advise`, `gate_settings_path_leak_wire`, `gate_dual_lgtm_validate`, `gate_dual_lgtm_gap_emit`, `gate_state_transition_guard`, `gate_wrapper_help_parity`, `gate_wrapper_role_merge`, `gate_shim_log_privacy`, `gate_graceful_shutdown_unit`, `gate_harness_bg_spawn`, `gate_lifecycle_syntax`, `gate_wrapper_help_golden`, and `gate_role_doc_invariants`. The two slower re-homed integration checks `gate_adopter_setup` and `gate_install_hooks_fail_closed` run in the `full` tier only. The `model_policy_*` entries are included here only as release-gate step-list integration; the model-policy source-of-truth implementation, registry content, generated artifact, and validator behavior are owned by their separate task lineage.

GitHub Actions runs the normal release gate on `main`, `develop`, and `codex/**` branches. A manual `workflow_dispatch` input can run `quick`, `local`, or `full`; `live_cross_family_smoke=true` additionally runs `scripts/cross-family-live-artifact-smoke.sh --json` on that runner. That opt-in step requires local subscription-authenticated Codex and Claude CLI availability and is intentionally not part of default push CI.

## 3. Failure Injection Map

Existing tests already cover the required `ALLOW/WARN/BLOCK` contracts.

| Surface | Evidence | Expected result |
| --- | --- | --- |
| typed lease open / heartbeat / close / reap regression | `rev_harness_lease_lifecycle_test.sh` | `BLOCK` on lease/finalize regression |
| malformed / running / missing-artifact lease acceptance | `rev_harness_lease_guard_test.sh` | `BLOCK` |
| wrapper role escape or caller-controlled wrapper override | `cross_agent_wrapper_matrix_test.sh` `X1`, `X3`, `X8`, `X10` | `BLOCK` |

This harness is semantic-free, so the semantic coordination / registry-export / capsule / `cargo test -p semantic-mcp` queue-lease failure-injection rows do not exist.

## 4. Static Comparison Rules

The release gate may record static comparisons for rollout review, but those comparisons are not the authoritative benchmark or memory surface.

Current comparisons are:

1. wrapper/coordinator inventory context alongside the canonical benchmark artifacts
2. coordinator core-shell delta versus commit `460dd29`

Interpretation:

- wrapper/coordinator totals are release-gate context only; current benchmark/memory evidence must come from `scripts/harness-benchmark.sh`
- coordinator core delta should remain net-negative or neutral

The gate script writes both comparisons into its summary artifact.

## 5. Rollback Rules

Rollback triggers:

- any release-gate command fails
- any failure-injection expectation deviates from its contracted `ALLOW/WARN/BLOCK`
- acceptance authority ambiguity reappears (acceptance authority is `docs/manual/verification-truth-matrix.md`)
- repo-local identity becomes non-canonical or fail-open

Rollback response:

1. stop rollout immediately
2. revert the current change set or restore the last known-good boundary
3. preserve `docs/manual/verification-truth-matrix.md` as acceptance authority during rollback
4. rerun the full release gate before calling the boundary healthy

## 6. Canonical Benchmark Surface

The old Phase 0 benchmark files are historical background only. Do not treat them as the current canonical anchor for benchmark or memory evidence.

Use the benchmark surface this way:

- authoritative release gate: `bash test/integration/harness_release_gate.sh`
- canonical benchmark/memory help: `bash scripts/harness-benchmark.sh --help`
- current benchmark/memory evidence: the fixed artifact paths written by a valid `scripts/harness-benchmark.sh` run

The release gate may echo static totals for rollout context, but benchmark and memory claims are re-established only from the latest canonical benchmark artifacts plus dated provenance in the current SOW / handover.

## 7. Volatile Evidence Placement

Do not update this runbook for each rerun.

When the gate is rerun, record the volatile evidence in the current dated SOW / handover:

- exact commands run
- command results
- latest artifact directory and summary path
- latest benchmark / memory artifact paths from a valid `scripts/harness-benchmark.sh` run
- sign-off level such as `full gate green` or `test-backed local sign-off`
- any reviewer caveat, missing evidence, or residual risk

Artifact layout remains stable:

- gate artifacts: `.claude/tmp/harness-release-gate/runs/<run-id>/`
- gate summary artifact: `.claude/tmp/harness-release-gate/runs/<run-id>/summary.md`
- gate latest pointers: `.claude/tmp/harness-release-gate/latest.json`, `.claude/tmp/harness-release-gate/latest-success.json`, `.claude/tmp/harness-release-gate/latest-failure.json`
- benchmark / memory artifacts: `.claude/tmp/benchmarks/<task-id>/<slice-id>/runs/<run-id>/`, with `.claude/tmp/benchmarks/<task-id>/<slice-id>/latest.json` and `.claude/tmp/benchmarks/<task-id>/<slice-id>/baselines/<baseline-id>.json`
- dated provenance: `.agent/active/sow/*.md` and `.agent/active/prompts/*.md`

## 8. Closeout Interpretation

Interpret the gate this way:

- a passing release gate is required for a healthy boundary
- a passing release gate by itself establishes `full gate green` / `test-backed local sign-off`, not reviewer-accepted completion
- any claim about the latest boundary must cite the current dated SOW / handover and current artifact path
- any benchmark or memory claim must cite the latest canonical artifacts from a valid `scripts/harness-benchmark.sh` run
- if the current dated evidence is missing, stale, or contradictory, treat the boundary as not yet re-established
