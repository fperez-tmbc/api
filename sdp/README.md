# ServiceDesk Plus Cloud — v3 REST API Notes

Field notes from hands-on testing. Covers auth, tickets, notes, and replies.
The SDP Cloud v3 API docs are incomplete — several working endpoints are undocumented.

---

## Platform

- **Product:** ServiceDesk Plus Cloud (ManageEngine)
- **Portal:** `itdesk`
- **Datacenter:** US (`com`)
- **Base URL:** `https://sdpondemand.manageengine.com/app/itdesk/api/v3`
- **Portal UI (requests):** `https://sdpondemand.manageengine.com/app/itdesk/ui/requests/{display_id}/details`
- **Portal UI (changes):** `https://sdpondemand.manageengine.com/app/itdesk/ChangDetails.do?CHANGEID={internal_id}&tab=conversations&subTab=details`
- **Custom domain (TMBC):** `https://servicedesk.themyersbriggs.com/app/itdesk/...`

---

## Authentication

Zoho OAuth 2.0 — client credentials + refresh token flow.

### Token refresh

```bash
curl -X POST "https://accounts.zoho.com/oauth/v2/token" \
  -d "grant_type=refresh_token" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "refresh_token=$REFRESH_TOKEN"
```

Returns `access_token` (short-lived). Use it as:

```
Authorization: Zoho-oauthtoken <access_token>
Accept: application/vnd.manageengine.sdp.v3+json
```

### Required OAuth scopes

| Scope | Purpose |
|-------|---------|
| `SDPOnDemand.requests.ALL` | Create, read, update, close, delete tickets; notes; replies |
| `SDPOnDemand.changes.ALL` | Create, read, update changes (`/changes` endpoints) |
| `SDPOnDemand.setup.READ` | Metadata lookups (categories, statuses, modes, etc.) |
| `SDPOnDemand.users.ALL` | Requester/technician management (required for `DELETE /requesters/{id}`) |
| `SDPOnDemand.solutions.ALL` | Create, read, update, delete solutions |

Combined scope string for full automation: `SDPOnDemand.requests.ALL,SDPOnDemand.changes.ALL,SDPOnDemand.users.ALL,SDPOnDemand.setup.ALL,SDPOnDemand.solutions.ALL`

