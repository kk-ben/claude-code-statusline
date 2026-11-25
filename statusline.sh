#!/bin/bash
# claude-code-statusline
# A rich multi-line statusLine for Claude Code (https://claude.com/claude-code).
#
# Line 1: [model · effort] 📁 dir | 🌿 git-branch
# Line 2: 🤖██░░░ 42% │ ⏳█▍░░░ 30% │ 📅▊░░░░ 18% │ 📖 ███▋░ 75% │ +120 -33 │ ✓ ✓2/5 │ $0.42 ⏱最長 12m05s · 直近 2m10s
# Line 3: (optional) per-model token usage — F n191.0k/c4.6M │ S n1.0M/c51.6M │ M99.0%/S0.9% │ 👤 name
# Line 4: (optional, last) 🪄 up to 5 skills used in the session, newest first (+N = how many more are not shown)
#
# Designed to be invoked from settings.json:
#   "statusLine": { "type": "command", "command": "bash <path>/statusline.sh" }
#
# License: MIT

input=$(cat)

# --- File mtime (epoch seconds). GNU stat takes -c; on macOS -c is an illegal
# option (prints nothing, non-zero) so it falls through to BSD -f. Order matters:
# on GNU, `stat -f` means "filesystem status" and would print garbage. ---
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# --- ANSI colors ---
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
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
lines_added=$(echo "$input" | "$JQ" -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | "$JQ" -r '.cost.total_lines_removed // 0')
effort_level=$(echo "$input" | "$JQ" -r '.effort.level // ""')

# --- Fable weekly usage % (cached, refreshed async, never blocks statusline) ---
# Account / config dir (fixed 2026-11-18): Claude Code runs this script with
# CLAUDE_CONFIG_DIR set to the window's own profile dir (measured: CLAUDE_CONFIG_DIR=
# <profile>, HOME=<the user's home>). The old code read $HOME/.claude/.credentials.json
# (a different login -> HTTP 429 / stale value), so credentials and the cache now
# follow CLAUDE_CONFIG_DIR (falls back to $HOME/.claude when it is unset).
# Retry pacing: a failed fetch used to leave the cache untouched, so the TTL stayed
# expired and EVERY statusline call from EVERY window re-hit the API. A separate
# attempt stamp (fable-weekly.try) now paces attempts to one per TTL even on failure.
# A value older than fable_stale_after is shown with a trailing "?".
cfg_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
fable_cache_dir="$cfg_dir/cache"
fable_cache_file="$fable_cache_dir/fable-weekly.txt"
fable_try_file="$fable_cache_dir/fable-weekly.try"
fable_lock_dir="$fable_cache_dir/fable-weekly.lock"
fable_cache_ttl=300
fable_stale_after=900

fable_weekly_pct=""
if [ -f "$fable_cache_file" ]; then
  cached_val=$(cat "$fable_cache_file" 2>/dev/null | tr -d '[:space:]')
  # cached_val may be an integer or a decimal (the oauth/usage API has been
  # observed returning fractional percent values), so round via printf
  # rather than a strict digit-only equality check (same pattern used below
  # for ctx_used / five_hour_pct / seven_day_pct).
  if [ -n "$cached_val" ]; then
    rounded_val=$(printf "%.0f" "$cached_val" 2>/dev/null)
    [ -n "$rounded_val" ] && fable_weekly_pct="$rounded_val"
  fi
fi

fable_now=$(date +%s)
fable_stale_mark=""
if [ -f "$fable_cache_file" ]; then
  fable_mtime=$(file_mtime "$fable_cache_file")
  if [ -n "$fable_mtime" ] && [ $(( fable_now - fable_mtime )) -ge "$fable_stale_after" ] 2>/dev/null; then
    fable_stale_mark="?"
  fi
fi

fable_try_age=999999
if [ -f "$fable_try_file" ]; then
  fable_try_mtime=$(file_mtime "$fable_try_file")
  [ -n "$fable_try_mtime" ] && fable_try_age=$(( fable_now - fable_try_mtime ))
fi

