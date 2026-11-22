#!/usr/bin/env bash
# Harbor notifier: compares ~/.harbor/status.json against prev.json and
# fires exactly one macOS notification per repo/app that newly transitioned
# to "failed". Never notifies on success, recovery, running, stale, or
# auth_error (those are visual-only per the approved design).
set -uo pipefail

HARBOR_DIR="${HARBOR_DIR:-$HOME/.harbor}"
STATUS_FILE="$HARBOR_DIR/status.json"
PREV_FILE="$HARBOR_DIR/prev.json"

[ -f "$STATUS_FILE" ] || exit 0

prev="{}"
[ -f "$PREV_FILE" ] && prev=$(cat "$PREV_FILE")

names=$(jq -r '.repos[].name' "$STATUS_FILE")

while IFS= read -r name; do
  [ -z "$name" ] && continue
  new_state=$(jq -r --arg n "$name" '.repos[] | select(.name == $n) | .state' "$STATUS_FILE")
  old_state=$(echo "$prev" | jq -r --arg n "$name" '.repos[]? | select(.name == $n) | .state // "unknown"')

  if [ "$new_state" = "failed" ] && [ "$old_state" != "failed" ]; then
    branch=$(jq -r --arg n "$name" '.repos[] | select(.name == $n) | .branch' "$STATUS_FILE")
    osascript -e "display notification \"$name just failed on $branch\" with title \"Harbor\" subtitle \"Pipeline failed\""
  fi
done <<< "$names"

# notify::testflight_state <status.json path expression as already-selected object>
# Mirrors StatusModel.swift's TestFlightStatus.state exactly (fetch_error
# wins, then processingState, then betaReviewStatus) — kept in one filter
# so both the "new" and "old" lookups below apply the identical rule.
testflight_state_filter='
  if .fetch_error then "auth_error"
  elif .processing_state == "processing" then "running"
  elif .processing_state == "failed" or .processing_state == "invalid" then "failed"
  elif .beta_review_status == "rejected" then "failed"
  elif .beta_review_status == "waiting_for_review" or .beta_review_status == "in_review" then "running"
  else "ok" end
'

apple_names=$(jq -r '.testflight[]?.name' "$STATUS_FILE")

while IFS= read -r name; do
  [ -z "$name" ] && continue
  entry=$(jq -c --arg n "$name" '.testflight[] | select(.name == $n)' "$STATUS_FILE")
  new_state=$(echo "$entry" | jq -r "$testflight_state_filter")

  prev_entry=$(echo "$prev" | jq -c --arg n "$name" '.testflight[]? | select(.name == $n)')
  old_state="unknown"
  [ -n "$prev_entry" ] && old_state=$(echo "$prev_entry" | jq -r "$testflight_state_filter")

  if [ "$new_state" = "failed" ] && [ "$old_state" != "failed" ]; then
    build_version=$(echo "$entry" | jq -r '.build_version')
    osascript -e "display notification \"$name build $build_version just failed\" with title \"Harbor\" subtitle \"TestFlight\""
  fi
done <<< "$apple_names"

cp "$STATUS_FILE" "$PREV_FILE"
