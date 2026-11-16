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
  run_json=$(gh run list --repo "$slug" --branch "$default_branch" --limit 3 \
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

  # Fetch EACH returned run's own job list, not just the latest — so the
  # UI's run picker can show real step-by-step detail for whichever run is
  # selected, not only the one currently in progress. 3 extra API calls per
  # repo per poll instead of up to 1; still trivial against GitHub's 5000/hr
  # limit even across a large watch list. GitHub's model is workflow -> jobs
  # -> steps with no stage-grouping comparable to GitLab's, so each job is
  # its own row (no aggregation needed, each job already carries one status).
  local current_step="" entries="[]"
  for i in $(seq 0 $((count - 1))); do
    local run_id entry_conclusion entry_url entry_updated entry_state stages_i jobs_json entry
    run_id=$(echo "$run_json" | jq -r ".[$i].databaseId // empty")
    entry_conclusion=$(echo "$run_json" | jq -r ".[$i].conclusion // empty")
    entry_url=$(echo "$run_json" | jq -r ".[$i].url // empty")
    entry_updated=$(echo "$run_json" | jq -r ".[$i].updatedAt // empty")

    case "$entry_conclusion" in
      success) entry_state="ok" ;;
      failure|cancelled) entry_state="failed" ;;
      *) entry_state="running" ;;
    esac

    stages_i="[]"
    if [ -n "$run_id" ]; then
      jobs_json=$(gh run view "$run_id" --repo "$slug" --json jobs 2>/dev/null)
      stages_i=$(echo "$jobs_json" | jq '
        [.jobs[]? | {
          name: .name,
          status: (
            if .conclusion == "success" then "ok"
            elif (.conclusion == "failure" or .conclusion == "cancelled") then "failed"
            elif .status == "in_progress" then "running"
            else "pending" end
          )
        }]
      ')
      if [ "$i" -eq 0 ]; then
        current_step=$(echo "$jobs_json" | jq -r '[.jobs[]?.steps[]? | select(.status == "in_progress")][0].name // empty')
      fi
    fi

    entry=$(jq -n --arg state "$entry_state" --arg url "$entry_url" --arg created_at "$entry_updated" --argjson stages "$stages_i" --arg run_id "$run_id" \
      '{state: $state, url: $url, created_at: $created_at, stages: $stages, run_id: $run_id}')
    entries=$(echo "$entries" | jq --argjson e "$entry" '. + [$e]')
  done

  local history
  history=$(echo "$entries" | jq 'reverse')

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
  pipeline_json=$(glab api "projects/$encoded_path/pipelines?ref=$default_branch&per_page=3" 2>/tmp/harbor-glab-err)
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

  # Fetch EACH returned pipeline's own job list, not just the latest — so
  # the UI's run picker can show real stage-by-stage detail for whichever
  # run is selected. GitLab's jobs have a real "stage" concept
  # (validate/test/build/...), so each entry's stages groups jobs by stage
  # and aggregates each stage's worst status, matching the column breakdown
  # GitLab's own pipeline UI shows. Stage order is preserved by first
  # appearance in the API response (pipeline-definition order), not sorted.
  local current_step="" entries="[]"
  for i in $(seq 0 $((count - 1))); do
    local pipeline_id entry_status entry_url entry_updated entry_state stages_i jobs_json entry
    pipeline_id=$(echo "$pipeline_json" | jq -r ".[$i].id // empty")
    entry_status=$(echo "$pipeline_json" | jq -r ".[$i].status // empty")
    entry_url=$(echo "$pipeline_json" | jq -r ".[$i].web_url // empty")
    entry_updated=$(echo "$pipeline_json" | jq -r ".[$i].updated_at // empty")

    case "$entry_status" in
      success) entry_state="ok" ;;
      failed|canceled|skipped) entry_state="failed" ;;
      *) entry_state="running" ;;
    esac

    stages_i="[]"
    if [ -n "$pipeline_id" ]; then
      jobs_json=$(glab api "projects/$encoded_path/pipelines/$pipeline_id/jobs" 2>/dev/null)
      # Keep each stage's individual jobs nested underneath it (not just the
      # stage's aggregate status) — matches GitLab's own pipeline UI, which
      # shows every job inside each stage column, not just a pass/fail per
      # stage. No extra API cost: same jobs_json already fetched above.
      #
      # Stage order: GitLab's own pipelines/:id/jobs endpoint returns jobs
      # by id DESCENDING (newest-looking first), not stage-execution order —
      # confirmed against real data where a later stage's job had a higher
      # id than an earlier stage's and so wrongly sorted first under a
      # first-appearance scheme. Job id is assigned at pipeline-creation
      # time following .gitlab-ci.yml's declared stage order, so sorting
      # each stage by its MINIMUM job id (ascending) reconstructs the real
      # validate -> test -> build -> ... order regardless of API order.
      stages_i=$(echo "$jobs_json" | jq '
        [.[] | {stage: .stage, status: .status, name: .name, id: .id}] as $jobs
        | ($jobs | group_by(.stage) | map({stage: .[0].stage, min_id: (map(.id) | min)}) | sort_by(.min_id) | map(.stage)) as $ordered
        | [$ordered[] as $s | ($jobs | map(select(.stage == $s)) | sort_by(.id)) as $sj | {
            name: $s,
            status: (
              if ($sj | any(.status == "failed" or .status == "canceled")) then "failed"
              elif ($sj | any(.status == "running")) then "running"
              elif ($sj | all(.status == "success" or .status == "skipped")) then "ok"
              else "pending" end
            ),
            jobs: [$sj[] | {
              name: .name,
              status: (
                if .status == "success" then "ok"
                elif (.status == "failed" or .status == "canceled") then "failed"
                elif .status == "running" then "running"
                else "pending" end
              )
            }]
          }]
      ')
      if [ "$i" -eq 0 ]; then
        current_step=$(echo "$jobs_json" | jq -r '[.[] | select(.status == "running")][0].stage // empty')
      fi
    fi

    entry=$(jq -n --arg state "$entry_state" --arg url "$entry_url" --arg created_at "$entry_updated" --argjson stages "$stages_i" --arg run_id "$pipeline_id" \
      '{state: $state, url: $url, created_at: $created_at, stages: $stages, run_id: $run_id}')
    entries=$(echo "$entries" | jq --argjson e "$entry" '. + [$e]')
  done

  local history
  history=$(echo "$entries" | jq 'reverse')

  jq -n \
    --arg name "$name" --arg platform "gitlab" --arg branch "$default_branch" \
    --arg state "$state" --arg label "$label" --arg url "$url" \
    --arg updated_at "$updated_at" --argjson history "$history" \
    --arg current_step "$current_step" \
    '{name: $name, platform: $platform, branch: $branch, state: $state, label: $label, url: $url, updated_at: $updated_at, history: $history, current_step: $current_step}'
}
