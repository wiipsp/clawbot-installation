# hybrid-search skill

A hybrid web search skill for OpenClaw / CoPaw that routes queries through
a self-hosted SearXNG instance with Tavily API fallback.

## Prerequisites

The search service must be deployed **before** registering this skill.
See `hybrid-search/deploy/README.md` for deployment instructions.

After deployment you should have:
- SearXNG running on port `18999`
- Adapter running on port `18000`
- Redis running as cache backend

Verify with:

```bash
curl -fsS "http://<adapter-ip>:18000/healthz"
# → {"ok":true}
```

## Folder Structure

```text
skills/hybrid-search/
  SKILL.md              # Skill definition (read by agent framework)
  README.md             # This file
  config/
    defaults.yaml       # Reference: runtime defaults documentation
    engines.yaml        # Reference: SearXNG engine list documentation
  tests/
    test-cases.md       # Validation scenarios and smoke tests
```

## Register in OpenClaw / CoPaw

### OpenClaw

```json5
{
  skills: {
    entries: {
      "hybrid-search": {
        enabled: true,
        env: {
          SEARXNG_BASE_URL: "http://127.0.0.1:18999/",
          ADAPTER_BASE_URL: "http://127.0.0.1:18000/",
          TAVILY_API_KEY: "tvly-xxxx"
        }
      }
    }
  }
}
```

### CoPaw (if config format differs, adapt accordingly)

```json5
{
  skills: {
    "hybrid-search": {
      path: "hybrid-search/skills/hybrid-search/SKILL.md",
      env: {
        SEARXNG_BASE_URL: "http://127.0.0.1:18999/",
        ADAPTER_BASE_URL: "http://127.0.0.1:18000/",
        TAVILY_API_KEY: "tvly-xxxx"
      }
    }
  }
}
```

> Replace IPs with your actual VPC internal addresses.
> Never commit real `TAVILY_API_KEY` values to version control.

## Runtime Defaults

| Parameter | Default | Notes |
|---|---|---|
| Request timeout | 8000 ms | Total request timeout |
| Local min results | 3 | Below this triggers Tavily fallback |
| EN/ZH default weight | 0.65 / 0.35 | Adjusts by query type |
| Cache TTL | 1800 s | 30 minutes |
| Rate limit | 30 req/min + 10 burst | Per client IP |

See `config/defaults.yaml` for the full reference.

## Smoke Test

After deployment and skill registration:

```bash
# Health check
curl -fsS "http://<adapter-ip>:18000/healthz"

# Search test (English)
curl -fsS -X POST "http://<adapter-ip>:18000/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"python fastapi dependency injection","max_results":5}'

# Search test (Chinese)
curl -fsS -X POST "http://<adapter-ip>:18000/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"机器学习 最新进展","max_results":5}'
```

Expected response structure:

```json
{
  "query": "机器学习 最新进展",
  "results": [
    {"title": "...", "content": "...", "url": "...", "source": "baidu", "score": 0.72},
    {"title": "...", "content": "...", "url": "...", "source": "juejin", "score": 0.68},
    {"title": "...", "content": "...", "url": "...", "source": "bing", "score": 0.65}
  ],
  "meta": {
    "cache_hit": false,
    "local_count": 12,
    "tavily_count": 0,
    "tavily_used": false,
    "translated_query": "machine learning latest",
    "fallback_reasons": ["zh_en_translate"]
  }
}
```

> `source` shows the real engine name (e.g. `bing`, `baidu`, `juejin`, `csdn`, `github`, `stackoverflow`, `tavily`).
> `translated_query` shows the auto-generated English query used for the second SearXNG request (null if not translated).
