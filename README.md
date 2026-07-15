# claude-code-statusline

A rich 2-line statusLine for [Claude Code](https://claude.com/claude-code) with smooth Unicode gauges, git status, last-invoked skill, task progress, cost / duration, and optional live feeds (Anthropic blog, Hacker News top, GitHub trending).

```
[Opus 4.7] 📁 …/cc-statusline | 🌿 main | 🪄 superpowers:brainstorming
🤖████▌░░░░░ 42% │ 📅█▊░░░░░░░ 18% │ 📖 █▋░░░░░░░░ 17% │ +120 -33 │ ✓ ✓2/5 │ $0.42 ⏱12m05s
📝 Introducing connectors for everyday Claude  │  🔥 I bought Friendster for $30k …  │  🐙 op7418/guizang-ppt-skill ★2.9k
```

The third line shrinks/expands automatically based on terminal width — see [Layout bands](#layout-bands).

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
| Feeds (optional) | latest Anthropic blog post, current HN top story, top GitHub repo created in last 7 days — all OSC 8 hyperlinks (Cmd+click in iTerm2 / WezTerm / kitty / new Terminal.app) |

---

## Requirements

- **bash** ≥ 3.2 (macOS default works)
- **jq** ≥ 1.5 — `brew install jq` on macOS, `apt install jq` on Debian/Ubuntu
- **git** (only used inside git repos)
- **python3** (only required for the feeds; statusline core works without it)
- **macOS** if you want the bundled LaunchAgents for hourly feed refresh; Linux works with cron (sample below)

---

## Quick install

```bash
git clone https://github.com/<you>/claude-code-statusline.git
cd claude-code-statusline

# Core only (no feeds, prints settings.json snippet to stdout)
bash install.sh

# Full set: core + feeds + macOS LaunchAgents + auto-patch settings.json
bash install.sh --with-feeds --patch-settings
```

The installer:

1. Copies `statusline.sh` to `$HOME/.claude/cc-statusline/statusline.sh` (override with `INSTALL_DIR=...`)
2. With `--with-feeds`: copies `feeds/*` and registers three macOS LaunchAgents labelled `com.${USER}.cc-statusline-{blog,hn,trending}` (override label prefix with `LABEL_PREFIX=...`)
3. With `--patch-settings`: rewrites `$HOME/.claude/settings.json` `statusLine` block (a timestamped backup is kept)

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

3. (Optional) Copy `feeds/*` somewhere, run them once to seed the cache, and schedule them hourly. Cache files are read from `$HOME/.claude/cache/latest-{blog,hn,trending}.txt` — missing files are silently skipped.

---

## Feeds: optional live content

The bottom row reads three cache files. If they're absent or empty, that part of the line just disappears.

### Where the cache lives

```
$HOME/.claude/cache/latest-blog.txt        # Anthropic / Claude blog post
$HOME/.claude/cache/latest-hn.txt          # Hacker News top story
$HOME/.claude/cache/latest-trending.txt    # Top GitHub repo (created in last 7d)
```

Each file is a single line containing an OSC 8 hyperlink — Cmd+click works in any terminal that implements [OSC 8](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda) (iTerm2, WezTerm, kitty, recent macOS Terminal.app, recent GNOME Terminal, etc.).

### Manually seeding the cache

```bash
bash feeds/fetch-blog.sh
bash feeds/fetch-hn.sh
bash feeds/fetch-trending.sh
```

### macOS — LaunchAgents (installed automatically by `--with-feeds`)

Three plists are installed under `~/Library/LaunchAgents/`:

```
com.${USER}.cc-statusline-blog.plist
com.${USER}.cc-statusline-hn.plist
com.${USER}.cc-statusline-trending.plist
```

Each runs the corresponding fetch script every 3600 seconds. To check status:

```bash
launchctl list | grep cc-statusline
tail -f ~/.claude/cache/latest-blog.log
```

To remove them: `bash install.sh --uninstall`.

### Linux / WSL — cron

```cron
# crontab -e
0 * * * * /path/to/feeds/fetch-blog.sh     >/dev/null 2>&1
5 * * * * /path/to/feeds/fetch-hn.sh       >/dev/null 2>&1
10 * * * * /path/to/feeds/fetch-trending.sh >/dev/null 2>&1
```

### Optional: title translation (any language)

The default is **English — no setup needed, no `claude` CLI required**. If you want titles in your own language, set `STATUSLINE_FEED_LANG` in the environment that runs the fetch scripts. Built-in language codes:

| Code | Language | Code | Language |
|---|---|---|---|
| `ja` | Japanese | `pt` | Portuguese |
| `zh` | Simplified Chinese | `ru` | Russian |
| `ko` | Korean | `ar` | Arabic |
| `fr` | French | `de` | German |
| `es` | Spanish | `en` (default) | no translation |

Other codes are passed straight through to the translation prompt (e.g. `STATUSLINE_FEED_LANG=Vietnamese` works too).

Translation requires the `claude` CLI on `$PATH` (uses Haiku with all tools disabled — fast and cheap). If the CLI is missing or returns nothing, the script silently falls back to the original English title.

To enable for a LaunchAgent, add this to the plist:

```xml
<key>EnvironmentVariables</key>
<dict>
  <key>STATUSLINE_FEED_LANG</key><string>ja</string>
</dict>
```

For cron, prefix the command: `STATUSLINE_FEED_LANG=zh /path/to/feeds/fetch-blog.sh`.

---

### Customize the feeds

The three default feeds (Anthropic blog, HN top, GitHub trending) are **just examples** — swap them for whatever you actually read.

- **Change the URL only** — open `feeds/fetch-blog.sh`, `feeds/fetch-hn.sh`, or `feeds/fetch-trending.sh` and replace the URL near the top. The OSC 8 hyperlink format and cache file path stay the same, so `statusline.sh` keeps reading them.
- **Different parsing** — `fetch-blog.sh` uses `feeds/extract_blog.py` to scrape `claude.com/blog`. Replace it with your own one-liner that prints `<slug-or-path>|<title>`.
- **Drop a feed entirely** — just don't run/install the corresponding fetcher. Missing cache files are silently skipped.
- **Add a fourth feed** — write a new `fetch-<name>.sh` that writes `$HOME/.claude/cache/latest-<name>.txt`, then add that path to the `for feed_file in ...` loop in `statusline.sh`.

The cache file format is:

```
<ESC>]8;;<URL><ESC>\<emoji> <title><ESC>]8;;<ESC>\
```

A literal example (newlines added for readability — the real file is one line):

```
\033]8;;https://example.com/post\
🌟 Some clickable headline
\033]8;;\
```

---

## Configuration

| Env var | Default | Effect |
|---|---|---|
| `CLAUDE_STATUSLINE_COLS` | (auto-detected) | Force the column width used for layout decisions. Useful for debugging. |
| `STATUSLINE_FEED_LANG` | `en` | Target language for feed title translation (`ja`, `zh`, `ko`, `fr`, `es`, `de`, `pt`, `ru`, `ar`, or any other language name). Requires the `claude` CLI; falls back to English silently. |
| `INSTALL_DIR` (installer) | `$HOME/.claude/cc-statusline` | Where the installer copies files. |
| `LABEL_PREFIX` (installer) | `com.${USER}.cc-statusline` | LaunchAgent label prefix. |

### Color thresholds

Edit `make_bar` calls in `statusline.sh`:

```bash
ctx_bar=$(make_bar "$ctx_used" 50 60)        # context: yellow ≥50, red ≥60
seven_bar=$(make_bar "$seven_day_pct")       # 7d rate: yellow ≥70 (default), red ≥90 (default)
fable_bar=$(make_bar "$fable_weekly_pct")    # Fable weekly: yellow ≥70 (default), red ≥90 (default)
```

### Layout bands

The script walks up the process tree to find the host terminal's real width (Claude Code passes a narrow ~67-col inner pty to the statusLine subprocess, which is misleading). Layout is then chosen by width:

| Width | Layout |
|---|---|
| ≥ 210 cols | 2 lines (metrics + all 3 feeds inline) |
| 140–209 | 3 lines (metrics / all feeds together) |
| 90–139 | 4 lines (metrics / blog / HN+trending) |
| < 90 | 5 lines (each feed on its own line) |

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
| Feeds never appear | Cache files missing/empty → run the fetch scripts manually to confirm they reach the network |
| `🪄 —` always | Transcript path empty or no `Skill` tool calls yet this session |
| `📖` gauge never appears | First run always shows nothing (cache not populated yet) — wait ~5s for the background fetch, or check `~/.claude/.credentials.json` exists and `curl` can reach `api.anthropic.com`; see [Fable weekly gauge](#fable-weekly-gauge) |
| `$X.XX` always shows `$0.00` | Correct if Fable wasn't used this session. If Fable *was* used: check `transcript_path` is non-empty and readable, and wait ~15s for the first background refresh; see [Fable-only session cost](#fable-only-session-cost) |
| Width detection wrong | Set `CLAUDE_STATUSLINE_COLS` to override |
| Garbled `…033[0m` after a feed link | Old version. The current script handles raw ESC vs `%b` correctly. Reinstall. |

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
├── statusline.sh                # the main script (no deps beyond jq + bash)
├── feeds/
│   ├── fetch-blog.sh            # Anthropic blog → cache file
│   ├── fetch-hn.sh              # HN top story → cache file
│   ├── fetch-trending.sh        # GitHub trending → cache file
│   ├── extract_blog.py          # parses claude.com/blog HTML
│   └── sanitize_title.py        # trims to display-cell budget
├── launchagents/                # macOS plist templates (placeholders)
│   ├── com.example.cc-statusline-blog.plist
│   ├── com.example.cc-statusline-hn.plist
│   └── com.example.cc-statusline-trending.plist
├── examples/
│   └── sample-input.json        # for local smoke-testing
├── install.sh                   # installer (--with-feeds, --patch-settings, --uninstall)
├── LICENSE
└── README.md
```

---

## License

MIT — see [LICENSE](LICENSE).
