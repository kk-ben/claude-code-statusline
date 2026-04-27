#!/bin/bash
# claude-code-statusline
# A 2-line rich statusLine for Claude Code (https://claude.com/claude-code).
#
# Line 1:  [model] 📁 dir | 🌿 git-branch | 🪄 last-skill
# Line 2:  🤖▓▓▓░░ 42% │ 📅▓░░░░ 18% │ +120 -33 │ ●3 ✓2/5 │ $0.42 ⏱12m05s
# Line 3+: optional feeds (Anthropic blog / HN top / GitHub trending)
#
# Designed to be invoked from settings.json:
#   "statusLine": { "type": "command", "command": "bash <path>/statusline.sh" }
#
# License: MIT

input=$(cat)

# --- ANSI colors ---
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
# BLUE and RESET hold *raw* ESC bytes because they're concatenated directly
# next to an OSC 8 hyperlink terminator (ESC \). Keeping them as literal
# "\033..." strings would merge with the trailing backslash and `%b` would
# collapse the pair, leaving the visible glitch "033[0m" after the link.
BLUE=$'\033[94m'
DIM='\033[2m'
RESET=$'\033[0m'

# --- Smooth 8th-block bar (10-char wide, 80 sub-units) ---
# Usage: make_bar <pct> [yellow_th] [red_th]
make_bar() {
  local pct="${1:-0}"
  local yellow_th="${2:-70}"
  local red_th="${3:-90}"
  local pct_int
  pct_int=$(printf "%.0f" "$pct" 2>/dev/null || echo 0)
  [ "$pct_int" -gt 100 ] && pct_int=100
  [ "$pct_int" -lt 0 ] && pct_int=0

  local color
  if [ "$pct_int" -ge "$red_th" ]; then
    color="$RED"
  elif [ "$pct_int" -ge "$yellow_th" ]; then
    color="$YELLOW"
  else
    color="$GREEN"
  fi

  # 10 chars * 8 sub-units = 80 total steps
  local units=$(( pct_int * 80 / 100 ))
  [ "$units" -gt 80 ] && units=80
  local full=$(( units / 8 ))
  local remainder=$(( units % 8 ))
  local partial_used=0
  [ "$remainder" -gt 0 ] && partial_used=1
  local empty=$(( 10 - full - partial_used ))

  # 1/8 .. 7/8 partials (left-aligned eighth blocks)
  local partials=(" " "▏" "▎" "▍" "▌" "▋" "▊" "▉")

  local bar=""
  local i=0
  while [ $i -lt "$full" ]; do bar="${bar}█"; i=$((i+1)); done
  if [ "$remainder" -gt 0 ]; then bar="${bar}${partials[$remainder]}"; fi
  i=0
  while [ $i -lt "$empty" ]; do bar="${bar}░"; i=$((i+1)); done

  printf "%b%s%b" "$color" "$bar" "$RESET"
}

# --- Extract fields ---
JQ="$(command -v jq || echo /usr/bin/jq)"
model=$(echo "$input" | "$JQ" -r '.model.display_name // ""')
current_dir=$(echo "$input" | "$JQ" -r '.workspace.current_dir // ""')
transcript_path=$(echo "$input" | "$JQ" -r '.transcript_path // ""')
session_id=$(echo "$input" | "$JQ" -r '.session_id // ""')
ctx_used=$(echo "$input" | "$JQ" -r '.context_window.used_percentage // "null"')
seven_day_pct=$(echo "$input" | "$JQ" -r '.rate_limits.seven_day.used_percentage // "null"')
total_cost=$(echo "$input" | "$JQ" -r '.cost.total_cost_usd // "null"')
total_duration_ms=$(echo "$input" | "$JQ" -r '.cost.total_duration_ms // "null"')
lines_added=$(echo "$input" | "$JQ" -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | "$JQ" -r '.cost.total_lines_removed // 0')

# --- dir-last-3 (e.g. "parent/parent/basename") ---
dir_last3=""
if [ -n "$current_dir" ]; then
  part3=$(basename "$current_dir")
  parent2=$(dirname "$current_dir")
  part2=$(basename "$parent2")
  parent1=$(dirname "$parent2")
  part1=$(basename "$parent1")
  dir_last3="$part3"
  if [ "$part2" != "/" ] && [ "$part2" != "." ] && [ -n "$part2" ]; then
    dir_last3="${part2}/${dir_last3}"
    if [ "$part1" != "/" ] && [ "$part1" != "." ] && [ -n "$part1" ]; then
      dir_last3="${part1}/${dir_last3}"
    fi
  fi
fi

# --- git branch + dirty count ---
git_branch="—"
git_dirty_str=""
if [ -n "$current_dir" ] && [ -d "$current_dir" ]; then
  git_branch=$(git -C "$current_dir" branch --show-current 2>/dev/null)
  [ -z "$git_branch" ] && git_branch="—"
  dirty_n=$(git -C "$current_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ -n "$dirty_n" ] && [ "$dirty_n" != "0" ]; then
    git_dirty_str=$(printf "%b●%s%b" "$YELLOW" "$dirty_n" "$RESET")
  else
    git_dirty_str=$(printf "%b✓%b" "$GREEN" "$RESET")
  fi
fi

# --- last skill from transcript ---
last_skill="—"
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  last_skill=$(tail -n 500 "$transcript_path" 2>/dev/null \
    | "$JQ" -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name=="Skill") | .input.skill // empty' 2>/dev/null \
    | tail -n 1)
  [ -z "$last_skill" ] && last_skill="—"
