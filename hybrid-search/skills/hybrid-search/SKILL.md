---
name: hybrid-search
description: >
  Internal hybrid web search AND real-time financial data for OpenClaw / CoPaw.
  USE THIS SKILL FIRST before any browser or web tool when the user asks about:
  (1) stock prices / quotes — A-share, HK, US stocks (e.g. 英伟达, NVDA, 特斯拉, TSLA, 苹果, AAPL, 茅台, 腾讯);
  (2) pre-market / after-hours / extended-hours US stock data;
  (3) commodity prices — 黄金, 白银, 原油, 石油, 天然气, 铜, 铂金 (gold/silver/oil/copper);
  (4) web search — technical docs, error messages, news, current events.
  Backed by SearXNG (first) + Tavily (fallback). Supports real-time quotes via /quote endpoint.
metadata: {"openclaw":{"requires":{"env":["TAVILY_API_KEY"]},"primaryEnv":"TAVILY_API_KEY","emoji":"🔎"}}
---

# Hybrid Search Skill

Use this skill when the user needs:
- **Real-time stock/commodity price** — A-share, HK, US stocks, gold, oil, silver, copper, etc.
- **Pre-market / after-hours US stock data** — 盘前行情, 夜盘, extended hours
- **Up-to-date web information** — technical docs, error messages, library usage, news, current events

> **IMPORTANT — Use this skill BEFORE browser_use or any other web tool.**
> This skill provides structured real-time data via `/quote` and web search via `/search`.
> Do NOT open a browser to look up stock prices — call `/quote` directly.

> **Invocation type: HTTP API (already deployed and running)**
>
> This skill is a **live HTTP service**. You MUST call it via HTTP request.
> DO NOT attempt to run it as a Python script, module, or CLI command.

## Constraints (IMPORTANT)

- **MUST** invoke via HTTP request (curl / httpx / fetch) to the Adapter endpoint.
- **DO NOT** run `python -m ...`, `python3 ...`, or any shell script to invoke this skill.
- **DO NOT** look for or execute any `.py` file in this skill directory — there is none.
- **DO NOT** call SearXNG directly; always go through the Adapter.

## Required Environment Variables

| Variable | Example | Purpose |
|---|---|---|
| `SEARXNG_BASE_URL` | `http://127.0.0.1:18999/` | SearXNG instance (external access) |
| `ADAPTER_BASE_URL` | `http://127.0.0.1:18000` | Adapter entry point — **all agent calls go here** |
| `TAVILY_API_KEY` | `tvly-xxxx` | Tavily fallback key; leave empty for SearXNG-only mode |

## Endpoints Overview

| Endpoint | Method | Purpose |
|---|---|---|
| `GET /healthz` | GET | Health check |
| `POST /search` | POST | Web search (SearXNG + Tavily fallback) |
| `GET /quote?q=` | GET | **Real-time quote** — A-share, HK, US stocks (incl. pre-market/after-hours), commodities |

---

## /search — Web Search

### How to Call

```bash
curl -fsS -X POST http://127.0.0.1:18000/search \
  -H "Content-Type: application/json" \
  -d '{"query":"fastapi dependency injection best practices","max_results":5}'
```

### Request Body

| Field | Type | Required | Constraints | Default |
|---|---|---|---|---|
| `query` | string | yes | 1–256 chars | — |
| `max_results` | int | no | 1–20 | 10 |
| `time_range` | string | no | `day`, `week`, `month`, `year` | auto-detect |
| `topic` | string | no | `"general"`, `"news"` | auto-detect |
| `days` | int | no | 1–30, only used when `topic="news"` | auto-detect |

> **`topic` field (Tavily)**:
> - `"news"` — uses Tavily's **news index** for time-sensitive queries. Combines with `days` to limit recency window. Use for: 最新新闻, 今日行情, breaking news, etc.
> - `"general"` — standard web search (default)
> - **Auto-detect**: if your query contains time-sensitive keywords (最新/新闻/今天/latest/news/today etc.), `topic` is automatically set to `"news"` and `days` is set based on `time_range` (day→1, week→7, month→30). You do NOT need to set these manually for typical news queries.

> **`days` field**: only applies when `topic="news"`. Limits Tavily results to the last N days.
> Auto-mapped: `time_range=day`→1 day, `week`→7 days, `month`→30 days.

> **`time_range` field**: applies to **SearXNG** (not Tavily). Use alongside `topic="news"` for best coverage from both sources.

### Response Schema

```json
{
  "query": "fastapi dependency injection best practices",
  "results": [
    {
      "title": "Dependencies - FastAPI",
      "content": "FastAPI has a very powerful but intuitive Dependency Injection system...",
      "url": "https://fastapi.tiangolo.com/tutorial/dependencies/",
      "source": "bing",
      "score": 0.72
    }
  ],
  "meta": {
    "cache_hit": false,
    "local_count": 8,
    "tavily_count": 0,
    "tavily_enabled": true,
    "tavily_used": false,
    "translated_query": null,
    "time_range": null,
    "fallback_reasons": []
  }
}
```

