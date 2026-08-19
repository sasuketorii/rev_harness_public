#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/install-rev-harness-hooks.sh"
EVENT_LOG="${TMPDIR:-/tmp}/settings-merge-test-events.$$.jsonl"
TMP_ROOTS=()
PRESERVED_ROOT=""

cleanup() {
  local root
  for root in "${TMP_ROOTS[@]}"; do
    [[ ! -d "$root" ]] || /bin/rm -rf "$root"
  done
  /bin/rm -f "$EVENT_LOG"
}
trap cleanup EXIT

new_root() {
  local root
  root="$(mktemp -d)"
  TMP_ROOTS+=("$root")
  # The installer guards on the adopter root being a git repository
  # (git rev-parse --show-toplevel), so each temp adopter root must be a
  # real repo or installation aborts at setup.
  git init -q "$root"
  printf '%s\n' "$root"
}

run_installer() {
  local adopter_root="$1"
  PROJECT_ROOT="$adopter_root" \
  REV_HARNESS_WIRE_EVENT_LOG="$EVENT_LOG" \
    bash "$INSTALLER" \
      --adopter-root "$adopter_root" \
      --harness-root "$REPO_ROOT" >/dev/null
}

assert_count_one() {
  local needle="$1" file="$2" count
  count="$(grep -c "$needle" "$file" || true)"
  [[ "$count" == "1" ]] || {
    printf 'FAIL: expected one %s in %s, got %s\n' "$needle" "$file" "$count" >&2
    exit 1
  }
}

assert_all_hooks_once() {
  local file="$1"
  assert_count_one 'snapshot-pre.sh' "$file"
  assert_count_one 'snapshot-post.sh' "$file"
  assert_count_one 'snapshot-stop.sh' "$file"
  assert_count_one 'path-leak-advise.sh' "$file"
}

scenario_fresh_install() {
  local root settings
  root="$(new_root)"
  settings="$root/.claude/settings.local.json"

  run_installer "$root"

  [[ -f "$settings" ]] || { printf 'FAIL: settings.json not created\n' >&2; exit 1; }
  jq -e . "$settings" >/dev/null
  assert_all_hooks_once "$settings"
  printf 'PASS: Fresh install\n'
}

scenario_mcpservers_preserve() {
  local root settings
  root="$(new_root)"
  settings="$root/.claude/settings.local.json"
  mkdir -p "$(dirname "$settings")"
  printf '{"mcpServers":{"foo":{"command":"bar"}}}\n' > "$settings"

  run_installer "$root"

  assert_all_hooks_once "$settings"
  jq -e '.mcpServers.foo.command == "bar"' "$settings" >/dev/null
  PRESERVED_ROOT="$root"
  printf 'PASS: mcpServers preserve\n'
}

scenario_idempotency() {
  local root settings before_copy line_before status
  root="$1"
  settings="$root/.claude/settings.local.json"
  before_copy="$root/settings.before.json"
  cp "$settings" "$before_copy"
  line_before="$(wc -l < "$EVENT_LOG" | tr -d ' ')"

  run_installer "$root"

  assert_all_hooks_once "$settings"
  cmp "$before_copy" "$settings" >/dev/null || {
    printf 'FAIL: settings changed on idempotent reinstall\n' >&2
    exit 1
  }
  status="$(tail -n "$((line_before + 1))" "$EVENT_LOG" | tail -n 1 | jq -r '.status')"
  [[ "$status" == "noop" ]] || {
    printf 'FAIL: expected noop event, got %s\n' "$status" >&2
    exit 1
  }
  printf 'PASS: Idempotency\n'
}

scenario_no_managed_ids_sentinel() {
  # After a fresh wire, the legacy `_managed_ids` sentinel must be ABSENT:
  # idempotency is keyed on actual hook-command presence, not the sentinel.
  local root settings
  root="$(new_root)"
  settings="$root/.claude/settings.local.json"

  run_installer "$root"

  jq -e '.hooks | has("_managed_ids") | not' "$settings" >/dev/null || {
    printf 'FAIL: _managed_ids sentinel present after wire (should be absent)\n' >&2
    exit 1
  }
  printf 'PASS: no _managed_ids sentinel\n'
}

scenario_legacy_sentinel_migrates() {
  # Migration: a config pre-seeded with the legacy `_managed_ids` key AND the
  # managed hook commands is treated as not-cleanly-wired (sentinel present),
  # so a re-merge strips the sentinel with no hook duplication.
  local root settings
  root="$(new_root)"
  settings="$root/.claude/settings.local.json"
  mkdir -p "$(dirname "$settings")"

  # First wire to obtain a real managed config, then re-introduce the legacy
  # sentinel to simulate a pre-migration adopter.
  run_installer "$root"
  jq '.hooks._managed_ids = ["legacy-snapshot-pre","legacy-snapshot-post","legacy-path-leak-advise","legacy-snapshot-stop"]' \
    "$settings" > "$settings.seed" && mv "$settings.seed" "$settings"
  jq -e '.hooks | has("_managed_ids")' "$settings" >/dev/null || {
    printf 'FAIL: could not seed legacy sentinel\n' >&2
    exit 1
  }

  # Re-run the merge: sentinel must be stripped, hooks must not duplicate.
  run_installer "$root"

  jq -e '.hooks | has("_managed_ids") | not' "$settings" >/dev/null || {
    printf 'FAIL: legacy _managed_ids sentinel not stripped on migration\n' >&2
    exit 1
  }
  assert_all_hooks_once "$settings"

  # A subsequent re-run is now a clean noop (no sentinel, all commands present).
  local line_before status
  line_before="$(wc -l < "$EVENT_LOG" | tr -d ' ')"
  run_installer "$root"
  assert_all_hooks_once "$settings"
  status="$(tail -n "$((line_before + 1))" "$EVENT_LOG" | tail -n 1 | jq -r '.status')"
  [[ "$status" == "noop" ]] || {
    printf 'FAIL: expected noop after migration, got %s\n' "$status" >&2
    exit 1
  }
  printf 'PASS: legacy sentinel migrates (stripped, no dup, idempotent)\n'
}

scenario_invalid_json_refuse() {
  local root settings rc status
  root="$(new_root)"
  settings="$root/.claude/settings.local.json"
  mkdir -p "$(dirname "$settings")"
  printf '{ not valid json\n' > "$settings"

  set +e
  PROJECT_ROOT="$root" REV_HARNESS_WIRE_EVENT_LOG="$EVENT_LOG" \
    bash "$INSTALLER" --adopter-root "$root" --harness-root "$REPO_ROOT" >/dev/null 2>&1
  rc="$?"
  set -e

  [[ "$rc" == "2" ]] || { printf 'FAIL: invalid JSON exit=%s, want 2\n' "$rc" >&2; exit 1; }
  status="$(tail -n 1 "$EVENT_LOG" | jq -r '.status')"
  [[ "$status" == "error" ]] || {
    printf 'FAIL: expected error event, got %s\n' "$status" >&2
    exit 1
  }
  printf 'PASS: invalid JSON refuse\n'
}

main() {
  command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required\n' >&2; exit 2; }
  : > "$EVENT_LOG"

  scenario_fresh_install
  scenario_mcpservers_preserve
  scenario_idempotency "$PRESERVED_ROOT"
  scenario_no_managed_ids_sentinel
  scenario_legacy_sentinel_migrates
  scenario_invalid_json_refuse

  printf 'ALL PASS\n'
}

main "$@"
