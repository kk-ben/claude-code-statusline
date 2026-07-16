#!/bin/bash
# claude-code-statusline
# A 2-line rich statusLine for Claude Code (https://claude.com/claude-code).
#
# Line 1: [model] 📁 dir | 🌿 git-branch | 🪄 last-skill
# Line 2: 🤖██░░░ 42% │ ⏳█▍░░░ 30% │ 📅▊░░░░ 18% │ 📖███▋░ 75% │ +120 -33 │ ✓ ✓2/5 │ $0.42 ⏱12m05s
# Line 3: (optional) per-model token usage — F n191.0k/c4.6M │ O n0/c0 │ S n1.0M/c51.6M │ H n0/c0  │  M99.0%/S0.9%
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
DIM='\033[2m'
RESET=$'\033[0m'

# --- Smooth 8th-block bar (5-char wide, 40 sub-units) ---
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

  # 5 chars * 8 sub-units = 40 total steps
  local units=$(( pct_int * 40 / 100 ))
  [ "$units" -gt 40 ] && units=40
  local full=$(( units / 8 ))
  local remainder=$(( units % 8 ))
  local partial_used=0
  [ "$remainder" -gt 0 ] && partial_used=1
  local empty=$(( 5 - full - partial_used ))

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

# --- Format a token count as an integer, "N.Nk", or "N.NM" (integer math only) ---
fmt_tok() {
  local n="${1:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -ge 1000000 ]; then
    printf "%d.%dM" $(( n / 1000000 )) $(( (n * 10 / 1000000) % 10 ))
  elif [ "$n" -ge 1000 ]; then
    printf "%d.%dk" $(( n / 1000 )) $(( (n * 10 / 1000) % 10 ))
  else
    printf "%d" "$n"
  fi
}

# --- Extract fields ---
JQ="$(command -v jq || echo /usr/bin/jq)"
model=$(echo "$input" | "$JQ" -r '.model.display_name // ""')
current_dir=$(echo "$input" | "$JQ" -r '.workspace.current_dir // ""')
git_worktree_raw=$(echo "$input" | "$JQ" -r '.workspace.git_worktree // empty')
transcript_path=$(echo "$input" | "$JQ" -r '.transcript_path // ""')
session_id=$(echo "$input" | "$JQ" -r '.session_id // ""')
ctx_used=$(echo "$input" | "$JQ" -r '.context_window.used_percentage // "null"')
seven_day_pct=$(echo "$input" | "$JQ" -r '.rate_limits.seven_day.used_percentage // "null"')
five_hour_pct=$(echo "$input" | "$JQ" -r '.rate_limits.five_hour.used_percentage // "null"')
total_duration_ms=$(echo "$input" | "$JQ" -r '.cost.total_duration_ms // "null"')
lines_added=$(echo "$input" | "$JQ" -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | "$JQ" -r '.cost.total_lines_removed // 0')

# --- Fable weekly usage % (cached, refreshed async, never blocks statusline) ---
fable_cache_dir="$HOME/.claude/cache"
fable_cache_file="$fable_cache_dir/fable-weekly.txt"
fable_lock_dir="$fable_cache_dir/fable-weekly.lock"
fable_cache_ttl=300

