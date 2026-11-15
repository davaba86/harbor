#!/usr/bin/env bash
# Harbor: platform detection + normalized pipeline status fetch.
# Sourced by poll.sh. Every function prints one JSON object on stdout,
# or prints nothing and returns non-zero on hard failure (caller decides
# whether that means "mark stale" or "mark auth error").

set -uo pipefail

# harbor::detect_platform <repo_path>
# Echoes "github", "gitlab", or "" (unknown) based on the origin remote.
harbor::detect_platform() {
  local repo_path="$1"
  local remote
  remote=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || { echo ""; return 1; }
  case "$remote" in
    *github.com*) echo "github" ;;
    *gitlab.com*) echo "gitlab" ;;
    *) echo "" ;;
  esac
}

# harbor::github_slug <repo_path>
# Echoes "owner/repo" parsed from the origin remote.
harbor::github_slug() {
  local repo_path="$1"
  local remote
  remote=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || return 1
  remote="${remote%.git}"
  remote="${remote#https://github.com/}"
  remote="${remote#git@github.com:}"
  echo "$remote"
}

# harbor::gitlab_path <repo_path>
# Echoes the URL-encoded group/project path parsed from the origin remote.
harbor::gitlab_path() {
  local repo_path="$1"
  local remote
  remote=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || return 1
  remote="${remote%.git}"
  remote="${remote#https://gitlab.com/}"
  remote="${remote#git@gitlab.com:}"
  echo "${remote//\//%2F}"
}

# harbor::fetch_github <repo_path> <display_name>
# Prints a normalized status JSON object, or returns 1 (stale) / 2 (auth error).
harbor::fetch_github() {
  local repo_path="$1" name="$2"
  local slug
  slug=$(harbor::github_slug "$repo_path") || return 1

  local default_branch
  default_branch=$(gh repo view --repo "$slug" --json defaultBranchRef -q .defaultBranchRef.name 2>/tmp/harbor-gh-err)
  if [ $? -ne 0 ]; then
    grep -qiE '401|403|authentic' /tmp/harbor-gh-err && return 2
    return 1
  fi

  local run_json
  run_json=$(gh run list --repo "$slug" --branch "$default_branch" --limit 5 \
    --json status,conclusion,headBranch,url,updatedAt,databaseId 2>/tmp/harbor-gh-err)
  if [ $? -ne 0 ]; then
    grep -qiE '401|403|authentic' /tmp/harbor-gh-err && return 2
    return 1
  fi

  local count
  count=$(echo "$run_json" | jq 'length')
  if [ "$count" -eq 0 ]; then
    return 1
  fi

  local status conclusion branch url updated_at state label
  status=$(echo "$run_json" | jq -r '.[0].status // empty')
  conclusion=$(echo "$run_json" | jq -r '.[0].conclusion // empty')
  branch=$(echo "$run_json" | jq -r '.[0].headBranch // empty')
  url=$(echo "$run_json" | jq -r '.[0].url // empty')
  updated_at=$(echo "$run_json" | jq -r '.[0].updatedAt // empty')

  case "$conclusion" in
    success) state="ok"; label="OK" ;;
    failure|cancelled) state="failed"; label="Failed" ;;
    *) state="running"; label="Running" ;;
  esac

  # Only worth the extra API round-trip while a run is actually in progress —
  # for every other state the step-level detail is moot.
  local current_step=""
  if [ "$state" = "running" ]; then
    local run_id
    run_id=$(echo "$run_json" | jq -r '.[0].databaseId // empty')
    if [ -n "$run_id" ]; then
      local jobs_json
      jobs_json=$(gh run view "$run_id" --repo "$slug" --json jobs 2>/dev/null)
      current_step=$(echo "$jobs_json" | jq -r '[.jobs[]?.steps[]? | select(.status == "in_progress")][0].name // empty')
    fi
  fi

  local history
  history=$(echo "$run_json" | jq '
    [.[] | {
      state: (if .conclusion == "success" then "ok"
              elif (.conclusion == "failure" or .conclusion == "cancelled") then "failed"
              else "running" end),
      url: .url,
      created_at: .updatedAt
    }] | reverse
  ')

  jq -n \
    --arg name "$name" --arg platform "github" --arg branch "$branch" \
    --arg state "$state" --arg label "$label" --arg url "$url" \
    --arg updated_at "$updated_at" --argjson history "$history" \
    --arg current_step "$current_step" \
    '{name: $name, platform: $platform, branch: $branch, state: $state, label: $label, url: $url, updated_at: $updated_at, history: $history, current_step: $current_step}'
}

# harbor::fetch_gitlab <repo_path> <display_name>
harbor::fetch_gitlab() {
  local repo_path="$1" name="$2"
  local encoded_path
  encoded_path=$(harbor::gitlab_path "$repo_path") || return 1

  local project_json
  project_json=$(glab api "projects/$encoded_path" 2>/tmp/harbor-glab-err)
  if [ $? -ne 0 ]; then
    grep -qiE '401|403' /tmp/harbor-glab-err && return 2
    return 1
  fi
  local default_branch
  default_branch=$(echo "$project_json" | jq -r '.default_branch // "main"')

  local pipeline_json
  pipeline_json=$(glab api "projects/$encoded_path/pipelines?ref=$default_branch&per_page=5" 2>/tmp/harbor-glab-err)
  if [ $? -ne 0 ]; then
    grep -qiE '401|403' /tmp/harbor-glab-err && return 2
    return 1
  fi

  local count
  count=$(echo "$pipeline_json" | jq 'length')
  if [ "$count" -eq 0 ]; then
    return 1
  fi

  local status url updated_at state label
  status=$(echo "$pipeline_json" | jq -r '.[0].status // empty')
  url=$(echo "$pipeline_json" | jq -r '.[0].web_url // empty')
  updated_at=$(echo "$pipeline_json" | jq -r '.[0].updated_at // empty')

  case "$status" in
    success) state="ok"; label="OK" ;;
    failed|canceled|skipped) state="failed"; label="Failed" ;;
    *) state="running"; label="Running" ;;
  esac

  # Only worth the extra API round-trip while a pipeline is actually running —
  # GitLab's jobs have a real "stage" concept (build/test/deploy), which maps
  # directly to "which step" is currently executing.
  local current_step=""
  if [ "$state" = "running" ]; then
    local pipeline_id
    pipeline_id=$(echo "$pipeline_json" | jq -r '.[0].id // empty')
    if [ -n "$pipeline_id" ]; then
      local jobs_json
      jobs_json=$(glab api "projects/$encoded_path/pipelines/$pipeline_id/jobs" 2>/dev/null)
      current_step=$(echo "$jobs_json" | jq -r '[.[] | select(.status == "running")][0].stage // empty')
    fi
  fi

  local history
  history=$(echo "$pipeline_json" | jq '
    [.[] | {
      state: (if .status == "success" then "ok"
              elif (.status == "failed" or .status == "canceled" or .status == "skipped") then "failed"
              else "running" end),
      url: .web_url,
      created_at: .updated_at
    }] | reverse
  ')

  jq -n \
    --arg name "$name" --arg platform "gitlab" --arg branch "$default_branch" \
    --arg state "$state" --arg label "$label" --arg url "$url" \
    --arg updated_at "$updated_at" --argjson history "$history" \
    --arg current_step "$current_step" \
    '{name: $name, platform: $platform, branch: $branch, state: $state, label: $label, url: $url, updated_at: $updated_at, history: $history, current_step: $current_step}'
}
