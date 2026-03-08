# SPDX-License-Identifier: AGPL-3.0-or-later
"""Juejin (掘金) - Chinese developer community search engine."""

from json import dumps

from searx.result_types import EngineResults

about = {
    "website": "https://juejin.cn",
    "use_official_api": True,
    "require_api_key": False,
    "results": "JSON",
}

categories = ["it"]
paging = True
page_size = 10
timeout = 4.0

search_url = "https://api.juejin.cn/search_api/v1/search"


def request(query, params):
    params["url"] = search_url
    params["method"] = "POST"
    params["headers"]["Content-Type"] = "application/json"
    params["data"] = dumps(
        {
            "keyword": query,
            "search_type": 2,
            "cursor": str((params["pageno"] - 1) * page_size),
            "limit": page_size,
        }
    )


def response(resp):
    res = EngineResults()
    data = resp.json()

    for item in data.get("data") or []:
        if item.get("result_type") != 2:
            continue
        model = item.get("result_model", {})
        info = model.get("article_info", {})
        article_id = model.get("article_id", "")
        title = (info.get("title") or "").replace("<em>", "").replace("</em>", "")
        content = info.get("brief_content") or ""

        if not article_id or not title:
            continue

        res.add(
            res.types.LegacyResult(
                url=f"https://juejin.cn/post/{article_id}",
                title=title,
                content=content,
            )
        )

    return res
