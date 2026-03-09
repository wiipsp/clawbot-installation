# SPDX-License-Identifier: AGPL-3.0-or-later
"""36Kr (36氪) - Chinese tech and business news (RSS).

Feed: https://36kr.com/feed
Covers: startup funding, tech industry, product launches, business trends.
"""

from searx.engines.rss_base import _parse_feed, _overlap  # noqa: F401
from searx.result_types import EngineResults

about = {
    "website": "https://36kr.com",
    "use_official_api": False,
    "require_api_key": False,
    "results": "RSS",
}

categories = ["news", "it"]
paging = False
timeout = 6.0

feed_url = "https://36kr.com/feed"


def request(query, params):  # noqa: ARG001
    params["url"] = feed_url
    params["headers"]["Accept"] = (
        "application/rss+xml, application/atom+xml, application/xml, text/xml"
    )
    params["headers"]["Referer"] = "https://36kr.com/"
    return params


def response(resp):
    res = EngineResults()
    query = resp.search_params.get("q", "")

    items = _parse_feed(resp.text)
    items.sort(key=lambda x: x["date"], reverse=True)

    for item in items[:30]:
        combined = f"{item['title']} {item['content']}"
        if query and _overlap(query, combined) == 0:
            continue
        res.add(
            res.types.LegacyResult(
                url=item["url"],
                title=item["title"],
                content=item["content"][:300] if item["content"] else "",
            )
        )

    return res
