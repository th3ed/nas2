#!/usr/bin/env python3
"""FreshRSS Google Reader API client for Hermes Agent.

Stdlib-only (no pip dependencies). Provides subcommands for feed management,
article retrieval, and state changes via the Google Reader compatible API.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
CACHE_DIR = Path("/tmp/freshrss_cache")


def get_env(name):
    val = os.environ.get(name)
    if not val:
        print(f"Error: {name} environment variable is not set.", file=sys.stderr)
        sys.exit(1)
    return val


class HTMLStripper(HTMLParser):
    """Strip HTML tags, collapse whitespace, decode entities."""

    def __init__(self):
        super().__init__()
        self._parts = []
        self._skip = False

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skip = True
        elif tag in ("br", "p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "tr"):
            self._parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skip = False
        elif tag in ("p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6"):
            self._parts.append("\n")

    def handle_data(self, data):
        if not self._skip:
            self._parts.append(data)

    def get_text(self):
        text = "".join(self._parts)
        lines = []
        for line in text.splitlines():
            collapsed = " ".join(line.split())
            if collapsed:
                lines.append(collapsed)
        return "\n".join(lines)


def strip_html(html_content):
    stripper = HTMLStripper()
    stripper.feed(html_content or "")
    return stripper.get_text()


# --- Auth ---

def _cache_path(name):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    return CACHE_DIR / name


def _read_cache(name):
    p = _cache_path(name)
    if p.exists():
        return p.read_text().strip()
    return None


def _write_cache(name, value):
    p = _cache_path(name)
    p.write_text(value)


def _clear_cache(name):
    p = _cache_path(name)
    if p.exists():
        p.unlink()


def login(base_url, user, password):
    """Authenticate and return auth token."""
    url = f"{base_url}/api/greader.php/accounts/ClientLogin"
    data = urllib.parse.urlencode({"Email": user, "Passwd": password}).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode()
    except urllib.error.HTTPError as e:
        print(f"Error: Login failed (HTTP {e.code}). Check FRESHRSS_URL, FRESHRSS_USER, FRESHRSS_API_PASSWORD.", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Error: Cannot reach {base_url}: {e.reason}", file=sys.stderr)
        sys.exit(1)

    for line in body.splitlines():
        if line.startswith("Auth="):
            token = line[5:]
            _write_cache("auth_token", token)
            return token

    print("Error: Login response did not contain Auth token.", file=sys.stderr)
    sys.exit(1)


def get_auth_token():
    """Get cached auth token or login fresh."""
    base_url = get_env("FRESHRSS_URL").rstrip("/")
    user = get_env("FRESHRSS_USER")
    password = get_env("FRESHRSS_API_PASSWORD")

    cached = _read_cache("auth_token")
    if cached:
        return cached, base_url

    token = login(base_url, user, password)
    return token, base_url


def get_write_token(auth_token, base_url):
    """Fetch a short-lived write token for mutations."""
    cached = _read_cache("write_token")
    if cached:
        parts = cached.split("\n", 1)
        if len(parts) == 2:
            ts, token = parts
            if time.time() - float(ts) < 1500:  # 25 min TTL
                return token

    url = f"{base_url}/api/greader.php/reader/api/0/token"
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"GoogleLogin auth={auth_token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            token = resp.read().decode().strip()
    except urllib.error.HTTPError as e:
        print(f"Error: Failed to get write token (HTTP {e.code}).", file=sys.stderr)
        sys.exit(1)

    _write_cache("write_token", f"{time.time()}\n{token}")
    return token


# --- API helpers ---

def api_get(endpoint, params=None, retry_auth=True):
    """GET from the Google Reader API. Returns parsed JSON."""
    auth_token, base_url = get_auth_token()
    url = f"{base_url}/api/greader.php/reader/api/0/{endpoint}"
    if params:
        url += "?" + urllib.parse.urlencode(params)

    req = urllib.request.Request(url)
    req.add_header("Authorization", f"GoogleLogin auth={auth_token}")

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 401 and retry_auth:
            _clear_cache("auth_token")
            _clear_cache("write_token")
            return api_get(endpoint, params, retry_auth=False)
        print(f"Error: API request failed (HTTP {e.code}): {endpoint}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Error: Cannot reach API: {e.reason}", file=sys.stderr)
        sys.exit(1)


def api_post(endpoint, data, retry_auth=True):
    """POST to the Google Reader API. Returns response body."""
    auth_token, base_url = get_auth_token()
    write_token = get_write_token(auth_token, base_url)

    url = f"{base_url}/api/greader.php/reader/api/0/{endpoint}"
    post_data = {**data, "T": write_token}
    encoded = urllib.parse.urlencode(post_data, doseq=True).encode()

    req = urllib.request.Request(url, data=encoded, method="POST")
    req.add_header("Authorization", f"GoogleLogin auth={auth_token}")

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read().decode()
    except urllib.error.HTTPError as e:
        if e.code == 401 and retry_auth:
            _clear_cache("auth_token")
            _clear_cache("write_token")
            return api_post(endpoint, data, retry_auth=False)
        print(f"Error: API POST failed (HTTP {e.code}): {endpoint}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Error: Cannot reach API: {e.reason}", file=sys.stderr)
        sys.exit(1)


# --- Subcommands ---

def cmd_list_feeds(args):
    result = api_get("subscription/list", {"output": "json"})
    feeds = []
    for sub in result.get("subscriptions", []):
        categories = [c.get("label", "") for c in sub.get("categories", [])]
        feeds.append({
            "id": sub.get("id", ""),
            "title": sub.get("title", ""),
            "url": sub.get("url", ""),
            "site_url": sub.get("htmlUrl", ""),
            "categories": categories,
        })
    print(json.dumps({"feeds": feeds, "count": len(feeds)}, indent=2))


def cmd_list_categories(args):
    result = api_get("tag/list", {"output": "json"})
    categories = []
    for tag in result.get("tags", []):
        tag_id = tag.get("id", "")
        if "/label/" in tag_id:
            label = tag_id.split("/label/")[-1]
            categories.append({"id": tag_id, "label": label})
    print(json.dumps({"categories": categories, "count": len(categories)}, indent=2))


def cmd_unread_counts(args):
    result = api_get("unread-count", {"output": "json"})
    counts = []
    for item in result.get("unreadcounts", []):
        feed_id = item.get("id", "")
        if feed_id.startswith("feed/") or "/label/" in feed_id:
            counts.append({
                "id": feed_id,
                "count": int(item.get("count", 0)),
                "newest_item_timestamp": item.get("newestItemTimestampUsec", ""),
            })
    counts.sort(key=lambda x: x["count"], reverse=True)
    total = sum(c["count"] for c in counts)
    print(json.dumps({"unread_counts": counts, "total_unread": total}, indent=2))


def cmd_articles(args):
    params = {"output": "json", "n": str(args.count)}

    if args.unread_only:
        params["xt"] = "user/-/state/com.google/read"
    if args.starred:
        stream = "user/-/state/com.google/starred"
    elif args.feed:
        stream = args.feed if args.feed.startswith("feed/") else f"feed/{args.feed}"
    elif args.category:
        stream = f"user/-/label/{args.category}"
    else:
        stream = "user/-/state/com.google/reading-list"

    if args.since:
        params["ot"] = str(args.since)
    if args.oldest_first:
        params["r"] = "o"
    if args.continuation:
        params["c"] = args.continuation

    endpoint = f"stream/contents/{urllib.parse.quote(stream, safe='')}"
    result = api_get(endpoint, params)

    items = []
    for entry in result.get("items", []):
        content = entry.get("summary", {}).get("content", "")
        snippet = strip_html(content)[:200]
        categories = entry.get("categories", [])
        is_read = "user/-/state/com.google/read" in categories
        is_starred = "user/-/state/com.google/starred" in categories

        items.append({
            "id": entry.get("id", ""),
            "title": entry.get("title", ""),
            "feed_title": entry.get("origin", {}).get("title", ""),
            "author": entry.get("author", ""),
            "published": entry.get("published", 0),
            "url": next((a["href"] for a in entry.get("alternate", []) if a.get("href")), ""),
            "summary_snippet": snippet,
            "is_read": is_read,
            "is_starred": is_starred,
        })

    output = {"items": items, "count": len(items)}
    if result.get("continuation"):
        output["continuation"] = result["continuation"]
    print(json.dumps(output, indent=2))


def cmd_article_content(args):
    # The Google Reader API doesn't support fetching by single item ID directly via
    # stream/contents. We use the item IDs endpoint instead.
    auth_token, base_url = get_auth_token()
    url = f"{base_url}/api/greader.php/reader/api/0/stream/items/contents"
    post_data = urllib.parse.urlencode({"i": args.id, "output": "json"}).encode()

    req = urllib.request.Request(url, data=post_data, method="POST")
    req.add_header("Authorization", f"GoogleLogin auth={auth_token}")

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 401:
            _clear_cache("auth_token")
            print("Error: Authentication failed. Retry the command.", file=sys.stderr)
            sys.exit(1)
        print(f"Error: Failed to fetch article (HTTP {e.code}).", file=sys.stderr)
        sys.exit(1)

    entries = result.get("items", [])
    if not entries:
        print("Error: Article not found.", file=sys.stderr)
        sys.exit(1)

    entry = entries[0]
    content_html = entry.get("summary", {}).get("content", "")
    title = entry.get("title", "")
    author = entry.get("author", "")
    published = entry.get("published", 0)
    article_url = next((a["href"] for a in entry.get("alternate", []) if a.get("href")), "")
    feed_title = entry.get("origin", {}).get("title", "")

    if args.text:
        pub_str = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(published)) if published else "unknown"
        text_content = strip_html(content_html)
        output = f"Title: {title}\nAuthor: {author}\nPublished: {pub_str}\nURL: {article_url}\nFeed: {feed_title}\n\n{text_content}"
        print(output)
    else:
        print(json.dumps({
            "id": entry.get("id", ""),
            "title": title,
            "author": author,
            "published": published,
            "url": article_url,
            "feed_title": feed_title,
            "content_html": content_html,
            "content_text": strip_html(content_html),
        }, indent=2))


def cmd_mark_read(args):
    result = api_post("edit-tag", {
        "i": args.ids,
        "a": "user/-/state/com.google/read",
    })
    print(json.dumps({"status": "ok", "marked_read": args.ids}))


def cmd_mark_unread(args):
    result = api_post("edit-tag", {
        "i": args.ids,
        "r": "user/-/state/com.google/read",
    })
    print(json.dumps({"status": "ok", "marked_unread": args.ids}))


def cmd_star(args):
    result = api_post("edit-tag", {
        "i": args.ids,
        "a": "user/-/state/com.google/starred",
    })
    print(json.dumps({"status": "ok", "starred": args.ids}))


def cmd_unstar(args):
    result = api_post("edit-tag", {
        "i": args.ids,
        "r": "user/-/state/com.google/starred",
    })
    print(json.dumps({"status": "ok", "unstarred": args.ids}))


def cmd_mark_all_read(args):
    if not args.feed and not args.category:
        print("Error: --feed or --category is required for mark-all-read.", file=sys.stderr)
        sys.exit(1)

    if args.feed:
        stream = args.feed if args.feed.startswith("feed/") else f"feed/{args.feed}"
    else:
        stream = f"user/-/label/{args.category}"

    # Google Reader API expects timestamp in microseconds
    ts = str(int(time.time() * 1_000_000))
    result = api_post("mark-all-as-read", {"s": stream, "ts": ts})
    print(json.dumps({"status": "ok", "marked_all_read": stream}))


def cmd_add_feed(args):
    data = {"ac": "subscribe", "s": f"feed/{args.url}"}
    if args.category:
        data["a"] = f"user/-/label/{args.category}"
    if args.title:
        data["t"] = args.title

    result = api_post("subscription/edit", data)
    print(json.dumps({"status": "ok", "subscribed": args.url, "category": args.category or None}))


def cmd_remove_feed(args):
    feed_id = args.feed_id if args.feed_id.startswith("feed/") else f"feed/{args.feed_id}"
    result = api_post("subscription/edit", {"ac": "unsubscribe", "s": feed_id})
    print(json.dumps({"status": "ok", "unsubscribed": feed_id}))


# --- CLI ---

def main():
    parser = argparse.ArgumentParser(description="FreshRSS Google Reader API client")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # list-feeds
    subparsers.add_parser("list-feeds", help="List all subscribed feeds")

    # list-categories
    subparsers.add_parser("list-categories", help="List all feed categories")

    # unread-counts
    subparsers.add_parser("unread-counts", help="Show unread counts per feed")

    # articles
    p = subparsers.add_parser("articles", help="Fetch articles")
    p.add_argument("--feed", help="Filter by feed ID")
    p.add_argument("--category", help="Filter by category label")
    p.add_argument("--unread-only", action="store_true", help="Only unread articles")
    p.add_argument("--starred", action="store_true", help="Only starred articles")
    p.add_argument("--count", type=int, default=20, help="Number of articles (default: 20)")
    p.add_argument("--since", type=int, help="Only articles newer than this Unix timestamp")
    p.add_argument("--oldest-first", action="store_true", help="Oldest first order")
    p.add_argument("--continuation", help="Pagination continuation token")

    # article-content
    p = subparsers.add_parser("article-content", help="Get full article content")
    p.add_argument("id", help="Article ID")
    p.add_argument("--text", action="store_true", help="Output plain text (HTML stripped)")

    # mark-read
    p = subparsers.add_parser("mark-read", help="Mark articles as read")
    p.add_argument("ids", nargs="+", help="Article ID(s)")

    # mark-unread
    p = subparsers.add_parser("mark-unread", help="Mark articles as unread")
    p.add_argument("ids", nargs="+", help="Article ID(s)")

    # star
    p = subparsers.add_parser("star", help="Star articles")
    p.add_argument("ids", nargs="+", help="Article ID(s)")

    # unstar
    p = subparsers.add_parser("unstar", help="Unstar articles")
    p.add_argument("ids", nargs="+", help="Article ID(s)")

    # mark-all-read
    p = subparsers.add_parser("mark-all-read", help="Mark all articles in a feed/category as read")
    p.add_argument("--feed", help="Feed ID to mark all read")
    p.add_argument("--category", help="Category label to mark all read")

    # add-feed
    p = subparsers.add_parser("add-feed", help="Subscribe to a new feed")
    p.add_argument("url", help="Feed URL to subscribe to")
    p.add_argument("--category", help="Category to add the feed to")
    p.add_argument("--title", help="Custom title for the feed")

    # remove-feed
    p = subparsers.add_parser("remove-feed", help="Unsubscribe from a feed")
    p.add_argument("feed_id", help="Feed ID to unsubscribe from")

    args = parser.parse_args()

    commands = {
        "list-feeds": cmd_list_feeds,
        "list-categories": cmd_list_categories,
        "unread-counts": cmd_unread_counts,
        "articles": cmd_articles,
        "article-content": cmd_article_content,
        "mark-read": cmd_mark_read,
        "mark-unread": cmd_mark_unread,
        "star": cmd_star,
        "unstar": cmd_unstar,
        "mark-all-read": cmd_mark_all_read,
        "add-feed": cmd_add_feed,
        "remove-feed": cmd_remove_feed,
    }

    commands[args.command](args)


if __name__ == "__main__":
    main()
