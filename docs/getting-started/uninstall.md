# Uninstall

日本語版: [docs/ja/getting-started/uninstall.md](../ja/getting-started/uninstall.md)

There is no automated removal path yet. `scripts/rev-harness uninstall` prints
an advisory checklist and stops; it never deletes anything itself. This page
documents what `install` actually creates in an adopted project, and the
manual steps to remove it, based on running `install`, `clean`, and
`uninstall` against a throwaway git checkout while writing this document —
none of the output below is paraphrased from memory.

## `clean` vs `uninstall`: neither removes the harness

```bash
bash scripts/rev-harness clean        # remove runtime residue, keep the install
bash scripts/rev-harness uninstall    # reports what would be removed
```

These two commands are easy to misread as a two-step uninstall. They are not:

- `clean` runs the Cargo build-artifact janitor (`janitor_command: build-cleanup`
  in its output). It targets `harness-rust/target` and the local Cargo registry
  cache on the **canonical harness clone**, not the adopted project. On a
  project with no Rust build artifacts it reports `target_count: 1`,
  `freed_bytes: 0` and changes nothing. It does not touch `.agent/`, `.claude/`,
  `.shared/`, or `.rev-harness-state/`.
- `uninstall` is report-only. Running it against a real adopted project prints
  exactly this (only the paths differ):

  ```
  RevHarness uninstall checklist (advisory only)

  1. Remove canonical PATH export line from shell rc files. This checkout's
     scripts directory is:
       /path/to/your/rev_harness_public/scripts
     Find the matching line first (it may differ if you renamed the checkout):
       grep -n '/path/to/your/rev_harness_public/scripts' "${HOME}/.zshrc" "${HOME}/.bashrc" 2>/dev/null
     Then remove it, e.g.:
       sed -i.bak "\|/path/to/your/rev_harness_public/scripts|d" "${HOME}/.zshrc"
       sed -i.bak "\|/path/to/your/rev_harness_public/scripts|d" "${HOME}/.bashrc"

  2. Delete adopter state:
     rm -f .agent/registry/rev_harness_adoption_state.json

  3. Inspect installed links or dirs before removal:
     .claude/
     .agent/active/
     Remove only symlinks or directories created by the RevHarness install.

  4. Restore .git/hooks/pre-commit if needed.
     Expected backup: .git/hooks/pre-commit.rev-harness.bak (backup not detected)

  5. Decide what to do with .shared/project_id.
     This is immutable project identity; do not delete unless explicitly retiring the project.

  6. Cargo target cleanup is canonical-side only:
     /path/to/your/rev_harness_public/harness-rust/target
     This is not adopter-side uninstall state.
  ```

  The command resolves the scripts directory and cargo-target path from
  *this checkout's own actual location* at run time (via `--json` you get
  them as plain fields), so the paths above always match wherever you
  actually cloned the repo — they are not a fixed guess like
  `~/dev/rev_harness`. If you followed the default clone command in
  [Adoption Guide](../adoption-guide.md) that location is
  `~/dev/rev_harness_public`.

  `uninstall` accepts an `--apply` flag, but it is not implemented yet: passing
  it prints `uninstall --apply: deferred (not yet implemented)` to stderr and
  exits with status `2`, without deleting anything. The advisory-only checklist
  above is what you get either way — the harness would rather hand you an
  accurate list than guess wrong about what is safe to delete in your project.

## What `install` actually creates

Running `bash scripts/rev-harness install --target <project>` against a fresh
git checkout created the following, observed directly:

