#!/usr/bin/env bash
# Scripted assertions for bin/harbor-add.sh, using a scratch HARBOR_DIR and a
# throwaway git repo so this never touches real config or real repos.
set -uo pipefail
cd "$(dirname "$0")/.."

SCRATCH=$(mktemp -d)
export HARBOR_DIR="$SCRATCH"
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

cp config.example.json "$SCRATCH/config.json"

fake_repo="$SCRATCH/fake-repo"
mkdir -p "$fake_repo"
git -C "$fake_repo" init -q

# Case 1: add a brand-new repo.
bin/harbor-add.sh "fake-repo" "$fake_repo" > /dev/null
path=$(jq -r '.repos[] | select(.name == "fake-repo") | .path' "$SCRATCH/config.json")
assert_eq "adds new repo with resolved absolute path" "$fake_repo" "$path"

count=$(jq '.repos | length' "$SCRATCH/config.json")
assert_eq "existing repos are preserved, not replaced" "2" "$count"

# Case 2: re-adding the same name updates in place rather than duplicating.
bin/harbor-add.sh "fake-repo" "$fake_repo" > /dev/null
count=$(jq '[.repos[] | select(.name == "fake-repo")] | length' "$SCRATCH/config.json")
assert_eq "re-adding the same name does not duplicate" "1" "$count"

# Case 3: rejects a path that isn't a git repo.
mkdir -p "$SCRATCH/not-a-repo"
if bin/harbor-add.sh "bad" "$SCRATCH/not-a-repo" > /dev/null 2>&1; then
  echo "FAIL: should have rejected a non-git-repo path"
  fail=1
else
  echo "ok: rejects a path that is not a git repository"
fi

rm -rf "$SCRATCH"
exit $fail
