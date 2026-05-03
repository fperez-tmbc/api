# Drata API — Lessons Learned

## Reference
- V1 API: https://developers.drata.com/openapi/reference/v1/overview/
- V2 API: https://developers.drata.com/openapi/reference/v2/overview/

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

### Device Documents — `POST /devices/{deviceId}/documents`
- Uploads evidence for a specific device compliance check
- Multipart/form-data fields:
  - `type` (required): `HARD_DRIVE_ENCRYPTION_EVIDENCE`, `AUTO_UPDATES_EVIDENCE`, `ANTIVIRUS_EVIDENCE`, `PASSWORD_MANAGER_EVIDENCE`, `LOCK_SCREEN_EVIDENCE`
  - `file` (binary): accepted formats: .pdf, .docx, .odt, .doc, .xlsx, .ods, .pptx, .odp, .gif, .jpg, .jpeg, .png
  - `base64File` (string): alternative to binary file upload
- Returns 201 with `{id, name, type, fileUrl, createdAt, updatedAt}`
- `GET /devices/{deviceId}/documents` — list documents for a device
- `DELETE /devices/documents/{documentId}` — remove a document
- `GET /devices/documents/{documentId}/download` — returns signed S3 URL

### Evidence Library — `POST /workspaces/{workspaceId}/evidence-library`
- Standalone evidence items that can be linked to controls at creation via `controlIds[]`
- Multipart/form-data; required fields: `name`, `renewalDate`, `renewalScheduleType`, `source`, `filedAt`, `ownerId`
- `source` enum: `URL`, `S3_FILE`, `TICKET_PROVIDER`, `NONE`, `GOOGLE_DRIVE`, `ONE_DRIVE`, `BOX`, `DROPBOX`, `SHARE_POINT`, `TEST_RESULT`
- `renewalScheduleType` enum: `ONE_MONTH`, `TWO_MONTHS`, `THREE_MONTHS`, `SIX_MONTHS`, `ONE_YEAR`, `CUSTOM`, `NONE`

### Controls — External Evidence — `POST /workspaces/{workspaceId}/controls/{id}/external-evidence`
- Uploads evidence directly to a control (not a device)
- Required fields: `creationDate`, `renewalDate`, `renewalScheduleType`
- `GET /controls/{id}/external-evidence` — list evidence mapped to a control
- `DELETE /external-evidence/{id}` — remove evidence from a control

## Gotchas
- `GET /personnel/{id}/devices` response may be a bare list `[]` or `{"data": []}` — handle both
- `autoUpdateEnabled` can be `null` (check not run / MDM doesn't report it), not just true/false
- Personnel list filter `autoUpdatesCompliance` is a **personnel-level** rollup — a person flagged non-compliant may have multiple devices, only some of which are the problem; always fetch individual devices to confirm
- **`employmentStatuses[]` filter causes 400 in all forms** (with brackets, without, with index) — do not use it; apply employment status filtering client-side after fetching all records
- **Employment status values use full strings**: `CURRENT_EMPLOYEE`, `FORMER_EMPLOYEE`, `SERVICE_ACCOUNT`, `OUT_OF_SCOPE`, `FORMER_CONTRACTOR` — not short forms like `CURRENT`
- **`user` field structure**: name is `user.firstName` + `user.lastName`; email is `user.email` — there is no `user.name` field and identities do not carry email in this context
- **Personnel list is heavily polluted with service accounts** — health mailboxes and other service accounts dominate the early pages; actual employees may not appear until page 2 or 3 when paginating with `limit=50`
- **Device document upload uses `multipart/form-data`** — pass `file` as a named binary field with a filename and MIME type; passing raw bytes without a filename causes a 400
