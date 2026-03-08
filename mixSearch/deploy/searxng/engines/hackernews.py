"""Hacker News RSS feed engine."""
from searx.engines.rss_base import request, response  # noqa: F401

feed_url = "https://news.ycombinator.com/rss"
categories = ["news", "it"]
timeout = 8.0
proxies = {"http": "http://172.17.0.1:7890", "https": "http://172.17.0.1:7890"}
