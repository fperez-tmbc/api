# DMARC Aggregate Reports — Notes

Reading DMARC aggregate (RUA) reports is the only reliable way to see **what is signing
and sending as your domain from outside your own tenant**. Mail logs show what touched
your infrastructure; these show what external receivers saw.

## Setup

- **RUA mailbox:** `domainr@themyersbriggs.com` — collects reports for **nine** domains,
  not just one. Every DMARC record checked so far points `rua=` **and** `ruf=` here.
- **Auth:** `claude-m365` cert, app-only, `Mail.Read` tenant-wide. See [[../intune/README.md]].
- Reports arrive as **gzip or zip XML attachments**.

```
v=DMARC1; p=quarantine; fo=1; rua=mailto:domainr@themyersbriggs.com; ruf=mailto:domainr@themyersbriggs.com
```

`fo=1` is set, so per-message **failure** reports land in the same mailbox. Those name the
selector directly and are useful for a single incident, but carry the same short horizon.

## Scripts

| Script | Purpose |
|---|---|
| `fetch-reports.py` | Download + decompress every attachment to `./reports/` (skips existing) |
| `analyze-reports.py <domain>` | Selector, envelope, and policy breakdown for one domain |
| `report-coverage.py` | How far back the data can possibly see, per domain |

```bash
./report-coverage.py                                  # bound your conclusions FIRST
./fetch-reports.py                                    # 10-15 min, ~1,900 Graph calls
./analyze-reports.py themyersbriggs.net
./analyze-reports.py themyersbriggs.net --grep s1,s2,em9338
./analyze-reports.py --list                           # per-domain breakdown only
```

`reports/` is gitignored. Fetch is separate from analysis on purpose: the download is slow
and you will change the question more than once.

## The traps

**Page the Graph message list to the end.** An unpaged call silently truncates. This
produced a baseline built on **65 of 1,911** reports and understated one selector's signing
count from 14,502 to 578 — an order of magnitude, in a direction that changed conclusions.

**Group by `<policy_published><domain>` before counting anything.** One mailbox holds
reports for nine domains. Mixing them yields plausible, wrong numbers.

**A `<record>` can hold several `<spf>` or `<dkim>` elements.** Reporters may document
every identity they evaluated. `gosecure.net` emits HELO **plus** envelope **plus**
header-from in a single record:

```xml
<identifiers><header_from>example.com</header_from></identifiers>
<auth_results>
  <spf><domain>o1.ptr7256.sendgrid.example.com.</domain><result>none</result></spf>
  <spf><domain>em3639.example.com</domain>            <result>pass</result></spf>
  <spf><domain>example.com</domain>                   <result>pass</result></spf>
</auth_results>
```

Counting each element as an independent observation invented a 44-message "this domain
sends from its bare apex envelope" finding that did not exist, and nearly blocked a correct
SPF change. **Records with exactly one `<spf>` give the real envelope**; records with
several are one message seen from multiple angles. `analyze-reports.py` separates them.

**`policy_evaluated` is per-record, not per-signature.** Attributing it to every selector in
a multi-signature record inflates pass counts.

**Retention is whatever the mailbox holds, and it is probably shorter than you assume.**
Verified 2026-07-31: five domains all start on the **same day** (2026-06-28) and the mailbox
only goes back to 2026-04-28. A simultaneous start across unrelated zones is when `rua=`
was set, not coincidence. Nothing older is visible.

## What this data can and cannot answer

| Source | Reach | Blind spot |
|---|---|---|
| DMARC aggregate reports | ~1 month here, every reporting receiver | receivers who don't report; anything before `rua=` was set |
| Mimecast `archive/search` | back to ~2015 | only mail touching a TMBC mailbox |
| Cloudflare DNS analytics | 7 days on a Free zone | sampled counts; presence reliable, magnitude not |

None of them alone answers *"does anything still use this sender"*. The 2026-07-31 eWAY
delegation removal needed all three plus a live message header before the answer was solid:
see `task-tracker/projects/sendgrid-sender-hygiene/`.

**Alignment reminder that matters when reading these:** SPF is evaluated on the **envelope**
(return-path), not the `From:` header. A subdomain envelope like `em3639.example.com`
satisfies relaxed DMARC alignment against `From: @example.com`, and carries its **own** SPF
record — so the apex SPF is never consulted for that mail. Getting this backwards leads to
keeping apex `include:` mechanisms that nothing uses.

Related: `../cloudflare/README.md` (DNS analytics as a usage signal), `../mimecast/README.md`
(archive + envelope reading), `../exchange/README.md`.
