#!/usr/bin/env python3
"""Extract the latest Claude blog post (slug + title) from claude.com/blog HTML.

Usage: extract_blog.py <html_file>
Output: <slug>|<title>   (one line, '|' separator)
Exit 1 if no post link found.
"""
import re, html, sys

if len(sys.argv) < 2:
    sys.exit(1)
h = open(sys.argv[1], 'r', encoding='utf-8', errors='ignore').read()

# Each post card renders as:
#   <a ... data-cta-copy="TITLE" ... data-cta="Blog page" ... href="/blog/<slug>"...>
# DOM order matches published-newest-first, so the first match is the latest post.
pat = re.compile(
    r'<a[^>]*?data-cta-copy="([^"]+)"'
    r'[^>]*?data-cta="Blog page"'
    r'[^>]*?href="(/blog/[a-z0-9-]+)"',
    re.DOTALL,
)
m = pat.search(h)
if not m:
    sys.exit(1)

title = html.unescape(m.group(1)).replace('|', '/').strip()
slug = m.group(2).strip()
print(f"{slug}|{title}")
