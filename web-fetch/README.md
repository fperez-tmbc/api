# Web Fetch Field Notes

Methods for retrieving web page content from the command line. Listed in order of preference (least effort first).

---

## Method 1: curl (static pages)

Works for any page that doesn't require JavaScript to render its content.

```bash
curl -s -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" \
  -H "Accept: text/html,application/xhtml+xml" \
  -H "Accept-Language: en-US,en;q=0.9" \
  -L "https://example.com"
```

**Gotchas:**
- `-A` (User-Agent) is required — many sites return 403 or a bot-detection page with the default curl UA
- `-L` follows redirects
- Pages that load content via JavaScript will return empty containers or placeholder HTML — no actual content

**When it fails:** You get back an HTML shell with `<div id="app"></div>` or similar empty containers, or a 403. Move to a site-specific trick or chrome --dump-dom.

---

## Method 2: Site-specific JSON/API endpoints

Many sites expose clean data endpoints that bypass JS rendering entirely.

### Reddit

Append `.json` to any post URL to get the full post + all comments as JSON:

```bash
curl -s -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" \
  -H "Accept: application/json" \
  -H "Accept-Language: en-US,en;q=0.9" \
  "https://www.reddit.com/r/sysadmin/comments/POSTID/post_title/.json?limit=100"
```

Parse with Python:
```python
import json, html, sys

data = json.load(sys.stdin)

def clean(text):
    return html.unescape(text or '').strip()

def print_comments(listing, depth=0):
    if not listing or listing.get('kind') != 'Listing':
        return
    for child in listing.get('data', {}).get('children', []):
        kind = child.get('kind')
        d = child.get('data', {})
        if kind == 't1':
            author = d.get('author', '[deleted]')
            score = d.get('score', 0)
            body = clean(d.get('body', ''))
            indent = '  ' * depth
            print(f"{indent}--- u/{author} (score: {score}) ---")
            print(f"{indent}{body}\n")
            replies = d.get('replies')
            if replies and isinstance(replies, dict):
                print_comments(replies, depth + 1)
        elif kind == 'more':
            print(f"{'  '*depth}[+ {len(d.get('children',[]))} more not loaded]")

post = data[0]['data']['children'][0]['data']
print(f"Title: {post['title']}\nBody:\n{clean(post.get('selftext',''))}\n")
print("=== COMMENTS ===")
print_comments(data[1])
```

**Gotchas:**
- Saving a Reddit page via "Save As" in a browser captures pre-JS HTML — comments will be missing. Use the `.json` endpoint instead.
- The `.json` URL requires the same User-Agent header as above; plain curl returns 403.
- `?limit=100` fetches up to 100 top-level comments. Deeply nested threads may still show `[+ N more not loaded]`.

---

## Method 3: chrome --dump-dom (JS-rendered pages)

Launches headless Chrome, executes JavaScript, waits for the page to settle, then dumps the fully rendered DOM to stdout. Use this when curl returns empty containers and there's no site-specific API.

### macOS path
```bash
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
```

### Basic usage
```bash
"$CHROME" --headless --dump-dom "https://example.com"
```

### With JS settle time
```bash
"$CHROME" --headless --dump-dom --virtual-time-budget=5000 "https://example.com"
```
`--virtual-time-budget=N` (milliseconds) — advances virtual time to let timers/async JS fire before the dump. 5000ms is a reasonable default; increase for slow-loading pages.

### Suppress console noise
```bash
"$CHROME" --headless --dump-dom --virtual-time-budget=5000 \
  --disable-logging --log-level=3 \
  "https://example.com" 2>/dev/null
```

### Pipe into Python to strip tags
```bash
"$CHROME" --headless --dump-dom --virtual-time-budget=5000 "https://example.com" 2>/dev/null \
  | python3 -c "
import re, html, sys
content = sys.stdin.read()
text = re.sub(r'<[^>]+>', ' ', content)
text = re.sub(r'\s+', ' ', html.unescape(text))
print(text[:10000])
"
```

**Gotchas:**
- Some sites detect headless Chrome (missing plugins, `navigator.webdriver=true`) and serve a CAPTCHA or degraded page. Adding `--disable-blink-features=AutomationControlled` can help.
- Pages that require login won't work without passing cookies (`--user-data-dir` pointing to a logged-in Chrome profile).
- Output is still HTML — you still need to parse it. For structured data, look for JSON embedded in `<script>` tags before stripping all tags.
- Chrome must not already have a conflicting profile lock; use `--user-data-dir=$(mktemp -d)` to avoid conflicts.

### Full robust invocation
```bash
TMPDIR=$(mktemp -d)
"$CHROME" --headless --dump-dom \
  --virtual-time-budget=5000 \
  --disable-logging --log-level=3 \
  --user-data-dir="$TMPDIR" \
  --disable-blink-features=AutomationControlled \
  "https://example.com" 2>/dev/null
rm -rf "$TMPDIR"
```

---

## Decision Tree

```
Can curl return the content?
  YES → use Method 1 (curl)
  NO (empty containers / 403) →
    Is there a site-specific JSON/API endpoint?
      YES → use Method 2 (e.g. Reddit .json)
      NO →
        Try chrome --dump-dom (Method 3)
          Content still missing → page requires login or has strong bot detection;
          may need to save manually from a logged-in browser session
```

---

## Extracting Content from Saved HTML Files

When a page was saved from a browser (e.g. `reddit.txt`), comments and dynamic content may still be absent if the browser saved before JS finished. The file will be large HTML with minified JS bundles.

Useful extraction patterns:

```bash
# Strip all HTML tags and collapse whitespace
python3 -c "
import re, html, sys
with open('page.html') as f: content = f.read()
text = re.sub(r'<[^>]+>', ' ', content)
text = re.sub(r'\s+', ' ', html.unescape(text))
print(text)
"

# Find all <p> tag text
python3 -c "
import re, html
with open('page.html') as f: content = f.read()
for p in re.findall(r'<p[^>]*>(.*?)</p>', content, re.DOTALL):
    clean = re.sub(r'<[^>]+>', '', p).strip()
    clean = html.unescape(clean)
    if len(clean) > 50: print(clean)
"

# Extract JSON from a specific custom element
python3 -c "
import re, html
with open('page.html') as f: content = f.read()
# Adjust tag name as needed (shreddit-post, faceplate-markdown, etc.)
for m in re.findall(r'<shreddit-post[^>]*>', content, re.DOTALL):
    print(html.unescape(m[:2000]))
"
```

**Note:** If comments or body content are absent from a saved HTML file, the page likely loads them via JavaScript after the initial render. Use the `.json` endpoint (Reddit) or `chrome --dump-dom` to capture a fully rendered version instead of saving from the browser.
