# Why there is no semantic index

日本語版: [docs/ja/architecture/why-no-semantic-index.md](../ja/architecture/why-no-semantic-index.md)

RevHarness used to ship a semantic code-intelligence subsystem. It was removed.
This page records what it was, why it went away, and what replaced it — because
"we tried this and stopped" is more useful to a reader than silence, and because
anyone evaluating an agent harness in 2026 will reasonably ask why this one has
no vector index.

## What it was

For most of the harness's life, context acquisition ran through a semantic
layer:

- A per-project SQLite database (`semantic.db`), namespaced by the repository's
  `project_id`, holding registry, symbol, full-text-search, and decision tables.
- A **tree-sitter** symbol index that parsed the codebase into a queryable
  symbol graph.
- An **MCP server** exposing a `sem.*` tool surface — `sem.context.top_k`,
  `sem.capsule`, `sem.search`, `sem.admin.gc` — that agents called over JSON-RPC.
- A **context capsule**: a compressed ~220-token summary the agent received
  instead of raw file contents.
- Two Rust crates (`semantic-mcp`, `tree-sitter-index`), bootstrap and launch
  scripts, dedicated CI gates, a stale-index freshness contract, and a database
  lock protocol.

The premise was standard and, at the time, reasonable: large repositories
overwhelm an agent's context window, so build an index, retrieve the relevant
slice, and hand the agent a compressed capsule.

## Why it was removed

The removal happened in two deliberate stages, not in one frustrated afternoon.

**Stage 1 (v0.2.0) — demotion to an opt-in addon.** Core stopped auto-starting
the semantic MCP server. New adopters became core-only by default. The semantic
crates stayed in the workspace but built and tested only through explicit addon
gates. Crucially, this release also opened a **measurement window**: index
maintenance cost, addon gate usage, review-cycle cost, and criteria for
extracting the subsystem into a separate project.

**Stage 2 (v0.3.0) — complete removal.** The measurement came back against
keeping it. The subsystem was deleted: both crates, the MCP wire surface, the
capsule, the FTS5 tables, the semantic CI gates, the addon tier, the semantic
skills and rules module, and the docs. The change removed roughly **42,900 lines
across 229 files** while adding about 2,000.

Three things drove that decision:

1. **The index had to be kept fresh, and freshness is a fail-closed surface.**
   An index that is stale is worse than no index — it confidently returns
   yesterday's structure. Guarding against that meant a freshness contract, a
   staleness gate, and a failure mode where the harness refuses to proceed
   because the index is behind. That is a permanent maintenance tax paid on
   every commit, and it buys correctness only for the retrieval layer, not for
   the work itself.

2. **Agentic search caught up.** `rg` over a well-organized repository, driven
   by an agent that can iterate on its own queries, turned out to retrieve
   what was needed without a precomputed index. The agent reads what it decides
   it needs, in the order it decides to need it. A fixed top-k retrieval cannot
   adapt that way.

3. **The capsule was lossy in the wrong direction.** Compressing a file into a
   220-token summary discards exactly the detail — an off-by-one, a guard
   clause, an unusual early return — that matters when you are about to change
   the file. It saved context budget by removing the part worth reading.

The removal was explicitly scoped so that it would not touch the parts that
carry the harness's value: the deterministic gates, the dual-review evidence
requirement, and the install smoke gate were all preserved unchanged.

## What replaced it

Targeted search plus raw reads, guided by checked-in index maps:

- **`rg` / agentic search** — the agent forms and refines its own queries.
- **`INDEX_MAP` documents** (`docs/INDEX_MANIFEST.md`, `docs/INDEX_MAP-*.md`) —
  hand-maintained maps of where authority lives in the repository. These are a
  **navigation aid, not acceptance truth**; `scripts/ci/index-map-check.sh`
  keeps them from drifting, but nothing accepts work on their say-so.
- **`.shared/project_id`** — the durable identity that state, cache, and
  evidence bind to. This survived the removal; it was never semantic.

## What this means for you

- There is **no vector database, no embedding model, and no MCP server** to run,
  bootstrap, or keep in sync. Installation has no index-building step.
- Context quality depends on your repository being navigable and your index maps
  being honest, not on a retrieval pipeline being tuned.
- If your use case genuinely needs semantic retrieval, this harness is not
  hostile to it — it simply does not provide it. Wire your own MCP server; the
  wrapper layer does not care what tools the agent has.
- If you want the original subsystem, it is not gone from history. Pin to a
  pre-0.3.0 tag, or restore the deleted crates and wiring from the git history
  of the upstream repository. Nothing was rewritten to make that impossible.

The retired invariants (`I-2`, `I-13`, and the addon invariants `Addon-I-2`,
`Addon-I-2b`, `Addon-I-13`) are kept as tombstones in
[`docs/canonical-invariants.md`](../canonical-invariants.md). Their IDs are
never reused, so a stale reference resolves to an explicit "this was removed"
rather than to a renumbered rule that means something else.
