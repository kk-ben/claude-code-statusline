# claude-code-statusline

A rich 2-line statusLine for [Claude Code](https://claude.com/claude-code) with smooth Unicode gauges, git status, last-invoked skill, task progress, Fable-only cost / duration, and a per-model token breakdown (main loop vs subagents).

```
[Opus 4.7] 📁 …/cc-statusline | 🌿 main | 🪄 superpowers:brainstorming
🤖████▌░░░░░ 42% │ 📅█▊░░░░░░░ 18% │ 📖 █▋░░░░░░░░ 17% │ +120 -33 │ ✓ ✓2/5 │ $0.42 ⏱12m05s
F n191.0k/c4.6M ↳n0/c0 │ O n0/c0 ↳n0/c0 │ S n589.9k/c30.2M ↳n52.9k/c469.0k │ H n0/c0 ↳n0/c0
```

The third line shows, per model family (Fable/Opus/Sonnet/Haiku), how many tokens were newly processed (`n`) vs read from prompt cache (`c`) this session — first for the main loop, then (after `↳`) for subagents. See [Per-model token breakdown](#per-model-token-breakdown).

---

## Features

| Segment | What it shows |
|---|---|
| `[model]` | `display_name` from Claude Code stdin (e.g. `Opus 4.7`); strips `(...)` parenthetical when terminal is narrow |
| `📁 dir` | up to 3 trailing path components, collapses to basename on narrow terminals |
| `🌿 git-branch` | current branch via `git branch --show-current` (`—` if not a repo) |
| `🪄 last-skill` | most recent `Skill` tool call from the session transcript |
| `🤖 ctx-bar` | context window % with smooth 8th-block bar (yellow ≥50, red ≥60) |
| `📅 7d-bar` | 7-day rate limit % (yellow ≥70, red ≥90) |
| `📖 Fable-bar` | Fable 5 weekly usage % (yellow ≥70, red ≥90) — fetched separately from `/api/oauth/usage` and cached, since it isn't in the stdin payload; see [Fable weekly gauge](#fable-weekly-gauge) |
| `+N -M` | lines added / removed in this session |
| `●N` / `✓` | git dirty file count, or green check if clean |
| `✓N/M` | TaskCreate progress (completed / total) for the current `session_id` |
| `$X.XX ⏱H:MMmSSs` | Fable-5-only cost this session (not the blended stdin total — see [Fable-only session cost](#fable-only-session-cost)) and total duration |
| `F n../c.. ↳n../c.. │ O ... │ S ... │ H ...` (line 3) | Per model family (Fable/Opus/Sonnet/Haiku), new-vs-cached tokens this session — `n`=input+output+cache-write, `c`=cache-read; before `↳` is the main loop, after it is subagents — see [Per-model token breakdown](#per-model-token-breakdown) |

---

## Requirements

- **bash** ≥ 3.2 (macOS default works)
- **jq** ≥ 1.5 — `brew install jq` on macOS, `apt install jq` on Debian/Ubuntu
- **git** (only used inside git repos)
- **curl** (only for the Fable weekly gauge, which calls the OAuth usage API)

---

## Quick install

```bash
git clone https://github.com/<you>/claude-code-statusline.git
cd claude-code-statusline

# Prints settings.json snippet to stdout
bash install.sh

# Also auto-patch settings.json
bash install.sh --patch-settings
```

The installer:

1. Copies `statusline.sh` to `$HOME/.claude/cc-statusline/statusline.sh` (override with `INSTALL_DIR=...`)
2. With `--patch-settings`: rewrites `$HOME/.claude/settings.json` `statusLine` block (a timestamped backup is kept)

> `install.sh` still accepts `--with-feeds` (copies the `feeds/*` scripts and registers macOS LaunchAgents), but `statusline.sh` no longer renders that output — the third line now shows the [per-model token breakdown](#per-model-token-breakdown) instead. The flag is kept only so `--uninstall` can clean up LaunchAgents from older installs.

Restart Claude Code (or open a new session) — the new statusline appears immediately.

---

## Manual install

If you'd rather not run the installer:

1. Copy `statusline.sh` somewhere readable, e.g. `~/.claude/cc-statusline/statusline.sh`, and `chmod +x` it.
2. Add this to `~/.claude/settings.json`:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash /absolute/path/to/statusline.sh"
     }
   }
   ```

The `feeds/*` scripts from earlier versions still exist in this repo but are no longer read by `statusline.sh` — see the note in [Quick install](#quick-install).

---

## Per-model token breakdown

Line 3 answers "how much did each model actually do this session, and how much of that was fresh work vs re-reading cached context?" — split by model family and by main-loop vs subagent.

1. On each invocation, the script reads `~/.claude/cache/fable-model-tokens-<session_id>.txt` (16 cached integers) if present — no transcript parsing on the hot path.
2. If that cache is missing or older than 20s, a background subshell refreshes it, same non-blocking pattern as the gauges above.
3. The refresher computes two numbers per model family, per scope:
   - **`n` (new)** — `input_tokens + output_tokens + cache_creation_input_tokens`: tokens freshly processed or newly written to cache this turn.
   - **`c` (cache)** — `cache_read_input_tokens`: tokens re-read from a previous cache write, billed at a 90% discount.

   These are kept separate because summing them into one "tokens used" figure is misleading in a long session: re-reading a large accumulated context on every turn (`c`) can dwarf the actual new content (`n`) by 10-20x, making token usage look far higher than the work actually done.
4. **Model family** is matched by substring in `message.model` (`fable`, `opus`, `sonnet`, `haiku` — case-insensitive), so it covers any dated/variant model id (`claude-fable-5`, `claude-opus-4-8`, etc.) without needing exact version strings.
5. **Scope** — main loop is `transcript_path` itself; subagents are every `agent-*.jsonl` under `<transcript_dir>/<session_id>/subagents/` (that's where Claude Code logs each Task/Agent-tool-spawned subagent's own turns, separately from the main transcript). Each file is deduped by `message.id` independently before summing (same duplicate-turn issue as the Fable-only cost block — a turn can appear 2-3x per file as content blocks stream in) and the per-file sums are added together.
6. The result renders as, per model: `F n<new>/c<cache> ↳n<new>/c<cache>` — the part before `↳` is the main loop, the part after is the subagent total. All four models always show, even at `n0/c0`, so the line doesn't shift position turn to turn.

---

## Configuration

| Env var | Default | Effect |
|---|---|---|
| `CLAUDE_STATUSLINE_COLS` | (auto-detected) | Force the column width used for line-1 truncation decisions. Useful for debugging. |
| `INSTALL_DIR` (installer) | `$HOME/.claude/cc-statusline` | Where the installer copies files. |
| `LABEL_PREFIX` (installer) | `com.${USER}.cc-statusline` | LaunchAgent label prefix (only relevant to the legacy `--with-feeds` flag). |

### Color thresholds

Edit `make_bar` calls in `statusline.sh`:

```bash
ctx_bar=$(make_bar "$ctx_used" 50 60)        # context: yellow ≥50, red ≥60
seven_bar=$(make_bar "$seven_day_pct")       # 7d rate: yellow ≥70 (default), red ≥90 (default)
fable_bar=$(make_bar "$fable_weekly_pct")    # Fable weekly: yellow ≥70 (default), red ≥90 (default)
```

### Line-1 width truncation

The script walks up the process tree to find the host terminal's real width (Claude Code passes a narrow ~67-col inner pty to the statusLine subprocess, which is misleading). That width then drives how aggressively line 1 shortens `[model]`, `📁 dir`, and `🪄 last-skill`:

| Width | Behavior |
|---|---|
| ≥ 140 cols | Full model name, up to 3 path components, untrimmed skill name |
| 90–139 | Strips `(...)` from the model name, collapses dir to `…/basename`, caps skill at 24 chars |
| < 90 | Short model word only, basename-only dir, caps skill at 14 chars |

Lines 2 and 3 aren't width-dependent — they always print in full.

---

## Smoke-test locally

```bash
bash statusline.sh < examples/sample-input.json
```

You should see two lines with the gauges populated. To force a specific terminal width:

```bash
CLAUDE_STATUSLINE_COLS=120 bash statusline.sh < examples/sample-input.json
```

---

## How it talks to Claude Code

Claude Code invokes the statusLine command on every UI tick, piping a JSON payload to stdin. The fields this script reads:

```jsonc
{
  "model":          { "display_name": "Opus 4.7 (1M context)" },
  "workspace":      { "current_dir": "/abs/path/to/cwd" },
  "transcript_path": "/abs/path/to/transcript.jsonl",
  "session_id":     "uuid",
  "context_window": { "used_percentage": 42 },
  "rate_limits":    { "seven_day": { "used_percentage": 18 } },
  "cost": {
    "total_cost_usd":      0.42,
    "total_duration_ms":   725000,
    "total_lines_added":   120,
    "total_lines_removed": 33
  }
}
```

Anything missing renders as `—` or is omitted. Output goes to stdout; exit code is ignored.

Note: `cost.total_cost_usd` is present in the stdin payload but intentionally not read — the `$X.XX` segment shows a Fable-only figure recomputed from `transcript_path` instead. See [Fable-only session cost](#fable-only-session-cost).

The "last skill" segment also tails the last ~500 lines of `transcript_path` looking for `tool_use` entries with `name == "Skill"`. The "task progress" segment reads `~/.claude/tasks/<session_id>/*.json` (Claude Code's TaskCreate state).

---

## Fable weekly gauge

Claude Code's stdin payload only exposes `rate_limits.seven_day` (the overall weekly limit) — it does not include a Fable-5-specific number. That figure only exists in the OAuth usage API, so the `📖` gauge is fetched out-of-band instead of parsed from stdin:

1. On each invocation, the script reads `~/.claude/cache/fable-weekly.txt` (a single integer, 0–100) if present and renders the gauge from it immediately — no network call on the hot path.
2. If that cache is missing or older than 300s, a background subshell is forked (`( ... ) & disown`) to refresh it; the visible statusLine for *this* tick is never blocked on the network.
3. The refresher reads the OAuth access token from `~/.claude/.credentials.json` (`.claudeAiOauth.accessToken`), calls:
   ```bash
   curl -s --max-time 5 \
     -H "Authorization: Bearer $token" \
     -H "Content-Type: application/json" \
     -H "anthropic-beta: oauth-2025-04-20" \
     "https://api.anthropic.com/api/oauth/usage"
   ```
   and extracts the percent via:
   ```bash
   jq -r '.limits[]? | select(.kind=="weekly_scoped" and .scope.model.display_name=="Fable") | .percent'
   ```
4. The result is written to a `.tmp.$$` file and `mv`'d into place atomically. A `mkdir`-based lock (`fable-weekly.lock`, self-clearing after 60s if stale) prevents concurrent refreshers from racing.
5. Any failure at any step (no credentials file, no token, curl error, non-numeric response) silently leaves the existing cache untouched — the gauge just shows the last known value, or hides itself if there's never been a successful fetch.

Nothing in this path is written to git or logged; only the single cached percentage touches disk.

---

## Fable-only session cost

`cost.total_cost_usd` in the stdin payload is Claude Code's dollar-equivalent for the *whole* session, blended across every model used — main loop plus any subagents. For a workflow where subagents run on a subscription-included model (e.g. Sonnet, no extra charge) and only the main-loop model is Fable 5 (which can incur real overage billing), that blended total is misleading: it looks like it's costing money even when the subagent share is actually free. The `$X.XX` segment instead shows a Fable-5-only figure, recomputed locally:

1. On each invocation, the script reads `~/.claude/cache/fable-cost-<session_id>.txt` (a cached dollar amount) if present — no transcript parsing on the hot path.
2. If that cache is missing or older than 15s, a background subshell is forked to refresh it, same non-blocking pattern as the weekly gauge above.
3. The refresher streams `transcript_path` (the session's local JSONL transcript) through `jq`:
   - Filters to `type == "assistant"` entries.
   - **Dedupes by `message.id`** first — Claude Code re-emits the same message (identical `usage` numbers) as its content blocks stream in, so a turn can appear 2-3x in the file; summing without dedup inflates the cost 2-3x.
   - Keeps only turns where `message.model` starts with `claude-fable-5` (covers both Fable 5 and any Fable-5-family variant, e.g. Mythos 5, which share pricing).
   - Sums `input_tokens`, `output_tokens`, `cache_read_input_tokens`, and the two `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens` cache-write buckets separately.
   - Converts to dollars using Claude Fable 5's official per-token pricing (verified 2026-07-16 against [platform.claude.com/docs/en/about-claude/pricing](https://platform.claude.com/docs/en/about-claude/pricing)):

     | Token type | Price |
     |---|---|
     | Input | $10 / MTok |
     | 5-minute cache write | $12.50 / MTok |
     | 1-hour cache write | $20 / MTok |
     | Cache read (hit) | $1 / MTok |
     | Output | $50 / MTok |

4. The result is written atomically (`.tmp.$$` + `mv`) behind a per-session `mkdir` lock (self-clearing after 30s if stale), identical mechanics to the weekly gauge.
5. If Fable was never used this session, or the transcript/cache isn't ready yet, the segment shows `$0.00` rather than hiding — it's a real "$0 spent on Fable so far," not a missing value.

If Anthropic changes Fable 5's pricing, update the five constants in the `jq` formula inside the "Fable-only session cost" block in `statusline.sh` — they aren't fetched from anywhere.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Statusline doesn't appear | settings.json `statusLine.command` path wrong → check `bash <that path>` works in a shell |
| Bars never colored / always green | `ctx_used` and `seven_day_pct` are `null` in stdin — your Claude Code may be older; the script just hides those segments |
| `🪄 —` always | Transcript path empty or no `Skill` tool calls yet this session |
| `📖` gauge never appears | First run always shows nothing (cache not populated yet) — wait ~5s for the background fetch, or check `~/.claude/.credentials.json` exists and `curl` can reach `api.anthropic.com`; see [Fable weekly gauge](#fable-weekly-gauge) |
| `$X.XX` always shows `$0.00` | Correct if Fable wasn't used this session. If Fable *was* used: check `transcript_path` is non-empty and readable, and wait ~15s for the first background refresh; see [Fable-only session cost](#fable-only-session-cost) |
| Line 3 (`F n.../c...`) never appears, or all-zero | First run always shows nothing (cache not populated yet) — wait ~20s. If still all-zero, check `<transcript_dir>/<session_id>/subagents/` actually exists for sessions that used subagents; see [Per-model token breakdown](#per-model-token-breakdown) |
| Width detection wrong | Set `CLAUDE_STATUSLINE_COLS` to override |

---

## Known Issues

### Scrollback duplication during long thinking sessions

**Symptom**: On Claude Code v2.1.x (verified on 2.1.119), long-thinking responses (e.g. `xhigh` effort, multi-minute) cause the entire TUI viewport — welcome banner, prompt line, assistant message, status bar — to be re-emitted to primary scrollback 2–5 times at slightly different column widths. The session jsonl is unaffected — pure rendering artifact.

This affects any non-trivial multi-line statusline (including this one); it is **not specific to this repo**.

**Root cause** (upstream): Claude Code v2.1.101 introduced a regression where SIGWINCH / relayout events leak the entire transcript into primary scrollback instead of redrawing in place. Statusline updates (which fire on every spinner tick during thinking) count as relayout triggers. Tracked in [anthropics/claude-code#46834](https://github.com/anthropics/claude-code/issues/46834), [#52547](https://github.com/anthropics/claude-code/issues/52547), [#51828](https://github.com/anthropics/claude-code/issues/51828).

**Workaround**: set `CLAUDE_CODE_NO_FLICKER=1` in `~/.claude/settings.json` env section:

```json
{
  "env": {
    "CLAUDE_CODE_NO_FLICKER": "1"
  }
}
```

This opts into Claude Code's alt-screen rendering with virtualized scrollback (documented in upstream `CHANGELOG.md`), restoring the pre-2.1.101 behavior.

**Tradeoff**: alt-screen mode clears the visible viewport on Claude Code exit, so terminal scrollback no longer holds conversation history. Use `/resume` or `~/.claude/projects/<project>/<session>.jsonl` to review past sessions.

Once Anthropic resolves the upstream regression, this env var can be removed.

---

## Repo layout

```
.
├── statusline.sh                # the main script (deps: jq, bash, curl)
├── feeds/                       # legacy — no longer read by statusline.sh
│   ├── fetch-blog.sh
│   ├── fetch-hn.sh
│   ├── fetch-trending.sh
│   ├── extract_blog.py
│   └── sanitize_title.py
├── launchagents/                # macOS plist templates (legacy, --with-feeds only)
│   ├── com.example.cc-statusline-blog.plist
│   ├── com.example.cc-statusline-hn.plist
│   └── com.example.cc-statusline-trending.plist
├── examples/
│   └── sample-input.json        # for local smoke-testing
├── install.sh                   # installer (--with-feeds [legacy], --patch-settings, --uninstall)
├── LICENSE
└── README.md
```

---

## License

MIT — see [LICENSE](LICENSE).
