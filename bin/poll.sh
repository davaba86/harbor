#!/usr/bin/env bash
# Harbor poller: fetches latest pipeline status for repos in
# ~/.harbor/config.json and writes ~/.harbor/status.json atomically.
#
# Usage:
#   poll.sh            refresh every configured repo (the normal launchd cycle)
#   poll.sh <name>      refresh just that one repo in place — used by the
#                       app's per-card "Refresh" button, so clicking one
#                       repo doesn't wait on or re-fetch every other one.
set -uo pipefail
cd "$(dirname "$0")"
source lib/common.sh
source lib/apple.sh

HARBOR_DIR="${HARBOR_DIR:-$HOME/.harbor}"
CONFIG="$HARBOR_DIR/config.json"
STATUS_FILE="$HARBOR_DIR/status.json"
ERROR_LOG="$HARBOR_DIR/errors.log"
TMP_FILE="$HARBOR_DIR/status.json.tmp"
TARGET_REPO="${1:-}"

mkdir -p "$HARBOR_DIR"

if [ ! -f "$CONFIG" ]; then
  echo "$(date -u +%FT%TZ) missing config: $CONFIG" >> "$ERROR_LOG"
  exit 1
fi

# Previous status, used to preserve last-known entries when a fetch fails.
prev_status="{}"
[ -f "$STATUS_FILE" ] && prev_status=$(cat "$STATUS_FILE")

# poll::fetch_one <name> <path>
# Echoes the normalized status entry for one repo, applying the same
# fallback rules either mode uses: auth error surfaces immediately, any
# other fetch failure keeps the last-known entry (or falls back to "stale"
# if there's no prior entry to keep), unknown platform / missing path just
# logs and echoes nothing.
poll::fetch_one() {
  local name="$1" path="$2"

  if [ ! -d "$path/.git" ]; then
    echo "$(date -u +%FT%TZ) [$name] path missing or not a git repo: $path" >> "$ERROR_LOG"
    return 1
  fi

  local platform result fetch_status=0
  platform=$(harbor::detect_platform "$path")
  case "$platform" in
    github) result=$(harbor::fetch_github "$path" "$name"); fetch_status=$? ;;
    gitlab) result=$(harbor::fetch_gitlab "$path" "$name"); fetch_status=$? ;;
    *)
      echo "$(date -u +%FT%TZ) [$name] unknown platform for remote" >> "$ERROR_LOG"
      return 1
      ;;
  esac

  local now entry
  now=$(date -u +%FT%TZ)

  if [ "$fetch_status" -eq 2 ]; then
    entry=$(jq -n --arg name "$name" --arg platform "$platform" \
      '{name: $name, platform: $platform, branch: "", state: "auth_error", label: "Auth", url: "", updated_at: ""}')
  elif [ "$fetch_status" -ne 0 ] || [ -z "$result" ]; then
    echo "$(date -u +%FT%TZ) [$name] fetch failed, keeping last known state" >> "$ERROR_LOG"
    entry=$(echo "$prev_status" | jq --arg name "$name" '.repos[]? | select(.name == $name)')
    [ -z "$entry" ] && entry=$(jq -n --arg name "$name" --arg platform "$platform" \
      '{name: $name, platform: $platform, branch: "", state: "stale", label: "Stale", url: "", updated_at: ""}')
  else
    entry="$result"
  fi

  echo "$entry" | jq --arg fetched_at "$now" '. + {fetched_at: $fetched_at}'
}

if [ -n "$TARGET_REPO" ]; then
  path=$(jq -r --arg n "$TARGET_REPO" '.repos[] | select(.name == $n) | .path' "$CONFIG")
  if [ -z "$path" ]; then
    echo "$(date -u +%FT%TZ) [$TARGET_REPO] not found in config" >> "$ERROR_LOG"
    exit 1
  fi

  entry=$(poll::fetch_one "$TARGET_REPO" "$path")
  [ -z "$entry" ] && exit 0

  # In-place replace by name (map, not filter+append) so this never
  # reorders the other repos — a full refresh-all run would otherwise be
  # the only thing that ever changes card order, which would be confusing.
  jq --arg name "$TARGET_REPO" --argjson e "$entry" --arg generated_at "$(date -u +%FT%TZ)" '
    .generated_at = $generated_at |
    .repos |= map(if .name == $name then $e else . end)
  ' "$STATUS_FILE" > "$TMP_FILE"
  mv "$TMP_FILE" "$STATUS_FILE"
  exit 0