fi

# --- task progress (completed/total) from ~/.claude/tasks/<session_id>/ ---
task_str=""
if [ -n "$session_id" ]; then
  task_dir="$HOME/.claude/tasks/$session_id"
  if [ -d "$task_dir" ]; then
    total=0
    completed=0
    for f in "$task_dir"/*.json; do
      [ -f "$f" ] || continue
      total=$((total + 1))
      st=$("$JQ" -r '.status // ""' "$f" 2>/dev/null)
      [ "$st" = "completed" ] && completed=$((completed + 1))
    done
    if [ "$total" -gt 0 ]; then
      if [ "$completed" = "$total" ]; then
        task_str=$(printf "%b✓%s/%s%b" "$GREEN" "$completed" "$total" "$RESET")
      else
        task_str=$(printf "✓%s/%s" "$completed" "$total")
      fi
    fi
  fi
fi

# --- Detect terminal width ---
# Claude Code invokes the statusline child with its own narrow inner pty
# (≈67 cols, = the UI pane width). /dev/tty, tput cols, stty size, and the
# JSON input all reflect that inner pty, not the real terminal. Real width
# is found by walking up the process tree to Claude Code's own tty.
term_cols=0
pid=$$
for hop in 1 2 3 4 5 6 7 8; do
  parent_pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -z "$parent_pid" ] || [ "$parent_pid" = "0" ] || [ "$parent_pid" = "1" ]; then
    break
  fi
  pid="$parent_pid"
  ptty=$(ps -p "$pid" -o tty= 2>/dev/null | tr -d ' ')
  if [ -z "$ptty" ] || [ "$ptty" = "?" ] || [ "$ptty" = "??" ]; then
    continue
  fi
  ptty_path="/dev/$ptty"
  [ -e "$ptty_path" ] || continue
  sz=$(stty size < "$ptty_path" 2>/dev/null | awk '{print $2}')
  if [ -n "$sz" ] && [ "$sz" -gt 0 ] 2>/dev/null; then
    if [ "$sz" -gt "$term_cols" ] 2>/dev/null; then
      term_cols="$sz"
    fi
  fi
done

# Fallbacks
if ! [ "$term_cols" -gt 0 ] 2>/dev/null; then
  if [ -r /dev/tty ]; then
    term_cols=$(stty size </dev/tty 2>/dev/null | awk '{print $2}' || echo 0)
  fi
fi
if ! [ "$term_cols" -gt 0 ] 2>/dev/null; then
  term_cols=$(tput cols 2>/dev/null || echo 0)
fi
if ! [ "$term_cols" -gt 0 ] 2>/dev/null; then
  term_cols="${COLUMNS:-0}"
fi
if ! [ "$term_cols" -gt 0 ] 2>/dev/null; then
  term_cols=160
fi
# Manual override: env CLAUDE_STATUSLINE_COLS=<n> forces a width.
if [ -n "${CLAUDE_STATUSLINE_COLS:-}" ] && [ "$CLAUDE_STATUSLINE_COLS" -gt 0 ] 2>/dev/null; then
  term_cols="$CLAUDE_STATUSLINE_COLS"
fi

# --- LINE 1 (dynamic truncation by terminal width) ---
# Width bands drive how aggressively we shorten model / dir / skill.
#   term_cols ≥ 140 : full everything
#   90 ≤ cols < 140 : strip "(...)" suffix from model, collapse dir to "…/basename", cap skill at 24
#   cols < 90       : short model word only, basename-only dir, cap skill at 14

if [ "$term_cols" -lt 140 ] 2>/dev/null; then
  model_disp=$(printf '%s' "$model" | sed -E 's/ *\([^)]*\) *$//')
else
  model_disp="$model"
fi

if [ -z "$current_dir" ]; then
  dir_disp=""
elif [ "$term_cols" -lt 90 ] 2>/dev/null; then
  dir_disp=$(basename "$current_dir")
elif [ "$term_cols" -lt 140 ] 2>/dev/null; then
  dir_disp="…/$(basename "$current_dir")"
else
  dir_disp="$dir_last3"
fi

trim_ascii() {
  local s="$1" cap="$2" out="" i
  for ((i=0; i<${#s} && i<cap; i++)); do
    out="${out}${s:$i:1}"
  done
  if [ "${#s}" -gt "$cap" ]; then
    out="${out}…"
  fi
  printf '%s' "$out"
}
skill_disp="$last_skill"
if [ "$skill_disp" != "—" ] && [ -n "$skill_disp" ]; then
  if [ "$term_cols" -lt 90 ] 2>/dev/null; then
    skill_disp=$(trim_ascii "$last_skill" 14)
  elif [ "$term_cols" -lt 140 ] 2>/dev/null; then
    skill_disp=$(trim_ascii "$last_skill" 24)
  fi
fi

printf "[%s] 📁 %s | 🌿 %s | 🪄 %s\n" \
  "$model_disp" "$dir_disp" "$git_branch" "$skill_disp"

# --- LINE 2 components ---

# Context window usage (yellow 50, red 60 — earlier warning since context
# fills up faster than rate limits and needs earlier attention)
ctx_seg=""
if [ "$ctx_used" != "null" ]; then
  ctx_bar=$(make_bar "$ctx_used" 50 60)
  ctx_pct_int=$(printf "%.0f" "$ctx_used")
  ctx_seg=$(printf "🤖%b %s%%" "$ctx_bar" "$ctx_pct_int")
fi

# 7-day rate (yellow 70, red 90)
seven_seg=""
if [ "$seven_day_pct" != "null" ]; then
  seven_bar=$(make_bar "$seven_day_pct")
  seven_pct_int=$(printf "%.0f" "$seven_day_pct")
  seven_seg=$(printf "📅%b %s%%" "$seven_bar" "$seven_pct_int")
fi

# lines added / removed this session
lines_seg=""
if [ "$lines_added" != "0" ] || [ "$lines_removed" != "0" ]; then
  lines_seg=$(printf "%b+%s%b %b-%s%b" "$GREEN" "$lines_added" "$RESET" "$RED" "$lines_removed" "$RESET")
fi

# cost
if [ "$total_cost" = "null" ]; then
  cost_str="\$0.00"
else
  cost_str=$(printf "\$%.2f" "$total_cost")
fi

# duration (h/m when long, m/s otherwise)
if [ "$total_duration_ms" = "null" ]; then
  duration_str="0m"
else
  total_sec=$(printf "%.0f" "$(echo "$total_duration_ms / 1000" | bc -l 2>/dev/null || echo 0)")
  dur_min=$((total_sec / 60))
  if [ "$dur_min" -ge 60 ]; then
    dur_h=$((dur_min / 60))
    dur_m=$((dur_min % 60))
    duration_str="${dur_h}h${dur_m}m"
  else
    dur_sec=$((total_sec % 60))
    duration_str="${dur_min}m${dur_sec}s"
  fi
fi

# local state group (git dirty + tasks)
local_state=""
[ -n "$git_dirty_str" ] && local_state="$git_dirty_str"
if [ -n "$task_str" ]; then
  if [ -n "$local_state" ]; then
    local_state="${local_state} ${task_str}"
  else
    local_state="$task_str"
  fi
fi

# Metrics sections (always one line)
metrics=()
[ -n "$ctx_seg" ]      && metrics+=("$ctx_seg")
[ -n "$seven_seg" ]    && metrics+=("$seven_seg")
[ -n "$lines_seg" ]    && metrics+=("$lines_seg")
[ -n "$local_state" ]  && metrics+=("$local_state")
metrics+=("${cost_str} ⏱${duration_str}")

# Feeds: blog / HN top / GitHub trending (OSC 8 hyperlinks, bright blue).
# Cache files are populated by the optional fetch scripts in feeds/.
# Missing files are silently skipped.
feeds=()
for feed_file in \
    "$HOME/.claude/cache/latest-blog.txt" \
    "$HOME/.claude/cache/latest-hn.txt" \
    "$HOME/.claude/cache/latest-trending.txt"; do
  if [ -s "$feed_file" ]; then
    feeds+=("${BLUE}$(cat "$feed_file")${RESET}")
  fi
done

# Join an array of sections with " │ "
join_sections() {
  local out=""
  local sep=" │ "
  local first=1
  for seg in "$@"; do
    if [ "$first" = "1" ]; then
      out="$seg"; first=0
    else
      out="${out}${sep}${seg}"
    fi
  done
  printf '%b\n' "$out"
}

# --- Dynamic layout by width ---
# Thresholds tuned for default iTerm2 / macOS Terminal font metrics.
# Roughly: metrics alone ~70 cols, each feed ~35-45 cols.
#
# width ≥ 210 : 2 lines  (metrics + 3 feeds on the same row)
# width ≥ 140 : 3 lines  (metrics / all feeds together)
# width ≥ 90  : 4 lines  (metrics / blog / HN+trending)
# width <  90 : 5 lines  (metrics / blog / HN / trending)
if [ "$term_cols" -ge 210 ]; then
  join_sections "${metrics[@]}" "${feeds[@]}"
elif [ "$term_cols" -ge 140 ]; then
  join_sections "${metrics[@]}"
  [ "${#feeds[@]}" -gt 0 ] && join_sections "${feeds[@]}"
elif [ "$term_cols" -ge 90 ]; then
  join_sections "${metrics[@]}"
  [ "${#feeds[@]}" -gt 0 ] && printf '%b\n' "${feeds[0]}"
  if [ "${#feeds[@]}" -gt 1 ]; then
    join_sections "${feeds[@]:1}"
  fi
else
  join_sections "${metrics[@]}"
  for feed in "${feeds[@]}"; do
    printf '%b\n' "$feed"
  done
fi
