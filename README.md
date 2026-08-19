# RevHarness

**A mid-weight, repo-local harness that makes AI coding agents produce verifiable
work instead of confident-sounding work.**

日本語版: [docs/ja/README.md](docs/ja/README.md)

RevHarness sits inside your repository — not as a daemon, not as a service — and
enforces four things that agent-driven development tends to lose:

- **Acceptance is mechanical.** "Done" means a named deterministic check exited
  zero and left an artifact behind. An agent saying it finished is not evidence.
- **Invocation goes through one entry point.** Every agent call runs through a
  wrapper that fixes the reasoning effort and web-search policy for the role,
  enforces a minimum model, and strips or rejects command-line attempts to
  widen those settings. Calling the vendor CLI directly bypasses all of it —
  the harness constrains cooperating users, it is not a security boundary.
- **Review leaves artifacts.** Advancing a phase requires two review files to
  exist on disk carrying a verdict, plus a smoke run that exited zero. The
  harness checks that those artifacts are present and say what they must say;
  it does not — and cannot — prove which model wrote them.
- **Failure is closed, not open.** When the harness cannot tell whether
  something is safe, it stops. Destructive actions require an explicit opt-in
  flag every time.

**Mid-weight is the honest word, not a hedge.** This is not a drop-in file you
add and forget. It is 77 shell scripts, 103 tests, a three-crate Rust core, and a
set of conventions your agents are expected to follow. Everything in it is plain
text you can open and change — no daemon, no service, no binary you have to trust
— but there is real surface area here, and adopting it means taking on that
surface. If you want something you can absorb in an afternoon, this is the wrong
tool. If you want the acceptance model and are willing to carry the machinery
that enforces it, this is the trade.

**Scope: this is a backend harness.** It exists to produce backend and system
code quickly and at a quality you can defend. It is not a frontend harness —
none of the design-system, component-sourcing, or visual-judgment machinery that
frontend work needs is here, and adding it was never the goal.

---

## The problem it solves

Point a capable agent at a real codebase and four failure modes show up, reliably:

| Failure | What it looks like | What RevHarness does |
|---|---|---|
| **Unreproducible acceptance** | The same request produces different results, and "LGTM" becomes a verbal promise | `docs/manual/verification-truth-matrix.md` is the single acceptance authority. Only deterministic check artifacts can justify completion language |
| **Boundary erosion** | An agent quietly widens its scope, or a reviewer starts implementing | Every call goes through a role-pinned wrapper that fixes effort and search policy, enforces a model floor, and strips or refuses command-line attempts to widen them |
| **Context explosion** | Large repos drown the agent in irrelevant reads | Context is acquired by targeted search and raw reads against an index map, not by bulk ingestion |
| **Reviews that miss production** | Two strong models both sign off, and the change still breaks on a real install | A smoke gate builds a throwaway adopter checkout, installs into it, and verifies the result before the phase can advance |

That last row is the one that justifies the rest. Agent review is genuinely
good at finding logic errors and genuinely bad at noticing that the thing does
not install. So the harness does not let agent approval alone advance a phase.

---

## Quick start

RevHarness installs **into** a project; it is not a project template you work
inside. Clone it once, then point it at the repository you actually want to
harness.

```bash
git clone https://github.com/sasuketorii/rev_harness_public.git
cd rev_harness_public

# 1. Confirm this machine can run it (non-destructive)
bash scripts/harness-doctor.sh

# 2. Install into your project
bash scripts/rev-harness install --target /path/to/your/project

# 3. Make one role-pinned agent call
echo "Summarize this repository's acceptance model." \
  | bash scripts/codex-wrapper.sh --role reviewer --stdin
```

Running `install` without `--target`, inside the harness checkout itself, is
refused on purpose — the harness will not install into its own source tree.

`install` is idempotent: it preserves existing state and fills in only what is
missing, so re-running it is the normal way to repair a half-configured
checkout.

**macOS users:** the harness needs bash 4+, and macOS ships bash 3.2. Run
`brew install bash` first. This is the single most common installation failure.
See [Requirements](docs/getting-started/requirements.md).

Full path: [Requirements](docs/getting-started/requirements.md) →
[Installation](docs/getting-started/installation.md) →
[First run](docs/getting-started/first-run.md) →
[Daily use](docs/getting-started/daily-use.md) →
[Troubleshooting](docs/getting-started/troubleshooting.md)

---

## Recommended setup

The harness runs on whatever you have, but it was built and used against this
configuration, and this is what the defaults assume.

### Subscriptions

| Provider | Plan |
|---|---|
| Anthropic | Claude Max 20x |
| OpenAI | ChatGPT Pro |

Two families, not one. The review gate's value comes from the reviewer being a
genuinely different model from the implementer; running everything through one
provider keeps the ceremony and loses most of the benefit.

