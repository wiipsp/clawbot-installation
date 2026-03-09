import asyncio
import logging
import os
import re
import time
from collections import defaultdict, deque
from email.utils import parsedate_to_datetime
from typing import Any, Deque, Dict, List, Tuple
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from xml.etree import ElementTree as ET

import httpx
from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, Field

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
logger = logging.getLogger("adapter")

app = FastAPI(title="Hybrid Search Adapter", version="0.4.0")

SEARXNG_INTERNAL_URL = os.getenv("SEARXNG_INTERNAL_URL", "http://searxng:8080")
TAVILY_API_KEY = os.getenv("TAVILY_API_KEY", "").strip()
ENABLE_TAVILY = os.getenv("ENABLE_TAVILY", "true").lower() == "true"
LOCAL_MIN_RESULTS = int(os.getenv("LOCAL_MIN_RESULTS", "3"))
# If the best local result scores below this threshold, treat as low-relevance and fallback to Tavily.
# Typical range: 0.2 (very loose) ~ 0.5 (strict). Default 0.3 works well in practice.
LOCAL_MIN_RELEVANCE = float(os.getenv("LOCAL_MIN_RELEVANCE", "0.3"))
REQUEST_TIMEOUT_MS = int(os.getenv("REQUEST_TIMEOUT_MS", "8000"))
ENGINE_TIMEOUT_MS = int(os.getenv("ENGINE_TIMEOUT_MS", "2500"))
RETRY_COUNT = int(os.getenv("RETRY_COUNT", "1"))
RETRY_BACKOFF_MS = int(os.getenv("RETRY_BACKOFF_MS", "250"))
CACHE_TTL_SEC = int(os.getenv("CACHE_TTL_SEC", "1800"))
NEGATIVE_CACHE_TTL_SEC = int(os.getenv("NEGATIVE_CACHE_TTL_SEC", "120"))
RATE_LIMIT_RPM = int(os.getenv("RATE_LIMIT_RPM", "30"))
BURST = int(os.getenv("BURST", "10"))
MAX_QUERY_LEN = 256
TAVILY_URL = "https://api.tavily.com/search"
# International RSS engines (require proxy in GFW environment)
# Keep in sync with searxng/settings.yml international engines
# NOTE: In GFW environment, set SEARXNG_ENGINES env var to exclude these
INTERNATIONAL_ENGINES = "reuters,bbc,techcrunch,arstechnica,hackernews,economist,foreignaffairs"

# Default engines (GFW-safe). Override via SEARXNG_ENGINES env var for global mode.
SEARXNG_ENGINES = os.getenv(
    "SEARXNG_ENGINES",
    "bing,baidu,github,stackexchange,juejin,csdn,sinafinance,36kr",
)
# Engines used when topic=news or time_sensitive=True
# Override via SEARXNG_NEWS_ENGINES env var for global mode
SEARXNG_NEWS_ENGINES = os.getenv(
    "SEARXNG_NEWS_ENGINES",
    "baidu,bing news,sinafinance,36kr",
)

# RSS feeds fetched in parallel when topic=news; each entry: (name, url, category)
# category: "tech" | "finance" | "general" | "international"
_RSS_FEEDS: List[Tuple[str, str, str]] = [
    ("36kr",      "https://36kr.com/feed",                          "tech"),
    ("huxiu",     "https://www.huxiu.com/rss/0.xml",                "tech"),
    ("ycombinator", "https://news.ycombinator.com/rss",             "tech"),
    ("bbc_tech",  "https://feeds.bbci.co.uk/news/technology/rss.xml", "international"),
]
# Max items to extract per RSS feed per request
_RSS_MAX_PER_FEED = int(os.getenv("RSS_MAX_PER_FEED", "10"))
# RSS results cache TTL (seconds) — shorter than news search cache
_RSS_CACHE_TTL = int(os.getenv("RSS_CACHE_TTL_SEC", "180"))

# Baidu result quality control:
#   BAIDU_SCORE_PENALTY: multiplier applied to baidu results' base score (0~1, lower = weaker)
#   BAIDU_MAX_RATIO:     max fraction of final results that can come from baidu (0~1)
BAIDU_SCORE_PENALTY = float(os.getenv("BAIDU_SCORE_PENALTY", "0.6"))
BAIDU_MAX_RATIO = float(os.getenv("BAIDU_MAX_RATIO", "0.4"))

WEIGHT_EN_DEFAULT = float(os.getenv("WEIGHT_EN_DEFAULT", "0.65"))
WEIGHT_ZH_DEFAULT = float(os.getenv("WEIGHT_ZH_DEFAULT", "0.35"))
WEIGHT_EN_TECH = float(os.getenv("WEIGHT_EN_TECH", "0.75"))
WEIGHT_ZH_TECH = float(os.getenv("WEIGHT_ZH_TECH", "0.25"))
WEIGHT_EN_LOCAL = float(os.getenv("WEIGHT_EN_LOCAL", "0.40"))
WEIGHT_ZH_LOCAL = float(os.getenv("WEIGHT_ZH_LOCAL", "0.60"))

RATE_STATE: Dict[str, Deque[float]] = defaultdict(deque)
CACHE: Dict[str, Tuple[float, Dict[str, Any]]] = {}


VALID_TIME_RANGES = {"day", "week", "month", "year"}
VALID_TOPICS = {"general", "news"}
NEWS_CACHE_TTL_SEC = int(os.getenv("NEWS_CACHE_TTL_SEC", "300"))


class SearchReq(BaseModel):
    query: str = Field(..., min_length=1, max_length=MAX_QUERY_LEN)
    max_results: int = Field(10, ge=1, le=20)
    time_range: str | None = Field(None, description="day, week, month, year")
    topic: str | None = Field(
        None,
        description=(
            "Search topic for Tavily: 'news' for time-sensitive news queries, "
            "'general' (default) for everything else. "
            "When topic='news', Tavily uses its news index and the `days` window is applied."
        ),
    )
    days: int | None = Field(
        None,
        ge=1,
        le=30,
        description="Only used when topic='news'. Limits Tavily results to the last N days (1–30).",
    )


def now_ts() -> float:
    return time.time()


def contains_zh(text: str) -> bool:
    return bool(re.search(r"[\u4e00-\u9fff]", text))