if [ "$fable_try_age" -ge "$fable_cache_ttl" ] 2>/dev/null; then
  mkdir -p "$fable_cache_dir" 2>/dev/null
  # Clear a stale lock (fetcher killed mid-flight) so refresh can't wedge forever
  if [ -d "$fable_lock_dir" ]; then
    lock_mtime=$(file_mtime "$fable_lock_dir")
    if [ -n "$lock_mtime" ] && [ $(( $(date +%s) - lock_mtime )) -gt 60 ]; then
      rmdir "$fable_lock_dir" 2>/dev/null
    fi
  fi
  (
    mkdir "$fable_lock_dir" 2>/dev/null || exit 0
    trap 'rmdir "$fable_lock_dir" 2>/dev/null' EXIT
    : > "$fable_try_file" 2>/dev/null
    creds_file="$cfg_dir/.credentials.json"
    token=""
    if [ -f "$creds_file" ]; then
      token=$("$JQ" -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
    fi
    # GUI installs of Claude Code on macOS store OAuth in the login Keychain
    # instead of .credentials.json — same JSON payload, different location.
    # Only for the default config dir: the Keychain entry below belongs to the
    # default login, so with a custom CLAUDE_CONFIG_DIR it would be another account.
    if [ -z "$token" ] && [ -z "${CLAUDE_CONFIG_DIR:-}" ] && [ "$(uname)" = "Darwin" ]; then
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
    # percent can be an integer or a decimal (API has been observed returning
    # fractional values) — round it here so the cache always holds a plain
    # integer that the strict digit check on the reader side can accept.
    pct=$(printf "%.0f" "$pct" 2>/dev/null)
    case "$pct" in
      ''|*[!0-9]*) exit 0 ;;
    esac
    tmp_file="${fable_cache_file}.tmp.$$"
    printf '%s\n' "$pct" > "$tmp_file" 2>/dev/null
    mv -f "$tmp_file" "$fable_cache_file" 2>/dev/null
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

# --- account name (the part of the login email before "@"; cached, refreshed async) ---
# Source (measured 2026-11-18): the statusline stdin JSON has no account field, so the name
# comes from oauthAccount.emailAddress in the window's own global config:
# $CLAUDE_CONFIG_DIR/.claude.json, or $HOME/.claude.json when CLAUDE_CONFIG_DIR is unset.
# Only the text before "@" is ever kept: the full address and the domain are never cached
# or shown. .claude.json is large, so it is read at most once per acct_ttl seconds, off the
# hot path, into a cache keyed by the config dir. Nothing is shown when it cannot be read.
account_seg=""
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  acct_src="$CLAUDE_CONFIG_DIR/.claude.json"
else
  acct_src="$HOME/.claude.json"
fi
acct_cache_dir="$HOME/.claude/cache"
acct_key="${cfg_dir//[^A-Za-z0-9]/_}"
acct_cache_file="$acct_cache_dir/account-name-${acct_key}.txt"
acct_lock_dir="$acct_cache_dir/account-name-${acct_key}.lock"
acct_ttl=300

if [ -f "$acct_cache_file" ]; then
  acct_name=$(head -n 1 "$acct_cache_file" 2>/dev/null | tr -d '[:space:]')
  case "$acct_name" in
    ''|*[!A-Za-z0-9._+-]*) : ;;
    *) account_seg="👤 $acct_name" ;;
  esac
fi

acct_age=999999
if [ -f "$acct_cache_file" ]; then
  acct_mtime=$(file_mtime "$acct_cache_file")
  [ -n "$acct_mtime" ] && acct_age=$(( $(date +%s) - acct_mtime ))
fi

