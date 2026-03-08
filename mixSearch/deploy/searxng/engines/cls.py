# SPDX-License-Identifier: AGPL-3.0-or-later
"""CLS (财联社) - Chinese real-time financial news search engine.

Scrapes cls.cn search results via HTML parsing.
Covers: A-share breaking news, market events, policy announcements.
"""

from urllib.parse import quote_plus

from lxml import html as lxml_html

from searx.result_types import EngineResults

about = {
    "website": "https://www.cls.cn",
    "use_official_api": False,
    "require_api_key": False,
    "results": "HTML",
}

categories = ["finance", "news"]
paging = True
timeout = 5.0

_SEARCH_URL = "https://www.cls.cn/searchPage"


def request(query, params):
    page = params["pageno"]
    params["url"] = f"{_SEARCH_URL}?keyword={quote_plus(query)}&type=article&page={page}"
    params["headers"]["Referer"] = "https://www.cls.cn/"
    params["headers"]["User-Agent"] = (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/122.0.0.0 Safari/537.36"
    )


def response(resp):
    res = EngineResults()
    dom = lxml_html.fromstring(resp.text)

    # cls.cn search result cards
    cards = dom.xpath(
        '//div[contains(@class,"search-result")]//div[contains(@class,"article-item")]'
        '| //div[contains(@class,"search-list")]//div[contains(@class,"item")]'
        '| //ul[contains(@class,"search")]//li'
    )

    for card in cards:
        links = card.xpath('.//a/@href')
        titles = card.xpath('.//a[contains(@class,"title")] | .//h3//a | .//h2//a | .//a[@class]')
        if not links or not titles:
            continue

        url = links[0]
        if url.startswith("/"):
            url = "https://www.cls.cn" + url

        title = titles[0].text_content().strip()
        if not title:
            continue

        content_nodes = card.xpath(
            './/p[contains(@class,"desc")] | .//p[contains(@class,"summary")] | .//p'
        )
        content = content_nodes[0].text_content().strip() if content_nodes else ""

        res.add(res.types.LegacyResult(url=url, title=title, content=content))

    return res
