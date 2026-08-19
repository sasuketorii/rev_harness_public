#!/usr/bin/env bash
# Validate P5 shared-rule consolidation coverage.
#
# Normative-line extraction intentionally stays documented here because this
# script is the migration gate. Final regex set:
#   MUST|MUST NOT|must not|must|Never|Do not|do not|禁止|必須|fail-closed|厳守|絶対|原則禁止|のみ|required|Required|してはならない|すること|とする|しないこと
#
# Destination validation:
#   - moved/retained rows pass only when the mapped destination contains the
#     normalized old rule text, or when the row has an explicit `rewording:`
#     note carrying reviewer-checkable old/new text and the destination contains
#     both the mapped RS-ID and the normalized `new=` text.
#   - rewording rows emit a machine-readable JSONL audit table with old/new
#     quotes. The script does not decide semantic equivalence; that verdict is
#     deliberately human/reviewer-audited.
#   - retired rows must use `retired:` with a visible reason; they are counted
#     and listed instead of silently passing.
#
# Exit codes:
#   0 clean
#   1 policy violation
#   2 usage error
#   3 environment failure
set -euo pipefail

BASE_REF=""
# No default map: the P5 rule-migration map was an adopter-local .agent/active/
# work artifact (not shipped in this distribution), so --map is required.
MAP_FILE=""
NORMATIVE_RE='MUST|MUST NOT|must not|must|Never|Do not|do not|禁止|必須|fail-closed|厳守|絶対|原則禁止|のみ|required|Required|してはならない|すること|とする|しないこと'

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/ci/rules-consolidation-coverage.sh --base <ref> --map <path>

Exit codes:
  0  clean
  1  policy violation
  2  usage error
  3  environment failure
USAGE
}

die_usage() {
  printf 'rules-consolidation-coverage: %s\n' "$*" >&2
  usage
  exit 2
}

die_env() {
  printf 'rules-consolidation-coverage: %s\n' "$*" >&2
  exit 3
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --base)
      [[ "$#" -ge 2 ]] || die_usage "--base requires a value"
      BASE_REF="$2"
      shift 2
      ;;
    --map)
      [[ "$#" -ge 2 ]] || die_usage "--map requires a value"
      MAP_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done

[[ -n "$BASE_REF" ]] || die_usage "--base is required"
command -v git >/dev/null 2>&1 || die_env "git is required"
command -v python3 >/dev/null 2>&1 || die_env "python3 is required"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die_env "not a git repository"
cd "$REPO_ROOT"
git rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null || die_env "base ref does not resolve: $BASE_REF"
[[ -n "$MAP_FILE" ]] || die_usage "--map is required (no default migration map ships in this distribution)"
[[ -r "$MAP_FILE" ]] || die_env "migration map not readable: $MAP_FILE"

python3 - "$BASE_REF" "$MAP_FILE" "$NORMATIVE_RE" <<'PY'
import json
import os
import re
import subprocess
import sys
import unicodedata

BASE_REF = sys.argv[1]
MAP_FILE = sys.argv[2]
NORMATIVE_RE = sys.argv[3]
OLD_FILES = [
    "AGENTS.md",
    "CLAUDE.md",
    ".agent_rules/RULES.md",
    ".claude/CLAUDE-LOCAL.md",
    ".agent/PROJECT_CONTEXT.md",
]
RS_RE = re.compile(r"RS-(LANG|SAFE|WORK|ACC|DELEG|SEM|FE)-[0-9]{2}")


def fail_env(msg: str) -> None:
    print(f"rules-consolidation-coverage: {msg}", file=sys.stderr)
    raise SystemExit(3)