| Field | Description |
|---|---|
| `results[].source` | Real engine name: `"bing"`, `"baidu"`, `"juejin"`, `"csdn"`, `"github"`, `"stackexchange"`, `"sinafinance"`, `"36kr"`, `"tavily"` |
| `meta.translated_query` | Auto-translated English query for dual SearXNG search (null if not translated) |
| `meta.time_range` | Applied time filter for SearXNG: `day`/`week`/`month`/`year` or null |
| `meta.topic` | Effective Tavily topic: `"news"` or `"general"` or null |
| `meta.days` | Effective Tavily days window (only for `topic=news`) |
| `meta.fallback_reasons` | Why Tavily was triggered (see below) |

### Fallback Reasons

| Reason | Meaning |
|---|---|
| `low_local_recall` | SearXNG returned fewer than `LOCAL_MIN_RESULTS` (default 3) |
| `zh_en_translate` | Chinese query auto-translated to English for dual SearXNG search |
| `local_error` | SearXNG request failed or timed out |

---

## /quote — Real-time Stock & Commodity Quote

> ### 🔴 Trigger: Use `/quote` immediately for ANY of these user requests
> | User says | Call |
> |---|---|
> | "英伟达股价" / "NVDA 多少钱" / "帮我看下英伟达" | `GET /quote?q=NVDA` |
> | "特斯拉盘前" / "TSLA 夜盘" / "特斯拉延盘行情" | `GET /quote?q=TSLA` → read `extended` field |
> | "苹果股票" / "AAPL price" | `GET /quote?q=AAPL` |
> | "茅台今天" / "贵州茅台行情" / "600519" | `GET /quote?q=茅台` |
> | "黄金价格" / "金价" / "gold price" | `GET /quote?q=黄金` |
> | "原油" / "石油今天" / "oil price" | `GET /quote?q=原油` |
> | Any stock code: 600519, 002594, 00700, NVDA, AAPL, TSLA | `GET /quote?q=<code>` |
>
> **DO NOT** use browser_use, web search, or any other tool for the above —
> `/quote` returns structured real-time data directly.

Use this endpoint when the user asks about **stock price, market cap, change, volume** for A-share, HK, US stocks, or **commodity prices** (gold, oil, silver, copper, natural gas).

> **When to use /quote instead of /search**:
> - User asks about stock price, current quote, 盘前, 盘后, 夜盘, 延盘, 行情, 涨跌, 多少钱
> - User mentions a company name + 股票/price/涨跌 (茅台, 英伟达, 特斯拉, 苹果, 腾讯, 比亚迪…)
> - User mentions a ticker symbol (NVDA, AAPL, TSLA, MSFT…) or A-share/HK code
> - User asks about commodity price (黄金, 原油, 白银, 铜, 天然气…)
> - DO NOT use /search for these — it only returns article links, not live structured data
>
> **Cryptocurrency (比特币/以太坊 etc.)**: Use `/search` — Tavily handles it.

### How to Call

```bash
# Chinese name — must URL-encode (use --data-urlencode or %XX encoding)
curl -s --get --data-urlencode "q=茅台" "http://127.0.0.1:18000/quote"
curl -s --get --data-urlencode "q=白银" "http://127.0.0.1:18000/quote"
curl -s --get --data-urlencode "q=天然气" "http://127.0.0.1:18000/quote"

# ASCII ticker / code — can use directly
curl -s "http://127.0.0.1:18000/quote?q=600519"
curl -s "http://127.0.0.1:18000/quote?q=NVDA"
curl -s "http://127.0.0.1:18000/quote?q=00700"

# Python (httpx/requests auto-encode)
import httpx
r = httpx.get("http://127.0.0.1:18000/quote", params={"q": "英伟达"})
```

> **Note**: Chinese characters MUST be URL-encoded (e.g. `白银` → `%E7%99%BD%E9%93%B6`).
> In Python `httpx`/`requests`, passing `params={"q": "..."}` handles this automatically.

### Query Parameter

| Parameter | Description | Examples |
|---|---|---|
| `q` | Stock code, Chinese name, or commodity keyword | `茅台`, `600519`, `比亚迪`, `腾讯控股`, `00700`, `AAPL`, `黄金`, `原油`, `白银`, `铜`, `天然气` |

Supported markets:
- **Shanghai A-share**: 6-digit code starting with `6` (e.g. `600519`)
- **Shenzhen A-share**: 6-digit code starting with `0` or `3` (e.g. `002594`, `300750`)
- **Hong Kong**: 5-digit code (e.g. `00700`) or Chinese name
- **US stocks**: ticker symbol (e.g. `AAPL`, `TSLA`, `NVDA`) or Chinese name (e.g. `苹果`, `特斯拉`)
- **Commodities**: Chinese keyword or English code — see table below

