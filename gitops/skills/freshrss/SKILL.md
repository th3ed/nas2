---
name: freshrss
description: "Manage RSS feeds and articles via a self-hosted FreshRSS instance. Read articles, get summaries, check unread counts, mark read/starred, add or remove feed subscriptions."
version: 1.0.0
author: Ed Andrews
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [RSS, News, Reading, FreshRSS, Feeds, Articles]
required_environment_variables:
  - name: FRESHRSS_URL
    prompt: "FreshRSS base URL (e.g. https://rss.example.com)"
    help: "The base URL of your FreshRSS instance, without trailing slash"
  - name: FRESHRSS_USER
    prompt: "FreshRSS username"
    help: "Your FreshRSS login username"
  - name: FRESHRSS_API_PASSWORD
    prompt: "FreshRSS API password"
    help: "Set in FreshRSS under Profile > API Management. This is separate from your web login password."
---

# FreshRSS

Interact with a self-hosted FreshRSS instance via the Google Reader API.

## When to Use

- User asks about RSS feeds, news, articles, or unread items
- User wants a news briefing or article summaries
- User asks to subscribe or unsubscribe from feeds
- User wants to mark articles as read, star/unstar items
- User asks about feed categories or unread counts
- User says "what's new", "any news", "check my feeds"

## Quick Reference

| Command | Description |
|---------|-------------|
| `list-feeds` | List all subscribed feeds |
| `list-categories` | List feed categories/labels |
| `unread-counts` | Show unread counts per feed |
| `articles [flags]` | Fetch articles with filtering |
| `article-content <id> --text` | Get article text for summarization |
| `mark-read <id> [...]` | Mark article(s) as read |
| `mark-unread <id> [...]` | Mark article(s) as unread |
| `star <id> [...]` | Star article(s) |
| `unstar <id> [...]` | Unstar article(s) |
| `mark-all-read --feed <id>` | Mark entire feed as read |
| `add-feed <url>` | Subscribe to a new feed |
| `remove-feed <id>` | Unsubscribe from a feed |

All commands: `python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py <command> [options]`

## Common Workflows

### Morning Briefing

1. Check what's unread: `python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py unread-counts`
2. Fetch unread articles: `python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py articles --unread-only --count 10`
3. For interesting articles, get full text: `python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py article-content "<article_id>" --text`
4. Summarize the content for the user
5. After user confirms, mark as read: `python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py mark-read "<article_id>"`

### Summarize a Specific Feed

1. List feeds to find the right one: `python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py list-feeds`
2. Fetch recent articles from that feed: `python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py articles --feed "<feed_id>" --count 5`
3. Get full content for each: `python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py article-content "<id>" --text`
4. Provide a consolidated summary

### Add a New Subscription

1. **Ask the user to confirm** the feed URL before proceeding
2. Subscribe: `python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py add-feed "https://example.com/feed.xml" --category "Tech"`
3. Verify: `python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py list-feeds`

### Catch Up on a Category

1. List categories: `python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py list-categories`
2. Fetch unread in category: `python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py articles --category "News" --unread-only --count 20`
3. Summarize headlines, offer to dive deeper into specific articles
4. Mark batch as read after user confirms

## Command Reference

### articles

Fetch articles with filtering and pagination.

```bash
python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py articles [options]
```

| Flag | Description |
|------|-------------|
| `--feed <feed_id>` | Filter to specific feed |
| `--category <label>` | Filter to category |
| `--unread-only` | Only unread articles |
| `--starred` | Only starred articles |
| `--count <n>` | Number to fetch (default 20) |
| `--since <timestamp>` | Articles newer than Unix timestamp |
| `--oldest-first` | Reverse chronological order |
| `--continuation <token>` | Pagination token from previous response |

Output includes a `continuation` field when more results are available — pass it back to get the next page.

### article-content

Fetch the full content of a single article.

```bash
python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py article-content "<article_id>" --text
```

- Without `--text`: returns JSON with both `content_html` and `content_text`
- With `--text`: returns clean plain text optimized for reading/summarization

### add-feed

```bash
python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py add-feed "<url>" --category "Label" --title "Custom Name"
```

### remove-feed

```bash
python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py remove-feed "<feed_id>"
```

### mark-all-read

```bash
python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py mark-all-read --feed "<feed_id>"
python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py mark-all-read --category "Label"
```

## Pitfalls

- **ALWAYS confirm with the user before mutations.** Never call `add-feed`, `remove-feed`, `mark-all-read`, or any write command without explicit user approval.
- **No server-side search.** To find articles by keyword, fetch articles and filter by title/snippet in the output.
- **Article content may be partial.** Some feeds only provide summaries; the script returns whatever FreshRSS has stored.
- **Article IDs are long strings.** They look like `tag:google.com,2005:reader/item/0000001234abcdef`. Always quote them in commands.
- **Pagination.** If a response has a `continuation` field, there are more results. Use `--continuation` to fetch the next page.

## Verification

Test connectivity:

```bash
python3 ${HERMES_SKILL_DIR}/scripts/freshrss.py list-feeds
```

Expected: JSON with feed titles and IDs. On failure, check that `FRESHRSS_URL`, `FRESHRSS_USER`, and `FRESHRSS_API_PASSWORD` are set correctly.
