# themyersbriggs.com Google Landscape

Point-in-time survey taken **2026-08-19**, the day API access was established.
Everything here was read from the live APIs, not inferred. Re-run the commands in
`README.md` to refresh.

Purpose: know what exists before work arrives, so tasks can start immediately.

---

## Summary

A small, young Google Workspace tenant that is **not a workplace**. Nobody does email or
documents here in any meaningful volume. What it actually is:

1. An **identity provider**, where SaaS tools are signed into with Google accounts
2. A **GCP host** for a consumer-facing B2C build (MBTI For You, Strong)
3. A small **endpoint management** footprint

Matt Humora is effectively the only user. Frank's access was added 2026-08-19.

---

## Tenant

| Field | Value |
|-------|-------|
| Primary domain | themyersbriggs.com |
| Customer ID | C0314gz35 |
| Created | 2025-11-25 |
| Licences | 5 × Google Workspace Business Standard (SKU 1010020028) |
| Registered contact | Matthew Humora, The Myers Briggs Company, US |
| Total storage used | 218 MB of 6 TB |

### Domains

| Domain | Type | Verified |
|--------|------|----------|
| themyersbriggs.com | primary | yes |
| mbti.com | alias | yes (added 2026-08-05) |
| themyersbriggs.com.test-google-a.com | alias | yes |

**Mail does not route to Google.** MX for themyersbriggs.com points at
`owa.themyersbriggs.com`. Google mailboxes exist but sit outside the normal Exchange and
Mimecast path.

---

## Users

| User | OU | Admin | Created | Last login |
|------|----|-------|---------|------------|
| mhumora | `/0314gz35` | **super** | 2025-11-14 | 2026-08-19 |
| asherwood | `/` | no | 2025-11-26 | 2026-08-05 |
| fperez | `/` | **super** | 2026-08-19 | 2026-08-19 |
| support | `/` | no | 2026-08-18 | 2026-08-18 |
| svaradaraj | `/` | no | **2023-08-28** | **2025-11-26** |

Super admin is held by mhumora and fperez. A third `_SEED_ADMIN_ROLE` assignment points
at principal `110857756164081126886`, which resolves to no current user.

**Groups:** exactly one, `supportaccount@themyersbriggs.com`.

**Org units:** five, and the naming is unusual. Four are named after Google customer IDs
(`/00jqfr32`, `/01grbd9y`, `/0314gz35`, `/03m3w1pv`) plus `/Workspace Guests`. That
pattern, combined with svaradaraj's account predating the tenant by two years, is the
signature of a Workspace transfer or unmanaged-account absorption rather than a
hand-built structure. Worth understanding before reorganising anything.

---

## Actual usage (measured 2026-08-15)

Do not assume this tenant is idle, and do not assume it is busy. The numbers:

| Service | Result |
|---------|--------|
| Gmail | 0 MB stored. 1 account, 1 email received, 1 webmail user |
| Drive | 218 MB, 1 active user in 30 days, Google Slides only |
| Meet | zero across all 49 metrics |
| Classroom / ChromeOS / Apps Script | zero |
| Device management | 4 devices over 30 days (3 Mac, 1 Windows), 2 users |
| Authorized apps | 27 |

Per user, all of it is Matt:

| User | Drive | Gmail received (8/14, 8/15, 8/16) |
|------|-------|-----------------------------------|
| mhumora | 218 MB | 0, 1, 4 |
| asherwood | 0 | 0, 0, 0 |
| svaradaraj | 0 | 0, 0, 0 |

Matt's Gmail is low-volume but rising, not dormant.

---

## Identity: authorized third-party apps

This is the tenant's real function. Roughly 30 SaaS applications are signed into with
Google accounts, essentially all of them Matt's.

Nearly every one requests only `userinfo.profile`, `userinfo.email` and `openid`. That is
pure SSO with no access to Google data, which is the benign case.

