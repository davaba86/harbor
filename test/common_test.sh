#!/usr/bin/env bash
# Scripted assertions for bin/lib/common.sh. Run: bash test/common_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source bin/lib/common.sh

fail=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $desc (expected '$expected', got '$actual')"
    fail=1
  else
    echo "ok: $desc"
  fi
}

# Platform detection against this very repo's own remote — derives the
# expected slug independently from the raw remote URL rather than hardcoding
# an owner/repo, so this test passes the same way on a fork as on the original.
platform=$(harbor::detect_platform ".")
assert_eq "detects github platform for harbor repo" "github" "$platform"

remote=$(git remote get-url origin)
expected_slug=$(echo "$remote" | sed -E 's#.*github\.com[:/]##; s#\.git$##')
slug=$(harbor::github_slug ".")
assert_eq "parses github owner/repo" "$expected_slug" "$slug"

exit $fail
