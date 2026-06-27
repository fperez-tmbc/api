# SharePoint / OneDrive via Microsoft Graph — `claude-sharepoint` app

App-only access to read SharePoint & OneDrive file content via Microsoft Graph. Created 2026-06-19 because the **Azure CLI cannot get Graph `Sites`/`Files` scopes** (first-party preauthorization, `AADSTS65002` — see memory `reference-azcli-graph-sites-blocked`). Our own app reg can be granted these because we own it.

## App registration

| Field | Value |
|-------|-------|
| Display name | `claude-sharepoint` |
| Client ID | `e3a1e75f-6114-4aed-8f2e-7fbb4198bd0f` |
| SP object ID | `23863ebd-c35f-421c-8ab3-1c158403b111` |
| Tenant | The Myers-Briggs Company (`d5c15341-dfce-470a-bfdf-72c3dab91e7c`) |
| Permission | Microsoft Graph **`Sites.Read.All`** (application, admin-consented) — read-only, all SharePoint sites |
| Secret | 2-year, stored in creds file; expires 2028-06 |
| Credentials | `~/GitHub/.tokens/sharepoint-graph` (TENANT_ID, CLIENT_ID, CLIENT_SECRET) |

Why `Sites.Read.All` (all sites) rather than `Sites.Selected`: per-site `Sites.Selected` grants require `Sites.FullControl.All` to administer, which we can't drive via az. Read-only-all-sites also serves the planned SharePoint storage-consumption review. Tighten to `Sites.Selected` later if desired.

## Token + use

```bash
source ~/GitHub/.tokens/sharepoint-graph
TOKEN=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -d grant_type=client_credentials -d client_id=$CLIENT_ID -d client_secret=$CLIENT_SECRET \
  -d scope=https://graph.microsoft.com/.default \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

# token carries roles:["Sites.Read.All"]; common calls:
# search a file (MCP sharepoint_search gives driveId+itemId), then download content:
curl -s -L -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/drives/{driveId}/items/{itemId}/content" -o out.xlsx
# list a site's drives / search: /sites/{siteId}, /sites/{siteId}/drives, /search/query
```

## Notes / gotchas

- **Download driveItem content** (delegated would need `Files.Read`/`Sites.Read.All`; we use application `Sites.Read.All`). Endpoint: `GET /drives/{driveId}/items/{itemId}/content` (302 → pre-signed URL; `curl -L` follows it).
- The **M365 MCP connector** (`mcp__claude_ai_Microsoft_365__read_resource`) can also read file content, but returns a **flattened text rendering** of spreadsheets (loses sheets/columns). Use this app + openpyxl to parse real `.xlsx` structure.
- `driveId`/`itemId` for a known file: get them from MCP `sharepoint_search` results (the `uri` is `file:///{driveId}/{itemId}`).
- App-only = no user context; it can read any site. Audit via the app's sign-in logs if needed.
