# Drata API — Lessons Learned

## Authentication
- Bearer token: `Authorization: Bearer <API_KEY>` header on all requests
- API key stored locally at `~/GitHub/.tokens/drata` (not in this repo)
- Scripts load key via `DRATA_API_KEY` env var, falling back to the token file

## V1 vs V2

| | V1 | V2 |
|---|---|---|
| Base URL | `https://public-api.drata.com/public` | `https://public-api.drata.com/public/v2` |
| Pagination | `page` + `limit` (max 50) | cursor-based (`cursor` + `size`, max 500) |
| Best for | Personnel, Devices | Assets |

## Key Endpoints

### Personnel — `GET /personnel`
- Filter compliance issues directly in the query (avoids client-side filtering):
  - `autoUpdatesCompliance=false` — employees failing auto-update check
  - `deviceCompliance=false` — employees failing overall device compliance
  - `employmentStatuses[]=CURRENT` — limit to active employees
- Response includes nested `user.identities[]` for email addresses

### Devices — `GET /personnel/{id}/devices`
- Use `expand[]=complianceChecks` to get per-check compliance fields
- Key compliance fields on each device:
  - `autoUpdateEnabled` (bool | null)
  - `encryptionEnabled`, `firewallEnabled`, `antivirusEnabled`, `passwordManagerEnabled`
  - `isDeviceCompliant` — overall pass/fail
- `sourceType` tells you the MDM source: JAMF, INTUNE, KANDJI, JUMPCLOUD, AGENT, etc.

### Assets (V2) — `GET /assets`
- Cursor-based pagination; can fetch up to 500 per page
- `expand[]=complianceChecks` for device compliance detail
- `employmentStatus` filter available; `userId` to scope to one person

## Gotchas
- `GET /personnel/{id}/devices` response may be a bare list `[]` or `{"data": []}` — handle both
- `autoUpdateEnabled` can be `null` (check not run / MDM doesn't report it), not just true/false
- Personnel list filter `autoUpdatesCompliance` is a **personnel-level** rollup — a person flagged non-compliant may have multiple devices, only some of which are the problem; always fetch individual devices to confirm
- **`employmentStatuses[]` filter causes 400 in all forms** (with brackets, without, with index) — do not use it; apply employment status filtering client-side after fetching all records
- **Employment status values use full strings**: `CURRENT_EMPLOYEE`, `FORMER_EMPLOYEE`, `SERVICE_ACCOUNT`, `OUT_OF_SCOPE`, `FORMER_CONTRACTOR` — not short forms like `CURRENT`
- **`user` field structure**: name is `user.firstName` + `user.lastName`; email is `user.email` — there is no `user.name` field and identities do not carry email in this context