def is_tech_query(text: str) -> bool:
    low = text.lower()
    keywords = [
        "error", "exception", "traceback", "fastapi", "python", "java", "golang",
        "kubernetes", "docker", "api", "sdk", "runtime", "性能", "报错", "调试", "框架",
    ]
    return any(k in low for k in keywords)


def is_local_query(text: str) -> bool:
    low = text.lower()
    keywords = ["政策", "本地", "国内", "新闻", "招聘", "城市", "天气",
                "股票", "基金", "债券", "a股", "沪深", "港股", "财经",
                "经济", "上市", "涨跌", "行情", "公告", "研报"]
    return any(k in low for k in keywords)


def is_time_sensitive(text: str) -> bool:
    low = text.lower()
    keywords = [
        "新闻", "最新", "今天", "今日", "昨天", "本周", "近期", "刚刚",
        "发布", "更新", "公告", "事件", "热点", "实时", "breaking",
        "latest", "today", "yesterday", "this week", "recent", "news",
        "release", "announce", "update",
    ]
    return any(k in low for k in keywords)


ZH_EN_DICT: Dict[str, str] = {
    "自然语言处理": "natural language processing",
    "计算机视觉": "computer vision",
    "大语言模型": "large language model",
    "持续集成": "continuous integration",
    "持续部署": "continuous deployment",
    "版本控制": "version control",
    "依赖注入": "dependency injection",
    "负载均衡": "load balancing",
    "单元测试": "unit testing",
    "集成测试": "integration testing",
    "最佳实践": "best practices",
    "机器学习": "machine learning",
    "深度学习": "deep learning",
    "人工智能": "artificial intelligence",
    "神经网络": "neural network",
    "操作系统": "operating system",
    "开源": "open source",
    "大模型": "large language model",
    "微调": "fine-tuning",
    "推理": "inference",
    "训练": "training",
    "数据库": "database",
    "缓存": "cache",
    "部署": "deployment",
    "容器": "container",
    "微服务": "microservice",
    "框架": "framework",
    "性能": "performance",
    "优化": "optimization",
    "并发": "concurrency",
    "异步": "async",
    "接口": "interface",
    "前端": "frontend",
    "后端": "backend",
    "全栈": "fullstack",
    "算法": "algorithm",
    "爬虫": "web scraping",
    "编译器": "compiler",
    "安全": "security",
    "加密": "encryption",
    "认证": "authentication",
    "授权": "authorization",
    "测试": "testing",
    "报错": "error",
    "调试": "debugging",
    "配置": "configuration",
    "插件": "plugin",
    "扩展": "extension",
    "芯片": "chip",
    "处理器": "processor",
    "显卡": "graphics card",
    "内存": "memory",
    "手机": "smartphone",
    "笔记本": "laptop",
    "评测": "review",
    "对比": "comparison",
    "区别": "difference",
    "最新": "latest",
    "发布": "release",
    "更新": "update",
    "教程": "tutorial",
    "指南": "guide",
    "文档": "documentation",
    "网络": "network",
    "搜索": "search",
}

_SORTED_ZH_KEYS = sorted(ZH_EN_DICT.keys(), key=len, reverse=True)


def build_en_query(query: str) -> str | None:
    """Build an English query from a Chinese query. Returns None if no translation possible."""
    if not contains_zh(query):
        return None

    en_parts: List[str] = []
    remaining = query

    for zh in _SORTED_ZH_KEYS:
        if zh in remaining:
            en_parts.append(ZH_EN_DICT[zh])
            remaining = remaining.replace(zh, " ")

    en_words = re.findall(r"[a-zA-Z0-9][\w.\-]*", query)
    en_parts.extend(en_words)

    if not en_parts:
        return None

    seen: set[str] = set()
    unique: List[str] = []
    for p in en_parts:
        low = p.lower()
        if low not in seen:
            seen.add(low)
            unique.append(p)

    result = " ".join(unique).strip()
    return result if result else None


def normalize_url(url: str) -> str:
    if not url:
        return ""
    parts = urlsplit(url.strip())
    keep = []
    for k, v in parse_qsl(parts.query, keep_blank_values=True):
        lk = k.lower()
        if lk.startswith("utm_") or lk in {"spm", "from", "from_source", "source"}:
            continue
        keep.append((k, v))
    return urlunsplit((parts.scheme, parts.netloc, parts.path.rstrip("/"), urlencode(keep), ""))


def _tokenize(text: str) -> list:
    """Chinese bigram + unigram, English word tokens (2+ chars)."""
    segments = re.findall(r"[\u4e00-\u9fff]+", text)
    tokens: list = []
    for seg in segments:
        tokens.extend(list(seg))
        for i in range(len(seg) - 1):
            tokens.append(seg[i] + seg[i + 1])
    tokens.extend(w.lower() for w in re.findall(r"[a-zA-Z0-9]+", text) if len(w) > 1)
    return tokens


def overlap_score(query: str, text: str) -> float:
    q = _tokenize(query)
    t = set(_tokenize(text))
    if not q:
        return 0.0
    hit = sum(1 for token in q if token in t)
    return hit / max(len(q), 1)


def choose_weights(query: str) -> Tuple[float, float]:
    if is_tech_query(query):
        return WEIGHT_EN_TECH, WEIGHT_ZH_TECH
    if is_local_query(query):
        return WEIGHT_EN_LOCAL, WEIGHT_ZH_LOCAL
    return WEIGHT_EN_DEFAULT, WEIGHT_ZH_DEFAULT


def is_en_result(item: Dict[str, Any]) -> bool:
    sample = f"{item.get('title', '')} {item.get('content', '')}"
    return not contains_zh(sample)


def _extract_engine(item: Dict[str, Any]) -> str:
    """Extract the real engine name from a SearXNG result item."""
    engines = item.get("engines")
    if engines and isinstance(engines, list):
        return engines[0]
    engine = item.get("engine")
    if engine and isinstance(engine, str):
        return engine
    return "searxng"


def to_common(item: Dict[str, Any], provider: str) -> Dict[str, Any]:
    title = item.get("title") or ""
    content = item.get("content") or item.get("snippet") or ""
    url = normalize_url(item.get("url") or item.get("link") or "")
    source = _extract_engine(item) if provider == "searxng" else "tavily"
    result: Dict[str, Any] = {
        "title": title,
        "content": content,
        "url": url,
        "source": source,
        "_provider": provider,
    }
    # Preserve publish date for freshness scoring (SearXNG field: publishedDate)
    pub = item.get("publishedDate") or item.get("published_date") or item.get("published")
    if pub:
        result["_published"] = pub
    return result


