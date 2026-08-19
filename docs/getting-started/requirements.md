# Requirements

Everything on this page was verified against the source tree, not assumed. Where
a requirement is enforced by code, the enforcing location is cited so you can
check it yourself.

日本語版: [docs/ja/getting-started/requirements.md](../ja/getting-started/requirements.md)

---

## 1. Supported operating systems

| OS | Status | Notes |
|---|---|---|
| macOS (Apple Silicon / Intel) | Supported | Requires a newer bash than the system one — see §2 |
| Linux (Debian/Ubuntu, Fedora, Arch, …) | Supported | No extra work; distro bash is already 4+ |
| WSL2 (Ubuntu et al.) | Expected to work, **not verified** | Treated as Linux; no WSL-specific code path exists |
| Windows (cmd / PowerShell, native) | **Not supported** | Every script is POSIX-shell based |

The harness contains **no macOS-only commands** (`sw_vers`, `pbcopy`, `osascript`
appear nowhere in the tree). Where BSD and GNU tools differ — `stat`, `date`,
`readlink` — every call site either branches on `uname == Darwin` or probes with
`command -v` and falls back.

## 2. bash 4.0 or newer — the one requirement that actually bites

**This is the most common installation failure, and it only affects macOS.**

macOS ships `/bin/bash` frozen at **3.2** for licensing reasons (Apple avoids
GPLv3). The harness uses bash 4 features — associative arrays (`declare -A`) in
`scripts/ci/index-map-check.sh` and `scripts/harness-active-artifact-pruner.sh`,
and `mapfile` in several others. On bash 3.2 these are **syntax errors**, so the
script dies before it can print anything useful.

Check what you have:

```bash
bash --version
```

If it reports 3.2 on macOS, install a current bash and make sure it comes first
on `PATH`:

```bash
brew install bash
```

Scripts use `#!/usr/bin/env bash`, so they pick up whichever bash `PATH` finds
first. You do **not** need to change your login shell, and you do not need to
replace `/bin/bash`.

Linux distributions ship bash 4+ (usually 5.x), so no action is needed there.

## 3. Required command-line tools

These four are hard-required — `scripts/harness-doctor.sh` fails closed if any
is missing:

| Tool | Why | Preinstalled? |
|---|---|---|
| `git` | Repository operations throughout | macOS: with Xcode CLT. Linux: usually needs installing |
| `jq` | Every JSON state file is read and written through it | **No** — install it |
| `awk` | Text processing | Yes, both platforms |
| `sha256sum` **or** `shasum` | Hash verification for evidence and snapshots | Linux has `sha256sum`; macOS has `shasum` |

Everything else is optional and guarded by `command -v`, so a missing tool
degrades one feature rather than breaking the harness:

| Tool | Needed for | If missing |
|---|---|---|
| `flock` | Lock files during parallel dispatch | Locking is skipped (macOS has no `flock` by default) |
| `setsid` | Process-group isolation for background workers | Falls back to plain spawn |
| `timeout` / `gtimeout` | Wrapper timeouts | Timeout enforcement is skipped |
| `python3` | A few helper scripts | Those helpers are skipped |
| `shellcheck` | Linting your own contributions | Lint step is skipped |
| `ripgrep` (`rg`) | Faster search | Falls back to `grep` |
| `sqlite3` | Shell-side database inspection | Inspection scripts are skipped |

### 3a. `pytest` — required for the first-run tutorial, not for the harness itself

The harness core never imports or shells out to `pytest`. It is not part of the
hard-required list above and `scripts/harness-doctor.sh` does not check for it.

However, the [first-run tutorial](first-run.md) walks you through writing and
running a Python test with it (`python3 -m pytest -q test_greet.py`, step 4). If
you intend to follow that tutorial end to end, install both `python3` and
`pytest` first:

```bash
python3 -m pip install pytest
```

If you only plan to use the harness on non-Python projects, you can skip this —
just be aware the tutorial as written will fail at step 4 without it.

## 4. Agent CLIs

Both are **optional to install** but you need at least one to actually do
agent-driven development — the harness will warn you at setup time if neither is
present (`setup/bootstrap.sh`).

| CLI | Install | Role |
|---|---|---|
| Claude Code | `npm install -g @anthropic-ai/claude-code` | Orchestrator and coder |
| Codex CLI | `npm install -g @openai/codex` | Independent reviewer, cross-family delegation |
| Cursor CLI | see Cursor docs | Fully optional; a wrapper exists but nothing depends on it |

The harness never stores credentials. It relies entirely on each CLI's own login
state or the provider environment variables those CLIs read. No API key is
hardcoded anywhere in this repository, and none should be added.

Using two different model families is not decoration — the review gate is built
on the assumption that the reviewer is a *different* model from the implementer.
Running everything through one family weakens that gate, though it still works.

## 5. Rust toolchain (optional)

Only needed if you build `harness-rust/`. The shell layer runs without it.

- Workspace of three crates: `agent-core`, `harness-cache`, `shared`
- The pinned toolchain lives in `harness-rust/rust-toolchain.toml`
- A **C compiler is required** — `rusqlite` uses its `bundled` feature and
  compiles SQLite from source, so you need Xcode Command Line Tools on macOS or
  `build-essential` on Debian/Ubuntu

```bash
curl https://sh.rustup.rs -sSf | sh
```

## 6. Disk, memory, network

| Resource | Requirement |
|---|---|
| Disk (checkout) | ~9 MB |
| Disk (with a full Rust release build) | Allow ~1.5 GB — the release profile uses fat LTO |
| Memory | No measured floor. Normal developer machines are fine |
| Network | Needed for `git` and for whichever agent CLI you use. The harness's own scripts reach the network in exactly one place: `scripts/model-policy.sh` fetches provider documentation when you ask it to verify a model-policy change against official evidence. Nothing else calls out |

## 7. One-shot install commands

### macOS

```bash
xcode-select --install
brew install bash jq git coreutils ripgrep shellcheck
npm install -g @anthropic-ai/claude-code @openai/codex
```

`coreutils` supplies `timeout`/`gtimeout`. `flock` and `setsid` remain absent on
macOS and the harness handles that by design — you do not need to chase them.

### Debian / Ubuntu

```bash
sudo apt update
sudo apt install -y bash jq git build-essential util-linux coreutils ripgrep shellcheck
npm install -g @anthropic-ai/claude-code @openai/codex
```

## 8. Verify before you continue

```bash
bash scripts/harness-doctor.sh
```

This checks the hard requirements above and reports what is missing. It is
non-destructive and safe to run at any time.

## 9. Language, before you clone further

This README and everything under `getting-started/` are English. Most of the
harness's normative documents — the acceptance authority
(`docs/manual/verification-truth-matrix.md`), the role definitions under
`docs/roles/`, `.claude/CLAUDE-LOCAL.md`, and the large majority of other
files outside `docs/ja/` (hundreds of them; the exact count drifts as files
are added or removed, so it is not tracked here) — are Japanese and have not
been translated. Agents respond to the
user in Japanese by default (`.agent_rules/shared-language.md`, rules
`RS-LANG-01` and `RS-LANG-03`); edit those two rules to change the default.
Setup script console output (e.g. `scripts/init-project.sh`) is also Japanese.
See `docs/README.md` for the full picture.

Next: [Adoption Guide](../adoption-guide.md)