| Path | What it is |
|---|---|
| `.shared/project_id` | Immutable project identity. Everything else keys off this. |
| `.shared/rev-harness-adopter-setup.state.json` | Adopter-setup phase-tracking state. |
| `.rev-harness-state/state.json` | The `install`/`clean`/`uninstall` state machine and command history. |
| `.rev-harness-state/snapshots/<run-id>/` | Pre-change snapshot taken before the install run. |
| `.agent/PROJECT_CONTEXT.md`, `.agent/requirements.md` | Generated project templates. |
| `.agent/registry/model_policy.json` | Copied-in model routing policy. |
| `.agent/registry/rev_harness_adoption_state.json` | **A symlink** to `.rev-harness-state/state.json`, not a separate file. |
| `.agent/generated/`, `.agent/active/`, `.agent/archive/`, `.agent/metrics/` | Empty scaffold directories for later runtime output. |
| `.claude/settings.local.json` | Claude Code local settings merged in by the installer. |
| `.claude/settings.local.json.bak.<timestamp>-<pid>` | Backup of `settings.local.json` written immediately before every hook merge — including when no `settings.local.json` existed yet, in which case the installer first writes an empty `{}` and then backs up that empty file before merging in the managed hooks. Verified by running the installer against a project with no prior `.claude/` directory: the `.bak.*` file was created anyway (containing `{}`). |
| `.claude/tmp/.gitkeep` | Placeholder keeping the scratch directory in git. |
| `.git/hooks/pre-commit` | The RevHarness guard hook. If a pre-commit hook already existed, it is backed up to `.git/hooks/pre-commit.rev-harness.bak` first (this is the backup path `uninstall`'s checklist item 4 looks for). |
| `docs/design/.gitkeep`, `docs/manual/.gitkeep`, `docs/requirements/.gitkeep`, `docs/requirements/README.md` | Empty scaffold directories/templates under `docs/`. |
| `.gitignore` | Appended with `.claude/tmp/`, `workspace/`, `*.log`, `.DS_Store`, `.rev_harness/`, `semantic.db`, `semantic.db-wal`, `semantic.db-shm`, `.migration.lock` (only lines not already present). |

## Removing it by hand

There is no single command; do these in order.

1. **Delete the harness scaffold directories and files**, keeping anything you
   have since put real content into:

   ```bash
   rm -rf .shared .rev-harness-state
   rm -rf .agent/generated .agent/active .agent/archive .agent/metrics
   rm -f .agent/registry/rev_harness_adoption_state.json .agent/registry/model_policy.json
   rm -f .agent/PROJECT_CONTEXT.md .agent/requirements.md
   rm -rf .claude/tmp
   rm -f .claude/settings.local.json.bak.*
   find docs -name '.gitkeep' -delete
   ```

   Review `.agent/PROJECT_CONTEXT.md` and `.agent/requirements.md` before
   deleting them — if you filled them in with real project content, keep
   them instead.

2. **Restore or remove the pre-commit hook.**

   ```bash
   if [ -f .git/hooks/pre-commit.rev-harness.bak ]; then
     mv .git/hooks/pre-commit.rev-harness.bak .git/hooks/pre-commit
   else
     rm -f .git/hooks/pre-commit
   fi
   ```

3. **Undo the `.gitignore` additions** the installer made, if you no longer
   want them (they are also just useful defaults for most projects, so it is
   fine to leave them):

   ```bash
   sed -i.bak '/^\.claude\/tmp\/$/d;/^workspace\/$/d;/^\*\.log$/d;/^\.DS_Store$/d;/^\.rev_harness\/$/d;/^semantic\.db$/d;/^semantic\.db-wal$/d;/^semantic\.db-shm$/d;/^\.migration\.lock$/d' .gitignore
   ```

4. **`.claude/settings.local.json`** carries per-project Claude Code state that
   may include settings you added yourself after install. Diff it before
   deleting:

   ```bash
   git diff -- .claude/settings.local.json
   ```

   Delete or hand-edit it once you have confirmed nothing you need is in
   there.

5. **`.shared/project_id`** is already gone if you ran step 1. Only skip
   deleting it if you plan to reinstall against the same project later and
   want state to key off the same identity.

6. **Remove the harness's own PATH export**, if you added one to your shell rc
   file when connecting the CLIs. Match on the actual clone path you used
   (the default from [Adoption Guide](../adoption-guide.md) is
   `~/dev/rev_harness_public/scripts`), not a fixed guess — find it first,
   then delete it:

   ```bash
   scripts_dir="$HOME/dev/rev_harness_public/scripts"   # adjust if you cloned elsewhere
   grep -n "$scripts_dir" "${HOME}/.zshrc" "${HOME}/.bashrc" 2>/dev/null
   sed -i.bak "\|$scripts_dir|d" "${HOME}/.zshrc"
   sed -i.bak "\|$scripts_dir|d" "${HOME}/.bashrc"
   ```

7. **Cargo build artifacts** (`harness-rust/target`, the Cargo registry cache)
   belong to your local clone of the harness itself, not to the adopted
   project. Delete them the normal way (`cargo clean` inside `harness-rust/`,
   or `rm -rf harness-rust/target`) if you are removing the harness clone
   entirely.

Verify you are done with `git status`: everything the harness added should now
be gone or intentionally kept, and nothing outside the paths above should have
changed.

Next: [Troubleshooting](troubleshooting.md) if something above didn't match
what you observed in your own project.
