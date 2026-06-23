# Decodo Web Scraping API Field Notes

Decodo (formerly Smartproxy) Web Scraping API — used for SERP scraping (Google
Search) to detect trademark-infringing ads. Project: `themyersbriggs/trademark-ad-monitor`.

## Connection

| Field | Value |
|-------|-------|
| Real-time (sync) | `https://scraper-api.decodo.com/v2/scrape` |
| Async (single) | `https://scraper-api.decodo.com/v2/task` |
| Async (batch) | `https://scraper-api.decodo.com/v2/task/batch` |
| Creds file | `~/GitHub/.tokens/decodo` (JSON: `username`, `password`, `basic_token`) |
| Web Scraping API user | `U0000439745` |
| Plan | Free Web Scraping API plan ($1 budget / 365 days) on the proxies account |

## Auth — IMPORTANT gotcha (two credential types, easy to confuse)

Decodo has **two unrelated credential systems**. Only one works with the scraper API:

1. **Account → API Keys tab** — named keys (e.g. `scraping-automation`), value is a
   long hex string. This is a *different* auth system. Passing it as
   `Authorization: Basic <hexkey>` against `/v2/scrape` returns
   **`401 {"status":"failed","message":"Username invalid."}`**. Do **not** use it here.
2. **Web Scraping API → Authentication tab** — a `username` + `password` (and a
   pre-generated Basic token). **This is what `/v2/scrape` wants.**

Auth is standard HTTP Basic = `base64(username:password)`:

```bash
TOKEN=$(python3 -c "import json;print(json.load(open('$HOME/GitHub/.tokens/decodo'))['basic_token'])")
curl -s -X POST https://scraper-api.decodo.com/v2/scrape \
  -H "Authorization: Basic ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"target":"google_search","query":"mbti free","geo":"India","device_type":"desktop","page_from":"1","page_count":1,"parse":true}'
# or:  curl -u "$USER:$PASS" ...
```

## SERP request (google_search)

| Param | Notes |
|-------|-------|
| `target` | `google_search` (also `bing_search`, etc.) |
| `query` | the search phrase |
| `geo` | country **name** works (e.g. `"India"`, `"United States"`); also city/coords |
| `device_type` | `desktop`, `desktop_chrome`, `mobile`, `mobile_ios`, ... |
| `page_from` / `page_count` | 1-10; each page ≈ 10 results |
| `parse` | `true` → structured JSON (default false = raw HTML) |
| `headless` | `png`/`html` for rendered output (PNG screenshots — not yet validated) |

## Parsed response shape

Sections are **three levels deep**:

```
body["results"][0]["content"]["results"]["results"]   # -> the SERP sections
  -> { organic[], paid[], pla[], related_questions[], related_searches[],
       videos[], search_information{}, total_results_count, navigation }
```

`paid[]` (text ads) fields that matter:

| Field | Meaning |
|-------|---------|
| `title` | ad headline |
| `desc` | ad body text |
| `data_rw` | the long Google **`/aclk?...&adurl`** click-tracking URL |
| `data_pcu` | list of clean display URLs (advertiser domain, e.g. `https://www.progressive.com/`) |
| `pos` / `pos_overall` | rank within ads / overall |
| `sitelinks` | ad sitelinks |

`pla[]` = product-listing / shopping ads (different shape).

## Getting ads to appear (SOLVED — use google_ads + JS rendering)

With `target=google_search` and no rendering, `paid[]` came back **empty even for
high-competition queries** (Google suppresses ads for non-human-looking traffic).
The same `car insurance quotes` query returned 1 ad then 0 minutes later.

**Fix (measured 0 → 5-6 ads on the same queries):**

- Use `target=google_ads` — purpose-built to surface paid ads "at the highest ad
  display rate". Works on the **Free** plan (docs say "Advanced plan" but it ran
  fine; watch for enforcement / higher cost).
- Set `headless: "html"` (JS rendering) — ads are JS-injected and absent from
  static HTML.

```json
{"target":"google_ads","query":"myers briggs test","geo":"United States",
 "device_type":"desktop","page_count":1,"parse":true,"headless":"html"}
```

Real run caught `mytraitprofile.com` and `mindprofile.co` (infringers) plus
`mbtionline.com` (own/partner). Remaining misses are **real ad-inventory
variance** (low-competition term+geo genuinely has no live ads), mitigated by
broad keywords + repeat sampling. Further levers: `device_type: mobile`,
city-level geo.

## Targets / search engines

`google_search`, `google_ads`, `google_ai_mode`, `bing_search`, plus Amazon,
Walmart, Target, YouTube, Reddit, TikTok, ChatGPT, Perplexity. For SERP ad
monitoring use **`google_ads`**; `bing_search` for Bing (its parsed ad-field
shape is not yet validated here).

## Pricing (confirmed from dashboard 2026-06-23, per 1k requests)

Rate depends on proxy pool + JS rendering. Free-plan rates:

| Pool | rate /1k |
|------|----------|
| Standard | $0.50 |
| Standard + JS | $0.75 |
| Premium | $1.00 |
| **Premium + JS** | **$1.50** |

Template targets (incl. `google_ads`) run on the **Premium** pool, and we enable
JS rendering (`headless:html`), so our effective rate is **Premium + JS =
$1.50/1k** on the free plan. Paid plans lower this toward ~$1.00-1.20/1k. The free
plan = **$1** of usage ≈ **666 requests** at $1.50/1k. Rate limit 10 req/s (free).

Cost ≈ `(countries × keywords) / 1000 × 1.50`.