if [ "$acct_age" -ge "$acct_ttl" ] 2>/dev/null; then
  if [ -d "$acct_lock_dir" ]; then
    acct_lock_mtime=$(file_mtime "$acct_lock_dir")
    if [ -n "$acct_lock_mtime" ] && [ $(( $(date +%s) - acct_lock_mtime )) -gt 30 ]; then
      rmdir "$acct_lock_dir" 2>/dev/null
    fi
  fi
  (
    mkdir -p "$acct_cache_dir" 2>/dev/null
    mkdir "$acct_lock_dir" 2>/dev/null || exit 0
    trap 'rmdir "$acct_lock_dir" 2>/dev/null' EXIT
    acct_out=$("$JQ" -r '.oauthAccount.emailAddress // empty | split("@")[0]' "$acct_src" 2>/dev/null)
    acct_rc=$?
    if [ -f "$acct_src" ] && [ "$acct_rc" = "0" ]; then
      # an address without an account name is cached as empty, so it is not re-read until the TTL passes
      tmp_file="${acct_cache_file}.tmp.$$"
      printf '%s\n' "$acct_out" > "$tmp_file" 2>/dev/null
      mv -f "$tmp_file" "$acct_cache_file" 2>/dev/null
    elif [ -f "$acct_cache_file" ]; then
      # unreadable / mid-write: keep the old value, only push the next try out by one TTL
      touch "$acct_cache_file" 2>/dev/null
    else
      : > "$acct_cache_file" 2>/dev/null
    fi
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
    fcost_mtime=$(file_mtime "$fcost_cache_file")
    if [ -n "$fcost_mtime" ]; then
      fcost_age=$(( $(date +%s) - fcost_mtime ))
    fi
  fi

  if [ "$fcost_age" -ge "$fcost_ttl" ] 2>/dev/null; then
    if [ -d "$fcost_lock_dir" ]; then
      fcost_lock_mtime=$(file_mtime "$fcost_lock_dir")
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
model_tok_segs=()
model_tok_totals=()
model_tok_ms_seg=""
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
      # One segment per model family (fixed order F/O/S/H), paired with its
      # total token count (new+cache) so line 3 (see the priority-trim
      # block near the bottom) can drop the lowest-usage models first when
      # the line doesn't fit — it never wraps onto extra lines.
      model_tok_segs=(
        "$(printf 'F n%s/c%s' "$(fmt_tok "$c_fn")" "$(fmt_tok "$c_fc")")"
        "$(printf 'O n%s/c%s' "$(fmt_tok "$c_on")" "$(fmt_tok "$c_oc")")"
        "$(printf 'S n%s/c%s' "$(fmt_tok "$c_sn")" "$(fmt_tok "$c_sc")")"
        "$(printf 'H n%s/c%s' "$(fmt_tok "$c_hn")" "$(fmt_tok "$c_hc")")"
      )
      model_tok_totals=(
        "$(( c_fn + c_fc ))"
        "$(( c_on + c_oc ))"
        "$(( c_sn + c_sc ))"
        "$(( c_hn + c_hc ))"
      )
      grand=$(( c_main + c_sub ))
      if [ "$grand" -gt 0 ]; then
        main_tenths=$(( c_main * 1000 / grand ))
        sub_tenths=$(( c_sub * 1000 / grand ))
        model_tok_ms_seg=$(printf 'M%d.%d%%/S%d.%d%%' \
          $(( main_tenths / 10 )) $(( main_tenths % 10 )) \
          $(( sub_tenths / 10 )) $(( sub_tenths % 10 )))
      fi
    fi
  fi

  mtok_age=999999
  if [ -f "$mtok_cache_file" ]; then
    mtok_mtime=$(file_mtime "$mtok_cache_file")
    if [ -n "$mtok_mtime" ]; then
      mtok_age=$(( $(date +%s) - mtok_mtime ))
    fi
  fi

  if [ "$mtok_age" -ge "$mtok_ttl" ] 2>/dev/null; then
    if [ -d "$mtok_lock_dir" ]; then
      mtok_lock_mtime=$(file_mtime "$mtok_lock_dir")
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

# --- last skill from transcript (cached per-session, refreshed async) ---
# Skill use is recorded in two forms (measured 2026-11-18):
#  (a) assistant tool_use name=="Skill"  -> .input.skill      (windows that have the Skill tool)
#  (b) assistant tool_use name=="Read" of .../skills/<name>/SKILL.md
#      (the fable-coordinator parent windows have no Skill tool and read SKILL.md directly)
# The old detector only knew (a) and only scanned `tail -n 500` lines, so parent
# windows (b) and any long session (last use older than 500 lines) always showed "—".
# Now both forms are scanned over the whole transcript, off the hot path: grep -F
# prefilters the few candidate lines, jq (-R + fromjson?, tolerant of a torn line)
# picks the last five distinct names (newest first, a repeated name counts once at its
# newest use); result cached per session like the other blocks. The names are shown on
# their own line (line 4, "🪄 a · b · c · d · e +N", N = distinct names not shown) —
# nothing is printed when no skill was used.
# Cache format: up to 5 name lines, then one "#total=<all distinct names>" line (only when
# at least one name exists). A cache without the "#total=" line (older format) is read as
# total == number of names, i.e. no "+N".
skill_names=()
skill_total=0
if [ -n "$session_id" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  skill_cache_dir="$HOME/.claude/cache"
  skill_cache_file="$skill_cache_dir/last-skill-${session_id}.txt"
  skill_lock_dir="$skill_cache_dir/last-skill-${session_id}.lock"
  skill_ttl=15

  if [ -f "$skill_cache_file" ]; then
    while IFS= read -r cached_skill; do
      cached_skill="${cached_skill//[[:space:]]/}"
      case "$cached_skill" in
        ''|—) continue ;;
        '#total='*) skill_total="${cached_skill#\#total=}"; continue ;;
        '#'*) continue ;;
      esac
      [ "${#skill_names[@]}" -lt 5 ] && skill_names+=("$cached_skill")
    done < "$skill_cache_file"
    case "$skill_total" in ''|*[!0-9]*) skill_total=0 ;; esac
    [ "$skill_total" -lt "${#skill_names[@]}" ] && skill_total="${#skill_names[@]}"
  fi

  skill_age=999999
  if [ -f "$skill_cache_file" ]; then
    skill_mtime=$(file_mtime "$skill_cache_file")
    [ -n "$skill_mtime" ] && skill_age=$(( $(date +%s) - skill_mtime ))
  fi

  if [ "$skill_age" -ge "$skill_ttl" ] 2>/dev/null; then
    if [ -d "$skill_lock_dir" ]; then
      skill_lock_mtime=$(file_mtime "$skill_lock_dir")
      if [ -n "$skill_lock_mtime" ] && [ $(( $(date +%s) - skill_lock_mtime )) -gt 30 ]; then
        rmdir "$skill_lock_dir" 2>/dev/null
      fi
    fi
    (
      mkdir -p "$skill_cache_dir" 2>/dev/null
      mkdir "$skill_lock_dir" 2>/dev/null || exit 0
      trap 'rmdir "$skill_lock_dir" 2>/dev/null' EXIT
      skill_jq='
        fromjson? | select(.type=="assistant") | .message.content[]?
        | select(type=="object" and .type=="tool_use")
        | if .name=="Skill" then (.input.skill // empty)
          elif .name=="Read" then ((.input.file_path // "") | select(test("/skills/[^/]+/SKILL\\.md$")) | sub("^.*/skills/";"") | sub("/SKILL\\.md$";""))
          else empty end'
      found=$(grep -a -F -e '"name":"Skill"' -e 'SKILL.md' "$transcript_path" 2>/dev/null \
        | grep -a -F '"type":"assistant"' \
        | "$JQ" -R -r "$skill_jq" 2>/dev/null \
        | awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) if (!seen[a[i]]++) { t++; if (t <= 5) print a[i] } if (t > 0) print "#total=" t }')
      tmp_file="${skill_cache_file}.tmp.$$"
      # An empty result is cached too (as "—") so a session with no skill use is not rescanned every call
      printf '%s\n' "${found:-—}" > "$tmp_file" 2>/dev/null
      mv -f "$tmp_file" "$skill_cache_file" 2>/dev/null
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
fi

# --- autopilot durations (cached per-session, refreshed async) ---
# Replaces the old elapsed-time readout. One "autopilot run" = from a human input
# line (type=user, not tool_result, not isMeta, origin.kind=="human" — or, in
# transcripts without origin, not a task-notification / command / interrupt / summary
# line) to the timestamp of the last assistant / tool_result line before the next
# human input. The run in progress is counted as (now − start); it is "in progress"
# when the last assistant/tool_result line is a tool_result or an assistant turn whose
# stop_reason is not end_turn/stop_sequence/max_tokens/refusal, and no interrupt
# marker follows. Cache line: "<longest_closed_sec> <last_start_epoch> <last_end_epoch> <running 0|1>".
# Idle gaps are not counted (since 2026-11-18): when two adjacent counted lines (human input /
# assistant / tool_result) are ap_gap_limit seconds or more apart, the run is cut there — it ends
# at the earlier line and a new run starts at the later one. A run in progress whose last line
# is ap_gap_limit seconds or more old is not treated as running (its duration is end − start).
ap_gap_limit=1800   # the single place that sets the idle-gap cut (seconds)
# Labels for the two durations; override with env vars (e.g. "max" / "last").
ap_label_longest="${CLAUDE_STATUSLINE_LABEL_LONGEST:-最長}"
ap_label_latest="${CLAUDE_STATUSLINE_LABEL_LATEST:-直近}"
ap_str="—"
if [ -n "$session_id" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  ap_cache_dir="$HOME/.claude/cache"
  ap_cache_file="$ap_cache_dir/autopilot-${session_id}.txt"
  ap_lock_dir="$ap_cache_dir/autopilot-${session_id}.lock"
  ap_ttl=15

  fmt_dur() {
    local s="${1:-0}"
    case "$s" in ''|*[!0-9]*) s=0 ;; esac
    if [ "$s" -ge 3600 ]; then
      printf '%dh%dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
    else
      printf '%dm%ds' $(( s / 60 )) $(( s % 60 ))
    fi
  }

  if [ -f "$ap_cache_file" ]; then
    IFS=' ' read -r ap_max ap_start ap_end ap_run < "$ap_cache_file" 2>/dev/null
    ap_valid=1
    for v in "$ap_max" "$ap_start" "$ap_end" "$ap_run"; do
      case "$v" in ''|*[!0-9]*) ap_valid=0 ;; esac
    done
    if [ "$ap_valid" = "1" ] && [ "$ap_start" -gt 0 ]; then
      ap_now=$(date +%s)
      if [ "$ap_run" = "1" ] && [ $(( ap_now - ap_end )) -lt "$ap_gap_limit" ]; then
        ap_recent=$(( ap_now - ap_start ))
      else
        ap_recent=$(( ap_end - ap_start ))
      fi
      [ "$ap_recent" -lt 0 ] && ap_recent=0
      ap_longest="$ap_max"
      [ "$ap_recent" -gt "$ap_longest" ] && ap_longest="$ap_recent"
      ap_str="${ap_label_longest} $(fmt_dur "$ap_longest") · ${ap_label_latest} $(fmt_dur "$ap_recent")"
    fi
  fi

  ap_age=999999
  if [ -f "$ap_cache_file" ]; then
    ap_mtime=$(file_mtime "$ap_cache_file")
    [ -n "$ap_mtime" ] && ap_age=$(( $(date +%s) - ap_mtime ))
  fi

  if [ "$ap_age" -ge "$ap_ttl" ] 2>/dev/null; then
    if [ -d "$ap_lock_dir" ]; then
      ap_lock_mtime=$(file_mtime "$ap_lock_dir")
      if [ -n "$ap_lock_mtime" ] && [ $(( $(date +%s) - ap_lock_mtime )) -gt 30 ]; then
        rmdir "$ap_lock_dir" 2>/dev/null
      fi
    fi
    (
      mkdir -p "$ap_cache_dir" 2>/dev/null
      mkdir "$ap_lock_dir" 2>/dev/null || exit 0
      trap 'rmdir "$ap_lock_dir" 2>/dev/null' EXIT
      ap_jq='
        def ts: .timestamp | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601;
        def txt: (.message.content | if type=="string" then . else (map(select(type=="object" and .type=="text") | .text) | join(" ")) end);
        def has_tr: ((.message.content | type)=="array") and (.message.content | any(.[]; type=="object" and .type=="tool_result"));
        def synth: (txt | test("^\\s*(<task-notification>|<command-name>|<local-command|<system-reminder>|This session is being continued|\\[Request interrupted|Caveat:)"));
        def is_human: .type=="user" and (.isMeta != true) and (has_tr | not)
          and (if .origin.kind != null then .origin.kind == "human"
               elif .turnOrigin != null then .turnOrigin == "human"
               else (synth | not) end);
        def is_stop: .type=="user" and (.isMeta != true) and (has_tr | not)
          and (.origin.kind == null) and (.turnOrigin == null) and (txt | test("^\\s*\\[Request interrupted"));
        def is_act: .type=="assistant" or (.type=="user" and has_tr);
        reduce (inputs | select((.type=="user" or .type=="assistant") and (.isSidechain != true) and (.timestamp != null))) as $l
          ({max:0, start:null, end:null, run:false};
            ($l | ts) as $t
            | if ($l | is_human) then
                (if .start != null then .max = ([.max, (.end - .start)] | max) else . end)
                | .start = $t | .end = $t | .run = true
              elif ($l | is_stop) then .run = false
              elif ($l | is_act) and (.start != null) then
                (if ($t - .end) >= $gap then .max = ([.max, (.end - .start)] | max) | .start = $t else . end)
                | .end = $t
                | .run = ($l.type == "user" or (($l.message.stop_reason // "") | IN("end_turn","stop_sequence","max_tokens","refusal") | not))
              else . end)
        | [.max, (.start // 0), (.end // 0), (if .run then 1 else 0 end)] | map(floor) | @tsv'
      ap_out=$("$JQ" -n -r --argjson gap "$ap_gap_limit" "$ap_jq" "$transcript_path" 2>/dev/null | tr '\t' ' ')
      IFS=' ' read -r o_max o_start o_end o_run <<< "$ap_out"
      for v in "$o_max" "$o_start" "$o_end" "$o_run"; do
        case "$v" in ''|*[!0-9]*) exit 0 ;; esac
      done
      tmp_file="${ap_cache_file}.tmp.$$"
      printf '%s %s %s %s\n' "$o_max" "$o_start" "$o_end" "$o_run" > "$tmp_file" 2>/dev/null
      mv -f "$tmp_file" "$ap_cache_file" 2>/dev/null
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
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
# Claude Code (verified 2026-08-05 against CLI v2.1.219 source + a runtime
# capture) sets the COLUMNS env var to the actual statusline-pane width
# (process.stdout.columns) when it spawns this script — stdin JSON carries
# no width field. COLUMNS is the authoritative value and must be trusted
# first: a runtime capture showed COLUMNS=64 (the real pane width) while
# walking the process tree for an outer tty found 70 cols from a wider,
# unrelated outer terminal — that mismatch is the confirmed root cause of
# line 2 failing to wrap in production (Cursor Remote-SSH). The process-tree
# walk and other fallbacks below now only run when COLUMNS is unset (e.g.
# invoking this script by hand outside Claude Code).
term_cols=0
if [ -n "${COLUMNS:-}" ] && [ "$COLUMNS" -gt 0 ] 2>/dev/null; then
  term_cols="$COLUMNS"
fi

if ! [ "$term_cols" -gt 0 ] 2>/dev/null; then
  pid=$$
  for _ in 1 2 3 4 5 6 7 8; do
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
fi

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
  term_cols=160
fi
# Manual override: env CLAUDE_STATUSLINE_COLS=<n> forces a width.
if [ -n "${CLAUDE_STATUSLINE_COLS:-}" ] && [ "$CLAUDE_STATUSLINE_COLS" -gt 0 ] 2>/dev/null; then
  term_cols="$CLAUDE_STATUSLINE_COLS"
fi

# --- LINE 1 (dynamic truncation by terminal width) ---
# Width bands drive how aggressively we shorten model / dir.
#   term_cols ≥ 140 : full everything
#   90 ≤ cols < 140 : strip "(...)" suffix from model, collapse dir to "…/basename"
#   cols < 90       : short model word only, basename-only dir

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

# effort.level comes straight from the stdin JSON; absent (model has no effort parameter) -> nothing is shown
model_label="$model_disp"
[ -n "$effort_level" ] && model_label="${model_disp} · ${effort_level}"

printf "[%s] 📁 %s | 🌿 %s%s\n" \
  "$model_label" "$dir_disp" "$git_branch" "$worktree_marker"

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
  fable_seg=$(printf "📖 %b %s%%%s" "$fable_bar" "$fable_weekly_pct" "$fable_stale_mark")
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

# duration: autopilot longest / latest (see the "autopilot durations" block above)
duration_str="$ap_str"

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

# Visible length of a section (ANSI color codes stripped, since they take
# zero terminal columns but would otherwise inflate the wrap-width count).
visible_len() {
  local stripped
  stripped=$(printf '%b' "$1" | sed -E 's/\x1b\[[0-9;]*m//g')
  printf '%s' "$stripped" | wc -m | tr -d ' '
}

# Join an array of sections with " │ ", wrapping onto additional lines
# (rather than letting the terminal hard-truncate) once the running width
# would exceed term_cols. Each wrapped line is emitted separately so line 2
# can spill onto line 3+ on narrow terminals.
join_sections() {
  local sep=" │ "
  local sep_len=3
  local -a wrapped=()
  local cur="" cur_len=0
  local seg seg_len
  for seg in "$@"; do
    seg_len=$(visible_len "$seg")
    if [ -z "$cur" ]; then
      cur="$seg"; cur_len="$seg_len"
    elif [ $(( cur_len + sep_len + seg_len )) -le "$term_cols" ]; then
      cur="${cur}${sep}${seg}"
      cur_len=$(( cur_len + sep_len + seg_len ))
    else
      wrapped+=("$cur")
      cur="$seg"; cur_len="$seg_len"
    fi
  done
  [ -n "$cur" ] && wrapped+=("$cur")
  local line
  for line in "${wrapped[@]}"; do
    printf '%b\n' "$line"
  done
}

# --- LINE 2: metrics ---
join_sections "${metrics[@]}"

# --- LINE 3 (optional): per-model token usage, main loop vs subagents ---
# Always a single line — never wraps. When the full breakdown doesn't fit
# in term_cols, segments are dropped in priority order until it does:
#   1. zero-token models are dropped outright (they carry no information)
#   2. if still too wide, the remaining lowest-usage model is dropped,
#      repeating until only the highest-usage model(s) are left
#   3. finally the trailing M/S (main-vs-subagent) segment is dropped
# With room to spare, all segments show as before.
if [ "${#model_tok_segs[@]}" -gt 0 ]; then
  mt_active=(1 1 1 1)
  for mt_i in 0 1 2 3; do
    [ "${model_tok_totals[$mt_i]}" -eq 0 ] && mt_active[$mt_i]=0
  done
  mt_show_ms=1
  [ -z "$model_tok_ms_seg" ] && mt_show_ms=0

  build_line3() {
    local out="" first=1 i
    for i in 0 1 2 3; do
      if [ "${mt_active[$i]}" = "1" ]; then
        if [ "$first" = "1" ]; then out="${model_tok_segs[$i]}"; first=0
        else out="${out} │ ${model_tok_segs[$i]}"; fi
      fi
    done
    if [ "$mt_show_ms" = "1" ]; then
      if [ "$first" = "1" ]; then out="$model_tok_ms_seg"; first=0
      else out="${out} │ ${model_tok_ms_seg}"; fi
    fi
    if [ -n "$account_seg" ]; then
      if [ "$first" = "1" ]; then out="$account_seg"; first=0
      else out="${out} │ ${account_seg}"; fi
    fi
    printf '%s' "$out"
  }

  mt_line=$(build_line3)
  mt_len=$(visible_len "$mt_line")

  while [ -n "$mt_line" ] && [ "$mt_len" -gt "$term_cols" ] 2>/dev/null; do
    mt_min_i=-1
    mt_min_val=-1
    for mt_i in 0 1 2 3; do
      if [ "${mt_active[$mt_i]}" = "1" ]; then
        if [ "$mt_min_i" = "-1" ] || [ "${model_tok_totals[$mt_i]}" -lt "$mt_min_val" ]; then
          mt_min_i="$mt_i"; mt_min_val="${model_tok_totals[$mt_i]}"
        fi
      fi
    done
    if [ "$mt_min_i" != "-1" ]; then
      mt_active[$mt_min_i]=0
    elif [ "$mt_show_ms" = "1" ]; then
      mt_show_ms=0
    else
      break
    fi
    mt_line=$(build_line3)
    mt_len=$(visible_len "$mt_line")
  done

  [ -n "$mt_line" ] && printf '%s\n' "$mt_line"
fi

# --- LINE 4 (optional): skills used in this session, newest first (max 5) ---
# Never wraps: when it does not fit in term_cols the oldest names are dropped first.
# The rest that is not shown (more than 5 used, or names dropped for width) is appended
# as " +N" (N = skill_total - shown names); the width check includes the " +N".
# Not printed at all when the session has used no skill.
if [ "${#skill_names[@]}" -gt 0 ]; then
  sk_n="${#skill_names[@]}"
  while :; do
    sk_line="🪄 ${skill_names[0]}"
    for ((sk_i = 1; sk_i < sk_n; sk_i++)); do sk_line="${sk_line} · ${skill_names[$sk_i]}"; done
    sk_more=$(( skill_total - sk_n ))
    [ "$sk_more" -gt 0 ] && sk_line="${sk_line} +${sk_more}"
    [ "$sk_n" -le 1 ] && break
    [ "$(visible_len "$sk_line")" -le "$term_cols" ] 2>/dev/null && break
    sk_n=$(( sk_n - 1 ))
  done
  printf '%s\n' "$sk_line"
fi
exit 0
