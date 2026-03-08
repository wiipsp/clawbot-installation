# SPDX-License-Identifier: AGPL-3.0-or-later
"""Generic RSS/Atom feed engine base for SearXNG.

Subclass this by setting module-level variables:
    feed_url   : str   - the RSS/Atom URL to fetch
    categories : list  - SearXNG categories

The engine fetches the feed, parses all items, then filters by keyword
overlap with the query (title + description). Results are sorted by
publish date (newest first) before filtering.

Usage in a concrete engine module:
    from searx.engines.rss_base import request, response  # noqa: F401
    feed_url = "https://example.com/rss"
    categories = ["news"]
"""

import re
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from xml.etree import ElementTree as ET  # noqa: N817

from searx.result_types import EngineResults

# Override in concrete engine modules
feed_url: str = ""
categories: list = ["news"]
paging = False
timeout = 8.0
# Maximum items fetched from the feed before keyword filtering
_MAX_FEED_ITEMS = 50
# Minimum keyword overlap ratio to include a result (0 = include all)
_MIN_OVERLAP = 0.0


def request(query, params):  # noqa: ARG001
    params["url"] = feed_url
    params["headers"]["Accept"] = "application/rss+xml, application/atom+xml, application/xml, text/xml"
    return params


def _parse_date(text: str | None) -> datetime:
    """Parse RFC 2822 or ISO 8601 date strings, return UTC datetime."""
    if not text:
        return datetime.min.replace(tzinfo=timezone.utc)
    try:
        return parsedate_to_datetime(text).astimezone(timezone.utc)
    except Exception:
        pass
    try:
        return datetime.fromisoformat(text.rstrip("Z")).replace(tzinfo=timezone.utc)
    except Exception:
        return datetime.min.replace(tzinfo=timezone.utc)


def _strip_tags(text: str) -> str:
    """Remove HTML/XML tags from a string."""
    return re.sub(r"<[^>]+>", "", text or "").strip()


def _tokenize(text: str) -> set:
    tokens: set = set()
    # Chinese bigrams
    segments = re.findall(r"[\u4e00-\u9fff]+", text)
    for seg in segments:
        tokens.update(list(seg))
        for i in range(len(seg) - 1):
            tokens.add(seg[i] + seg[i + 1])
    # English words (2+ chars)
    tokens.update(w.lower() for w in re.findall(r"[a-zA-Z0-9]+", text) if len(w) > 1)
    return tokens


def _overlap(query: str, text: str) -> float:
    q = _tokenize(query.lower())
    t = _tokenize(text.lower())
    if not q:
        return 1.0
    return len(q & t) / len(q)


def _ns(tag: str, namespace: str) -> str:
    return f"{{{namespace}}}{tag}" if namespace else tag


def _parse_feed(xml_text: str) -> list[dict]:
    """Parse RSS 2.0 or Atom feed, return list of dicts with title/url/content/date."""
    items: list[dict] = []
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return items

    tag = root.tag.lower()

    # Atom feed
    if "atom" in tag or root.tag == "{http://www.w3.org/2005/Atom}feed":
        ns = "http://www.w3.org/2005/Atom"
        for entry in root.findall(f"{{{ns}}}entry"):
            title_el = entry.find(f"{{{ns}}}title")
            title = _strip_tags(title_el.text or "") if title_el is not None else ""
            link_el = entry.find(f"{{{ns}}}link")
            url = ""
            if link_el is not None:
                url = link_el.get("href") or link_el.text or ""
            summary_el = entry.find(f"{{{ns}}}summary") or entry.find(f"{{{ns}}}content")
            content = _strip_tags(summary_el.text or "") if summary_el is not None else ""
            updated_el = entry.find(f"{{{ns}}}updated") or entry.find(f"{{{ns}}}published")
            date = _parse_date(updated_el.text if updated_el is not None else None)
            if title and url:
                items.append({"title": title, "url": url, "content": content, "date": date})

    # RSS 2.0
    else:
        channel = root.find("channel") or root
        for item in channel.findall("item"):
            title_el = item.find("title")
            title = _strip_tags(title_el.text or "") if title_el is not None else ""
            link_el = item.find("link")
            url = (link_el.text or "").strip() if link_el is not None else ""
            desc_el = item.find("description")
            content = _strip_tags(desc_el.text or "") if desc_el is not None else ""
            date_el = item.find("pubDate")
            date = _parse_date(date_el.text if date_el is not None else None)
            if title and url:
                items.append({"title": title, "url": url, "content": content, "date": date})

    return items


def response(resp):
    res = EngineResults()
    query = resp.search_params.get("q", "")

    items = _parse_feed(resp.text)
    # Sort by date descending
    items.sort(key=lambda x: x["date"], reverse=True)
    items = items[:_MAX_FEED_ITEMS]

    for item in items:
        combined = f"{item['title']} {item['content']}"
        if _MIN_OVERLAP > 0 and _overlap(query, combined) < _MIN_OVERLAP:
            continue
        res.add(
            res.types.LegacyResult(
                url=item["url"],
                title=item["title"],
                content=item["content"][:300] if item["content"] else "",
            )
        )

    return res