Fine-grained request sub-scopes (if you don't want `.ALL`):

| Sub-scope | Grants |
|-----------|--------|
| `SDPOnDemand.requests.READ` | GET tickets, notes, conversations |
| `SDPOnDemand.requests.CREATE` | POST /requests |
| `SDPOnDemand.requests.UPDATE` | PUT /requests/{id}, PUT /requests/{id}/close |

### Initial OAuth setup (one-time)

1. Go to [Zoho Developer Console](https://accounts.zoho.com/developerconsole) → Add Client → **Self Client**
2. Save the **Client ID** and **Client Secret**
3. Generate a grant code with the required scope string
4. Exchange the grant code for a refresh token:

```bash
curl -X POST "https://accounts.zoho.com/oauth/v2/token" \
  -d "grant_type=authorization_code" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "code=$GRANT_CODE" \
  -d "redirect_uri=https://sdpondemand.manageengine.com"
```

Store the `refresh_token` securely — it is long-lived. Use the token refresh flow above for day-to-day API calls.

> Grant codes are **single-use** and expire after **10 minutes**. If the exchange fails, generate a new one — don't retry with the same code.

**If you get `OAUTH_SCOPE_MISMATCH`** on a call, the refresh token was generated with insufficient scopes. Re-run the grant code + exchange flow with the full combined scope string to get a new refresh token.

### Request format

All write endpoints take the payload as a URL-encoded `input_data` form field — **not** raw JSON body:

```bash
curl -X POST "$BASE_URL/requests" \
  -H "Authorization: Zoho-oauthtoken $TOKEN" \
  -H "Accept: application/vnd.manageengine.sdp.v3+json" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "input_data=$(cat payload.json)"
```

---

## ID Types

SDP uses two IDs for every ticket:

| Type | Example | Use |
|------|---------|-----|
| `display_id` | `101085` | Human-readable ticket number shown in the UI |
| `id` (internal) | `260962000001848088` | Required for all API sub-resource calls |

### Look up internal ID from display ID

```bash
curl ... "$BASE_URL/requests?input_data=$(urlencode '{"list_info":{"row_count":"1","search_fields":{"display_id":"101085"}}}')"
```

Read the `id` field from `requests[0].id` in the response.

---

## Endpoints

### Tickets

| Operation | Method | Endpoint | Notes |
|-----------|--------|----------|-------|
| Create | POST | `/requests` | Payload wrapped in `request` key |
| Get one | GET | `/requests/{id}` | Use internal ID |
| List / search | GET | `/requests` | Pass `input_data` with `list_info` + `search_fields` |
| Update (partial) | PUT | `/requests/{id}` | Only include fields to change; omit the rest |
| Update resolution | PUT | `/requests/{id}` | Payload with only `resolution.content` — updates resolution text without closing |
| Close | PUT | `/requests/{id}/close` | Requires `closure_info` in payload; see structure below |
| Delete | DELETE | `/requests/{id}` | Returns `status_code: 2000` on success |

#### Create ticket payload structure

```json
{
  "request": {
    "subject": "Ticket title",
    "description": "<div><p>HTML body</p></div>",
    "requester": {"email_id": "user@example.com"},
    "request_type": {"name": "Request"},
    "category": {"name": "Information Security"},
    "subcategory": {"name": "Audit"},
    "group": {"name": "Helpdesk"},
    "urgency": {"name": "Medium"},
    "impact": {"name": "Medium"},
    "status": {"name": "Open"},
    "mode": {"name": "Web Form"},
    "udf_fields": {"txt_user_priority3": "Medium"}
  }
}
```

**Required fields** (API returns error 4012 if missing): `urgency`, `impact`, `udf_fields.txt_user_priority3`

Category/subcategory values must match what's configured in the portal. Use `GET /categories` to list valid values (see Metadata Lookups section below).

#### Close ticket payload

```json
{
  "request": {
    "closure_info": {
      "closure_code": {"name": "Success"},
      "closure_comments": "Plain text summary of what was resolved.",
      "requester_ack_resolution": true
    },
    "resolution": {
      "content": "<div><p>Full HTML resolution text here.</p></div>"
    }
  }
}
```

Use `PUT /requests/{internal_id}/close` with this as `input_data`.

#### Resolution-only update (without closing)

```json
{
  "request": {
    "resolution": {
      "content": "<div><p>Updated resolution text.</p></div>"
    }
  }
}
```

Use `PUT /requests/{internal_id}` — ticket stays open, only the resolution field is updated.

---

### Notes

Notes are internal communications. They can be marked visible to the requester but do **not** send an email.

| Operation | Method | Endpoint |
|-----------|--------|----------|
| Add note | POST | `/requests/{id}/notes` |
| Update note | PUT | `/requests/{id}/notes/{note_id}` |
| Delete note | DELETE | `/requests/{id}/notes/{note_id}` |
| List notes | GET | `/requests/{id}/notes` |

#### Add note payload

```json
{
  "request_note": {
    "description": "<p>HTML content here</p>",
    "show_to_requester": true
  }
}
```

Wrapper key is `request_note` (not `note`).

---

### Replies (Email)

**This endpoint is not in the v3 API docs — discovered by probing.**

Sends an actual email reply through the ticket's email thread. Shows up in conversations as type `REQREPLY`.

| Operation | Method | Endpoint |
|-----------|--------|----------|
| Get pre-populated template | GET | `/requests/{id}/reply` |
| Send reply | POST | `/requests/{id}/reply` |

#### GET /reply — pre-populated template response

```json
{
  "notification": {
    "to": ["requester@example.com"],
    "cc": [],
    "subject": "Re: [Request ID :##101085##] : Ticket Subject",
    "description": "<div>... technician signature pre-filled ...</div>"
  },
  "response_status": {"status_code": 2000, "status": "success"}
}
```

Useful to grab the subject line (which includes the magic `##display_id##` token) and pre-filled signature HTML.

#### POST /reply — send the email

```json
{
  "notification": {
    "to": ["requester@example.com"],
    "cc": [],
    "subject": "Re: [Request ID :##101085##] : Ticket Subject",
    "description": "<p>Your reply body here</p>"
  }
}
```

Returns `{"response_status": {"status_code": 2000, "status": "success"}}` on success.

---

### Conversations

Read-only. Returns the full email/note history for a ticket.

| Operation | Method | Endpoint |
|-----------|--------|----------|
| List conversations | GET | `/requests/{id}/conversations` |

**POST to `/conversations` returns `Invalid Method` — use `/reply` instead.**

#### Conversation types seen in the wild

| Type | Description |
|------|-------------|
| `RequesterAck_E-Mail` | Auto-acknowledgement sent to requester on ticket creation |
| `RequestAssignReqrNotify_E-Mail` | Notification to requester when ticket is assigned |
| `QueueReqTechNotify_E-Mail` | Notification to technician when ticket enters queue |
| `TechIntimation_E-Mail` | Technician intimation email |
| `NOTES` | Notes added via the `/notes` endpoint |
| `REQREPLY` | Email reply sent via the `/reply` endpoint |

---

---

### Solutions

Scope required: `SDPOnDemand.solutions.ALL`

| Operation | Method | Endpoint |
|-----------|--------|----------|
| Create | POST | `/solutions` |
| Get one | GET | `/solutions/{id}` |
| Update | PUT | `/solutions/{id}` |
| Delete | DELETE | `/solutions/{id}` |
| List / search | GET | `/solutions` |

Wrapper key is `solution` (singular).

Portal UI: `https://servicedesk.themyersbriggs.com/app/itdesk/ui/solutions/{id}/details`

#### Create solution payload

```json
{
  "solution": {
    "title": "Solution title",
    "description": "<p>HTML content</p>",
    "keywords": "comma, separated, keywords",
    "topic": {"id": "260962000000007971"}
  }
}
```

**Required fields:** `title`, `description`, `topic`. `status` is not a valid field on create — omit it.

#### Approve a solution

Solutions are created with `approval_status: UnApproved`. To approve, PUT with the Approved status ID:

```json
{
  "solution": {
    "approval_status": {"id": "260962000000006827"}
  }
}
```

| approval_status | ID |
|---|---|
| UnApproved | `260962000000006825` |
| Approved | `260962000000006827` |

`status` is always `null` in the API — approval state is tracked via `approval_status` only. `is_public` is `false` even on approved solutions and does not control visibility.

#### Topics

There is no working `/topics` or `/solution_topics` endpoint (both return 404). To get a valid topic ID, read an existing solution and copy its `topic.id`. The default topic in this portal is **General** (`id: 260962000000007971`).

---

---

### Changes

| Operation | Method | Endpoint | Notes |
|-----------|--------|----------|-------|
| Create | POST | `/changes` | Payload wrapped in `change` key |
| Get one | GET | `/changes/{id}` | Use internal ID |
| Update (partial) | PUT | `/changes/{id}` | Only include fields to change |

Scope required: `SDPOnDemand.changes.ALL` — this is a **separate scope** from `SDPOnDemand.requests.ALL`. If your refresh token was generated without it, you'll get `OAUTH_SCOPE_MISMATCH`. Re-generate the grant code with the expanded scope string and exchange for a new refresh token.

#### Create change payload structure

```json
{
  "change": {
    "title": "Change title",
    "description": "<div><p>HTML body</p></div>",
    "change_type": {"name": "Minor"},
    "change_owner": {"email_id": "user@example.com"},
    "group": {"name": "Helpdesk"},
    "urgency": {"name": "Normal"},
    "impact": {"name": "Affects Business"},
    "priority": {"name": "Normal"},
    "template": {"id": "260962000001175093"},
    "scheduled_start_time": {"value": "1776960000000"},
    "scheduled_end_time": {"value": "1776963600000"}
  }
}
```

**`scheduled_start_time` / `scheduled_end_time`**: Pass as millisecond epoch in UTC wrapped in a `value` string. The API interprets these as UTC — if you pass a local-time epoch, the stored time will be off by your UTC offset. Verify by checking `display_value` in the response.

**`reason_for_change`**: Must match an existing configured value in the portal — cannot pass an arbitrary string. Omit the field entirely if you don't have a matching value (it's nullable); passing an invalid value returns error `4001`.

**`template`**: Pass by internal ID (not name). The template ID can be found in the portal URL when viewing a change template.

#### Update change payload (partial)

Only include the fields you want to change:

```json
{
  "change": {
    "scheduled_start_time": {"value": "1776960000000"},
    "scheduled_end_time": {"value": "1776963600000"}
  }
}
```

#### Close a change

Set status to `"Completed"` via a regular partial PUT — there is no separate `/close` endpoint for changes (`PUT /changes/{id}/close` returns `4004 Internal Error`):

```json
{
  "change": {
    "status": {"name": "Completed"}
  }
}
```

The TMBC workflow automatically transitions the stage to `"Close"` (stage_index 8) and populates `completed_time` in the response. Confirmed working on CH-22.

#### CAB evaluation update (advance to Approved)

In the SDP portal, this is done by setting the stage to CAB Evaluation, status to Approved, and adding a status comment. Via API:

```json
{
  "change": {
    "stage": {"name": "CAB Evaluation"},
    "status": {"name": "Approved"},
    "status_comment": "Approver name / notes here"
  }
}
```

> **Note:** `status_comment` field name is unverified via API — tested manually in the portal only. If the PUT succeeds but the comment doesn't appear, try `"comment"` or omit it and add the approval note as a change note via `POST /changes/{id}/notes` instead.

After setting status to Approved, the TMBC Change workflow automatically transitions the change to the Implementation stage.

#### Change lifecycle — TMBC workflow stages observed

| stage_index | internal_name | name | How to reach |
|-------------|---------------|------|--------------|
| 1 | `submission` | Submission | Default on creation |
| 4 | `implementation` | Implementation | Workflow auto-transition after Approved in CAB Evaluation |
| 8 | `close` | Close | Workflow auto-transition after status set to Completed |

The gap in stage_index values (2, 3, 5–7) corresponds to Planning, CAB Evaluation, and Review/UAT stages that exist in the workflow but weren't traversed for Minor changes. `stage.internal_name` is more reliable than `stage.name` for programmatic checks.

#### `approval_status` vs `status`

These are independent fields on a change object. A change can have `approval_status: Approved` and `status: In Progress` simultaneously — approved at the CAB level but still being implemented.

#### Notes on a change

| Operation | Method | Endpoint |
|-----------|--------|----------|
| Add note | POST | `/changes/{id}/notes` |
| Delete note | DELETE | `/changes/{id}/notes/{note_id}` |

Wrapper key is `note` (not `change_note` or `request_note`):

```json
{
  "note": {
    "description": "<p>HTML content here</p>"
  }
}
```

`show_to_requester` is not a valid field for change notes — including it returns `4001 EXTRA_KEY_FOUND_IN_JSON`.

> **UX note:** Change notes land in the **Conversations** tab as plain pre-formatted text — no syntax highlighting, no line breaks rendered. For structured implementation logs (commands run, outcome), appending an `<h3>` section to the change **description** via `PUT /changes/{id}` is cleaner and more readable.

#### ID types

Same pattern as requests — `display_id` (e.g., `CH-22`) vs internal `id` (e.g., `260962000001919001`). All API calls use the internal ID.

---

### Requesters (Users)

Scope required: `SDPOnDemand.users.ALL`

| Operation | Method | Endpoint |
|-----------|--------|----------|
| List requesters | GET | `/requesters` |
| Delete requester | DELETE | `/requesters/{requester_id}` |

Deletion use case: after migrating from on-prem SDP to SDP Cloud, legacy user accounts that have no Entra ID identity cannot be deleted through the UI. Use the API to delete them.

---

### Metadata Lookups

Scope required: `SDPOnDemand.setup.ALL` or `SDPOnDemand.setup.READ`

Use these when a POST returns an "invalid value" error for a linked field — the value you're passing doesn't match what's configured in the portal.

All use `GET` with `input_data` containing `list_info`:

```bash
sdp_call GET "/categories" --data-urlencode 'input_data={"list_info":{"row_count":100,"start_index":1}}' -G
```

| Endpoint | Returns |
|----------|---------|
| `/categories` | All request categories |
| `/categories/{cat_id}/subcategories` | Subcategories under a specific category |
| `/request_types` | Request types (Incident, Request, etc.) |
| `/priorities` | Priority values |
| `/urgencies` | Urgency values |
| `/impacts` | Impact values |
| `/groups` | Technician groups |
| `/statuses` | Request statuses |

Categories are a two-level hierarchy — fetch all categories first, then fetch subcategories per category ID.

---

## Endpoints That Don't Exist

Tested and confirmed invalid (return `4007 Invalid URL`):

- `GET/POST /requests/{id}/replies`
- `GET /requests/{id}/send_reply`
- `GET /requests/{id}/emails`
- `GET /requests/{id}/conversations/{conversation_id}` (individual conversation lookup)

---

## Error Codes

| Code | Meaning |
|------|---------|
| `2000` | Success |
| `4000` | General failure — check nested `messages[].status_code` and `messages[].message` for the specific reason |
| `4004` | Internal error (seen on `PUT /changes/{id}/close` — endpoint exists but doesn't work) |
| `4007` | Invalid URL — endpoint doesn't exist |
| `4012` | Missing required field |
| `OAUTH_SCOPE_MISMATCH` | Refresh token lacks the required scope |

`4001` appears as a **nested** `messages[].status_code` inside a `4000` response, not as a top-level code. It covers multiple field validation failures — the `message` field says which:

| `4001` message | Cause |
|----------------|-------|
| `EXTRA_KEY_FOUND_IN_JSON` | Field not valid for this resource (e.g. `show_to_requester` on change notes) |
| `FIELD_NOT_FOUND` | Field value doesn't match a configured option (e.g. invalid `reason_for_change`) |

---

---

## Scripting Gotchas

### zsh: never use `path` as a local variable name

In zsh, `path` is a special array tied to `$PATH`. Inside a function, `local path=...` silently wipes `PATH` for that function's scope, causing `command not found: curl` (or any other external command). Use `endpoint`, `url_path`, or any other name instead.

### Listing requests: use `-G` with `--data-urlencode`

For GET requests that take `input_data`, pass it as a query parameter using curl's `-G` flag combined with `--data-urlencode`. Without `-G`, curl sends it as a POST body:

```bash
sdp_call GET "/requests" -G --data-urlencode "input_data=$payload"
```

### Token scope is checked at token-exchange time, not at call time

If your token was generated with insufficient scope, the API returns `OAUTH_SCOPE_MISMATCH` on the first call that needs a higher-privilege scope — not at token refresh time. To verify what scope a token actually has, exchange the refresh token and inspect the `scope` field in the response.

---

## Official Docs

- [SDP Cloud API v3 Overview](https://www.manageengine.com/products/service-desk/sdpod-v3-api/SDPOD-V3-API.html)
- [Requests reference](https://www.manageengine.com/products/service-desk/sdpod-v3-api/requests/request.html)
- [Request Notes reference](https://www.manageengine.com/products/service-desk/sdpod-v3-api/requests/request_note.html)
- [Zoho OAuth 2.0 Guide](https://www.manageengine.com/products/service-desk/sdpod-v3-api/getting-started/oauth-2.0.html)
