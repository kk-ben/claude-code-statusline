#!/bin/bash
# Fetch the latest Anthropic / Claude blog post and cache it as an OSC 8
# hyperlink line for the Claude Code statusLine.
#
# Cache file: $HOME/.claude/cache/latest-blog.txt
# Safe to fail silently — the statusline falls back to an empty feed slot.
#
# ▶ Want a different blog? Replace the URL in step 1 below and adjust the
#   selector in feeds/extract_blog.py (or write your own tiny extractor).
#
# Optional translation (works for any language):
#   STATUSLINE_FEED_LANG=ja → Japanese    STATUSLINE_FEED_LANG=zh → Chinese
#   STATUSLINE_FEED_LANG=ko → Korean      STATUSLINE_FEED_LANG=fr → French
#   STATUSLINE_FEED_LANG=es → Spanish     STATUSLINE_FEED_LANG=de → German
#   STATUSLINE_FEED_LANG=pt → Portuguese  STATUSLINE_FEED_LANG=ru → Russian
#   STATUSLINE_FEED_LANG=ar → Arabic      (anything else → passed through to the
#                                         translator prompt as the target name)
#   STATUSLINE_FEED_LANG=en or unset (default) → no translation, English as-is.
#
# Translation requires the local `claude` CLI on $PATH. Falls back to English
# silently if the CLI is missing or returns an empty response.

set -uo pipefail

CACHE_DIR="$HOME/.claude/cache"
CACHE_FILE="$CACHE_DIR/latest-blog.txt"
STATE_FILE="$CACHE_DIR/latest-blog.state"
LOG_FILE="$CACHE_DIR/latest-blog.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$CACHE_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# 1. Fetch blog index
HTML_TMP=$(mktemp -t cc-statusline-blog.XXXXXX)
trap 'rm -f "$HTML_TMP"' EXIT

if ! curl -sL --max-time 15 -A "Mozilla/5.0 (claude-code-statusline)" \
     https://claude.com/blog -o "$HTML_TMP"; then
  log "curl failed"
  exit 0
fi

# 2. Extract latest slug + title
LATEST=$(python3 "$SCRIPT_DIR/extract_blog.py" "$HTML_TMP" 2>/dev/null || true)
if [ -z "${LATEST:-}" ]; then
  log "extract failed"
  exit 0
fi

SLUG="${LATEST%%|*}"
TITLE_EN="${LATEST#*|}"
URL="https://claude.com${SLUG}"

# 3. Skip translation if slug unchanged
PREV_SLUG=""
[ -f "$STATE_FILE" ] && PREV_SLUG=$(cat "$STATE_FILE" 2>/dev/null || true)
if [ "$SLUG" = "$PREV_SLUG" ] && [ -s "$CACHE_FILE" ]; then
  log "unchanged: $SLUG"
  exit 0
fi

# 4. Optional translation via local `claude` CLI (any target language)
TITLE_OUT=""
LANG_PREF="${STATUSLINE_FEED_LANG:-en}"
if [ "$LANG_PREF" != "en" ] && [ -n "$LANG_PREF" ]; then
  case "$LANG_PREF" in
    ja) LANG_NAME="Japanese" ;;
    zh) LANG_NAME="Simplified Chinese" ;;
    ko) LANG_NAME="Korean" ;;
    fr) LANG_NAME="French" ;;
    es) LANG_NAME="Spanish" ;;
    de) LANG_NAME="German" ;;
    pt) LANG_NAME="Portuguese" ;;
    ru) LANG_NAME="Russian" ;;
    ar) LANG_NAME="Arabic" ;;
    *)  LANG_NAME="$LANG_PREF" ;;  # passthrough — Claude usually understands ISO codes
  esac
  CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
  [ -z "$CLAUDE_BIN" ] && [ -x "/opt/homebrew/bin/claude" ] && CLAUDE_BIN="/opt/homebrew/bin/claude"
  if [ -n "$CLAUDE_BIN" ]; then
    PROMPT="You are an offline translator. Translate the English blog headline below to natural concise ${LANG_NAME}. Aim for roughly 30 to 40 display cells. Output ONLY the translation on a single line. No quotes, no markdown, no romanization, no explanation. Do not search or browse.

Headline: ${TITLE_EN}"
    RAW=$(perl -e 'alarm(60); exec @ARGV' -- \
      "$CLAUDE_BIN" -p \
      --model claude-haiku-4-5-20251001 \
      --disallowed-tools "Bash Read Write Edit WebFetch WebSearch Glob Grep TodoWrite Skill Agent NotebookEdit" \
      --output-format text \
      "$PROMPT" 2>/dev/null || true)
    if [ -n "$RAW" ]; then
      TITLE_OUT=$(printf '%s' "$RAW" | python3 "$SCRIPT_DIR/sanitize_title.py" 2>/dev/null || true)
    fi
    [ -z "$TITLE_OUT" ] && log "claude -p empty resp (lang=$LANG_PREF)"
  else
    log "claude CLI not found (lang=$LANG_PREF requested)"
  fi
fi

# 5. Fall back to English title
if [ -z "$TITLE_OUT" ]; then
  TITLE_OUT=$(printf '%s' "$TITLE_EN" | python3 "$SCRIPT_DIR/sanitize_title.py" 2>/dev/null || printf '%s' "$TITLE_EN")
fi

# 6. Write OSC 8 hyperlink atomically
OUT_TMP="${CACHE_FILE}.tmp"
printf '\033]8;;%s\033\\📝 %s\033]8;;\033\\\n' "$URL" "$TITLE_OUT" > "$OUT_TMP"
mv "$OUT_TMP" "$CACHE_FILE"
printf '%s' "$SLUG" > "$STATE_FILE"

log "updated: $SLUG | $TITLE_OUT"
