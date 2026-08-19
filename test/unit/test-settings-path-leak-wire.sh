#!/usr/bin/env bash
set -euo pipefail

settings=".claude/settings.json"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

require_file() {
  local path="$1"

  if [[ ! -f "$path" ]]; then
    fail "missing file: $path"
  fi
}

json_valid() {
  python3 -c "import json; json.load(open('.claude/settings.json'))"
  pass "settings.json is valid JSON"
}

commands_for() {
  local section="$1"

  jq -r --arg section "$section" \
    '.hooks[$section][]?.hooks[]?.command // empty' \
    "$settings"
}

require_exact_command() {
  local section="$1"
  local expected="$2"

  if ! commands_for "$section" | grep -Fqx "$expected"; then
    fail "$section missing exact command: $expected"
  fi

  pass "$section contains exact command: $expected"
}

require_command_name() {
  local section="$1"
  local expected="$2"

  if ! commands_for "$section" | grep -Fq "$expected"; then
    fail "$section missing command containing: $expected"
  fi

  pass "$section contains command containing: $expected"
}

main() {
  require_file "$settings"

  json_valid

  require_exact_command \
    "PostToolUse" \
    ".claude/hooks/path-leak-advise.sh"

  require_command_name "PostToolUse" "snapshot-post.sh"
  require_command_name "PostToolUse" "codex-review-hook.sh"
  require_command_name "PreToolUse" "snapshot-pre.sh"
  require_command_name "Stop" "snapshot-stop.sh"

  pass "settings path-leak hook wiring preserved required hooks"
}

main "$@"
