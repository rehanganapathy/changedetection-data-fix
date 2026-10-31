#!/usr/bin/env python3
"""
Reproduces the "watches/fields disappear" bug on a changedetection.io instance
that is reachable without a password.

It behaves like any ordinary web crawler, link-preview bot or uptime/SEO scanner:
it follows every same-origin <a href> with plain GET requests. It never submits
forms, never runs JavaScript and never sends a password.

Usage (ONLY against your own test instance, never someone else's):
    python3 crawler_repro.py http://127.0.0.1:5000
"""
import argparse
import re
import sys
import urllib.parse
import urllib.request

HREF = re.compile(r'href="([^"]+)"')


def get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {"User-Agent": "generic-crawler/1.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode("utf-8", "replace")


UUID_RE = re.compile(r"/edit/([0-9a-f-]{36})")


def list_watches(base):
    # Read the watch list from the dashboard itself (no API key needed,
    # because the crawl may rotate the API key via GET /settings/reset-api-key).
    return sorted(set(UUID_RE.findall(get(base + "/"))))


def crawl(base, max_pages):
    host = urllib.parse.urlparse(base).netloc
    seen, queue, hits = set(), [base + "/"], []
    while queue and len(seen) < max_pages:
        url = queue.pop(0)
        if url in seen:
            continue
        seen.add(url)
        if re.search(r"/(delete|toggle-all|clear_history|delete_all|reset-api-key)|[?&]op=", url):
            hits.append(url)
        try:
            html = get(url)
        except Exception:
            continue
        for href in HREF.findall(html):
            nxt = urllib.parse.urldefrag(urllib.parse.urljoin(url, href.replace("&amp;", "&")))[0]
            p = urllib.parse.urlparse(nxt)
            if p.netloc == host and "/static/" not in p.path and nxt not in seen:
                queue.append(nxt)
    return seen, hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("--max-pages", type=int, default=300)
    a = ap.parse_args()
    base = a.base.rstrip("/")

    before = list_watches(base)
    print(f"Watches BEFORE crawl: {len(before)}")

    seen, hits = crawl(base, a.max_pages)
    print(f"\nCrawler fetched {len(seen)} URLs with plain GET. State-changing URLs it hit:")
    for h in hits:
        print(f"  GET {h}")

    after = list_watches(base)
    print(f"\nWatches AFTER crawl: {len(after)}")
    lost = set(before) - set(after)
    for u in sorted(lost):
        print(f"  LOST watch {u}")
    sys.exit(1 if lost else 0)


if __name__ == "__main__":
    main()
