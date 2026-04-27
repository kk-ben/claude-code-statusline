#!/bin/bash
# Fetch the GitHub "top starred repo created in the last 7 days" via the
# public search API (60/hour unauthenticated, plenty for hourly statusLine
# updates). Cached as an OSC 8 hyperlink line.
#
# Cache file: $HOME/.claude/cache/latest-trending.txt

set -uo pipefail

CACHE_DIR="$HOME/.claude/cache"
CACHE_FILE="$CACHE_DIR/latest-trending.txt"
STATE_FILE="$CACHE_DIR/latest-trending.state"
LOG_FILE="$CACHE_DIR/latest-trending.log"
mkdir -p "$CACHE_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

# 7 days ago in YYYY-MM-DD (BSD `date -v` on macOS, GNU `date -d` on Linux)
DATE_7D=$(date -v-7d '+%Y-%m-%d' 2>/dev/null || date -d '-7 days' '+%Y-%m-%d' 2>/dev/null || true)
if [ -z "$DATE_7D" ]; then
  log "date calc failed"; exit 0
fi

API_URL="https://api.github.com/search/repositories?q=created:%3E${DATE_7D}&sort=stars&order=desc&per_page=1"
RESP=$(curl -s --max-time 15 \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -A "claude-code-statusline" \
  "$API_URL")

FULL=$(printf '%s' "$RESP" | jq -r '.items[0].full_name // ""' 2>/dev/null)
URL=$(printf '%s' "$RESP"  | jq -r '.items[0].html_url // ""' 2>/dev/null)
STARS=$(printf '%s' "$RESP" | jq -r '.items[0].stargazers_count // 0' 2>/dev/null)

if [ -z "$FULL" ] || [ "$FULL" = "null" ] || [ -z "$URL" ] || [ "$URL" = "null" ]; then
  MSG=$(printf '%s' "$RESP" | jq -r '.message // ""' 2>/dev/null)
  log "empty resp (msg=${MSG:-none}): $(printf '%s' "$RESP" | head -c 160)"
  exit 0
fi

# Compact star count (e.g. 2934 → "2.9k")
if [ "$STARS" -ge 1000 ]; then
  STARS_STR=$(awk -v n="$STARS" 'BEGIN { printf "%.1fk", n/1000 }')
else
  STARS_STR="$STARS"
fi

# Skip if unchanged
PREV_FULL=""
[ -f "$STATE_FILE" ] && PREV_FULL=$(cat "$STATE_FILE" 2>/dev/null || true)
if [ "$FULL" = "$PREV_FULL" ] && [ -s "$CACHE_FILE" ]; then
  log "unchanged: $FULL"; exit 0
fi

OUT_TMP="${CACHE_FILE}.tmp"
printf '\033]8;;%s\033\\🐙 %s ★%s\033]8;;\033\\\n' "$URL" "$FULL" "$STARS_STR" > "$OUT_TMP"
mv "$OUT_TMP" "$CACHE_FILE"
printf '%s' "$FULL" > "$STATE_FILE"

log "updated: $FULL (★$STARS_STR)"
