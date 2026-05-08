# Zoho Mail API Notes

Field notes from hands-on work against the aionetworking.com Zoho Workspace org.
Covers OAuth setup, org details, working endpoints, known limitations, and gotchas.

---

## Org Details

| Field | Value |
|-------|-------|
| Domain | `aionetworking.com` |
| Data Center | US (`zoho.com`) |
| Org ID (zoid) | `923449493` |
| Admin account | `frank@aionetworking.com` |
| Admin accountId | `4454574000000008002` |

### Users

| Name | Email | accountId | zuid |
|------|-------|-----------|------|
| Frank Perez | frank@aionetworking.com | 4454574000000008002 | 923457178 |
| Anabella Ortiz | anabella@aionetworking.com | 4200425000000008002 | 923461951 |
| Dorian Ortiz | dorian@aionetworking.com | 4190883000000008002 | 923461760 |
| Jordyn Kusumoto-Perez | jordyn@aionetworking.com | 4186110000000008002 | 923462455 |
| Trishia Trammel | trishia@aionetworking.com | 4174218000000008002 | 923465404 |

---

## Authentication

Zoho uses OAuth 2.0. Credentials are stored at `~/GitHub/.tokens/zoho`.

**Token endpoint (US):** `https://accounts.zoho.com/oauth/v2/token`

**API base URL:** `https://mail.zoho.com/api/`

### Get a new access token from the refresh token

```bash
source <(grep -v '^#' ~/GitHub/.tokens/zoho | sed 's/^/export /')

curl -s -X POST "https://accounts.zoho.com/oauth/v2/token" \
  -d "grant_type=refresh_token" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "refresh_token=${REFRESH_TOKEN}"
```

### Scopes granted

The current Self Client has these scopes:

```
ZohoMail.organization.ALL
ZohoMail.accounts.ALL
ZohoMail.filters.ALL
ZohoMail.folders.ALL
```

### Regenerating a grant code (when refresh token is revoked)

1. Go to `https://api-console.zoho.com` → Self Client → Generate Code
2. Enter the scopes above (comma-separated, no spaces)
3. Paste the code and exchange it:

```bash
curl -s -X POST "https://accounts.zoho.com/oauth/v2/token" \
  -d "grant_type=authorization_code" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  -d "code=<GRANT_CODE>"
```

4. Save the new `refresh_token` to `~/GitHub/.tokens/zoho`

---

## Working Endpoints

### List all org users

```bash
curl -s "https://mail.zoho.com/api/organization/${ORG_ID}/accounts?limit=50" \
  -H "Authorization: Zoho-oauthtoken ${ACCESS_TOKEN}"
```

### Get a specific user account

```bash
curl -s "https://mail.zoho.com/api/accounts/${ACCOUNT_ID}" \
  -H "Authorization: Zoho-oauthtoken ${ACCESS_TOKEN}"
```

### Get filters + metaInfo for authenticated user

```bash
curl -s "https://mail.zoho.com/api/accounts/${ACCOUNT_ID}/filters" \
  -H "Authorization: Zoho-oauthtoken ${ACCESS_TOKEN}"
```

Returns `metaInfo` with feature toggles including `smartFilter`.

---

## Account Update API (`PUT /api/accounts/{accountId}`)

Uses a `mode` parameter to specify what to update. Documented modes:

| Mode | Required fields | Notes |
|------|----------------|-------|
| `updateDisplayName` | `displayName`, `sendMailId` | Admin also requires `zuid` |
| `addForwarding` | `forwardAddress` | |
| `enableForwarding` | `forwardId`, `status` | |
| `addVacationReply` | `fromDate`, `toDate`, `message` | |

Admin endpoint: `https://mail.zoho.com/api/organization/{zoid}/accounts/{accountId}`
(Same modes apply.)

---

## Known Limitations

### Smart Filters (Newsletter/Notifications folders)
- Zoho Mail automatically classifies emails into "Newsletter" and "Notifications" folders via Smart Filters.
- Smart Filters are driven by email header analysis (e.g., `List-Unsubscribe`).
- **Zoho's own documentation states: "Smart Filters cannot be exported or deleted."**
- The `smartFilter: true` flag is visible in the filters metaInfo response but has no documented write endpoint.
- No org-level admin toggle exists in the admin console or API.
- **Workaround:** Each user must manually disable it in Zoho Mail → Settings → Filters → Smart Filters.

### Conversation View
- Conversation View (email threading) is a per-user display preference.
- It is **not exposed via the API** — not in the Accounts API, Users API, or any other endpoint.
- The Accounts API `mode` parameter has no mode for this setting.
- **Workaround:** Each user must toggle it in Zoho Mail → Settings → Mail → Conversation View.

### Cross-user account access
- `ZohoMail.accounts.ALL` only grants access to the **authenticated user's own** account data via `/api/accounts/`.
- Accessing other users' account-level data (filters, folders) via admin credentials is not supported through standard endpoints — only the org-level user listing works.
- The org admin endpoint `https://mail.zoho.com/api/organization/{zoid}/accounts/{accountId}/` supports display name and forwarding updates but not filters or preferences.
