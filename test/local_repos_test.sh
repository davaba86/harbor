#!/usr/bin/env bash
# Scripted assertions for bin/local-repos.sh. Run: bash test/local_repos_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."

SCRATCH=$(mktemp -d)
export HARBOR_DIR="$SCRATCH"
fail=0

assert() {
  local desc="$1" ok="$2"
  if [ "$ok" = "1" ]; then
    echo "ok: $desc"
  else
    echo "FAIL: $desc"
    fail=1
  fi
}

git_quiet() { git -C "$1" -c user.email=test@example.com -c user.name=Test "${@:2}"; }

# --- Case: missing config is a safe no-op, not a crash ---
out=$(bin/local-repos.sh 2>/dev/null)
status=$?
assert "missing config exits nonzero" "$([ "$status" -ne 0 ] && echo 1 || echo 0)"
assert "missing config echoes an empty array" "$([ "$out" = "[]" ] && echo 1 || echo 0)"
assert "missing config is logged to errors.log" "$(grep -q 'missing config' "$SCRATCH/errors.log" 2>/dev/null && echo 1 || echo 0)"

# --- Build a real repo-a with a bare "origin" so origin/HEAD + origin/main are real ---
BARE="$SCRATCH/origin.git"
git init -q --bare -b main "$BARE"

REPO_A="$SCRATCH/repo-a"
git init -q -b main "$REPO_A"
git_quiet "$REPO_A" commit -q --allow-empty -m init
git_quiet "$REPO_A" remote add origin "$BARE"
git_quiet "$REPO_A" push -q origin main

# A branch that gets merged into main (and pushed, so origin/main reflects it).
git_quiet "$REPO_A" checkout -q -b merged-feature
git_quiet "$REPO_A" commit -q --allow-empty -m "merged work"
git_quiet "$REPO_A" checkout -q main
git_quiet "$REPO_A" merge -q --no-ff merged-feature -m "merge feature"
git_quiet "$REPO_A" push -q origin main

# A branch that's ahead of main and never merged.
git_quiet "$REPO_A" checkout -q -b wip-feature
git_quiet "$REPO_A" commit -q --allow-empty -m "wip work"
git_quiet "$REPO_A" checkout -q main

# A worktree that stays healthy, and one whose directory gets deleted out
# from under git, which is exactly what `git worktree list --porcelain`
# flags as "prunable".
git_quiet "$REPO_A" worktree add -q "$SCRATCH/wt-healthy" -b healthy-wt-branch > /dev/null
git_quiet "$REPO_A" worktree add -q "$SCRATCH/wt-stale" -b stale-wt-branch > /dev/null
rm -rf "$SCRATCH/wt-stale"

cat > "$SCRATCH/config.json" <<EOF
{"interval_seconds":60,"repos":[
  {"name":"repo-a","path":"$REPO_A"},
  {"name":"repo-b","path":"$SCRATCH/not-a-real-repo"}
]}
EOF

out=$(bin/local-repos.sh 2>/dev/null)

merged=$(echo "$out" | jq -r '.[] | select(.name=="repo-a") | .mergedBranches | join(",")')
assert "merged branch is reported" "$(echo ",$merged," | grep -q ',merged-feature,' && echo 1 || echo 0)"
assert "default branch itself is never reported as merged" "$(echo ",$merged," | grep -q ',main,' && echo 0 || echo 1)"
assert "unmerged branch is not reported" "$(echo ",$merged," | grep -q ',wip-feature,' && echo 0 || echo 1)"

prunable_paths=$(echo "$out" | jq -r '.[] | select(.name=="repo-a") | .prunableWorktrees[].path')
assert "stale worktree is reported as prunable" "$(echo "$prunable_paths" | grep -q 'wt-stale' && echo 1 || echo 0)"
assert "healthy worktree is not reported as prunable" "$(echo "$prunable_paths" | grep -q 'wt-healthy' && echo 0 || echo 1)"

repo_b_count=$(echo "$out" | jq '[.[] | select(.name=="repo-b")] | length')
assert "missing repo path is skipped, not included in output" "$([ "$repo_b_count" = "0" ] && echo 1 || echo 0)"
assert "missing repo path is logged to errors.log" "$(grep -q 'repo-b.*path missing' "$SCRATCH/errors.log" && echo 1 || echo 0)"

/bin/rm -rf "$SCRATCH"
exit $fail