| Keyword | English | Symbol | Unit |
|---------|---------|--------|------|
| `黄金` | gold / xau / gc | COMEX Gold | USD/oz |
| `白银` | silver / xag / si | COMEX Silver | USD/oz |
| `原油` / `石油` | crude / wti / cl | NYMEX WTI Crude | USD/bbl |
| `天然气` | natgas / ng | NYMEX Natural Gas | USD/MMBtu |
| `铜` | copper / hg | COMEX Copper | USD/lb |
| `铂金` | platinum / pl / xpt | NYMEX Platinum | USD/oz |
| `钯金` | palladium / pa / xpd | NYMEX Palladium | USD/oz |

### Response Schema

A-share / HK / US stock example:
```json
{
  "symbol": "sh600519",
  "name": "贵州茅台",
  "market": "SH",
  "currency": "CNY",
  "price": 1401.18,
  "open": 1415.0,
  "prev_close": 1426.19,
  "high": 1423.0,
  "low": 1392.09,
  "volume": 4801443,
  "amount": 6743267103.0,
  "change": -25.01,
  "change_pct": -1.75,
  "date": "2026-03-04",
  "time": "15:00:03",
  "cache_hit": false
}
```

Commodity example:
```json
{
  "symbol": "hf_GC",
  "name": "黄金 (COMEX)",
  "market": "COMEX",
  "currency": "USD",
  "unit": "USD/oz",
  "price": 5207.7,
  "open": 5207.4,
  "prev_close": 5207.0,
  "high": 5210.0,
  "low": 5092.8,
  "change": 0.7,
  "change_pct": 0.01,
  "date": "2026-03-04",
  "time": "18:13:51",
  "cache_hit": false
}
```

| Field | Description |
|---|---|
| `symbol` | Internal symbol (`sh`/`sz`/`hk`/`gb_`/`hf_` + code) |
| `price` | Current regular-session price |
| `change` | Price change vs previous close |
| `change_pct` | Percentage change (e.g. `-1.75` means -1.75%) |
| `volume` | Trading volume (shares) |
| `amount` | Trading amount (CNY/HKD) |
| `date` / `time` | Last update timestamp |
| `extended` | **US stocks only** — pre-market or after-hours data (see below) |
| `cache_hit` | Data served from cache (TTL: 60s) |

`extended` object (present only when US stock has extended-hours data):

| Field | Description |
|---|---|
| `extended.price` | Pre-market or after-hours price |
| `extended.change` | Change vs last regular-session close |
| `extended.change_pct` | Change % vs last regular-session close |
| `extended.datetime_est` | Timestamp in US Eastern Time (EST) |
| `extended.volume` | Extended-session trading volume |

### Error Responses

| HTTP Status | Meaning |
|---|---|
| 404 | Stock not found — unrecognized code or name |
| 502 | Quote data fetch failed (upstream issue) |

---

## Query Construction Guidelines

### Good Practices for /search

- Be specific: `"python requests library connection timeout error"` > `"python error"`
- For error debugging, include the key error message: `"ModuleNotFoundError: No module named 'pandas'"`
- For Chinese topics, use Chinese query: `"FastAPI 依赖注入 最佳实践"`
- Keep queries under 256 characters
- Use `max_results: 5` for focused questions, `max_results: 10` for exploratory research
- For news/current events, add "最新" or "latest" to the query, or explicitly set `topic: "news"` + `time_range: "day"`
- For breaking news (past 24h): `{"query": "...", "topic": "news", "time_range": "day", "days": 1}`
- For weekly news digest: `{"query": "...", "topic": "news", "time_range": "week"}` (days auto-set to 7)

### When to Use /quote vs /search

| User Intent | Use |
|---|---|
| "茅台今天股价多少" | `/quote?q=茅台` |
| "茅台最近新闻" | `/search` with `query: "茅台 最新新闻"` |
| "A股今天涨跌情况" | `/search` (general market overview) |
| "比亚迪现在多少钱" | `/quote?q=比亚迪` |
| "黄金价格" / "金价" | `/quote?q=黄金` |
| "国际油价" / "原油今天" | `/quote?q=原油` |
| "白银行情" | `/quote?q=白银` |
| "天然气价格" | `/quote?q=天然气` |
| "比特币价格" / "以太坊" | `/search` — Tavily handles crypto |
| "黄金相关新闻" | `/search` with `query: "黄金 最新新闻"` |

## Error Handling

| HTTP Status | Meaning | Agent Action |
|---|---|---|
| 200 | Success | Parse response |
| 400 | Bad request | Fix query and retry |
| 404 | Not found (/quote) | Try different name/code, or use /search |
| 429 | Rate limited (30 req/min + 10 burst) | Wait 60s then retry |
| 5xx | Server error | Inform user that service is temporarily unavailable |

## Rate Limits

- **30 requests per minute** per client IP, with **10 burst** allowance.
- Applies to both `/search` and `/quote`.
- Avoid calling in a loop; batch your information needs into fewer, well-crafted queries.

## Guardrails

- **Never expose `TAVILY_API_KEY`** in responses, logs, or prompts.
- Always include source URLs when presenting search results to the user.
- Keep search-based responses concise — summarize, don't dump raw results.
- Remember: this skill is an HTTP API. Never attempt to execute it as code.

