# SPDX-License-Identifier: AGPL-3.0-or-later
"""Sina Finance (新浪财经) - Chinese financial news engine via RSS.

Uses the Sina Finance rolling news JSON API to fetch latest financial news,
then filters by keyword overlap with the query.

API: https://feed.mix.sina.com.cn/api/roll/get
  pageid=153  (finance channel)
  lid=2516    (finance news list, ~100k articles)
"""

import json as _json

from searx.engines.rss_base import _overlap
from searx.result_types import EngineResults

about = {
    "website": "https://finance.sina.com.cn",
    "use_official_api": True,
    "require_api_key": False,
    "results": "JSON",
}

categories = ["finance", "news", "general"]
paging = False
timeout = 5.0

_API_URL = "https://feed.mix.sina.com.cn/api/roll/get"
_PAGE_SIZE = 50


def request(query, params):  # noqa: ARG001
    params["url"] = (
        f"{_API_URL}"
        f"?pageid=153"
        f"&lid=2516"
        f"&num={_PAGE_SIZE}"
        f"&page=1"
        f"&r=1"
    )
    params["headers"]["Referer"] = "https://finance.sina.com.cn/"
    return params


def response(resp):
    res = EngineResults()
    query = resp.search_params.get("q", "")

    try:
        data = _json.loads(resp.text)
    except Exception:
        return res

    articles = (data.get("result") or {}).get("data") or []

    for item in articles:
        title = (item.get("title") or "").strip()
        url = item.get("url") or item.get("link") or ""
        content = (item.get("intro") or item.get("summary") or "").strip()

        if not url or not title:
            continue

        combined = f"{title} {content}"
        if query and _overlap(query, combined) == 0:
            continue

        res.add(res.types.LegacyResult(url=url, title=title, content=content[:200]))

    return res