fi

entries="[]"
repo_count=$(jq '.repos | length' "$CONFIG")

for i in $(seq 0 $((repo_count - 1))); do
  name=$(jq -r ".repos[$i].name" "$CONFIG")
  path=$(jq -r ".repos[$i].path" "$CONFIG")
  entry=$(poll::fetch_one "$name" "$path")
  [ -z "$entry" ] && continue
  entries=$(echo "$entries" | jq --argjson e "$entry" '. + [$e]')
done

# poll::fetch_apple_one <name> <bundle_id> <key_id> <issuer_id>
# Same fallback contract as poll::fetch_one above: auth error and missing
# key surface immediately as their own state, any other failure keeps the
# last-known entry (or "stale" if there's no prior entry to keep).
poll::fetch_apple_one() {
  local name="$1" bundle_id="$2" key_id="$3" issuer_id="$4"
  local result fetch_status now entry

  result=$(harbor::fetch_apple "$name" "$bundle_id" "$key_id" "$issuer_id")
  fetch_status=$?
  now=$(date -u +%FT%TZ)

  if [ "$fetch_status" -eq 2 ]; then
    entry=$(jq -n --arg name "$name" --arg bundle_id "$bundle_id" \
      '{name: $name, bundle_id: $bundle_id, processing_state: "invalid", beta_review_status: null, build_version: "", build_number: "", url: "", updated_at: "", fetch_error: "auth"}')
  elif [ "$fetch_status" -eq 3 ]; then
    echo "$now [$name] no ASC key on disk for key_id $key_id" >> "$ERROR_LOG"
    entry=$(jq -n --arg name "$name" --arg bundle_id "$bundle_id" \
      '{name: $name, bundle_id: $bundle_id, processing_state: "invalid", beta_review_status: null, build_version: "", build_number: "", url: "", updated_at: "", fetch_error: "missing_key"}')
  elif [ "$fetch_status" -ne 0 ] || [ -z "$result" ]; then
    echo "$now [$name] apple fetch failed, keeping last known state" >> "$ERROR_LOG"
    entry=$(echo "$prev_status" | jq --arg name "$name" '.testflight[]? | select(.name == $name)')
    [ -z "$entry" ] && entry=$(jq -n --arg name "$name" --arg bundle_id "$bundle_id" \
      '{name: $name, bundle_id: $bundle_id, processing_state: "invalid", beta_review_status: null, build_version: "", build_number: "", url: "", updated_at: ""}')
  else
    entry="$result"
  fi

  echo "$entry" | jq --arg fetched_at "$now" '. + {fetched_at: $fetched_at}'
}

testflight_entries="[]"
apple_count=$(jq '.apple_apps // [] | length' "$CONFIG")

for i in $(seq 0 $((apple_count - 1))); do
  name=$(jq -r ".apple_apps[$i].name" "$CONFIG")
  bundle_id=$(jq -r ".apple_apps[$i].bundle_id" "$CONFIG")
  key_id=$(jq -r ".apple_apps[$i].key_id" "$CONFIG")
  issuer_id=$(jq -r ".apple_apps[$i].issuer_id" "$CONFIG")
  entry=$(poll::fetch_apple_one "$name" "$bundle_id" "$key_id" "$issuer_id")
  [ -z "$entry" ] && continue
  testflight_entries=$(echo "$testflight_entries" | jq --argjson e "$entry" '. + [$e]')
done

jq -n --arg generated_at "$(date -u +%FT%TZ)" --argjson repos "$entries" --argjson testflight "$testflight_entries" \
  '{generated_at: $generated_at, repos: $repos, testflight: $testflight}' > "$TMP_FILE"
mv "$TMP_FILE" "$STATUS_FILE"
