#!/usr/bin/env bash
# Harbor notifier: compares ~/.harbor/status.json against prev.json and
# fires exactly one macOS notification per repo that newly transitioned
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

cp "$STATUS_FILE" "$PREV_FILE"
