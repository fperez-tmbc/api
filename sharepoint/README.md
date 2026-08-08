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

---

## OneDrive / SharePoint admin operations (learned 2026-08-07)

From a OneDrive restore + tenant-wide site-collection-admin cleanup. `Sites.Read.All`
is **not** enough for most of this — see the permission notes at the end.

### Recycle bin: use `/_api/site/`, NOT `/_api/web/`

On a **personal (OneDrive) site**, `/_api/web/RecycleBin` returns `200` with **zero
items** even when the bin holds thousands. `$filter=ItemState eq 1|2` also returns 0.
This looks exactly like an empty recycle bin and led to a wrong "nothing to restore"
conclusion.

```bash
GET {site}/_api/web/RecycleBin        # 200, 0 items — LIES on personal sites
GET {site}/_api/site/RecycleBin       # correct; needs Sites.FullControl.All (403 otherwise)
```

- No `nextLink` / `$skiptoken` paging — page by **raising `$top`** until the returned
  count is less than the requested size (`$top=20000` returned all 18,215).
- Useful fields only: `Id, LeafName, DirName, DirNamePath, ItemType (1=file, 5=folder),
  ItemState (1=first-stage, 2=second-stage), Size, AuthorName, DeletedByName, DeletedDate`.
  **No original modified date / version info** is exposed while an item sits in the bin.
- Restore: `POST {site}/_api/site/recyclebin('{id}')/restore()` → `200 {"odata.null":true}`.
  Restoring **preserves original Created/Modified/author and version history** — it is an
  undelete of the same item.

### Graph `copy` destroys metadata; recycle-bin restore preserves it

Cross-drive **move is not supported** by Graph (`PATCH parentReference` is same-drive
only), so a "move" is copy + delete. But `driveItem: copy` creates a **new** item:
created/modified stamp to *now* and the author becomes the app (`SharePoint App`).
`includeAllVersionHistory: true` keeps versions but **not** provenance metadata.

If the originals are still in the source recycle bin, restoring them is far better
than copying. Sequence that works (order matters):

1. delete the copied **files**
2. delete the now-empty **folders**, deepest-first
3. restore original **folders**, shallowest-first
4. restore original **files**

Make it idempotent by author: only delete items whose `createdBy` is `SharePoint App`,
and only restore bin entries whose `DeletedByName` is the human who did the move. That
way a re-run can never eat a restored original or resurrect your own deleted copy.

### Litigation hold blocks deleting NON-EMPTY folders

```
403 accessDenied — "Request was cancelled by event received. If attempting to
delete a non-empty folder, it's possible that it's on hold"
```

Files delete fine; **empty** folders delete fine (`204`). Only non-empty folders are
refused. Hence the empty-then-delete ordering above.

### Site lock state — read/write via CSOM against the -admin site

Graph does not expose `LockState`. `Set-SPOSite -LockState` is CSOM under the hood and
can be driven directly with `Sites.FullControl.All` — no PowerShell needed:

```
POST https://{tenant}-admin.sharepoint.com/_vti_bin/client.svc/ProcessQuery
Content-Type: text/xml
Tenant TypeId: {268004ae-ef6b-4e9b-8425-127220d84719}
  GetSitePropertiesByUrl(url, false) → Query LockState / Status / StorageUsage / Owner
  SetProperty LockState = "Unlock" | "ReadOnly" | "NoAccess", then Method Update
```

Takes effect in seconds. A `ReadOnly` site rejects **every** write, including site
collection admin changes, with the misleading
`"You need to be a site collection administrator to set this property."` — that is a
lock, not a permissions problem. Check `LockState` before diagnosing permissions.

### `423 notAllowed` is NOT a site lock

38 OneDrives returned `403` to SharePoint REST and `423 notAllowed — "Access to this
site has been blocked"` to Graph, while reporting `LockState: Unlock`. These are
departed-user OneDrives in a retention/pending-deletion state. **`Set-SPOSite
-LockState Unlock` will not clear it** (an earlier note here claiming otherwise was
wrong). Cause still unresolved — treat these as un-auditable while the account stays
deleted.

### Site collection admins over REST

```
GET  {site}/_api/web/siteusers?$select=Title,Email,LoginName,IsSiteAdmin&$top=500
POST {site}/_api/web/siteusers(@v)?@v='{urlencoded LoginName}'
     X-HTTP-Method: MERGE, IF-MATCH: *, odata=verbose
     body: {"__metadata":{"type":"SP.User"},"IsSiteAdmin":false}
```

`LoginName` format is `i:0#.f|membership|user@domain` and must be **fully URL-encoded**
(the `#` and `|` both matter). Removing admin leaves the person as a site *user* — that
is expected, and is how you re-add them.

Enumerate every OneDrive with search from the **-my** host:

```
GET {tenant}-my.sharepoint.com/_api/search/query
    ?querytext='contentclass:STS_Site AND SiteTemplate:SPSPERS'
    &trimduplicates=false&rowlimit=500&selectproperties='Path,Title'
```

### People picker filters on accountEnabled, NOT licensing

`ClientPeoplePickerSearchUser` returns **nothing** for a disabled account, even a
licensed one — so admin dialogs show *"No exact match was found … This entry is not
found"* and refuse to save. Tested every combination:

| accountEnabled | licensed | resolves |
|---|---|---|
| true  | yes | ✅ |
| true  | **no**  | ✅ |
| false | yes | ❌ |
| false | no  | ❌ |

So **assigning a licence does not help**; only re-enabling does. For a directory-synced
user that means `Enable-ADAccount` on-prem + delta sync (resolved within ~1 min, no UPA
lag observed). Better still, avoid the picker: REST/CSOM does not use it. A **deleted**
account can never be resolved and will break the dialog permanently — clear the entry
via REST.

### Permissions actually required (app-only, direct appRoleAssignment)

| Task | Needs |
|---|---|
| Read site users / admins | `Sites.Read.All` (SharePoint) |
| Read `/_api/site/RecycleBin`, restore, set LockState | **`Sites.FullControl.All`** (SharePoint) |
| Read/write drive items | `Files.ReadWrite.All` (Graph) |

`Sites.Manage.All` is **not** sufficient for the site-collection recycle bin — still 403.
Grant these as **direct `appRoleAssignment`s** on the `claude-m365` SP; never use admin
consent on that app (it reconciles to an incomplete manifest and strips
`Exchange.ManageAsApp` + Graph roles). Role propagation into a new token takes ~30 s.
