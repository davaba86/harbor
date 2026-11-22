#!/usr/bin/env bash
# Harbor local-repos report: for every repo in ~/.harbor/config.json,
# lists branches already merged into the default branch and worktrees git
# itself reports as prunable. Entirely local (no network, no gh/glab) —
# called by poll.sh every cycle and cached into status.json's local_repos
# key, same as repos/testflight, so the Local Repos tab reads instantly
# instead of recomputing on every open.
#
# Usage: local-repos.sh
# Output: one JSON array on stdout, one entry per configured repo
# (including repos with nothing to report — the caller decides what to
# show). A repo whose path is missing/not a git repo is skipped (logged to
# errors.log) rather than aborting the whole run, same as poll.sh.
set -uo pipefail
cd "$(dirname "$0")"

HARBOR_DIR="${HARBOR_DIR:-$HOME/.harbor}"
CONFIG="$HARBOR_DIR/config.json"
ERROR_LOG="$HARBOR_DIR/errors.log"

mkdir -p "$HARBOR_DIR"

if [ ! -f "$CONFIG" ]; then
  echo "$(date -u +%FT%TZ) missing config: $CONFIG" >> "$ERROR_LOG"
  echo "[]"
  exit 1
fi

# local_repos::default_branch <repo_path>
# Echoes the repo's default branch name (no "origin/" prefix), resolved
# entirely locally — no API call, unlike the GitHub/GitLab default-branch
# lookups in common.sh. Falls back to whichever of main/master exists as a
# remote-tracking branch if the HEAD symref isn't set (e.g. a clone made
# with --single-branch under an unusual name, or before the symref existed).
local_repos::default_branch() {
  local repo_path="$1"
  local ref
  ref=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$ref" ]; then
    echo "${ref#refs/remotes/origin/}"
    return 0
  fi
  for candidate in main master; do
    if git -C "$repo_path" show-ref --verify --quiet "refs/remotes/origin/$candidate"; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# local_repos::merged_branches <repo_path> <default_branch>
# Echoes one local branch name per line that's already merged into
# origin/<default_branch>, excluding the default branch itself.
local_repos::merged_branches() {
  local repo_path="$1" default_branch="$2"
  git -C "$repo_path" branch --format='%(refname:short)' --merged "origin/$default_branch" 2>/dev/null \
    | grep -v -x "$default_branch"
}

# local_repos::prunable_worktrees <repo_path>
# Echoes "<path>\t<reason>" one per line for every worktree `git worktree
# list --porcelain` itself flags as prunable.
local_repos::prunable_worktrees() {
  local repo_path="$1"
  git -C "$repo_path" worktree list --porcelain 2>/dev/null | awk '
    /^worktree / { path = substr($0, 10) }
    /^prunable / { print path "\t" substr($0, 10) }
  '
}

entries="[]"
repo_count=$(jq '.repos | length' "$CONFIG")

for i in $(seq 0 $((repo_count - 1))); do
  name=$(jq -r ".repos[$i].name" "$CONFIG")
  path=$(jq -r ".repos[$i].path" "$CONFIG")

  if [ ! -d "$path/.git" ]; then
    echo "$(date -u +%FT%TZ) [$name] path missing or not a git repo: $path" >> "$ERROR_LOG"
    continue
  fi

  default_branch=$(local_repos::default_branch "$path")
  if [ -z "$default_branch" ]; then
    echo "$(date -u +%FT%TZ) [$name] could not determine default branch" >> "$ERROR_LOG"
    continue
  fi

  merged_json=$(local_repos::merged_branches "$path" "$default_branch" | jq -R . | jq -s .)
  worktrees_json=$(local_repos::prunable_worktrees "$path" | jq -R 'split("\t") | {path: .[0], reason: .[1]}' | jq -s .)

  entry=$(jq -n --arg name "$name" --argjson merged "$merged_json" --argjson worktrees "$worktrees_json" \
    '{name: $name, mergedBranches: $merged, prunableWorktrees: $worktrees}')
  entries=$(echo "$entries" | jq --argjson e "$entry" '. + [$e]')
done

echo "$entries"
