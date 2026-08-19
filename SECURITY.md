# Security Policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report privately via **GitHub Security Advisories**:

1. Go to this repository's **Security** tab.
2. Select **Report a vulnerability** to open a private draft advisory.
3. Include: affected file(s)/script(s), the version or commit you tested,
   reproduction steps, and the impact you believe it has (e.g. arbitrary
   command execution, privilege escalation, sandbox/approval bypass,
   credential exposure).

If you do not have GitHub access or prefer another channel, open a regular
GitHub issue asking for a private contact path and we will follow up without
requiring you to disclose details publicly.

We aim to acknowledge new reports within a few business days. This is a
maintainer-run open-source project rather than a company with a formal SLA,
so response and fix timelines depend on severity and maintainer availability
— please say so in your report if you believe a vulnerability is actively
exploitable or otherwise urgent.

## Scope

In scope:
- The wrapper scripts under `scripts/` (`codex-wrapper.sh`,
  `claude-wrapper.sh`, `cursor-wrapper.sh`, `model-policy.sh`, and related
  helpers) and their fail-closed guarantees (fixed sandbox/approval policy,
  blocked CLI-flag overrides, minimum-model gating).
- Policy/registry files under `.agent/registry/` and how they are validated.
- `harness-rust/` crates.
- Hooks and commands under `.claude/` and `.codex/`.

Out of scope:
- Vulnerabilities in the underlying agent CLIs themselves (Codex CLI, Claude
  Code, Cursor CLI) — report those to their respective vendors.
- Vulnerabilities in third-party dependencies with no harness-specific
  exploitation path — please still report Rust dependency CVEs if you find
  one is unpatched in `harness-rust/Cargo.lock`, but general
  upstream-library disclosure should also go to the upstream project.

## Understand what this harness does before running it

This is important enough to say plainly, not just imply through defaults:

**This harness runs local shell scripts that invoke agent CLIs (Codex,
Claude Code, Cursor) with elevated, largely unattended permissions by
design.** The Codex and Claude Code wrapper scripts fix sandbox mode
(`workspace-write`) and approval policy (`never`/auto-approve) so that
agent-driven workflows can run without a human clicking "approve" on every
command. The Cursor wrapper (`scripts/cursor-wrapper.sh`) is narrower: its
default role, `ask`, is a wrapper-enforced true read-only path (no file
writes, no shell execution); only the explicit `agent` and `yolo` roles are
write-capable, and `yolo` additionally auto-approves shell commands. See
`docs/manual/cursor-cli-integration.md` for the per-role contract. That is
the intended, documented behavior — not a bug — but it means:

- An agent invoked through this harness can read, write, and delete files
  within the workspace it is granted, and can execute shell commands, without
  per-command human confirmation.
- If you weaken the sandbox or approval settings further (e.g. by passing
  `--sandbox danger-full-access`, `--dangerously-bypass-approvals-and-sandbox`,
  or equivalent flags/env vars that this harness's wrappers are designed to
  block), you are removing the harness's own safety net. The wrappers detect
  and reject a known set of such override attempts (see
  `blocked_overrides` in `.agent/registry/model_policy.json` and the
  argument filter in `scripts/codex-wrapper.sh`), but this is a denylist of
  known-dangerous flags, not a sandbox in the security sense — it cannot
  stop every way an underlying CLI might be told to escape its sandbox, and
  it cannot protect you if you invoke the underlying `codex`/`claude`/`cursor`
  binaries directly instead of going through the wrapper.
- Prompts and file contents you hand to an agent through this harness can
  contain instructions the agent may act on. Treat any content pulled from
  the network, from untrusted repositories, or from third parties as
  potentially adversarial input, the same way you would treat it when
  reviewing a pull request.
- Running this harness against a workspace containing credentials, private
  keys, or other secrets means an agent process could read and potentially
  exfiltrate them (e.g. via a tool call, a committed file, or a web request
  the agent is permitted to make). Keep secrets out of the workspace or use
  your OS/CI secret-manager mechanisms instead of plaintext files where
  possible.
- Model-policy fail-closed gates (minimum allowed model, hash-matched
  generated policy) protect against silently running with a
  weaker/downgraded model configuration, not against the risks above. Do not
  treat "the model gate passed" as "this invocation is safe."

If your threat model requires stronger isolation than an OS-level workspace
sandbox (e.g. untrusted third-party prompts, multi-tenant use, or handling
real secrets), run this harness inside a disposable container or VM with no
access to anything you are not willing to expose to an agent process.

## Disclosure

We prefer coordinated disclosure: please give us a reasonable window to
investigate and ship a fix or mitigation before any public write-up. We will
credit reporters (unless you ask us not to) once a fix is available.
