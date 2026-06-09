# Box API Field Notes

Box enterprise for The Myers-Briggs Company / OPP (the legacy OPP tenant, brought over from the acquisition). Used for the OPP Box cleanup + account merge.

## Connection

| Field | Value |
|-------|-------|
| Enterprise | "The Myers-Briggs Company" / `tmbcshare.app.box.com`, **enterprise_id 240012** |
| API base | `https://api.box.com/2.0` |
| Token URL | `https://api.box.com/oauth2/token` |
| Creds file | `~/GitHub/.tokens/box.json` (`client_id`, `client_secret`, `enterprise_id`) |
| App | **tmbc-migration-admin** (Custom App, Client Credentials Grant) |
| Scopes | Read/write all files+folders, Manage users, Manage groups |
| Config | App + Enterprise Access; "Generate user access tokens" (as-user) ON; service account is **admin** role |

## Two ways in (use the right one)

- **claude.ai Box MCP connector** — content-only, acts as the single logged-in user (`john.rogers@opp.com`). Handy for quick reads and `get_file_content` (auto-saves large files to disk). **No delete tool.** Not enterprise-wide.
- **CCG API app (this)** — admin/enterprise scope: enumerate all users, crawl any user's content (As-User), manage collaborations, **delete/move**, etc. Use for admin tasks and execution.

## Auth (Client Credentials Grant)

```python
import json,urllib.request,urllib.parse,os,socket
socket.setdefaulttimeout(60)   # ALWAYS set this — see gotchas
c=json.load(open(os.path.expanduser("~/GitHub/.tokens/box.json")))
def mint():
    d=urllib.parse.urlencode({"grant_type":"client_credentials",
        "client_id":c["client_id"],"client_secret":c["client_secret"],
        "box_subject_type":"enterprise","box_subject_id":c["enterprise_id"]}).encode()
    return json.load(urllib.request.urlopen(urllib.request.Request(c["token_url"],data=d)))["access_token"]
TOK=[mint()]   # ~60 min lifetime; re-mint on HTTP 401
def api(method,path,uid=None):
    h={"Authorization":f"Bearer {TOK[0]}"}
    if uid: h["As-User"]=str(uid)
    return urllib.request.urlopen(urllib.request.Request("https://api.box.com/2.0"+path,headers=h,method=method),timeout=120)
```

Token from CCG with `box_subject_type=enterprise` is the **service account** (admin). The service account's own root (folder `0`) is empty — content is owned per-user, so use **As-User** to see it.

## As-User

Add header `As-User: <user_id>` to act as a managed user. Folder `0` is then *that user's* root. Required for reading/owning content.

| User | ID | Note |
|------|----|----|
| john.rogers@opp.com | `193816152` | Admin, ~763 GB, holds nearly all content |
| sally.george@opp.com | `266207637` | ~10 GB real business content (MBTI materials/videos) |
| cmonger@themyersbriggs.com | `31841346866` | TMBC, ~10 MB |
| zfarooq@themyersbriggs.com | `24682546106` | TMBC IT, ~0 |

Only **4 managed users**. `@opp.com` and `@themyersbriggs.com` are **both internal** (same company; OPP acquired). External = any other domain.

## Core endpoints

| Call | Endpoint | Notes |
|------|----------|-------|
| Whoami | `GET /users/me` | Service account identity |
| List users | `GET /users?limit=200&fields=name,login,status,role,created_at,space_used` | Enterprise users (needs Manage users scope) |
| List folder items | `GET /folders/{id}/items?limit=1000&offset=N&fields=...` | `0` = root (per As-User). Paginate on `total_count`. |
| Folder details | `GET /folders/{id}?fields=name,size,has_collaborations,shared_link,content_modified_at,path_collection` | **Folder size = recursive rollup of file bytes** |
| Collaborations | `GET /folders/{id}/collaborations?limit=100` / `GET /files/{id}/collaborations` | `accessible_by.login`, `role`, `status` |
| File text | `GET /files/{id}/content` | For report CSVs; follows 302 to dl.boxcloud.com |
| Delete folder | `DELETE /folders/{id}?recursive=true` | `recursive=true` required if non-empty; → Trash (204 on success) |
| Trash item | `GET /folders/{id}/trash` | Confirm an item is in Trash after delete |

## Reports drive enumeration; API drives drill-down + execution

**Reports are faster and more robust than crawling** for "what exists." They generate server-side (can't be wedged by a network drop) and land in the **Box Reports** folder (`id 1045358509`). Download via `GET /files/{id}/content`. Large reports split into `Page_1/2…` CSVs — stitch them.

Workflow: **run report (Admin Console) → analyze CSV → API drill into standouts → API execute approved changes.** Do NOT use the API to fully crawl the tree (see gotchas).

Report types: **Folders and Files** (owner/path/size/dates, no access info), **Collaborations**, **Shared Links**, **User Details** (last-login + status — the only source of historical last-login), **User Activity** (event log over a date window).

## Gotchas

- **Always set a socket timeout** (`socket.setdefaulttimeout`) and re-mint token on 401. `urlopen` has no default timeout; a network drop (a power outage did this) leaves it hanging forever and wedges long runs.
- **Don't full-crawl the tree via per-folder API calls.** This account has 200k+ objects; an overnight crawl hung at 15.5k folders. Use the **Folders and Files report** for full inventory instead.
- **Folder `0` is per-user.** When crawling multiple users, do NOT dedup folder IDs on the literal `"0"` — it collides across users and silently skips everyone after the first.
- **No `last_login` on the user object.** Enterprise events are retained only ~2 weeks–2 months. Historical last-login comes only from the **User Details** report.
- **Folder `size` can be 0** when the subtree contains no files (it may still hold empty subfolders). `size==0` is a reliable "no files here" guard before a recursive delete. Example: `SoftwareStore/ManageEngine` = 17,508 folders, 0 files, 0 bytes.
- **Deletes go to Trash**, recoverable for the retention window. Default **30 days**; custom (7 days–10 years) requires **Box Governance**. Set in Admin Console → Enterprise Settings → Content & Sharing (bottom). Permanent purge is a separate, irreversible step.
- **MCP `list_folder_content` does not return folder sizes** — use `GET /folders/{id}?fields=size`.
- Box report download URLs are signed (302 → dl.boxcloud.com); urllib follows the redirect automatically.

## Cleanup project artifacts

`~/GitHub/box-opp-analysis/` — `full_tree.csv` (full inventory), `empty_folders_to_delete.csv` (deletion runbook), `box_crawl.py` (legacy crawler, superseded by reports), `MEETING-BRIEF.md`, deletion logs.

## Empty-folder deletion pattern (proven)

1. From the Folders and Files report, mark every folder ID that appears as an ancestor of any file → `has_files`.
2. "Empty" = folder not in `has_files` (recursively file-free).
3. Collapse to **top-most empty subtree** (parent is in `has_files` or is root) so one recursive delete clears the whole branch.
4. **Exclude/flag** empty folders with collaborations or shared links (deleting revokes access / breaks links) — the report doesn't carry this, so API-check each candidate.
5. Guard `size==0` immediately before each `DELETE ...?recursive=true`. Delete to Trash, verify gone (GET → 404) + in Trash, never permanent-purge without explicit approval.
