# Test Cases for hybrid-search

> Replace `<ADAPTER>` with your actual adapter address, e.g. `http://127.0.0.1:18000`.

## Case 1: Health Check

```bash
curl -fsS "<ADAPTER>/healthz"
```

**Assert**: Response is `{"ok":true}`, HTTP 200.

---

## Case 2: Chinese Technical Query

```bash
curl -fsS -X POST "<ADAPTER>/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"机器学习 最新 进展","max_results":5}'
```

**Assert**:
- HTTP 200
- `results` array is non-empty
- `results[].url` contains no duplicates
- `results[].source` is a real engine name (e.g. `"baidu"`, `"juejin"`, `"bing"`)
- `meta.local_count` >= 1
- `meta.translated_query` is non-null (Chinese query triggers auto-translation)
- `meta.fallback_reasons` contains `"zh_en_translate"`
- All `results` have non-empty `title`, `url`, and `content`

---

## Case 3: English Coding Query

```bash
curl -fsS -X POST "<ADAPTER>/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"fastapi dependency injection best practices","max_results":5}'
```

**Assert**:
- HTTP 200
- `results` array is non-empty
- `meta.fallback_reasons` is empty (English query, no translation needed)
- `meta.translated_query` is `null`
- EN-source results (GitHub, StackOverflow, Bing) appear in top results
- No duplicate URLs in `results`

---

## Case 4: Low Recall — Tavily Fallback

```bash
curl -fsS -X POST "<ADAPTER>/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"very niche framework runtime internals obscure topic","max_results":5}'
```

**Assert**:
- HTTP 200
- If `meta.local_count` < 3, then `meta.fallback_reasons` contains `"low_local_recall"`
- If Tavily key is set, `meta.tavily_used` may be `true`
- Response still contains usable `results` (even if few)

---

## Case 5: Tavily Key Missing — Graceful Degradation

Set `TAVILY_API_KEY=` (empty) in deploy `.env`, restart, then:

```bash
curl -fsS -X POST "<ADAPTER>/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"python asyncio tutorial","max_results":5}'
```

**Assert**:
- HTTP 200 (no crash)
- `meta.tavily_enabled` is `true` but `meta.tavily_used` is `false`
- `meta.tavily_count` is `0`
- Results come from SearXNG only
- No API key appears in response body

---

## Case 6: Rate Limiting

Send 41+ requests within 60 seconds from the same IP:

```bash
for i in $(seq 1 42); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "<ADAPTER>/search" \
    -H "Content-Type: application/json" \
    -d '{"query":"rate limit test","max_results":1}')
  echo "Request $i: HTTP $code"
done
```

**Assert**:
- First ~40 requests return HTTP 200 (30 RPM + 10 burst)
- Subsequent requests return HTTP 429
- 429 response body contains error detail, no crash

---

## Case 7: Input Validation

### 7a: Empty query

```bash
curl -s -o /dev/null -w "%{http_code}" -X POST "<ADAPTER>/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"","max_results":5}'
```

**Assert**: HTTP 400 or 422

### 7b: Query too long (> 256 chars)

```bash
long_query=$(python3 -c "print('a' * 300)")
curl -s -o /dev/null -w "%{http_code}" -X POST "<ADAPTER>/search" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"$long_query\",\"max_results\":5}"
```

**Assert**: HTTP 400 or 422

### 7c: max_results out of range

```bash
curl -s -o /dev/null -w "%{http_code}" -X POST "<ADAPTER>/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"test","max_results":100}'
```

**Assert**: HTTP 422 (Pydantic validation)

---

## Case 8: Cache Behavior

```bash
# First request
curl -fsS -X POST "<ADAPTER>/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"cache test query","max_results":3}' | python3 -c "import sys,json; print(json.load(sys.stdin)['meta']['cache_hit'])"
# → False

# Immediate second request (same query)
curl -fsS -X POST "<ADAPTER>/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"cache test query","max_results":3}' | python3 -c "import sys,json; print(json.load(sys.stdin)['meta']['cache_hit'])"
# → True
```

**Assert**:
- First call: `meta.cache_hit` is `false`
- Second call: `meta.cache_hit` is `true`

---

## Case 9: VPC Network Isolation

**From inside VPC** (same CIDR as `ALLOW_CIDR`):

```bash
curl -fsS "<ADAPTER>/healthz"
# → {"ok":true}
```

**From outside VPC** (different network):

```bash
curl --connect-timeout 5 "http://<public-ip>:18000/healthz"
# → Connection refused or timeout
```

**Assert**: Only VPC-internal traffic is accepted.

---

## Case 10: Time-Sensitive Query (Auto-detect)

```bash
curl -fsS -X POST "<ADAPTER>/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"AI 最新新闻","max_results":5}'
```

**Assert**:
- HTTP 200
- `meta.time_range` is `"week"` (auto-detected from "最新" / "新闻")
- Results are recent (within last week)
- Cache TTL is shortened (5 min instead of 30 min)

---

## Case 11: Explicit time_range Parameter

```bash
curl -fsS -X POST "<ADAPTER>/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"python release","max_results":5,"time_range":"month"}'
```

**Assert**:
- HTTP 200
- `meta.time_range` is `"month"`
- Results are filtered to last month

---

## Case 12: Invalid time_range

```bash
curl -s -o /dev/null -w "%{http_code}" -X POST "<ADAPTER>/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"test","time_range":"invalid"}'
```

**Assert**: HTTP 400
