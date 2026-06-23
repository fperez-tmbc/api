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

## Gotcha — ad capture is volatile / unreliable

`paid[]` is **frequently empty** even for high-competition queries. Observed the
*same* query (`car insurance quotes`, US) return 1 paid ad and then 0 ads minutes
later. Google appears to suppress ads for scraper/proxy traffic. For an
ad-monitoring use case this is the central reliability risk. Levers worth testing
before relying on it: **premium proxy pool**, **JS rendering on**, `device_type:
mobile`, and **city-level geo** instead of country-level.

## Pricing

Free plan caps at **$1** (~a few hundred requests). The playground showed roughly
**$1.5 / 1,000 requests** for the selected config — verify per target/options
before forecasting cost. Cost ≈ `(countries × keywords) / 1000 × price_per_1k`.