def _freshness_bonus(item: Dict[str, Any]) -> float:
    """Return a freshness bonus [0.0, 0.25] based on publishedDate age.

    Decay schedule:
      same day   → +0.25
      1–3 days   → +0.18
      4–7 days   → +0.10
      8–30 days  → +0.04
      > 30 days  → 0.0
    Returns 0.0 if no date available.
    """
    pub = item.get("_published")
    if not pub:
        return 0.0
    try:
        from datetime import datetime, timezone, timedelta
        # handle various formats: ISO 8601, "2026-03-04T06:23:00", "2026-03-04 06:23:00"
        pub_str = str(pub).strip().replace(" ", "T")
        # strip timezone suffix for simple parsing
        for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d"):
            try:
                dt = datetime.strptime(pub_str[:19], fmt).replace(tzinfo=timezone.utc)
                break
            except ValueError:
                continue
        else:
            return 0.0
        age_days = (datetime.now(timezone.utc) - dt).total_seconds() / 86400
        if age_days < 1:
            return 0.25
        if age_days < 4:
            return 0.18
        if age_days < 8:
            return 0.10
        if age_days < 31:
            return 0.04
        return 0.0
    except Exception:
        return 0.0


def dedupe_and_rank(items: List[Dict[str, Any]], query: str, time_sensitive: bool = False) -> List[Dict[str, Any]]:
    en_w, zh_w = choose_weights(query)
    by_url: Dict[str, Dict[str, Any]] = {}
    for item in items:
        url = item.get("url", "")
        if not url:
            continue
        text = f"{item.get('title', '')} {item.get('content', '')}"
        rel = overlap_score(query, text)
        lang_weight = en_w if is_en_result(item) else zh_w
        base = 0.1 if item.get("_provider") == "tavily" else 0.15
        freshness = _freshness_bonus(item)
        # When query is time-sensitive, freshness weight is doubled
        freshness_w = 2.0 if time_sensitive else 1.0
        base_score = 0.6 * rel + 0.3 * lang_weight + base
        is_baidu = item.get("source") == "baidu"
        # Penalty applied to both base AND freshness so baidu can't use date-richness to bypass it
        penalty = BAIDU_SCORE_PENALTY if is_baidu else 1.0
        score = (base_score + freshness * freshness_w) * penalty
        item["score"] = round(score, 6)
        old = by_url.get(url)
        if old is None or item["score"] > old.get("score", 0):
            by_url[url] = item
    ranked = sorted(by_url.values(), key=lambda x: x.get("score", 0), reverse=True)

    # Cap baidu results: separate non-baidu and baidu, interleave so baidu never dominates top slots
    if BAIDU_MAX_RATIO < 1.0 and ranked:
        non_baidu = [x for x in ranked if x.get("source") != "baidu"]
        baidu_items = [x for x in ranked if x.get("source") == "baidu"]
        max_baidu = max(1, int(len(ranked) * BAIDU_MAX_RATIO))
        baidu_items = baidu_items[:max_baidu]
        # Re-merge: interleave so baidu doesn't fill top N slots
        # Strategy: for every 1 baidu, ensure at least 1 non-baidu comes first
        merged: List[Dict[str, Any]] = []
        bi, ni = 0, 0
        while ni < len(non_baidu) or bi < len(baidu_items):
            if ni < len(non_baidu):
                merged.append(non_baidu[ni]); ni += 1
            if bi < len(baidu_items):
                merged.append(baidu_items[bi]); bi += 1
        return merged

    return ranked


def check_rate_limit(client_id: str) -> None:
    bucket = RATE_STATE[client_id]
    current = now_ts()
    window = 60.0
    allowed = RATE_LIMIT_RPM + BURST
    while bucket and current - bucket[0] > window:
        bucket.popleft()
    if len(bucket) >= allowed:
        logger.warning("rate_limit_exceeded client=%s", client_id)
        raise HTTPException(status_code=429, detail="请求频率超限")
    bucket.append(current)


def get_cache_key(query: str, max_results: int, topic: str | None = None, days: int | None = None) -> str:
    return f"{query.strip().lower()}::{max_results}::{topic or 'general'}::{days or ''}"


def cache_get(key: str) -> Dict[str, Any] | None:
    row = CACHE.get(key)
    if not row:
        return None
    exp, payload = row
    if now_ts() > exp:
        CACHE.pop(key, None)
        return None
    return payload


def cache_set(key: str, payload: Dict[str, Any], ttl: int) -> None:
    CACHE[key] = (now_ts() + max(ttl, 1), payload)


async def fetch_with_retry(
    client: httpx.AsyncClient, method: str, url: str, **kwargs: Any
) -> httpx.Response:
    last_exc: Exception | None = None
    attempts = RETRY_COUNT + 1
    for i in range(attempts):
        try:
            return await client.request(method, url, **kwargs)
        except Exception as exc:
            last_exc = exc
            if i + 1 >= attempts:
                break
            await asyncio.sleep(RETRY_BACKOFF_MS * (2**i) / 1000.0)
    if last_exc:
        raise last_exc
    raise RuntimeError("重试失败，未知错误")


@app.get("/healthz")
def health() -> Dict[str, bool]:
    return {"ok": True}


# ── Stock Quote ──────────────────────────────────────────────────────────────
# Market prefix rules for Sina Finance API (hq.sinajs.cn):
#   sh = Shanghai A-share (6xxxxx)
#   sz = Shenzhen A-share (0xxxxx / 3xxxxx)
#   hk = Hong Kong (5-digit, e.g. 00700)
#
# Resolve flow:
#   1. If input looks like a bare code → detect market and build symbol directly
#   2. Otherwise → call EastMoney suggest API to resolve name → QuoteID → symbol

_QUOTE_CACHE_TTL = 60  # seconds — real-time data, short TTL
_SUGGEST_URL = (
    "https://searchapi.eastmoney.com/api/suggest/get"
    "?type=14&token=D43BF722C8E33BDC906FB84D85E326617BEFCF241BCF&count=5"
)
_SINA_HQ_URL = "https://hq.sinajs.cn/list="
_SINA_HEADERS = {
    "Referer": "https://finance.sina.com.cn/",
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    ),
}

