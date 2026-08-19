#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s [--strict]\n' "${0##*/}" >&2
}

strict=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) strict=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
agents="$repo_root/AGENTS.md"
canonical="$repo_root/docs/canonical-invariants.md"
matrix="$repo_root/docs/manual/verification-truth-matrix.md"

policy_failures=0

fail_policy() {
  printf 'invariant sync check: %s\n' "$*" >&2
  policy_failures=$((policy_failures + 1))
}

env_fail() {
  printf 'invariant sync check: %s\n' "$*" >&2
  exit 3
}

for path in "$agents" "$canonical" "$matrix"; do
  [ -r "$path" ] || env_fail "required file not readable: ${path#"$repo_root"/}"
done

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/invariant-sync.XXXXXX")"
trap 'rm -rf "$tmp_dir" || true' EXIT

extract_table_ids() {
  awk -F'|' '
    /^\|/ {
      id=$2
      gsub(/`/, "", id)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
      split(id, parts, /[[:space:]]+/)
      id=parts[1]
      if (id ~ /^(I-[0-9]+[a-z]?|Addon-I-[0-9]+[a-z]?)$/) print id
    }
  ' "$1" | sort -u
}

extract_canonical_section_ids() {
  awk '
    /^### (I-[0-9]+[a-z]?|Addon-I-[0-9]+[a-z]?)([[:space:]]|$)/ {
      print $2
    }
  ' "$canonical" | sort -u
}

extract_table_ids "$agents" > "$tmp_dir/agents.ids"
extract_canonical_section_ids > "$tmp_dir/canonical.ids"
extract_table_ids "$matrix" > "$tmp_dir/matrix.ids"
cat "$tmp_dir/agents.ids" "$tmp_dir/canonical.ids" "$tmp_dir/matrix.ids" | sort -u > "$tmp_dir/all.ids"

while IFS= read -r id; do
  [ -n "$id" ] || continue
  grep -Fx "$id" "$tmp_dir/agents.ids" >/dev/null 2>&1 || fail_policy "$id missing from AGENTS.md invariant tables"
  grep -Fx "$id" "$tmp_dir/canonical.ids" >/dev/null 2>&1 || fail_policy "$id missing from docs/canonical-invariants.md sections"
  grep -Fx "$id" "$tmp_dir/matrix.ids" >/dev/null 2>&1 || fail_policy "$id missing from verification-truth-matrix invariant gates"
done < "$tmp_dir/all.ids"

for required in I-1 I-2 I-2b I-3 I-4 I-5 I-6 I-7 I-8 I-9 I-10 I-11 I-12 I-13 Addon-I-2 Addon-I-2b Addon-I-13; do
  grep -Fx "$required" "$tmp_dir/all.ids" >/dev/null 2>&1 || fail_policy "$required not resolved in invariant surfaces"
done

if rg -n '13 invariants|13 invariant|13-invariant' "$agents" "$canonical" "$matrix" >/tmp/invariant-sync-banned.$$ 2>/dev/null; then
  cat /tmp/invariant-sync-banned.$$ >&2
  rm -f /tmp/invariant-sync-banned.$$
  fail_policy "banned count-based invariant literal found"
else
  rm -f /tmp/invariant-sync-banned.$$ 2>/dev/null || true
fi

if rg -n '^(\| I-2 \|.*Tier 1|### I-2 .*Tier 1)' "$agents" "$canonical" "$matrix" >/tmp/invariant-sync-tier1.$$ 2>/dev/null; then
  cat /tmp/invariant-sync-tier1.$$ >&2
  rm -f /tmp/invariant-sync-tier1.$$
  fail_policy "I-2 still states Tier 1 capsule byte-stability as a core requirement"
else
  rm -f /tmp/invariant-sync-tier1.$$ 2>/dev/null || true
fi

# Tombstone literals: the retired semantic addon invariant IDs must remain
# resolvable as tombstones across the authority surfaces. The former
# transitional-state row-presence literals were dropped because the
# semantic-mcp shipped row no longer exists.
for literal in \
  'Addon-I-2' \
  'Addon-I-13'
do
  rg -F "$literal" "$agents" "$canonical" "$matrix" >/dev/null 2>&1 || fail_policy "required invariant migration literal missing: $literal"
done

[ -f "$repo_root/docs/SHIPPED_ARTIFACTS.md" ] || fail_policy "docs/SHIPPED_ARTIFACTS.md missing"
[ -x "$repo_root/scripts/ci/shipped-artifact-privacy-scan.sh" ] || fail_policy "shipped-artifact-privacy-scan.sh missing or not executable"
[ -x "$repo_root/scripts/ci/invariant-sync-check.sh" ] || {
  if [ "$strict" -eq 1 ]; then
    fail_policy "invariant-sync-check.sh is not executable"
  fi
}

if [ "$policy_failures" -gt 0 ]; then
  printf 'FAIL invariant sync check: findings=%s\n' "$policy_failures" >&2
  exit 1
fi

printf 'PASS invariant sync check: ids=%s strict=%s\n' "$(wc -l < "$tmp_dir/all.ids" | tr -d ' ')" "$strict"
