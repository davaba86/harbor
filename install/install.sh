#!/usr/bin/env bash
# Harbor installer: creates ~/.harbor, seeds config.json, builds and
# installs the native menu bar app, and loads both launchd jobs (poller
# + app). Re-run after changing interval_seconds in config.json.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_DIR="$(pwd)"
HARBOR_DIR="$HOME/.harbor"
PLIST_LABEL="com.harborapp.poller"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
XBAR_PLUGIN_DIR="$HOME/Library/Application Support/xbar/plugins"

mkdir -p "$HARBOR_DIR"

# Dotfiles-managed config (opt-in): set HARBOR_DOTFILES_CONFIG to a path
# inside your dotfiles repo (e.g. ~/dotfiles/harbor/config.json)
# and ~/.harbor/config.json becomes a symlink to it, so your watch list is
# versioned and backed up the same way as the rest of your dotfiles. Safe to
# re-run: never overwrites an existing dotfiles-repo config, and backs up
# (never silently discards) a pre-existing real config.json before linking.
if [ -n "${HARBOR_DOTFILES_CONFIG:-}" ]; then
  mkdir -p "$(dirname "$HARBOR_DOTFILES_CONFIG")"
  if [ ! -e "$HARBOR_DOTFILES_CONFIG" ]; then
    cp "$REPO_DIR/config.example.json" "$HARBOR_DOTFILES_CONFIG"
    echo "Seeded $HARBOR_DOTFILES_CONFIG from template."
  fi
  if [ -e "$HARBOR_DIR/config.json" ] && [ ! -L "$HARBOR_DIR/config.json" ]; then
    mv "$HARBOR_DIR/config.json" "$HARBOR_DIR/config.json.bak"
    echo "Backed up existing $HARBOR_DIR/config.json to config.json.bak before linking."
  fi
  ln -sf "$HARBOR_DOTFILES_CONFIG" "$HARBOR_DIR/config.json"
  echo "Linked $HARBOR_DIR/config.json -> $HARBOR_DOTFILES_CONFIG"
elif [ ! -f "$HARBOR_DIR/config.json" ]; then
  cp "$REPO_DIR/config.example.json" "$HARBOR_DIR/config.json"
  echo "Created $HARBOR_DIR/config.json from template — edit it to add repos."
fi

interval=$(jq -r '.interval_seconds' "$HARBOR_DIR/config.json")

sed \
  -e "s#__POLL_SCRIPT__#$REPO_DIR/bin/poll.sh#g" \
  -e "s#__NOTIFY_SCRIPT__#$REPO_DIR/bin/notify.sh#g" \
  -e "s#__INTERVAL_SECONDS__#$interval#g" \
  -e "s#__HARBOR_DIR__#$HARBOR_DIR#g" \
  "$REPO_DIR/install/com.harborapp.poller.plist.template" > "$PLIST_PATH"

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo "Loaded launchd job $PLIST_LABEL, polling every ${interval}s."
echo "Logs: $HARBOR_DIR/launchd.log"

# --- Native app (v0.2): build and install, replacing the xbar plugin ---
echo "Building native Harbor app..."
(cd "$REPO_DIR/swift" && swift build -c release)
HARBOR_BINARY="$REPO_DIR/swift/.build/release/Harbor"

if [ -f "$XBAR_PLUGIN_DIR/harbor.10s.sh" ]; then
  rm -f "$XBAR_PLUGIN_DIR/harbor.10s.sh"
  echo "Removed xbar plugin (replaced by the native app) to avoid two menu bar icons."
fi

APP_PLIST_LABEL="com.harborapp.menubar"
APP_PLIST_PATH="$HOME/Library/LaunchAgents/$APP_PLIST_LABEL.plist"
sed \
  -e "s#__HARBOR_BINARY__#$HARBOR_BINARY#g" \
  -e "s#__HARBOR_DIR__#$HARBOR_DIR#g" \
  -e "s#__REPO_DIR__#$REPO_DIR#g" \
  "$REPO_DIR/install/com.harborapp.menubar.plist.template" > "$APP_PLIST_PATH"

launchctl unload "$APP_PLIST_PATH" 2>/dev/null || true
launchctl load "$APP_PLIST_PATH"
echo "Loaded native Harbor app via launchd ($APP_PLIST_LABEL)."
