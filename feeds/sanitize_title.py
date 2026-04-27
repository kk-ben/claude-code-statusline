#!/usr/bin/env python3
"""Sanitize a feed title from stdin and trim to a display-cell budget.

- Strips markdown emphasis (**bold**, *italic*), backticks, quotes,
  trailing citations like [1], leading/trailing whitespace.
- Counts East Asian Wide / Fullwidth / Ambiguous as 2 cells, others as 1.
- Truncates with '…' when the cell budget is exceeded.
"""
import sys, re, unicodedata

BUDGET = 42  # display cells for the title portion

raw = sys.stdin.read()
raw = re.sub(r'\*{1,3}', '', raw)
raw = raw.replace('`', '')
raw = re.sub(r'\s*\[\d+\]', '', raw)
raw = raw.replace('\r', '').replace('\n', ' ').strip()
# strip matching outer quotes if present
for a, b in [('"', '"'), ("'", "'"), ('「', '」'), ('『', '』'),
             ('“', '”'), ('‘', '’')]:
    if raw.startswith(a) and raw.endswith(b) and len(raw) >= 2:
        raw = raw[1:-1].strip()
        break

out = []
cells = 0
for ch in raw:
    w = 2 if unicodedata.east_asian_width(ch) in ('W', 'F', 'A') else 1
    if cells + w > BUDGET:
        out.append('…')
        break
    out.append(ch)
    cells += w

sys.stdout.write(''.join(out))