Authenticate both CLIs in your terminal before you start. The harness never
handles credentials — it relies entirely on each CLI's own login state:

```bash
claude    # follow the login flow
codex     # follow the login flow
```

### Who drives

Run the **orchestrator on a Claude model through Claude Code** — the terminal
CLI or the desktop app, either works. From there the orchestrator calls out to
both Claude and Codex models as the work requires. Having one seat that
delegates in both directions is what makes cross-family review practical rather
than a manual chore.

### How model tiers are assigned

| Work | Tier | Why |
|---|---|---|
| Planning, investigation, review, release gating | Strongest available | These decisions are expensive to get wrong and cheap to run rarely |
| Implementation slices, documentation, low-risk edits | Faster, cheaper tier | These run constantly; paying top-tier rates for them burns your quota without improving the outcome |

This split is encoded in `.agent/registry/model_policy.json` rather than left to
whoever is typing. Override per invocation with `REV_HARNESS_CODEX_MODEL` when
you need to; the minimum-model floor still applies to the override, so you
cannot quietly downgrade a review below the policy.

---

## How it works

Five layers, most stable at the bottom:

```
Layer 4  Smoke verification    real install into a throwaway checkout
Layer 3  Product code          src/ — what you are actually building
Layer 2  Project state         plans, evidence, run state, lineage
Layer 1  Harness               scripts/ + harness-rust/ + skills + hooks
Layer 0  Ground truth          rules, invariants, immutable project identity
```

Acceptance must be grounded in **both** Layer 0 (a deterministic check) and
Layer 4 (a smoke run). Neither alone is sufficient — that asymmetry is the whole
design.

### Role-pinned invocation

Every agent call goes through a wrapper rather than the vendor CLI directly.
The three wrappers are not interchangeable — each vendor's CLI has its own
concept of "role", and each wrapper's `--help` is the source of truth:

```bash
# Codex: role fixes model tier + reasoning effort + web-search policy.
bash scripts/codex-wrapper.sh --role <coder|high-coder|reviewer|research|standard> --stdin < prompt.md

# Claude Code: NO --role flag. Deprecated passthrough shim (see below);
# pins --model/--effort explicitly and always requires --output.
bash scripts/claude-wrapper.sh --model opus --effort xhigh --output out.json "prompt"

# Cursor: role is one of Cursor's own official modes, not a Codex-style
# job role — ask (read-only, default), agent, or yolo (agent + auto-approve).
bash scripts/cursor-wrapper.sh --role <ask|agent|yolo> --stdin < prompt.md
```

`scripts/claude-wrapper.sh` is a **deprecated compatibility shim** — it prints
`[DEPRECATED]` on every invocation. Cross-family calls into Claude Code consume
Claude Agent SDK / Claude Code subscription usage and are excluded from the
harness's default orchestration flow; prefer the Task tool or a native Claude
Code subagent instead (`docs/agent-sdk-policy.md`). Passing it `--role` is not
rejected by the wrapper itself — the flag is silently forwarded to the
underlying `claude` CLI, which then fails with `error: unknown option '--role'`.

The wrapper resolves project identity and refuses to run if it is corrupt,
verifies the model policy hash, enforces the minimum model, fixes the reasoning
effort and web-search mode for the role, removes or rejects caller attempts to
override sandbox, approval, model, effort, or search, and emits one metrics line
per invocation.

Be precise about what the Codex role does and does not change. It sets
**effort and search** — `reviewer` runs at the highest effort, `research` is
the only role with live web search. It does **not** sandbox roles differently:
every role runs `workspace-write` with approval disabled. **A reviewer is not
read-only**, and you should not rely on it being unable to write.

Calling the vendor CLI directly works fine and bypasses every guard above. That
is a deliberate trade — the harness is an agreed protocol, not a cage.

### Invariants

Twelve invariants are written down as executable checks rather than as prose
anyone can reinterpret — privacy gates, evidence durability, ownership
declaration during parallel dispatch, snapshot hashes, facade/implementation
separation, explicit destructive opt-in, and the smoke-gated review
requirement. Each maps to a command you can run. The canonical set lives in
[`docs/canonical-invariants.md`](docs/canonical-invariants.md).

Their enforcement strength varies, and the document says which is which. Some
are genuinely blocking in CI. Others record evidence for a human to read rather
than mechanically refusing to proceed. Treat the distinction as load-bearing.

---

## What's in the box

