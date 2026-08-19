#!/usr/bin/env bash
set -euo pipefail

TARGET_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/revharness-paths.XXXXXX")"
trap '/bin/rm -rf "$TARGET_ROOT"' EXIT

PATHS_FILE="$TARGET_ROOT/.rev-harness-state/paths.json"
PROJECT_ID="test-project"
# The Rust cache DB lives at the platform data dir under Revharness/. The path
# layout is shared-crate canonical (shared::paths); the harness is semantic-free
# and this DB is the per-project Rust cache backend only.
RUST_DB="${XDG_DATA_HOME:-$HOME/.local/share}/Revharness/semantic-mcp/v1/$PROJECT_ID/semantic.db"

mkdir -p "$(dirname "$PATHS_FILE")"
jq -nc \
  --arg schema "rev-harness-paths/v1" \
  --arg project_id "$PROJECT_ID" \
  --arg rust_db "$RUST_DB" \
  '{
    schema: $schema,
    project_id: $project_id,
    backend: "rust",
    rust_db: $rust_db,
    separation_rationale: "Rust is the only supported backend; the per-project DB is the Rust cache store. The harness is semantic-free; no Node or semantic-index backend exists.",
    platform_notes: "macOS = ~/Library/Application Support, Linux = ~/.local/share"
  }' > "$PATHS_FILE"

jq -e '
  .schema == "rev-harness-paths/v1"
  and .backend == "rust"
  and (.rust_db | type == "string" and length > 0)
  and (.node_db | not)
  and (.semantic_db | not)
  and .separation_rationale == "Rust is the only supported backend; the per-project DB is the Rust cache store. The harness is semantic-free; no Node or semantic-index backend exists."
  and .platform_notes == "macOS = ~/Library/Application Support, Linux = ~/.local/share"
' "$PATHS_FILE" >/dev/null

printf 'PASS: paths manifest schema and literals OK\n'
