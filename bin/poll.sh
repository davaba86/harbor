#!/usr/bin/env bash
# Harbor poller: fetches latest pipeline status for every repo in
# ~/.harbor/config.json and writes ~/.harbor/status.json atomically.
set -uo pipefail
cd "$(dirname "$0")"
source lib/common.sh

HARBOR_DIR="${HARBOR_DIR:-$HOME/.harbor}"
CONFIG="$HARBOR_DIR/config.json"
STATUS_FILE="$HARBOR_DIR/status.json"
ERROR_LOG="$HARBOR_DIR/errors.log"
TMP_FILE="$HARBOR_DIR/status.json.tmp"

mkdir -p "$HARBOR_DIR"

if [ ! -f "$CONFIG" ]; then
  echo "$(date -u +%FT%TZ) missing config: $CONFIG" >> "$ERROR_LOG"
  exit 1
fi

# Previous status, used to preserve last-known entries when a fetch fails.
prev_status="{}"
[ -f "$STATUS_FILE" ] && prev_status=$(cat "$STATUS_FILE")

entries="[]"
repo_count=$(jq '.repos | length' "$CONFIG")

for i in $(seq 0 $((repo_count - 1))); do
  name=$(jq -r ".repos[$i].name" "$CONFIG")
  path=$(jq -r ".repos[$i].path" "$CONFIG")

  if [ ! -d "$path/.git" ]; then
    echo "$(date -u +%FT%TZ) [$name] path missing or not a git repo: $path" >> "$ERROR_LOG"
    continue
  fi

  platform=$(harbor::detect_platform "$path")
  result=""
  fetch_status=0
  case "$platform" in
    github) result=$(harbor::fetch_github "$path" "$name"); fetch_status=$? ;;
    gitlab) result=$(harbor::fetch_gitlab "$path" "$name"); fetch_status=$? ;;
    *)
      echo "$(date -u +%FT%TZ) [$name] unknown platform for remote" >> "$ERROR_LOG"
      continue
      ;;
  esac

  now=$(date -u +%FT%TZ)

  if [ "$fetch_status" -eq 2 ]; then
    # Auth error: surface immediately, not stale.
    entry=$(jq -n --arg name "$name" --arg platform "$platform" \
      '{name: $name, platform: $platform, branch: "", state: "auth_error", label: "Auth", url: "", updated_at: ""}')
  elif [ "$fetch_status" -ne 0 ] || [ -z "$result" ]; then
    # Fetch failed: keep last-known entry, marked stale by its own updated_at age
    # (the xbar plugin computes staleness from fetched_at, not by mutating state here).
    echo "$(date -u +%FT%TZ) [$name] fetch failed, keeping last known state" >> "$ERROR_LOG"
    entry=$(echo "$prev_status" | jq --arg name "$name" '.repos[]? | select(.name == $name)')
    [ -z "$entry" ] && entry=$(jq -n --arg name "$name" --arg platform "$platform" \
      '{name: $name, platform: $platform, branch: "", state: "stale", label: "Stale", url: "", updated_at: ""}')
  else
    entry="$result"
  fi

  entry=$(echo "$entry" | jq --arg fetched_at "$now" '. + {fetched_at: $fetched_at}')
  entries=$(echo "$entries" | jq --argjson e "$entry" '. + [$e]')
done

jq -n --arg generated_at "$(date -u +%FT%TZ)" --argjson repos "$entries" \
  '{generated_at: $generated_at, repos: $repos}' > "$TMP_FILE"
mv "$TMP_FILE" "$STATUS_FILE"
