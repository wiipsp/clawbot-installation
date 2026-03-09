# SPDX-License-Identifier: AGPL-3.0-or-later
"""CSDN - Chinese developer blogging / knowledge platform.

Scrapes the CSDN search page (so.csdn.net) via HTML parsing.
If the page structure changes, update the XPath selectors below.
"""

from urllib.parse import quote_plus

from lxml import html as lxml_html
from searx.result_types import EngineResults

about = {
    "website": "https://www.csdn.net",
    "use_official_api": False,
    "require_api_key": False,
    "results": "HTML",
}

categories = ["it"]
paging = True
timeout = 5.0

_SEARCH_URL = "https://so.csdn.net/so/search"


def request(query, params):
    page = params["pageno"]
    params["url"] = f"{_SEARCH_URL}?q={quote_plus(query)}&t=blog&p={page}"
    params["headers"]["Referer"] = "https://so.csdn.net/"


def response(resp):
    res = EngineResults()
    dom = lxml_html.fromstring(resp.text)

    for item in dom.xpath('//div[contains(@class,"search-list")]//div[contains(@class,"search-list-con")]'):
        links = item.xpath('.//a[contains(@class,"title")]/@href | .//dt//a/@href | .//h3//a/@href')
        titles = item.xpath('.//a[contains(@class,"title")] | .//dt//a | .//h3//a')

        if not links or not titles:
            continue

        url = links[0]
        title = titles[0].text_content().strip()
        title = title.replace("\n", " ").strip()

        content_nodes = item.xpath(
            './/p[contains(@class,"desc")] | .//dd//p | .//div[contains(@class,"content")]'
        )
        content = content_nodes[0].text_content().strip() if content_nodes else ""

        if url and title:
            res.add(res.types.LegacyResult(url=url, title=title, content=content))

    return res
