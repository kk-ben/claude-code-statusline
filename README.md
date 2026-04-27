# claude-code-statusline

A rich 2-line statusLine for [Claude Code](https://claude.com/claude-code) with smooth Unicode gauges, git status, last-invoked skill, task progress, cost / duration, and optional live feeds (Anthropic blog, Hacker News top, GitHub trending).

```
[Opus 4.7] 📁 …/cc-statusline | 🌿 main | 🪄 superpowers:brainstorming
🤖████▌░░░░░ 42% │ 📅█▊░░░░░░░ 18% │ +120 -33 │ ✓ ✓2/5 │ $0.42 ⏱12m05s
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
| `+N -M` | lines added / removed in this session |
| `●N` / `✓` | git dirty file count, or green check if clean |
| `✓N/M` | TaskCreate progress (completed / total) for the current `session_id` |
| `$X.XX ⏱H:MMmSSs` | session cost and total duration |
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

The "last skill" segment also tails the last ~500 lines of `transcript_path` looking for `tool_use` entries with `name == "Skill"`. The "task progress" segment reads `~/.claude/tasks/<session_id>/*.json` (Claude Code's TaskCreate state).

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Statusline doesn't appear | settings.json `statusLine.command` path wrong → check `bash <that path>` works in a shell |
| Bars never colored / always green | `ctx_used` and `seven_day_pct` are `null` in stdin — your Claude Code may be older; the script just hides those segments |
| Feeds never appear | Cache files missing/empty → run the fetch scripts manually to confirm they reach the network |
| `🪄 —` always | Transcript path empty or no `Skill` tool calls yet this session |
| Width detection wrong | Set `CLAUDE_STATUSLINE_COLS` to override |
| Garbled `…033[0m` after a feed link | Old version. The current script handles raw ESC vs `%b` correctly. Reinstall. |

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