def run_git_show(path: str) -> str:
    try:
        return subprocess.check_output(
            ["git", "show", f"{BASE_REF}:{path}"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        return ""


def normalize(value: str) -> str:
    value = unicodedata.normalize("NFKC", value)
    value = re.sub(r"`+", " ", value)
    value = re.sub(r"[*_~#>\[\]()<>{}|:;,.!?/\\\"'、。・「」『』（）【】]+", " ", value)
    value = re.sub(r"\s+", " ", value)
    return value.strip().lower()


def clean_cell(value: str) -> str:
    value = value.strip()
    if value.startswith("`") and value.endswith("`") and len(value) >= 2:
        value = value[1:-1]
    return value.replace("\\|", "|").strip()


def split_markdown_row(line: str) -> list[str]:
    if not line.startswith("|"):
        return []
    cells = []
    current = []
    escaped = False
    for char in line[1:]:
        if escaped:
            current.append("\\" + char if char != "|" else char)
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == "|":
            cells.append(clean_cell("".join(current)))
            current = []
            continue
        current.append(char)
    return cells


def parse_new_text(validation: str) -> str:
    match = re.search(r"rewording:\s*old=(.*?);\s*new=(.+)$", validation)
    if not match:
        return ""
    return match.group(2).strip()


def parse_old_text(validation: str) -> str:
    match = re.search(r"rewording:\s*old=(.*?);\s*new=(.+)$", validation)
    if not match:
        return ""
    return match.group(1).strip()


def destination_text(destination: str) -> str:
    dest = destination.split("#", 1)[0].strip()
    dest = dest.split(":", 1)[0].strip()
    if not dest:
        return ""
    if not os.path.isfile(dest):
        return ""
    with open(dest, "r", encoding="utf-8") as handle:
        return handle.read()


def extract_old_normative() -> list[dict[str, str]]:
    pattern = re.compile(NORMATIVE_RE)
    rows = []
    for path in OLD_FILES:
        content = run_git_show(path)
        if not content:
            continue
        for number, line in enumerate(content.splitlines(), start=1):
            if pattern.search(line):
                text = re.sub(r"\s+", " ", line).strip()
                rows.append({"loc": f"{path}:{number}", "text": text})
    return rows


def parse_map() -> dict[str, dict[str, str]]:
    result = {}
    with open(MAP_FILE, "r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            line = line.rstrip("\n")
            if not line.startswith("|") or line.startswith("|---"):
                continue
            cells = split_markdown_row(line)
            if len(cells) < 7 or cells[0] == "old file:line":
                continue
            loc = clean_cell(cells[0])
            result[loc] = {
                "line": str(line_number),
                "old_preview": clean_cell(cells[1]),
                "disposition": clean_cell(cells[2]),
                "rs_id": clean_cell(cells[3]),
                "destination": clean_cell(cells[4]),
                "strength": clean_cell(cells[5]),
                "validation": clean_cell(cells[6]),
            }
    return result


def collect_rs_ids() -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for root, _, filenames in os.walk(".agent_rules"):
        for filename in filenames:
            if not filename.endswith(".md"):
                continue
            path = os.path.join(root, filename)
            with open(path, "r", encoding="utf-8") as handle:
                for number, line in enumerate(handle, start=1):
                    for match in RS_RE.finditer(line):
                        found.setdefault(match.group(0), []).append(f"{path}:{number}")
    return found


old_rows = extract_old_normative()
map_rows = parse_map()
rs_locations = collect_rs_ids()
failures = 0
mapped = 0
retired = []
rewording_audit = []

for row in old_rows:
    loc = row["loc"]
    old_text = row["text"]
    old_norm = normalize(old_text)
    map_row = map_rows.get(loc)
    if map_row is None:
        print(f"FAIL unmapped normative line: {loc}\t{old_text}", file=sys.stderr)
        failures += 1
        continue

    mapped += 1
    disposition = map_row["disposition"]
    validation = map_row["validation"]
    if disposition.startswith("retired") or validation.startswith("retired:"):
        reason = validation.removeprefix("retired:").strip()
        if len(reason) < 10:
            print(f"FAIL retired row missing reason: {loc}", file=sys.stderr)
            failures += 1
        retired.append({"loc": loc, "reason": reason or disposition})
        continue

    destination = map_row["destination"]
    dest_text = destination_text(destination)
    if not dest_text:
        print(f"FAIL destination missing/unreadable: {loc} -> {destination}", file=sys.stderr)
        failures += 1
        continue

    dest_norm = normalize(dest_text)
    rs_id = map_row["rs_id"]
    if validation.startswith("rewording:"):
        if not RS_RE.fullmatch(rs_id):
            print(f"FAIL rewording row missing valid RS-id: {loc}", file=sys.stderr)
            failures += 1
            continue
        if f"[{rs_id}]" not in dest_text:
            print(f"FAIL rewording destination lacks mapped RS-id: {loc} -> {rs_id}", file=sys.stderr)
            failures += 1
            continue
        old_quote = parse_old_text(validation)
        new_text = parse_new_text(validation)
        if not old_quote or not new_text:
            print(f"FAIL rewording note lacks old/new quotes: {loc}", file=sys.stderr)
            failures += 1
            continue
        if normalize(old_quote) != old_norm:
            print(f"FAIL rewording old quote does not match source line: {loc}", file=sys.stderr)
            failures += 1
            continue
        if normalize(new_text) not in dest_norm:
            print(f"FAIL rewording new text not in destination: {loc} -> {rs_id}", file=sys.stderr)
            failures += 1
            continue
        rewording_audit.append(
            {
                "event": "rules_consolidation_rewording_audit_row",
                "semantic_verdict": "human-review-required",
                "loc": loc,
                "map_line": int(map_row["line"]),
                "rs_id": rs_id,
                "destination": destination,
                "old_quote": old_quote,
                "new_quote": new_text,
            }
        )
        continue

    if old_norm and old_norm in dest_norm:
        continue

    if not validation.startswith("rewording:"):
        print(f"FAIL destination lacks old text and no rewording note: {loc} -> {destination}", file=sys.stderr)
        failures += 1
        continue

for rs_id, locations in sorted(rs_locations.items()):
    if len(locations) > 1:
        print(f"FAIL duplicate RS id: [{rs_id}] {' '.join(locations)}", file=sys.stderr)
        failures += 1

for map_row in map_rows.values():
    rs_id = map_row["rs_id"]
    if rs_id and rs_id != "n/a" and RS_RE.fullmatch(rs_id) and rs_id not in rs_locations:
        print(f"FAIL migration-map RS-id missing from modules/index: [{rs_id}]", file=sys.stderr)
        failures += 1

print(
    json.dumps(
        {
            "event": "rules_consolidation_rewording_audit_header",
            "semantic_verdict_policy": "human_reviewer_audited_not_machine_decided",
            "fields": ["loc", "map_line", "rs_id", "destination", "old_quote", "new_quote"],
            "row_count": len(rewording_audit),
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )
)
for audit_row in rewording_audit:
    print(json.dumps(audit_row, ensure_ascii=False, separators=(",", ":")))

summary = {
    "event": "rules_consolidation_coverage",
    "base": BASE_REF,
    "old_normative_lines": len(old_rows),
    "mapped_lines": mapped,
    "retired_lines": len(retired),
    "rewording_rows": len(rewording_audit),
    "retired": retired,
    "failures": failures,
    "regex": NORMATIVE_RE,
    "map": MAP_FILE,
}
print(json.dumps(summary, ensure_ascii=False, separators=(",", ":")))

raise SystemExit(1 if failures else 0)
PY