fable_weekly_pct=""
if [ -f "$fable_cache_file" ]; then
  cached_val=$(cat "$fable_cache_file" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$cached_val" ] && [ "$cached_val" -eq "$cached_val" ] 2>/dev/null; then
    fable_weekly_pct="$cached_val"
  fi
fi

fable_cache_age=999999
if [ -f "$fable_cache_file" ]; then
  fable_mtime=$(stat -f %m "$fable_cache_file" 2>/dev/null || stat -c %Y "$fable_cache_file" 2>/dev/null)
  if [ -n "$fable_mtime" ]; then
    fable_now=$(date +%s)
    fable_cache_age=$(( fable_now - fable_mtime ))
  fi
fi

if [ "$fable_cache_age" -ge "$fable_cache_ttl" ] 2>/dev/null; then
  # Clear a stale lock (fetcher killed mid-flight) so refresh can't wedge forever
  if [ -d "$fable_lock_dir" ]; then
    lock_mtime=$(stat -f %m "$fable_lock_dir" 2>/dev/null || stat -c %Y "$fable_lock_dir" 2>/dev/null)
    if [ -n "$lock_mtime" ] && [ $(( $(date +%s) - lock_mtime )) -gt 60 ]; then
      rmdir "$fable_lock_dir" 2>/dev/null
    fi
  fi
  (
    mkdir "$fable_lock_dir" 2>/dev/null || exit 0
    trap 'rmdir "$fable_lock_dir" 2>/dev/null' EXIT
    mkdir -p "$fable_cache_dir" 2>/dev/null
    creds_file="$HOME/.claude/.credentials.json"
    token=""
    if [ -f "$creds_file" ]; then
      token=$("$JQ" -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
    fi
    # GUI installs of Claude Code on macOS store OAuth in the login Keychain
    # instead of .credentials.json — same JSON payload, different location
    if [ -z "$token" ] && [ "$(uname)" = "Darwin" ]; then
      token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
        | "$JQ" -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    fi
    [ -n "$token" ] || exit 0
    resp=$(curl -s --max-time 5 \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -H "anthropic-beta: oauth-2025-04-20" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    [ -n "$resp" ] || exit 0
    pct=$(echo "$resp" | "$JQ" -r '.limits[]? | select(.kind=="weekly_scoped" and .scope.model.display_name=="Fable") | .percent' 2>/dev/null | head -n 1)
    [ -n "$pct" ] || exit 0
    case "$pct" in
      ''|*[!0-9]*) exit 0 ;;
    esac
    tmp_file="${fable_cache_file}.tmp.$$"
    printf '%s\n' "$pct" > "$tmp_file" 2>/dev/null
    mv -f "$tmp_file" "$fable_cache_file" 2>/dev/null
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

# --- Fable-only session cost (cached per-session, refreshed async) ---
# cost.total_cost_usd in stdin is Claude Code's dollar-equivalent for the WHOLE
# session across every model used (main loop + subagents). Subagents typically
# run on Sonnet, which is subscription-included and never actually billed extra;
# only Fable turns can incur real overage charges. So instead of showing that
# blended total, this recomputes cost from the local transcript filtered to
# Fable-model turns only, using official per-token pricing (verified 2026-07-16,
# see https://platform.claude.com/docs/en/about-claude/pricing — update the
# constants below if Anthropic changes Fable 5 pricing):
#   input $10/MTok, 5m-cache-write $12.50/MTok, 1h-cache-write $20/MTok,
#   cache-read(hit) $1/MTok, output $50/MTok
#
# Each transcript turn can appear multiple times as identical duplicate lines
# (verified: same message.id, same usage numbers, up to 3x) because Claude Code
# re-emits the full message as content blocks stream in — so turns are deduped
# by message.id before summing, or the cost would be inflated 2-3x.
fable_cost_str=""
if [ -n "$session_id" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  fcost_cache_dir="$HOME/.claude/cache"
  fcost_cache_file="$fcost_cache_dir/fable-cost-${session_id}.txt"
  fcost_lock_dir="$fcost_cache_dir/fable-cost-${session_id}.lock"
  fcost_ttl=15

  if [ -f "$fcost_cache_file" ]; then
    cached_cost=$(cat "$fcost_cache_file" 2>/dev/null | tr -d '[:space:]')
    case "$cached_cost" in
      ''|*[!0-9.]*) : ;;
      *) fable_cost_str=$(printf '$%.2f' "$cached_cost" 2>/dev/null) ;;
    esac
  fi

  fcost_age=999999
  if [ -f "$fcost_cache_file" ]; then
    fcost_mtime=$(stat -f %m "$fcost_cache_file" 2>/dev/null || stat -c %Y "$fcost_cache_file" 2>/dev/null)
    if [ -n "$fcost_mtime" ]; then
      fcost_age=$(( $(date +%s) - fcost_mtime ))
    fi
  fi

  if [ "$fcost_age" -ge "$fcost_ttl" ] 2>/dev/null; then
    if [ -d "$fcost_lock_dir" ]; then
      fcost_lock_mtime=$(stat -f %m "$fcost_lock_dir" 2>/dev/null || stat -c %Y "$fcost_lock_dir" 2>/dev/null)
      if [ -n "$fcost_lock_mtime" ] && [ $(( $(date +%s) - fcost_lock_mtime )) -gt 30 ]; then
        rmdir "$fcost_lock_dir" 2>/dev/null
      fi
    fi
    (
      mkdir "$fcost_lock_dir" 2>/dev/null || exit 0
      trap 'rmdir "$fcost_lock_dir" 2>/dev/null' EXIT
      mkdir -p "$fcost_cache_dir" 2>/dev/null
      cost=$("$JQ" -n '
        [inputs | select(.type=="assistant")] as $all
        | ($all | unique_by(.message.id)) as $dedup
        | ($dedup | map(select((.message.model // "") | startswith("claude-fable-5")) | .message.usage)) as $u
        | ($u | map(.input_tokens // 0) | add // 0) as $in
        | ($u | map(.output_tokens // 0) | add // 0) as $out
        | ($u | map(.cache_read_input_tokens // 0) | add // 0) as $cread
        | ($u | map(.cache_creation.ephemeral_5m_input_tokens // 0) | add // 0) as $c5m
        | ($u | map(.cache_creation.ephemeral_1h_input_tokens // 0) | add // 0) as $c1h
        | (($in*10 + $c5m*12.5 + $c1h*20 + $cread*1 + $out*50) / 1000000)
      ' "$transcript_path" 2>/dev/null)
      case "$cost" in
        ''|*[!0-9.]*) exit 0 ;;
      esac
      tmp_file="${fcost_cache_file}.tmp.$$"
      printf '%s\n' "$cost" > "$tmp_file" 2>/dev/null
      mv -f "$tmp_file" "$fcost_cache_file" 2>/dev/null
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
fi

# --- Per-model token breakdown (cached, refreshed async) ---
# Replaces the optional feeds line. Sums tokens per model family (Fable/Opus/
# Sonnet/Haiku, matched by substring in message.model) across the whole
# session — both the main transcript (transcript_path) and every agent-*.jsonl
# under <transcript_dir>/<session_id>/subagents/ (where Task/Agent-tool
# subagent turns are logged separately from the main transcript). Main-loop
# and subagent usage are combined: a token costs the same either way, so
# there's no reason to split them here (unlike the $ cost segment above,
# where the split matters because subagents often run on a different,
# subscription-included model). Same dedup-by-message.id rationale as the
# Fable-only cost block: each turn can appear 2-3x per file.
#
# "New" tokens = input + output + cache_creation (freshly processed).
# "Cache" tokens = cache_read (context re-read from cache at a 90% discount) —
# kept separate because in a long session this can dwarf the new-token count
# (e.g. re-reading a 100k-token context on every one of 40 turns), so folding
# it into one "tokens used" figure looks wildly inflated.
# Format: F n<new>/c<cache> │ O n<new>/c<cache> │ S ... │ H ...  │  M<pct>%/S<pct>%
# The trailing M/S segment is the overall main-loop-vs-subagent split of all
# tokens combined (all models, new+cache) — a separate axis from the n/c
# breakdown above, and deliberately not crossed with it (see the
# "Per-model token breakdown" section in README for why).
model_tokens_line=""
if [ -n "$session_id" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  mtok_cache_dir="$HOME/.claude/cache"
  mtok_cache_file="$mtok_cache_dir/fable-model-tokens-${session_id}.txt"
  mtok_lock_dir="$mtok_cache_dir/fable-model-tokens-${session_id}.lock"
  mtok_ttl=20

  # Cache line layout: 10 numbers — fn fc on oc sn sc hn hc main_total sub_total
  if [ -f "$mtok_cache_file" ]; then
    IFS=' ' read -r c_fn c_fc c_on c_oc c_sn c_sc c_hn c_hc c_main c_sub < "$mtok_cache_file" 2>/dev/null
    valid=1
    for v in "$c_fn" "$c_fc" "$c_on" "$c_oc" "$c_sn" "$c_sc" "$c_hn" "$c_hc" "$c_main" "$c_sub"; do
      case "$v" in ''|*[!0-9]*) valid=0 ;; esac
    done
    if [ "$valid" = "1" ]; then
      model_tokens_line=$(printf 'F n%s/c%s │ O n%s/c%s │ S n%s/c%s │ H n%s/c%s' \
        "$(fmt_tok "$c_fn")" "$(fmt_tok "$c_fc")" \
        "$(fmt_tok "$c_on")" "$(fmt_tok "$c_oc")" \
        "$(fmt_tok "$c_sn")" "$(fmt_tok "$c_sc")" \
        "$(fmt_tok "$c_hn")" "$(fmt_tok "$c_hc")")
      grand=$(( c_main + c_sub ))
      if [ "$grand" -gt 0 ]; then
        main_tenths=$(( c_main * 1000 / grand ))
        sub_tenths=$(( c_sub * 1000 / grand ))
        ms_seg=$(printf '  │  M%d.%d%%/S%d.%d%%' \
          $(( main_tenths / 10 )) $(( main_tenths % 10 )) \
          $(( sub_tenths / 10 )) $(( sub_tenths % 10 )))
        model_tokens_line="${model_tokens_line}${ms_seg}"
      fi
    fi
  fi

  mtok_age=999999
  if [ -f "$mtok_cache_file" ]; then
    mtok_mtime=$(stat -f %m "$mtok_cache_file" 2>/dev/null || stat -c %Y "$mtok_cache_file" 2>/dev/null)
    if [ -n "$mtok_mtime" ]; then
      mtok_age=$(( $(date +%s) - mtok_mtime ))
    fi
  fi

  if [ "$mtok_age" -ge "$mtok_ttl" ] 2>/dev/null; then
    if [ -d "$mtok_lock_dir" ]; then
      mtok_lock_mtime=$(stat -f %m "$mtok_lock_dir" 2>/dev/null || stat -c %Y "$mtok_lock_dir" 2>/dev/null)
      if [ -n "$mtok_lock_mtime" ] && [ $(( $(date +%s) - mtok_lock_mtime )) -gt 30 ]; then
        rmdir "$mtok_lock_dir" 2>/dev/null
      fi
    fi
    (
      mkdir "$mtok_lock_dir" 2>/dev/null || exit 0
      trap 'rmdir "$mtok_lock_dir" 2>/dev/null' EXIT
      mkdir -p "$mtok_cache_dir" 2>/dev/null

      per_model_jq='
        def newtok(u): (u.input_tokens // 0) + (u.output_tokens // 0) + (u.cache_creation_input_tokens // 0);
        def cachetok(u): (u.cache_read_input_tokens // 0);
        ([inputs | select(.type=="assistant")] | unique_by(.message.id)) as $d
        | ($d | map(select((.message.model // "") | test("fable";"i"))))  as $f
        | ($d | map(select((.message.model // "") | test("opus";"i"))))   as $o
        | ($d | map(select((.message.model // "") | test("sonnet";"i")))) as $s
        | ($d | map(select((.message.model // "") | test("haiku";"i"))))  as $h
        | [
            ($f | map(newtok(.message.usage)) | add // 0), ($f | map(cachetok(.message.usage)) | add // 0),
            ($o | map(newtok(.message.usage)) | add // 0), ($o | map(cachetok(.message.usage)) | add // 0),
            ($s | map(newtok(.message.usage)) | add // 0), ($s | map(cachetok(.message.usage)) | add // 0),
            ($h | map(newtok(.message.usage)) | add // 0), ($h | map(cachetok(.message.usage)) | add // 0)
          ] | @tsv
      '

      is_digits() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

      read -r fn fc on oc sn sc hn hc < <("$JQ" -r "$per_model_jq" "$transcript_path" 2>/dev/null)
      for v in fn fc on oc sn sc hn hc; do
        is_digits "${!v}" || eval "$v=0"
      done
      main_total=$(( fn + fc + on + oc + sn + sc + hn + hc ))

      sub_total=0
      transcript_dir="$(dirname "$transcript_path")"
      transcript_stem="$(basename "$transcript_path" .jsonl)"
      subagents_dir="$transcript_dir/$transcript_stem/subagents"
      if [ -d "$subagents_dir" ]; then
        for af in "$subagents_dir"/agent-*.jsonl; do
          [ -f "$af" ] || continue
          read -r afn afc aon aoc asn asc ahn ahc < <("$JQ" -r "$per_model_jq" "$af" 2>/dev/null)
          skip=0
          for v in afn afc aon aoc asn asc ahn ahc; do
            is_digits "${!v}" || skip=1
          done
          [ "$skip" = "1" ] && continue
          sub_total=$(( sub_total + afn + afc + aon + aoc + asn + asc + ahn + ahc ))
          fn=$(( fn + afn )); fc=$(( fc + afc ))
          on=$(( on + aon )); oc=$(( oc + aoc ))
          sn=$(( sn + asn )); sc=$(( sc + asc ))
          hn=$(( hn + ahn )); hc=$(( hc + ahc ))
        done
      fi

      tmp_file="${mtok_cache_file}.tmp.$$"
      printf '%s %s %s %s %s %s %s %s %s %s\n' \
        "$fn" "$fc" "$on" "$oc" "$sn" "$sc" "$hn" "$hc" "$main_total" "$sub_total" > "$tmp_file" 2>/dev/null
      mv -f "$tmp_file" "$mtok_cache_file" 2>/dev/null
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
fi

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

# --- git worktree marker (🌲, only shown when workspace.git_worktree is truthy) ---
worktree_marker=""
case "$git_worktree_raw" in
  ""|false|null) : ;;
  true) worktree_marker=" 🌲" ;;
  *) worktree_marker=" 🌲${git_worktree_raw}" ;;
esac

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

printf "[%s] 📁 %s | 🌿 %s%s | 🪄 %s\n" \
  "$model_disp" "$dir_disp" "$git_branch" "$worktree_marker" "$skill_disp"

# --- LINE 2 components ---

# Context window usage (yellow 50, red 60 — earlier warning since context
# fills up faster than rate limits and needs earlier attention)
ctx_seg=""
if [ "$ctx_used" != "null" ]; then
  ctx_bar=$(make_bar "$ctx_used" 50 60)
  ctx_pct_int=$(printf "%.0f" "$ctx_used")
  ctx_seg=$(printf "🤖%b %s%%" "$ctx_bar" "$ctx_pct_int")
fi

# 5-hour session rate limit (yellow 70, red 90 — same defaults as 7-day)
five_seg=""
if [ "$five_hour_pct" != "null" ]; then
  five_bar=$(make_bar "$five_hour_pct")
  five_pct_int=$(printf "%.0f" "$five_hour_pct")
  five_seg=$(printf "⏳%b %s%%" "$five_bar" "$five_pct_int")
fi

# 7-day rate (green ≤50, yellow ≤75, red ≥76)
seven_seg=""
if [ "$seven_day_pct" != "null" ]; then
  seven_bar=$(make_bar "$seven_day_pct" 51 76)
  seven_pct_int=$(printf "%.0f" "$seven_day_pct")
  seven_seg=$(printf "📅%b %s%%" "$seven_bar" "$seven_pct_int")
fi

# Fable weekly rate (green ≤50, yellow ≤75, red ≥76)
fable_seg=""
if [ -n "$fable_weekly_pct" ]; then
  fable_bar=$(make_bar "$fable_weekly_pct" 51 76)
  fable_seg=$(printf "📖 %b %s%%" "$fable_bar" "$fable_weekly_pct")
fi

# lines added / removed this session
lines_seg=""
if [ "$lines_added" != "0" ] || [ "$lines_removed" != "0" ]; then
  lines_seg=$(printf "%b+%s%b %b-%s%b" "$GREEN" "$lines_added" "$RESET" "$RED" "$lines_removed" "$RESET")
fi

# cost (Fable-only, see the "Fable-only session cost" block above)
if [ -n "$fable_cost_str" ]; then
  cost_str="$fable_cost_str"
else
  cost_str="\$0.00"
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
[ -n "$five_seg" ]     && metrics+=("$five_seg")
[ -n "$seven_seg" ]    && metrics+=("$seven_seg")
[ -n "$fable_seg" ]    && metrics+=("$fable_seg")
[ -n "$lines_seg" ]    && metrics+=("$lines_seg")
[ -n "$local_state" ]  && metrics+=("$local_state")
metrics+=("${cost_str} ⏱${duration_str}")

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

# --- LINE 2: metrics ---
join_sections "${metrics[@]}"

# --- LINE 3 (optional): per-model token usage, main loop vs subagents ---
[ -n "$model_tokens_line" ] && printf '%s\n' "$model_tokens_line"
exit 0