# Commodity futures: keyword/code → Sina hf_ symbol + metadata
# Ref: https://hq.sinajs.cn/list=hf_GC
_COMMODITY_MAP: Dict[str, Dict[str, Any]] = {
    # --- Gold ---
    "黄金": {"symbol": "hf_GC", "name": "黄金 (COMEX)", "market": "COMEX", "currency": "USD", "unit": "USD/oz"},
    "gold": {"symbol": "hf_GC", "name": "黄金 (COMEX)", "market": "COMEX", "currency": "USD", "unit": "USD/oz"},
    "xau": {"symbol": "hf_GC", "name": "黄金 (COMEX)", "market": "COMEX", "currency": "USD", "unit": "USD/oz"},
    "gc": {"symbol": "hf_GC", "name": "黄金 (COMEX)", "market": "COMEX", "currency": "USD", "unit": "USD/oz"},
    # --- Silver ---
    "白银": {"symbol": "hf_SI", "name": "白银 (COMEX)", "market": "COMEX", "currency": "USD", "unit": "USD/oz"},
    "silver": {"symbol": "hf_SI", "name": "白银 (COMEX)", "market": "COMEX", "currency": "USD", "unit": "USD/oz"},
    "xag": {"symbol": "hf_SI", "name": "白银 (COMEX)", "market": "COMEX", "currency": "USD", "unit": "USD/oz"},
    "si": {"symbol": "hf_SI", "name": "白银 (COMEX)", "market": "COMEX", "currency": "USD", "unit": "USD/oz"},
    # --- Crude Oil ---
    "原油": {"symbol": "hf_CL", "name": "原油 (WTI)", "market": "NYMEX", "currency": "USD", "unit": "USD/bbl"},
    "石油": {"symbol": "hf_CL", "name": "原油 (WTI)", "market": "NYMEX", "currency": "USD", "unit": "USD/bbl"},
    "crude": {"symbol": "hf_CL", "name": "原油 (WTI)", "market": "NYMEX", "currency": "USD", "unit": "USD/bbl"},
    "wti": {"symbol": "hf_CL", "name": "原油 (WTI)", "market": "NYMEX", "currency": "USD", "unit": "USD/bbl"},
    "cl": {"symbol": "hf_CL", "name": "原油 (WTI)", "market": "NYMEX", "currency": "USD", "unit": "USD/bbl"},
    # --- Natural Gas ---
    "天然气": {"symbol": "hf_NG", "name": "天然气 (NYMEX)", "market": "NYMEX", "currency": "USD", "unit": "USD/MMBtu"},
    "natgas": {"symbol": "hf_NG", "name": "天然气 (NYMEX)", "market": "NYMEX", "currency": "USD", "unit": "USD/MMBtu"},
    "ng": {"symbol": "hf_NG", "name": "天然气 (NYMEX)", "market": "NYMEX", "currency": "USD", "unit": "USD/MMBtu"},
    # --- Copper ---
    "铜": {"symbol": "hf_HG", "name": "铜 (COMEX)", "market": "COMEX", "currency": "USD", "unit": "USD/lb"},
    "copper": {"symbol": "hf_HG", "name": "铜 (COMEX)", "market": "COMEX", "currency": "USD", "unit": "USD/lb"},
    "hg": {"symbol": "hf_HG", "name": "铜 (COMEX)", "market": "COMEX", "currency": "USD", "unit": "USD/lb"},
    # --- Platinum ---
    "铂金": {"symbol": "hf_XPT", "name": "铂金 (NYMEX)", "market": "NYMEX", "currency": "USD", "unit": "USD/oz"},
    "platinum": {"symbol": "hf_XPT", "name": "铂金 (NYMEX)", "market": "NYMEX", "currency": "USD", "unit": "USD/oz"},
    "xpt": {"symbol": "hf_XPT", "name": "铂金 (NYMEX)", "market": "NYMEX", "currency": "USD", "unit": "USD/oz"},
    "pl": {"symbol": "hf_XPT", "name": "铂金 (NYMEX)", "market": "NYMEX", "currency": "USD", "unit": "USD/oz"},
    # --- Palladium ---
    "钯金": {"symbol": "hf_XPD", "name": "钯金 (NYMEX)", "market": "NYMEX", "currency": "USD", "unit": "USD/oz"},
    "palladium": {"symbol": "hf_XPD", "name": "钯金 (NYMEX)", "market": "NYMEX", "currency": "USD", "unit": "USD/oz"},
    "xpd": {"symbol": "hf_XPD", "name": "钯金 (NYMEX)", "market": "NYMEX", "currency": "USD", "unit": "USD/oz"},
    "pa": {"symbol": "hf_XPD", "name": "钯金 (NYMEX)", "market": "NYMEX", "currency": "USD", "unit": "USD/oz"},
}

# A-share market type values in EastMoney QuoteID prefix
_EM_MARKET_TO_SINA = {
    "0": "sz",    # Shenzhen
    "1": "sh",    # Shanghai
    "116": "hk",  # Hong Kong
    "105": "gb",  # US NASDAQ
    "106": "gb",  # US NYSE
    "107": "gb",  # US ETF/other
}


def _code_to_sina_symbol(code: str) -> str | None:
    """Convert a bare stock code to Sina Finance symbol (e.g. '600519' → 'sh600519')."""
    code = code.strip().upper()
    # Hong Kong: 5-digit numeric
    if re.fullmatch(r"\d{5}", code):
        return f"hk{code.zfill(5)}"
    # Shanghai A-share: starts with 6
    if re.fullmatch(r"6\d{5}", code):
        return f"sh{code}"
    # Shenzhen A-share: starts with 0 or 3
    if re.fullmatch(r"[03]\d{5}", code):
        return f"sz{code}"
    # US stock: 1-5 uppercase letters (e.g. AAPL, TSLA, NVDA)
    if re.fullmatch(r"[A-Z]{1,5}", code):
        return f"gb_{code.lower()}"
    return None


def _em_quoteid_to_sina(quote_id: str) -> str | None:
    """Convert EastMoney QuoteID (e.g. '1.600519') to Sina symbol ('sh600519')."""
    parts = quote_id.split(".", 1)
    if len(parts) != 2:
        return None
    mkt, code = parts[0], parts[1]
    prefix = _EM_MARKET_TO_SINA.get(mkt)
    if prefix == "hk":
        return f"hk{code}"
    if prefix == "gb":
        return f"gb_{code.lower()}"
    if prefix:
        return f"{prefix}{code}"
    return None


