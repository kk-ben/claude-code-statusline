#!/bin/bash
# Fetch the current Hacker News top story and cache as an OSC 8 hyperlink
# line for the Claude Code statusLine.
#
# Cache file: $HOME/.claude/cache/latest-hn.txt
#
# See fetch-blog.sh for STATUSLINE_FEED_LANG=ja translation behavior.

set -uo pipefail

CACHE_DIR="$HOME/.claude/cache"
CACHE_FILE="$CACHE_DIR/latest-hn.txt"
STATE_FILE="$CACHE_DIR/latest-hn.state"
LOG_FILE="$CACHE_DIR/latest-hn.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$CACHE_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

# 1. Get current top story id
TOP_ID=$(curl -s --max-time 10 https://hacker-news.firebaseio.com/v0/topstories.json 2>/dev/null \
  | jq -r '.[0] // ""' 2>/dev/null)
if [ -z "$TOP_ID" ] || [ "$TOP_ID" = "null" ]; then
  log "no top id"; exit 0
fi

# 2. Get story detail
STORY=$(curl -s --max-time 10 "https://hacker-news.firebaseio.com/v0/item/${TOP_ID}.json")
TITLE_EN=$(printf '%s' "$STORY" | jq -r '.title // ""' 2>/dev/null)
URL=$(printf '%s' "$STORY" | jq -r '.url // ""' 2>/dev/null)
[ -z "$URL" ] || [ "$URL" = "null" ] && URL="https://news.ycombinator.com/item?id=${TOP_ID}"
if [ -z "$TITLE_EN" ]; then
  log "no title for $TOP_ID"; exit 0
fi

# 3. Skip if unchanged
PREV_ID=""
[ -f "$STATE_FILE" ] && PREV_ID=$(cat "$STATE_FILE" 2>/dev/null || true)
if [ "$TOP_ID" = "$PREV_ID" ] && [ -s "$CACHE_FILE" ]; then
  log "unchanged: $TOP_ID"; exit 0
fi

# 4. Optional translation via local `claude` CLI
TITLE_OUT=""
LANG_PREF="${STATUSLINE_FEED_LANG:-en}"
if [ "$LANG_PREF" = "ja" ]; then
  CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
  [ -z "$CLAUDE_BIN" ] && [ -x "/opt/homebrew/bin/claude" ] && CLAUDE_BIN="/opt/homebrew/bin/claude"
  if [ -n "$CLAUDE_BIN" ]; then
    PROMPT="You are an offline translator. Translate the English news/tech headline below to natural concise Japanese (20 to 30 Japanese characters). Output ONLY the Japanese translation on a single line. No quotes, no markdown, no romanization, no explanation. Do not search or browse.

Headline: ${TITLE_EN}"
    RAW_JA=$(perl -e 'alarm(60); exec @ARGV' -- \
      "$CLAUDE_BIN" -p \
      --model claude-haiku-4-5-20251001 \
      --disallowed-tools "Bash Read Write Edit WebFetch WebSearch Glob Grep TodoWrite Skill Agent NotebookEdit" \
      --output-format text \
      "$PROMPT" 2>/dev/null || true)
    if [ -n "$RAW_JA" ]; then
      TITLE_OUT=$(printf '%s' "$RAW_JA" | python3 "$SCRIPT_DIR/sanitize_title.py" 2>/dev/null || true)
    fi
  fi
fi

# 5. Fall back to English title
if [ -z "$TITLE_OUT" ]; then
  TITLE_OUT=$(printf '%s' "$TITLE_EN" | python3 "$SCRIPT_DIR/sanitize_title.py" 2>/dev/null || printf '%s' "$TITLE_EN")
fi

# 6. Write OSC 8 hyperlink atomically
OUT_TMP="${CACHE_FILE}.tmp"
printf '\033]8;;%s\033\\🔥 %s\033]8;;\033\\\n' "$URL" "$TITLE_OUT" > "$OUT_TMP"
mv "$OUT_TMP" "$CACHE_FILE"
printf '%s' "$TOP_ID" > "$STATE_FILE"

log "updated: $TOP_ID | $TITLE_OUT"
