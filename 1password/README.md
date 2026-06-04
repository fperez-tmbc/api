# 1Password Events API — field notes

Usage auditing for the 1Password Business account (themyersbriggs, `1password.com`/US).
Built to prioritize the 1Password **MSI → MSIX** migration (uninstall the broken
`8.12.22` MSI off active Windows-desktop users first).

## Auth / endpoint

- **Token:** `~/GitHub/.tokens/1password-events` — Events Reporting bearer JWT (read-only).
  Created in 1Password.com → **Integrations → Events Reporting → Other** → issue bearer token.
  Token's `aud` claim carries the base host; `fts` carries granted event types.
- **Base URL (US):** `https://events.1password.com`
  (Canada `.ca`, Europe `.eu`, Enterprise `events.ent.1password.com`.)
- **Auth header:** `Authorization: Bearer <token>`
- **Connectivity test:** `GET /api/auth/introspect` → `{UUID, IssuedAt, Features[]}`

## Endpoints used

POST (cursor-paginated):
- `/api/v1/signinattempts` — every sign-in session (all vaults). Primary "is this user
  active on the Windows desktop app" signal.
- `/api/v1/itemusages` — item views/copies/edits. **Only logs items in SHARED vaults**,
  not Private/Personal — so it under-counts. Use as a secondary signal.

Request body: first call `{"limit":1000,"start_time":"<RFC3339>"}`; then `{"cursor":"<cursor>"}`
until `has_more` is false. Items in `items[]`.

## Key fields & gotchas

- `client.platform_name` is the **device/machine name** for native apps
  (e.g. `RMDVANDYS04`), the browser ("Chrome extension") for extensions, and the pod
  name for the SCIM bridge. This gives **user → machine** straight from the API.
- `client.app_name`: `1Password for Windows` / `1Password for Mac` / `1Password Browser
  Extension` / `1Password for Web` / `1Password CLI` / `1Password for iOS` / `1Password SCIM Bridge`.
- `client.app_version` desktop build string decodes as `8.MM.PP.bbb`:
  `81222017`→8.12.22, `81221001`→8.12.21, `81212044`→8.12.12.
  **Version alone can't distinguish a broken MSI from a working MSIX** (both report
  8.12.22) — cross-reference PDQ's `Applications.Uninstall` (MsiExec product code) to
  confirm the MSI is actually present.
- User object is `target_user` on signinattempts, `user` on itemusages
  (`{uuid,email,name}`). Sign-in `category=="success"` = real session.

## Script

`events_audit.py [DAYS]` (default 60) — pulls both streams, lists distinct clients,
and ranks users by recency/volume of **Windows desktop** activity (with machine +
version). Writes `/tmp/1p_audit.json` for cross-referencing with PDQ Inventory.

Cross-reference with PDQ Inventory (`/pdq`) on machine name to confirm the MSI is still
installed and to get `CurrentUser` / scan freshness / Intune (IME) membership.