def _parse_sina_a_share(symbol: str, raw: str) -> Dict[str, Any]:
    """Parse Sina Finance A-share data string."""
    # format: "name,open,prev_close,current,high,low,bid,ask,vol,amount,...,date,time,..."
    parts = raw.split(",")
    if len(parts) < 32:
        return {}
    try:
        current = float(parts[3])
        prev_close = float(parts[2])
        change = round(current - prev_close, 4)
        change_pct = round(change / prev_close * 100, 2) if prev_close else 0.0
        return {
            "symbol": symbol,
            "name": parts[0],
            "market": "SH" if symbol.startswith("sh") else "SZ",
            "currency": "CNY",
            "price": current,
            "open": float(parts[1]),
            "prev_close": prev_close,
            "high": float(parts[4]),
            "low": float(parts[5]),
            "volume": int(parts[8]),
            "amount": float(parts[9]),
            "change": change,
            "change_pct": change_pct,
            "date": parts[30],
            "time": parts[31],
        }
    except (IndexError, ValueError):
        return {}


def _parse_sina_hk(symbol: str, raw: str) -> Dict[str, Any]:
    """Parse Sina Finance Hong Kong stock data string.

    Field layout (0-indexed):
      0=EN_name, 1=ZH_name, 2=open, 3=prev_close, 4=high, 5=low,
      6=current, 7=change_abs, 8=change_pct(%), 9=bid, 10=ask,
      11=volume(shares), 12=amount, ..., 17=date, 18=time
    """
    parts = raw.split(",")
    if len(parts) < 12:
        return {}
    try:
        current = float(parts[6]) if parts[6] else 0.0
        prev_close = float(parts[3]) if parts[3] else 0.0
        change = round(float(parts[7]) if parts[7] else current - prev_close, 4)
        change_pct = round(float(parts[8]) if parts[8] else 0.0, 3)
        date_str = parts[17].replace("/", "-") if len(parts) > 17 and parts[17] else ""
        time_str = parts[18] if len(parts) > 18 and parts[18] else ""
        return {
            "symbol": symbol,
            "name": parts[1] or parts[0],
            "market": "HK",
            "currency": "HKD",
            "price": current,
            "open": float(parts[2]) if parts[2] else None,
            "prev_close": prev_close,
            "high": float(parts[4]) if parts[4] else None,
            "low": float(parts[5]) if parts[5] else None,
            "volume": int(float(parts[11])) if parts[11] else None,
            "amount": float(parts[12]) if parts[12] else None,
            "change": change,
            "change_pct": change_pct,
            "date": date_str,
            "time": time_str,
        }
    except (IndexError, ValueError):
        return {}


def _parse_sina_us(symbol: str, raw: str) -> Dict[str, Any]:
    """Parse Sina Finance US stock data string (gb_ prefix).

    Verified field layout (0-indexed, 36 fields total):
      0=ZH_name, 1=regular_price, 2=change_pct(%), 3=regular_datetime,
      4=change_abs, 5=prev_close(昨收), 6=day_high, 7=day_low,
      8=52w_high, 9=52w_low, 10=volume, 11=avg_volume,
      12=market_cap, 13=turnover_rate, 14=pe_ratio (may be '--'),
      15-19=zeros, 20=?, 21=ext_price(盘前/盘后价),
      22=ext_change_pct(%), 23=ext_change_abs, 24=ext_datetime(EST),
      25=regular_close_datetime(EST), 26=day_open,
      27=ext_volume, 28=has_ext(1=yes), 29=year,
      30=?, 31=?, 32=?, 33=?, 34=?, 35=regular_close
    Note: [2]=chg_pct and [4]=chg_abs are vs prev_close [5]
          [22]=ext_chg_pct and [23]=ext_chg_abs are vs regular_close [35]
    """
    def _f(parts: list, idx: int) -> float | None:
        """Safe float parse — returns None if missing, empty, or non-numeric (e.g. '--')."""
        try:
            v = parts[idx] if idx < len(parts) else ""
            return float(v) if v and v not in ("--", "N/A") else None
        except (ValueError, IndexError):
            return None

    parts = raw.split(",")
    if len(parts) < 8:
        return {}
    try:
        regular_price = _f(parts, 1) or 0.0
        prev_close = _f(parts, 5) or 0.0
        change = round(_f(parts, 4) or (regular_price - prev_close), 4)
        change_pct = round(_f(parts, 2) or 0.0, 3)
        ticker = symbol[3:].upper()

        result: Dict[str, Any] = {
            "symbol": symbol,
            "ticker": ticker,
            "name": parts[0] or ticker,
            "market": "US",
            "currency": "USD",
            "price": regular_price,
            "open": _f(parts, 26),
            "prev_close": prev_close,
            "high": _f(parts, 6),
            "low": _f(parts, 7),
            "volume": int(float(parts[10])) if len(parts) > 10 and parts[10] else None,
            "market_cap": _f(parts, 12),
            "pe_ratio": _f(parts, 14),
            "change": change,
            "change_pct": change_pct,
            "datetime": parts[3] if len(parts) > 3 else "",
        }

        # Extended hours (pre-market or after-hours) data
        has_ext = len(parts) > 28 and parts[28] == "1"
        if has_ext and len(parts) > 24 and parts[21]:
            ext_price = _f(parts, 21)
            ext_close = _f(parts, 35) or regular_price
            if ext_price:
                result["extended"] = {
                    "price": ext_price,
                    "change": round(_f(parts, 23) or (ext_price - ext_close), 4),
                    "change_pct": round(_f(parts, 22) or 0.0, 3),
                    "datetime_est": parts[24] if len(parts) > 24 else "",
                    "volume": int(float(parts[27])) if len(parts) > 27 and parts[27] else None,
                }

        return result
    except Exception:
        return {}


