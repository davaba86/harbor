#!/usr/bin/env bash
# Harbor: add (or update) a repo in the live watch-list config.
# Usage: harbor-add.sh <name> <repo-path>
#
# Works whether ~/.harbor/config.json is a plain file or a symlink into a
# dotfiles repo (see README's "Dotfiles-managed config" section) — jq
# writes through the symlink transparently, so this is safe to call from
# other automation (a repo-scaffolding script, a cron job, etc.) without
# caring which mode the user is in.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $(basename "$0") <name> <repo-path>" >&2
  exit 1
fi

name="$1"
repo_path="$2"
HARBOR_DIR="${HARBOR_DIR:-$HOME/.harbor}"
CONFIG="$HARBOR_DIR/config.json"

if [ ! -d "$repo_path/.git" ]; then
  echo "error: $repo_path is not a git repository" >&2
  exit 1
fi
repo_path=$(cd "$repo_path" && pwd)

if [ ! -f "$CONFIG" ]; then
  echo "error: $CONFIG does not exist — run install/install.sh first" >&2
  exit 1
fi

tmp=$(mktemp)
jq --arg name "$name" --arg path "$repo_path" '
  .repos |= (map(select(.name != $name)) + [{name: $name, path: $path}])
' "$CONFIG" > "$tmp"
mv "$tmp" "$CONFIG"

echo "Added/updated \"$name\" -> $repo_path in $CONFIG"