Representative list: Atlassian, Bird (×2), ChatOn Web, Claude, Cloudflare Dashboard,
Cursor, DTS, Expensify, Figma, HubSpot, Lucidchart, Matecat, Mermaid Chart, Monotype,
Postman, Sentry, Shutterstock, Slack, Stripe, Tally, Vercel, Vimeo, 16Personalities,
axe DevTools, Google Chrome, Google Cloud SDK.

Two entries deserve attention:

- **`Untitled project`** requests `auth/forms`, a real data scope rather than plain SSO,
  under a client with no meaningful name. Unidentified.
- **`MBTI For You`** and **`Strong by The Myers-Briggs Company`** are not third-party at
  all. Their client IDs are the project numbers of `tmbc-b2c-prod` and `dev-b2cproject`
  respectively, so these are the company's own consumer apps.

---

## GCP

Organization **714796663328**, directory customer C0314gz35. One folder, `system-gsuite`.

### Projects

| Project ID | Name | Created | Owner |
|------------|------|---------|-------|
| `tmbc-b2c-prod` | tmbc-b2c-prod | 2026-08-19 | mhumora |
| `dev-b2cproject` | tmbc-b2c-dev | 2026-03-12 | mhumora |
| `hardy-force-505017-s5` | GoogleTagManagerAccess | 2026-08-09 | mhumora |
| `tmbc-fperez-automation` | TMBC Fperez Automation | 2026-08-19 | fperez |

The three B2C and GTM projects are Matt's production work. Treat anything outside
`tmbc-fperez-automation` as someone else's live environment.

### Org IAM

| Principal | Roles |
|-----------|-------|
| fperez | `resourcemanager.organizationAdmin`, `orgpolicy.policyAdmin` |
| mhumora | `resourcemanager.organizationAdmin`, `orgpolicy.policyAdmin` |
| asherwood | `cloud.admin` |
| `domain:themyersbriggs.com` | `billing.creator`, `projectCreator` |

Every user in the domain can create projects and billing accounts by default.

**No billing account is visible.** Anything requiring billing (most of Compute, most of
BigQuery) will refuse to run.

### Org policies in force

Eight constraints are set at the organization, all Google secure-by-default for orgs
created after May 2024:

- `iam.disableServiceAccountKeyCreation`
- `iam.disableServiceAccountKeyUpload`
- `iam.automaticIamGrantsForDefaultServiceAccounts`
- `iam.allowedPolicyMemberDomains`
- `essentialcontacts.allowedContactDomains`
- `storage.uniformBucketLevelAccess`
- `compute.restrictProtocolForwardingCreationForTypes`
- `compute.setNewProjectDefaultToZonalDNSOnly`

`iam.allowedPolicyMemberDomains` will block adding external identities to IAM policies,
which is the one most likely to surprise you during real work.

---

## Known gaps in this survey

- **Device enumeration is unavailable.** `gam print devices` requires a service account
  key, which org policy forbids. Aggregate device counts come from the Reports API
  instead. Per-device detail needs the Admin console.
- **No GA4, Tag Manager or Search Console assets** are visible to fperez, despite a
  project literally named GoogleTagManagerAccess existing. Those almost certainly sit
  under Matt's account. Verified negative: the API calls succeeded and returned empty.
- Usage figures are a single day, 2026-08-15. Reports data lags 2 to 3 days.

---

## Things someone should probably act on

Not urgent, not mine to decide, but they fell out of the survey:

1. **`svaradaraj@themyersbriggs.com`** has not logged in since 2025-11-26. Nine months
   dormant, still enabled, still consuming a Business Standard licence.
2. **One device is flagged risky** (`device_management:num_30days_risky_devices = 1`)
   out of four managed.
3. **2SV is not enforced** for anyone. Of 3 users measured, 1 was enrolled, 2 were not,
   and enforcement was off for all 3.
4. **The `Untitled project` OAuth grant** holds a Forms data scope under an unnamed
   client.
5. **A stale super-admin assignment** points at a principal that resolves to no user.
6. **Matt receives mail in Gmail** on a domain whose MX is Exchange, so that traffic
   bypasses the Exchange and Mimecast controls entirely.
