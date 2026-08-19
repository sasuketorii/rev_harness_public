# MCP Zombie Lifecycle Hygiene

**Audience**: operators worried about MCP helper process/connection buildup
across repeated agent and subagent invocations.

## Summary

- MCP servers in Claude Code are owned by the top-level session process, not
  by individual subagents. Spawning subagents inside one session does not, by
  itself, multiply MCP server processes — subagents share the parent
  session's existing MCP connections. Live observation on this host (many
  concurrent Claude Code / Codex sessions, `ps -Ao pid=,ppid=,etime=,args=`)
  confirmed every MCP helper process found had a live, non-`1` parent
  matching an actually-running session; growth tracks concurrent top-level
  sessions, not subagent count.
- The real gap was operational, not architectural: `scripts/cleanup-codex-mcp-zombies.sh`
  (which detects and can terminate a narrow, explicitly named set of MCP
  helper processes — `playwright-mcp`, `chrome-devtools-mcp`,
  `SkyComputerUseClient mcp`, and optionally `semantic-mcp`) was only ever
  invoked manually (via the `development-junk-cleanup` skill or by hand) or
  from tests. No lifecycle hook called it automatically. That is now fixed.

## Where the scan lives — and when it actually runs

**Read this before assuming it is running.** The scan is implemented inside
`.claude/hooks/agent-graceful-shutdown.sh` as a new phase, `gsd_mcp_zombie_scan`.
That hook is **not wired into any hook configuration in this repository**.
`.claude/settings.json` registers only `snapshot-stop.sh` on `Stop`; the
graceful-shutdown hook is invoked by the release gate's self-test and by unit
tests, and otherwise only if you wire it yourself.

So today the accurate statement is: *the detection logic exists, is tested, and
runs whenever the graceful-shutdown hook runs — which by default is during
self-test only.*

Wiring it to `Stop` is a deliberate decision, not an oversight, because that
hook carries other phases you may not want firing automatically — in particular
`gsd_dirty_exit_stash`, which performs a `git stash` when the worktree is dirty
at exit. **Stashing behind your back is dangerous when other work is running in
parallel in the same checkout.** If you want the MCP scan on every stop, either
wire the whole hook after reading what all of its phases do, or call
`scripts/cleanup-codex-mcp-zombies.sh report` directly from your own `Stop`
entry, which has no side effects at all.

The phase itself behaves as follows whenever it does run.

- **Always runs, always report-only, always fail-open.** It calls
  `scripts/cleanup-codex-mcp-zombies.sh report --include-semantic` and
  appends one JSON row per invocation to `.agent/metrics/mcp_zombie_scan.jsonl`
  (`{"event":"mcp_zombie_scan","total_matches":N,"counts":{...}}`). Any
  failure (script missing, `jq` missing, script errors) is swallowed and the
  phase returns `0` — it never blocks shutdown.
- **Never kills anything by default.** Detection and reaping are fully
  separated. Reaping requires two independent, unset-by-default environment
  variables set at invocation time:
  - `GSD_MCP_ZOMBIE_AUTOREAP=1` — enables a reap *attempt*. Without the
    second flag below, this still only computes and logs a dry-run
    would-kill list (`{"event":"mcp_zombie_reap_attempt","live":false}`) and
    signals nothing.
  - `GSD_MCP_ZOMBIE_AUTOREAP_LIVE=1` (in addition to the above) — actually
    sends signals, restricted to the `--orphan-only` candidate set (see
    below).

  Neither variable is set anywhere in committed config; an operator sets one
  or both explicitly for a single invocation. This follows the repo's I-11
  invariant (destructive operations require explicit opt-in).

## The `--orphan-only` safety filter

`scripts/cleanup-codex-mcp-zombies.sh` gained a new `--orphan-only` flag,
usable with both `report` and `kill --dry-run` / `kill --pids`. It restricts
candidates to rows where the process's parent pid is `1` — i.e. the process
has already been reparented to init/launchd because whatever process
launched it (the harness invocation, a Claude/Codex session) has already
exited.

This is the criterion the automatic lifecycle path uses, and it is
deliberately conservative on both axes:

1. **Which process names are even considered.** The existing classifier in
   `cleanup-codex-mcp-zombies.sh` only matches a short, explicit allowlist of
   known MCP helper binaries. A user's unrelated MCP servers (e.g.
   `xserver-mcp`, `shadcn mcp`, `notebooklm` MCP, `xcodebuildmcp`) are never
   classified at all, regardless of `--orphan-only`, because their process
   names are not in the classifier.
2. **Which classified processes are touched.** Among the classified names, a
   process with a live, non-`1` parent (i.e. still attached to a running
   session — ours or someone else's) is never a candidate. Only genuinely
   orphaned processes qualify, and even those still go through the existing
   script's `kill --dry-run` before any live invocation, and live `kill`
   still requires an explicit `--pids` list (now itself constrained to the
   orphan set).

Verified with `test/unit/test-mcp-zombie-orphan-filter.sh`, which uses a
`--ps-file` fixture mixing orphaned, live-parented, and unrelated-name rows
and asserts the orphan/live/unrelated boundaries hold exactly.

## Manual usage (unchanged)

For ad hoc inspection or a manual reap, use the `development-junk-cleanup`
skill or call the script directly:

```bash
# Detection only, safe by default
bash scripts/cleanup-codex-mcp-zombies.sh report --include-semantic

# Detection restricted to orphaned candidates only
bash scripts/cleanup-codex-mcp-zombies.sh report --include-semantic --orphan-only

# Dry-run of what a live kill would target
bash scripts/cleanup-codex-mcp-zombies.sh kill --dry-run --orphan-only --include-semantic

# Live kill still requires explicit PID confirmation
bash scripts/cleanup-codex-mcp-zombies.sh kill --pids <pid[,pid...]> --orphan-only --include-semantic
```

## What was intentionally left alone

`agent-graceful-shutdown.sh` itself is not wired into `.claude/settings.json`
as a `Stop` hook (that slot is used by `.claude/hooks/snapshot-stop.sh`); it
is invoked from wrapper scripts and tests only. Whether the whole
graceful-shutdown pipeline should also fire on every Claude Code `Stop` event
is a separate, larger decision outside the scope of this change — this fix
only adds the MCP-zombie phase to the pipeline that already exists, so it
benefits every current and future caller of that pipeline without expanding
its trigger surface.
