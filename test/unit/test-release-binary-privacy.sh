#!/usr/bin/env bash
set -euo pipefail

export REVHARNESS_PARALLEL_QUIESCE=1

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# Semantic-free harness: scan targets the core binary (agent-core); there is
# no semantic-mcp crate.
scanner="$repo_root/scripts/ci/release-binary-privacy-scan.sh"
build_package="agent-core"
binary="$repo_root/harness-rust/target/release/$build_package"
metrics="$repo_root/.agent/metrics/release_binary_privacy_scan.jsonl"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/release-binary-privacy-test.XXXXXX")"
trap 'rm -rf "$tmp_dir" || true' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

line_count() {
  if [ -f "$metrics" ]; then
    wc -l < "$metrics" | tr -d ' '
  else
    printf '0'
  fi
}

last_line() {
  if [ -f "$metrics" ]; then
    tail -1 "$metrics"
  fi
}

assert_last_result() {
  expected="$1"
  row="$(last_line)"
  case "$row" in
    *'"event":"release_binary_privacy_scan"'*'"schema":"release-binary-privacy-scan/v1"'*'"result":"'"$expected"'"'*)
      return 0
      ;;
    *)
      printf 'last JSONL row: %s\n' "$row" >&2
      fail "expected scanner result=$expected"
      ;;
  esac
}

assert_new_row() {
  before="$1"
  after="$(line_count)"
  if [ "$after" -le "$before" ]; then
    fail "expected metrics JSONL to append a row"
  fi
}

if [ ! -x "$binary" ]; then
  build_log="$tmp_dir/cargo-build.log"
  if ! (cd "$repo_root/harness-rust" && cargo build --release -p "$build_package" >"$build_log" 2>&1); then
    cat "$build_log" >&2
    fail "cargo build failed"
  fi
fi

plain_build_log="$tmp_dir/plain-cargo-build.log"
plain_strings="$tmp_dir/plain-cargo-strings.txt"
if ! (cd "$repo_root/harness-rust" && cargo clean -p "$build_package" >/dev/null 2>&1 && env -u RUSTFLAGS cargo build --release -p "$build_package" >"$plain_build_log" 2>&1); then
  cat "$plain_build_log" >&2
  fail "plain cargo build failed"
fi
strings "$binary" >"$plain_strings"
grep -qF '.cargo/registry/src/' "$plain_strings" || fail "plain cargo build should retain cargo registry path pattern"
grep -qF '.rustup/toolchains/' "$plain_strings" || fail "plain cargo build should retain rustup toolchain path pattern"
! grep -qF '/Users/' "$plain_strings" || fail "plain cargo build should not contain literal /Users/ username paths"
! grep -qF '/home/' "$plain_strings" || fail "plain cargo build should not contain literal /home/ username paths"

before_ok="$(line_count)"
if ! bash "$scanner" >"$tmp_dir/positive.out" 2>"$tmp_dir/positive.err"; then
  cat "$tmp_dir/positive.out"
  cat "$tmp_dir/positive.err" >&2
  fail "positive scan should exit 0"
fi
assert_new_row "$before_ok"
assert_last_result "ok"

fake_binary="$tmp_dir/fake-release-binary"
fake_prefix="/Users"
{
  printf '#!/usr/bin/env sh\n'
  printf 'printf %%s\\\\n ok >/dev/null\n'
  printf '# privacy test fixture: %s/redacted/.cargo/registry/src/fake\n' "$fake_prefix"
} > "$fake_binary"
chmod +x "$fake_binary"

before_leak="$(line_count)"
set +e
bash "$scanner" --binary "$fake_binary" >"$tmp_dir/negative.out" 2>"$tmp_dir/negative.err"
negative_status="$?"
set -e

if [ "$negative_status" -eq 0 ]; then
  cat "$tmp_dir/negative.out"
  cat "$tmp_dir/negative.err" >&2
  fail "negative scan should exit 1"
fi
if [ "$negative_status" -ne 1 ]; then
  cat "$tmp_dir/negative.err" >&2
  fail "negative scan returned unexpected status $negative_status"
fi
grep -q 'leak detected' "$tmp_dir/negative.err" || fail "negative stderr did not mention leak"
grep -q '<REDACTED_HOST_PATH>' "$tmp_dir/negative.err" || fail "negative stderr was not redacted"
assert_new_row "$before_leak"
assert_last_result "leak"

printf 'PASS release-binary-privacy positive result=ok negative result=leak\n'