def _parse_sina_futures(symbol: str, raw: str) -> Dict[str, Any]:
    """Parse Sina Finance futures/commodity data string (hf_ prefix).

    Field layout (0-indexed):
      0=current, 1=unused, 2=prev_close, 3=open, 4=high, 5=low,
      6=time, 7=settle, 8=prev_settle, 9=?, 10=?, 11=?, 12=date
    """
    parts = raw.split(",")
    if not parts or not parts[0]:
        return {}
    try:
        current = float(parts[0])
        prev = float(parts[2]) if len(parts) > 2 and parts[2] else current
        change = round(current - prev, 4)
        change_pct = round(change / prev * 100, 2) if prev else 0.0
        meta = _COMMODITY_MAP.get(symbol[3:].lower(), {})  # strip "hf_" prefix
        return {
            "symbol": symbol,
            "name": meta.get("name", symbol),
            "market": meta.get("market", "FUTURES"),
            "currency": meta.get("currency", "USD"),
            "unit": meta.get("unit", ""),
            "price": current,
            "open": float(parts[3]) if len(parts) > 3 and parts[3] else None,
            "prev_close": prev,
            "high": float(parts[4]) if len(parts) > 4 and parts[4] else None,
            "low": float(parts[5]) if len(parts) > 5 and parts[5] else None,
            "change": change,
            "change_pct": change_pct,
            "date": parts[12] if len(parts) > 12 and parts[12] else "",
            "time": parts[6] if len(parts) > 6 and parts[6] else "",
        }
    except (IndexError, ValueError):
        return {}


async def _resolve_symbol(query: str, client: httpx.AsyncClient) -> tuple[str | None, str | None]:
    """
    Resolve user query to a Sina Finance symbol.
    Returns (sina_symbol, em_name) or (None, None) on failure.
    """
    # 0. Check commodity map first (黄金/原油/白银/铜 etc.)
    commodity = _COMMODITY_MAP.get(query.strip().lower())
    if commodity:
        return commodity["symbol"], commodity["name"]

    # 1. Try direct code detection first
    direct = _code_to_sina_symbol(query.strip())
    if direct:
        return direct, None

    # 2. Use EastMoney suggest to resolve name → code
    try:
        resp = await client.get(
            _SUGGEST_URL,
            params={"input": query},
            headers={"Referer": "https://www.eastmoney.com/"},
            timeout=5.0,
        )
        resp.raise_for_status()
        data = resp.json()
        candidates = data.get("QuotationCodeTable", {}).get("Data") or []
        # Prefer A-share, then HK, then others
        preferred = None
        for item in candidates:
            qt = item.get("QuoteID", "")
            sym = _em_quoteid_to_sina(qt)
            if not sym:
                continue
            if preferred is None:
                preferred = (sym, item.get("Name", ""))
            # Prefer exact name match
            if item.get("Name") == query or item.get("UnifiedCode") == query:
                return sym, item.get("Name", "")
        if preferred:
            return preferred
    except Exception as exc:
        logger.warning("quote_resolve_failed query=%r error=%s", query, exc)

    return None, None


async def _fetch_quote(symbol: str, client: httpx.AsyncClient) -> Dict[str, Any] | None:
    """Fetch real-time quote from Sina Finance for a given symbol."""
    try:
        resp = await client.get(
            f"{_SINA_HQ_URL}{symbol}",
            headers=_SINA_HEADERS,
            timeout=5.0,
        )
        resp.raise_for_status()
        # Response: var hq_str_sh600519="...data...";
        text = resp.text
        match = re.search(r'hq_str_\w+="([^"]*)"', text)
        if not match:
            return None
        raw = match.group(1)
        if not raw:
            return None
        if symbol.startswith("hf_"):
            return _parse_sina_futures(symbol, raw)
        if symbol.startswith("hk"):
            return _parse_sina_hk(symbol, raw)
        if symbol.startswith("gb_"):
            return _parse_sina_us(symbol, raw)
        return _parse_sina_a_share(symbol, raw)
    except Exception as exc:
        logger.warning("quote_fetch_failed symbol=%r error=%s", symbol, exc)
        return None


@app.get("/quote")
async def quote(q: str, request: Request) -> Dict[str, Any]:
    """
    Real-time stock quote endpoint.

    Query parameter:
      q: stock code (e.g. 600519, 00700) or Chinese name (e.g. 茅台, 腾讯控股)
       or commodity keyword (e.g. 黄金, 原油, 白银, 铜, 天然气)

    Returns price, change, volume, etc. from Sina Finance.
    """
    q = q.strip()
    if not q:
        raise HTTPException(status_code=400, detail="q is required")

    client_ip = request.client.host if request.client else "unknown"
    check_rate_limit(client_ip)

    cache_key = f"quote::{q.lower()}"
    cached = cache_get(cache_key)
    if cached:
        return {**cached, "cache_hit": True}

    timeout = httpx.Timeout(8.0, connect=4.0)
    # hq.sinajs.cn uses a cert chain that may not be trusted inside the container;
    # verify=False is intentional here — this is an internal market data fetch only.
    async with httpx.AsyncClient(timeout=timeout, verify=False) as client:
        symbol, resolved_name = await _resolve_symbol(q, client)
        if not symbol:
            raise HTTPException(
                status_code=404,
                detail=f"无法识别的代码或名称: {q!r}，支持 A股/港股/美股代码、中文名称、大宗商品（黄金/原油/白银/铜/天然气等）",
            )

        data = await _fetch_quote(symbol, client)
        if not data:
            raise HTTPException(
                status_code=502,
                detail=f"行情数据获取失败 (symbol={symbol})",
            )

    # Enrich with resolved name if not already in data
    if resolved_name and not data.get("name"):
        data["name"] = resolved_name

    payload = {"cache_hit": False, **data}
    cache_set(cache_key, payload, _QUOTE_CACHE_TTL)
    logger.info("quote_ok q=%r symbol=%s price=%s", q, symbol, data.get("price"))
    return payload


