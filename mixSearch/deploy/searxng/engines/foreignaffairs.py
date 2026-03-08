# SPDX-License-Identifier: AGPL-3.0-or-later
"""Foreign Affairs - U.S. foreign policy and international relations analysis (RSS).

Feed: https://www.foreignaffairs.com/rss.xml
Note: accessible from Tencent Cloud; may be blocked on mainland desktop networks.
"""

from searx.engines.rss_base import _parse_feed, _overlap  # noqa: F401
from searx.result_types import EngineResults

about = {
    "website": "https://www.foreignaffairs.com",
    "use_official_api": False,
    "require_api_key": False,
    "results": "RSS",
}

categories = ["news"]
paging = False
timeout = 8.0

feed_url = "https://www.foreignaffairs.com/rss.xml"


def request(query, params):  # noqa: ARG001
    params["url"] = feed_url
    params["headers"]["Accept"] = (
        "application/rss+xml, application/atom+xml, application/xml, text/xml"
    )
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