| Area | Contents |
|---|---|
| `scripts/` | 77 shell scripts — wrappers, gates, lifecycle, guards; 15 of them under `scripts/ci/` |
| `harness-rust/` | Three crates: `agent-core` (lint and stamp subcommands), `harness-cache`, `shared` |
| `test/` | 103 test scripts — 41 unit, 60 integration (plus one shared helper under `test/integration/lib/`), 1 top-level; plus byte-pinned golden fixtures |
| `docs/` | Getting started, operator manuals, role definitions, the invariant set |
| `.claude/` `.agents/` `.codex/` `.cursor/` | Per-vendor configuration, skills, hooks, commands |
| `.agent_rules/` | Shared operating rules every agent family reads |
| `src/` | Empty in this checkout. Not a place to develop — see below |

`.claude/skills/` holds 34 skills — reusable operating procedures agents load on
demand, covering delegation discipline, scope guarding, deploy guards for
several platforms, and language-specific knowledge packs. They are mirrored to
`.agents/skills/` for vendor-neutral consumers; `.claude/skills/` is the single
source of truth and the mirror is generated.

---

## Adopting it in an existing repository

RevHarness is designed to overlay an existing project. `src/` in **this**
checkout is only a placeholder — it exists so that `install --target
<new-empty-project>` has something to copy for greenfield use. It is not a
directory you develop in from inside the harness clone itself: running
`install` is what creates a real, identity-bound `src/` inside your *target*
project. For an existing codebase your code stays where it is and the harness
layers on top instead of using `src/` at all. See
[Installation](docs/getting-started/installation.md#adopting-into-an-existing-repository).

The distribution manifest at
`.agent/registry/rev_harness_distribution_manifest.json` declares which paths
the harness owns, which are yours and must never be overwritten, and which need
structural merging rather than a copy.

---

## Where this came from

RevHarness is the successor to [CCTeam](https://github.com/sasuketorii/cc-team), and
it has been in continuous use and revision since mid-2025.

That timing matters for understanding why it looks the way it does. When this
line of work started, **Claude Code had no subagents.** There was no built-in way
to hand a task to a second agent, no role separation, and no mechanism for one
model to review another's output. If you wanted a second opinion from a
different model family, you built the plumbing yourself — process boundaries,
prompt handoff, artifact passing, and some way to tell whether the reviewer had
actually looked at the right thing.

So that plumbing got built. Then, because the plumbing kept catching real
problems, it got heavier: more gates, more invariants, more required evidence.
Then it got too heavy — ceremony fired on changes that did not deserve it, and
the harness started costing more attention than it saved. So it was cut back,
deliberately, more than once. The semantic index came out. The ceremony was
tiered so that trivial work stopped paying for heavy work's guarantees. Whole
subsystems were deleted rather than maintained.

What you are looking at is the residue of that cycle — built up, then filed
down, repeatedly, against real production work. Some of the vendors have since
shipped their own versions of the primitives this had to invent; subagents are
native now. The part that has not been commoditized is the part this repository
is actually about: deciding, mechanically, what counts as done.

---

## Why this exists

Agents made writing code fast. They did not make *reviewing* code fast, and
review is done by humans with a fixed daily budget of attention.

We hit that wall directly. Output outran the team's capacity to check it, and
the obvious fix — hire more reviewers — scales linearly with a cost that never
goes away. So we looked at what the reviews were actually catching, and the
answer was uncomfortable: **most of what humans were checking was mechanically
decidable.** Did the tests run. Did the check that should have blocked this
actually block it. Was the thing installed the thing that was reviewed. Did the
scope stay inside what was agreed. None of that needs judgment. It needs a gate.

So the gates were built, and the human review budget was spent on the residue —
the design calls, the risk calls, the things a script genuinely cannot decide.
The quality floor became something the machine guarantees rather than something
a tired person happens to notice, and the list of items a human must personally
look at got dramatically shorter.

That is also why the evidence is **plain markdown on disk** rather than opaque
internal state. Even when two models are reviewing each other, a human has to be
able to walk in, open a file, read what was claimed and what was checked, and
disagree. Machine-readable state that only the harness can interpret would have
closed that door. The artifacts are written to be read by a person who was not
in the room.

## Why we're publishing it — and why we stopped using it

Both halves of that sentence are true, and you deserve the second one before you
adopt anything.

**Why we stopped.** We run many projects at once. Every harness improvement had
to be propagated into every existing project's copy, and that migration work
grew until it was consuming a serious fraction of the time the harness was
supposed to save. In parallel, we found that a lot of what this armor enforces
can be carried instead by well-built agent identity — operating instincts strong
enough to fire without a gate reminding them to. That direction now looks like
it reaches a similar place with far less weight, so this harness is no longer
what we run day to day.

**Why it is still worth publishing.** The economics that pushed us off it are
specific to running a large portfolio. If you are one developer, or a company
with a handful of services, you never pay the migration tax that made this
expensive for us — you install it once and it works. Nothing in it has gone
stale or wrong; we outgrew its shape, not its substance.

It is also safe to publish. This repository is the backend and system-discipline
half of our tooling. The frontend knowledge and the finer-grained backend
know-how live elsewhere and are not here.

## What it is actually worth

The honest pitch is not "better code." It is **a quality floor that holds even
when the person driving is inexperienced.**

You have seen the alternative. Someone announces they built a site or a system
with an agent, and you can tell within seconds that an agent built it — the
uniform structure, the plausible-but-unconsidered choices, the tells. That is
what unassisted agent output converges to.

Our own work is a counterexample we can point at: [company.rev-c.com](https://company.rev-c.com)
and REVCN, our in-house system UI library, are written entirely by AI, and they
do not read as AI-made. The difference is not the model. Everyone has the same
models. The difference is that one workflow has a harness deciding what counts
as done, and the other has a person accepting whatever came back.

So when you look at this and think "I could just use Claude or Codex directly" —
you can, and you will get something. What comes out the other side is not the
same thing.

## What this does not do

Two independent model reviews of this repository — one Claude, one Codex — were
run before publication specifically to find over-claims. These are the ones they
found, kept here rather than quietly fixed in the prose:

- **It is not a security boundary.** Nothing stops someone from calling the
  vendor CLI directly, editing an evidence artifact by hand, or writing the
  state file themselves. There is no OS-level isolation. Do not present its
  output as tamper-resistant audit evidence.
- **Reviewers can write.** All roles run with `workspace-write`. Role changes
  effort and search, not filesystem access.
- **The review check verifies form, not authorship.** It confirms that two
  designated files exist and contain a verdict. It does not verify that two
  different models produced them, that they reviewed the right diff, or that a
  human did not write both.
- **The smoke gate tests the harness, not your product.** It installs into a
  throwaway checkout and exercises the harness lifecycle. Your build, your
  migrations, and your end-to-end tests are still yours to run.
- **Model identifiers age.** The floor check compares version numbers; it cannot
  tell whether a model exists, is available on your account, or is better.
- **It costs ceremony.** Two reviews take two reviews' worth of time and tokens.
  For a solo developer on a short-lived prototype, that overhead will likely
  exceed what the traceability is worth.
- **It is opinionated.** If you want a lighter touch, take the wrappers and the
  truth matrix and leave the rest.

If you need enforced reviewer isolation or compliance-grade audit evidence, this
harness does not provide them today, and you should not adopt it as though it
did.

## What was deliberately left out

This is not a full extract of what we run internally. **The gates and heuristics
that amount to our core competence were removed before publishing.** Specifically,
the judgment layer — which checks fire on which change surfaces, how risk is
classified, where the thresholds sit, and the accumulated rules about what
actually goes wrong — was tuned against our own work over a long time, and that
tuning is the part with commercial value. It is not here.

What ships is the skeleton and the mechanisms: the wrappers, the acceptance
contract, the evidence format, the smoke gate, the lifecycle, the invariant
structure. Those work. But a gate is only as good as the judgment encoded in it,
and some of these gates are now closer to well-formed placeholders than to
sharpened tools.

**So if something does not catch what you expected it to catch, that is probably
why — and fixing it is yours to do.** That is the intended use, not a
consolation. Your failure modes are not our failure modes. A harness tuned
against someone else's incidents would be the wrong harness anyway; what
transfers is the shape, and the shape is what this repository is.

Concretely, expect to invest in:

- Adding the checks that matter for *your* stack to the truth matrix, and wiring
  them into the release gate.
- Tightening the risk classification so that heavy ceremony fires on your
  genuinely dangerous surfaces and stays out of the way elsewhere.
- Extending the smoke gate to cover your product's install and startup path, not
  just the harness's.

Pull requests that sharpen the generic mechanisms are welcome. Pull requests
that hard-code your domain judgment into the shared layer are not — keep those
in your own fork, which is exactly where they belong.

## History worth knowing

RevHarness used to ship a semantic code-intelligence layer — tree-sitter symbol
indexing, a per-project SQLite index, an MCP server exposing `sem.*` retrieval
tools, and compressed context capsules. It was demoted to an opt-in addon, given
a measurement window, and then removed entirely: roughly 42,900 lines deleted.
Agentic search with `rg` retrieved what was needed without an index that had to
be kept fresh — and keeping it fresh was a fail-closed surface taxed on every
commit.

The full reasoning, and what to do if you want semantic retrieval anyway, is in
[Why there is no semantic index](docs/architecture/why-no-semantic-index.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Because the project's entire premise is
mechanical verification, pull requests are expected to carry the output of the
deterministic checks relevant to what they touch.

## Security

The harness runs shell scripts locally and hands scoped permissions to agent
CLIs. Read [SECURITY.md](SECURITY.md) before loosening any sandbox or approval
setting, and report vulnerabilities privately via GitHub Security Advisories.

## License

[Apache License 2.0](LICENSE).