def _parse_rss_date(date_str: str | None) -> str | None:
    """Parse RSS pubDate (RFC 2822) or ISO 8601 to ISO 8601 UTC string."""
    if not date_str:
        return None
    date_str = date_str.strip()
    # Try RFC 2822 (standard RSS pubDate: "Wed, 05 Mar 2026 04:00:00 GMT")
    try:
        dt = parsedate_to_datetime(date_str)
        from datetime import timezone
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    except Exception:
        pass
    # Try ISO 8601 directly
    try:
        from datetime import datetime, timezone
        for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
            try:
                dt = datetime.strptime(date_str[:19], fmt[:len(fmt)])
                return dt.replace(tzinfo=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
            except ValueError:
                continue
    except Exception:
        pass
    return None


def _parse_rss_feed(xml_text: str, source_name: str) -> List[Dict[str, Any]]:
    """Parse RSS 2.0 / Atom XML into common result dicts."""
    results: List[Dict[str, Any]] = []
    try:
        root = ET.fromstring(xml_text)
        ns = {"atom": "http://www.w3.org/2005/Atom"}
        # Detect format: RSS 2.0 vs Atom
        is_atom = root.tag in ("{http://www.w3.org/2005/Atom}feed", "feed")
        if is_atom:
            items = root.findall("{http://www.w3.org/2005/Atom}entry")
        else:
            channel = root.find("channel")
            items = channel.findall("item") if channel is not None else root.findall(".//item")

        for item in items:
            if is_atom:
                title = (item.findtext("{http://www.w3.org/2005/Atom}title") or "").strip()
                # Atom link is an element with href attribute
                link_el = item.find("{http://www.w3.org/2005/Atom}link")
                url = (link_el.get("href") if link_el is not None else "") or ""
                summary = (
                    item.findtext("{http://www.w3.org/2005/Atom}summary") or
                    item.findtext("{http://www.w3.org/2005/Atom}content") or ""
                ).strip()
                pub_raw = item.findtext("{http://www.w3.org/2005/Atom}published") or item.findtext("{http://www.w3.org/2005/Atom}updated")
            else:
                title = (item.findtext("title") or "").strip()
                url = (item.findtext("link") or item.findtext("url") or "").strip()
                summary = (item.findtext("description") or item.findtext("summary") or "").strip()
                pub_raw = item.findtext("pubDate") or item.findtext("published") or item.findtext("dc:date")

            if not title or not url:
                continue
            # Strip HTML tags from summary
            summary = re.sub(r"<[^>]+>", " ", summary)
            summary = re.sub(r"\s+", " ", summary).strip()[:300]
            pub_iso = _parse_rss_date(pub_raw)
            result: Dict[str, Any] = {
                "title": title,
                "content": summary,
                "url": normalize_url(url),
                "source": source_name,
                "_provider": "rss",
            }
            if pub_iso:
                result["_published"] = pub_iso
            results.append(result)
    except ET.ParseError:
        pass
    return results


async def _fetch_single_rss(
    client: httpx.AsyncClient,
    name: str,
    url: str,
    max_items: int,
) -> List[Dict[str, Any]]:
    """Fetch and parse a single RSS feed. Returns [] on any error."""
    try:
        resp = await client.get(
            url,
            headers={"User-Agent": "Mozilla/5.0 (compatible; HybridSearch/1.0)"},
            follow_redirects=True,
        )
        resp.raise_for_status()
        items = _parse_rss_feed(resp.text, name)[:max_items]
        logger.info("rss_ok feed=%s count=%d", name, len(items))
        return items
    except Exception as exc:
        logger.warning("rss_failed feed=%s error=%s", name, exc)
        return []


async def _fetch_rss_feeds(
    client: httpx.AsyncClient,
    query: str,
    max_per_feed: int = _RSS_MAX_PER_FEED,
) -> List[Dict[str, Any]]:
    """Fetch all RSS feeds in parallel, return keyword-filtered results sorted by date."""
    tasks = [
        _fetch_single_rss(client, name, url, max_per_feed)
        for name, url, _ in _RSS_FEEDS
    ]
    feed_results = await asyncio.gather(*tasks)
    all_items: List[Dict[str, Any]] = []
    for items in feed_results:
        all_items.extend(items)

    # Keyword filter: keep items whose title/content overlap with query
    # For news headline mode (very short query), keep all items
    q_tokens = set(_tokenize(query))
    if len(q_tokens) >= 2:
        filtered = [
            item for item in all_items
            if overlap_score(query, f"{item.get('title','')} {item.get('content','')}") > 0
        ]
        # Fall back to all items if filter is too aggressive
        if len(filtered) < 3:
            filtered = all_items
    else:
        filtered = all_items

    # Sort by publishedDate descending (most recent first)
    def _sort_key(item: Dict[str, Any]) -> str:
        return item.get("_published") or "1970-01-01T00:00:00"

    filtered.sort(key=_sort_key, reverse=True)
    return filtered


async def _fetch_searxng(
    client: httpx.AsyncClient, query: str, max_items: int,
    time_range: str | None = None,
    engines: str | None = None,
) -> Tuple[List[Dict[str, Any]], bool]:
    """Fetch results from SearXNG. Returns (results, failed)."""
    try:
        params: Dict[str, Any] = {
            "q": query, "format": "json", "safesearch": 1,
            "engines": engines or SEARXNG_ENGINES,
        }
        if time_range and time_range in VALID_TIME_RANGES:
            params["time_range"] = time_range
        resp = await fetch_with_retry(
            client,
            "GET",
            f"{SEARXNG_INTERNAL_URL}/search",
            params=params,
            headers={"X-Forwarded-For": "127.0.0.1"},
        )
        resp.raise_for_status()
        items = [
            to_common(x, "searxng")
            for x in resp.json().get("results", [])[:max_items]
        ]
        logger.info("searxng_ok count=%d query=%r", len(items), query)
        return items, False
    except Exception as exc:
        logger.warning("searxng_failed query=%r error=%s", query, exc)
        return [], True


@app.post("/search")
async def search(req: SearchReq, request: Request) -> Dict[str, Any]:
    query = req.query.strip()
    if not query:
        raise HTTPException(status_code=400, detail="查询内容不能为空")
    if len(query) > MAX_QUERY_LEN:
        raise HTTPException(status_code=400, detail="查询内容过长")

    client_ip = request.client.host if request.client else "unknown"
    check_rate_limit(client_ip)
    logger.info("search query=%r max_results=%d client=%s", query, req.max_results, client_ip)

    should_translate = contains_zh(query) and not is_local_query(query)
    en_query = build_en_query(query) if should_translate else None

    time_sensitive = is_time_sensitive(query)
    effective_time_range = req.time_range
    if time_sensitive and not effective_time_range:
        effective_time_range = "week"

    if req.time_range and req.time_range not in VALID_TIME_RANGES:
        raise HTTPException(status_code=400, detail=f"time_range must be one of: {', '.join(sorted(VALID_TIME_RANGES))}")
    if req.topic and req.topic not in VALID_TOPICS:
        raise HTTPException(status_code=400, detail=f"topic must be one of: {', '.join(sorted(VALID_TOPICS))}")

    # Auto-infer topic=news for time-sensitive queries unless caller already set it
    effective_topic = req.topic
    if effective_topic is None and time_sensitive:
        effective_topic = "news"

    # Auto-infer days window for news topic: day→1, week→7, month→30; default 7
    effective_days = req.days
    if effective_days is None and effective_topic == "news":
        _range_to_days = {"day": 1, "week": 7, "month": 30, "year": 365}
        effective_days = _range_to_days.get(effective_time_range or "week", 7)

    key = get_cache_key(query, req.max_results, effective_topic, effective_days)
    cached = cache_get(key)
    if cached:
        logger.info("cache_hit query=%r", query)
        return {**cached, "meta": {**cached["meta"], "cache_hit": True}}

    timeout = httpx.Timeout(REQUEST_TIMEOUT_MS / 1000.0, connect=ENGINE_TIMEOUT_MS / 1000.0)
    # RSS feeds may be slower; use a dedicated client with longer timeout
    rss_timeout = httpx.Timeout(10.0, connect=5.0)
    local_results: List[Dict[str, Any]] = []
    tavily_results: List[Dict[str, Any]] = []
    rss_results: List[Dict[str, Any]] = []
    fallback_reasons: List[str] = []

    async with httpx.AsyncClient(timeout=timeout) as client:
        # --- SearXNG phase: parallel Chinese + English queries ---
        fetch_max = req.max_results * 2
        # Use news-specific engines when topic=news or query is time-sensitive
        active_engines = SEARXNG_NEWS_ENGINES if effective_topic == "news" else None
        tasks: List[Any] = [_fetch_searxng(client, query, fetch_max, effective_time_range, active_engines)]
        if en_query:
            tasks.append(_fetch_searxng(client, en_query, fetch_max, effective_time_range, active_engines))
            fallback_reasons.append("zh_en_translate")
            logger.info("dual_searxng en_query=%r engines=%s", en_query, active_engines)

        # --- RSS phase: run in parallel with SearXNG when topic=news ---
        rss_task = None
        if effective_topic == "news":
            rss_client = httpx.AsyncClient(timeout=rss_timeout, verify=False)
            rss_task = asyncio.ensure_future(_fetch_rss_feeds(rss_client, query, _RSS_MAX_PER_FEED))

        searxng_results = await asyncio.gather(*tasks)

        local_failed = False
        for items, failed in searxng_results:
            local_results.extend(items)
            if failed:
                local_failed = True

        # Collect RSS results (ensure rss_client is closed)
        if rss_task is not None:
            try:
                rss_results = await rss_task
            finally:
                await rss_client.aclose()
            local_results.extend(rss_results)
            logger.info("rss_total count=%d query=%r", len(rss_results), query)

        if local_failed:
            fallback_reasons.append("local_error")
        if len(local_results) < LOCAL_MIN_RESULTS:
            fallback_reasons.append("low_local_recall")

        logger.info("searxng_total count=%d query=%r", len(local_results), query)

        # --- Tavily phase: only when SearXNG+RSS results are truly insufficient or irrelevant ---
        use_tavily = ENABLE_TAVILY and bool(TAVILY_API_KEY)
        # Pre-score local results to detect low-relevance scenarios
        # Exclude RSS items from relevance check: RSS is broadcast content, not query-matched
        best_local_score = 0.0
        if local_results:
            en_w, zh_w = choose_weights(query)
            for item in local_results:
                if item.get("_provider") == "rss":
                    continue
                text = f"{item.get('title', '')} {item.get('content', '')}"
                rel = overlap_score(query, text)
                lang_w = en_w if is_en_result(item) else zh_w
                base = 0.15
                score = 0.6 * rel + 0.3 * lang_w + base
                if score > best_local_score:
                    best_local_score = score

        low_relevance = best_local_score < LOCAL_MIN_RELEVANCE
        if low_relevance and local_results:
            fallback_reasons.append("low_local_relevance")

        should_fallback = use_tavily and (
            local_failed or len(local_results) < LOCAL_MIN_RESULTS or low_relevance
        )

        if should_fallback:
            logger.info(
                "tavily_fallback reasons=%s query=%r topic=%s days=%s",
                fallback_reasons, query, effective_topic, effective_days,
            )
            try:
                tavily_payload: Dict[str, Any] = {
                    "api_key": TAVILY_API_KEY,
                    "query": query,
                    "search_depth": "basic",
                    "include_answer": False,
                    "max_results": req.max_results,
                }
                if effective_topic:
                    tavily_payload["topic"] = effective_topic
                # 'days' only valid for topic=news
                if effective_topic == "news" and effective_days:
                    tavily_payload["days"] = effective_days
                tv = await fetch_with_retry(
                    client,
                    "POST",
                    TAVILY_URL,
                    json=tavily_payload,
                )
                if tv.is_success:
                    tavily_results = [
                        to_common(x, "tavily") for x in tv.json().get("results", [])
                    ]
                    logger.info("tavily_ok count=%d query=%r", len(tavily_results), query)
                else:
                    fallback_reasons.append("tavily_http_error")
                    logger.warning(
                        "tavily_http_error status=%d query=%r", tv.status_code, query
                    )
            except Exception as exc:
                fallback_reasons.append("tavily_request_error")
                logger.warning("tavily_request_error query=%r error=%s", query, exc)

    ranked = dedupe_and_rank(local_results + tavily_results, query, time_sensitive=time_sensitive)
    for item in ranked:
        item.pop("_provider", None)
        item.pop("_published", None)
    fallback_reasons = sorted(set(fallback_reasons))

    payload = {
        "query": query,
        "results": ranked[: req.max_results],
        "meta": {
            "cache_hit": False,
            "local_count": len(local_results),
            "rss_count": len(rss_results) if effective_topic == "news" else 0,
            "best_local_score": round(best_local_score, 3),
            "tavily_count": len(tavily_results),
            "tavily_enabled": ENABLE_TAVILY,
            "tavily_used": len(tavily_results) > 0,
            "translated_query": en_query,
            "time_range": effective_time_range,
            "topic": effective_topic,
            "days": effective_days,
            "fallback_reasons": fallback_reasons,
        },
    }

    if time_sensitive or effective_time_range:
        ttl = NEWS_CACHE_TTL_SEC if payload["results"] else NEGATIVE_CACHE_TTL_SEC
    else:
        ttl = CACHE_TTL_SEC if payload["results"] else NEGATIVE_CACHE_TTL_SEC
    cache_set(key, payload, ttl)
    logger.info(
        "search_done query=%r local=%d tavily=%d ranked=%d",
        query,
        len(local_results),
        len(tavily_results),
        len(payload["results"]),
    )
    return payload
