#!/bin/bash
# claude-code-statusline installer
#
# What it does:
#   1. Copies statusline.sh to $INSTALL_DIR (default: $HOME/.claude/cc-statusline)
#   2. (--with-feeds) Copies feeds/ scripts and registers macOS LaunchAgents
#      that refresh the feed cache hourly
#   3. Patches $HOME/.claude/settings.json to point statusLine at the script
#      (only if --patch-settings is given; otherwise prints the snippet)
#
# Usage:
#   bash install.sh                      # core only, no feeds, no settings patch
#   bash install.sh --with-feeds         # also install feeds + LaunchAgents (macOS)
#   bash install.sh --patch-settings     # patch settings.json automatically
#   bash install.sh --uninstall          # unload agents, remove plists
#
# Override install dir:
#   INSTALL_DIR=/custom/path bash install.sh

set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.claude/cc-statusline}"
SETTINGS_FILE="$HOME/.claude/settings.json"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
LABEL_PREFIX="${LABEL_PREFIX:-com.${USER}.cc-statusline}"

WITH_FEEDS=0
PATCH_SETTINGS=0
UNINSTALL=0

for arg in "$@"; do
  case "$arg" in
    --with-feeds)     WITH_FEEDS=1 ;;
    --patch-settings) PATCH_SETTINGS=1 ;;
    --uninstall)      UNINSTALL=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *)
      echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Uninstall ----------
if [ "$UNINSTALL" = "1" ]; then
  for kind in blog hn trending; do
    plist="$LAUNCH_DIR/${LABEL_PREFIX}-${kind}.plist"
    if [ -f "$plist" ]; then
      launchctl unload "$plist" 2>/dev/null || true
      rm -f "$plist"
      echo "removed $plist"
    fi
  done
  echo "Done. Note: $INSTALL_DIR and settings.json were left untouched."
  exit 0
fi

# ---------- Core install ----------
mkdir -p "$INSTALL_DIR"
cp -f "$SCRIPT_DIR/statusline.sh" "$INSTALL_DIR/statusline.sh"
chmod +x "$INSTALL_DIR/statusline.sh"
echo "installed: $INSTALL_DIR/statusline.sh"

# ---------- Feeds install (optional) ----------
if [ "$WITH_FEEDS" = "1" ]; then
  mkdir -p "$INSTALL_DIR/feeds" "$HOME/.claude/cache"
  cp -f "$SCRIPT_DIR/feeds/"*.sh "$INSTALL_DIR/feeds/"
  cp -f "$SCRIPT_DIR/feeds/"*.py "$INSTALL_DIR/feeds/"
  chmod +x "$INSTALL_DIR/feeds/"*.sh
  echo "installed: $INSTALL_DIR/feeds/"

  # Only register LaunchAgents on macOS
  if [ "$(uname)" = "Darwin" ]; then
    mkdir -p "$LAUNCH_DIR"
    for kind in blog hn trending; do
      tmpl="$SCRIPT_DIR/launchagents/com.example.cc-statusline-${kind}.plist"
      out="$LAUNCH_DIR/${LABEL_PREFIX}-${kind}.plist"
      sed \
        -e "s|__HOME__|$HOME|g" \
        -e "s|__INSTALL__|$INSTALL_DIR/feeds|g" \
        -e "s|com\\.example\\.cc-statusline-${kind}|${LABEL_PREFIX}-${kind}|g" \
        "$tmpl" > "$out"
      launchctl unload "$out" 2>/dev/null || true
      launchctl load "$out"
      echo "loaded:    $out"
    done
  else
    echo "non-macOS detected — see README for crontab equivalent"
  fi
fi

# ---------- settings.json snippet ----------
SNIPPET=$(cat <<JSON
{
  "statusLine": {
    "type": "command",
    "command": "bash $INSTALL_DIR/statusline.sh"
  }
}
JSON
)

if [ "$PATCH_SETTINGS" = "1" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq not found — required for --patch-settings" >&2
    echo "Manual: add the following to $SETTINGS_FILE:"
    echo "$SNIPPET"
    exit 1
  fi
  if [ -f "$SETTINGS_FILE" ]; then
    cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
  else
    echo '{}' > "$SETTINGS_FILE"
  fi
  tmp=$(mktemp)
  jq --arg cmd "bash $INSTALL_DIR/statusline.sh" \
     '.statusLine = {"type":"command","command":$cmd}' \
     "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
  echo "patched:   $SETTINGS_FILE (backup written alongside)"
else
  echo ""
  echo "----- add this to $SETTINGS_FILE -----"
  echo "$SNIPPET"
  echo "--------------------------------------"
  echo "(or rerun with --patch-settings to apply automatically)"
fi
