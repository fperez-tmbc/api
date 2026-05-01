# LogMeIn Rescue — API Notes

Field notes covering auth, endpoints, and gotchas for the LogMeIn Rescue API.
The API is ASPX-based (not pure REST) — methods are `.aspx` files on a single host.

---

## Platform

- **Product:** LogMeIn Rescue (GoTo)
- **Account ID:** `2619315` (The Myers-Briggs Company)
- **Admin ID:** `17325763` | **Tech ID:** `17325764`
- **Base URL:** `https://secure.logmeinrescue.com/API/`
- **SOAP WSDL:** `https://secure.logmeinrescue.com/api/api.asmx?wsdl`
- **Enterprise variant base URL:** `https://logmeinrescue-enterprise.com/API/` (same endpoint shape, different host)

All methods are HTTP endpoints in the form `<base_url>/<method>.aspx`.
Both GET (query string) and POST (form-encoded body) are accepted.

---

## Authentication

Three methods exist. Prefer **API Token** for new integrations.

### Method 1 — API Token (recommended)

Available only to **Master Account Holders (MAH)** and **Master Administrators (MA)**.

- Generate in account settings; the token is **displayed only once** — store it immediately.
- No documented expiry; remains valid until manually revoked or regenerated.
- Pass as `authcode` parameter on every request (same parameter name as Method 2).

```bash
curl "https://secure.logmeinrescue.com/API/getUser.aspx?authcode=<TOKEN>&node=<NODE_ID>&nodetype=technician"
```

Token location (TMBC): `~/GitHub/.tokens/logmein-rescue`

Token generation UI: Account Settings → API Token → Generate.
Docs: https://support.logmein.com/rescue/help/generate-api-token

### Method 2 — Auth Code (non-expiring, email/password exchange)

Better than Method 3 if you can't use an API token but can't handle session cookies.

```bash
# Returns an authcode valid indefinitely (until a new one is requested)
curl "https://secure.logmeinrescue.com/API/requestAuthCode.aspx?email=user@example.com&pwd=password"
```

Requesting a new authcode **invalidates the previous one**. Store the returned code; use it as `authcode` on subsequent calls.

### Method 3 — Session Cookie (email/password login)

```bash
# Returns a session cookie; must be passed on every subsequent request
curl -c cookies.txt "https://secure.logmeinrescue.com/API/login.aspx?email=user@example.com&pwd=password"
curl -b cookies.txt "https://secure.logmeinrescue.com/API/getUser.aspx?..."
```

Session expires after **20 minutes of inactivity**. Not suitable for long-running or scheduled integrations.

---

## Request Format

Parameters can be passed as query strings (GET) or form-encoded body (POST):

```bash
# GET
curl "https://secure.logmeinrescue.com/API/startSession.aspx?authcode=<TOKEN>&iSessionID=<ID>&iNodeID=<NODE>"

# POST
curl -X POST "https://secure.logmeinrescue.com/API/startSession.aspx" \
  -d "authcode=<TOKEN>&iSessionID=<ID>&iNodeID=<NODE>"
```

Responses are XML by default. Some reporting endpoints support TEXT and JSON output (see `setOutput.aspx`).

---

## Key Endpoints

### Account / Hierarchy

| Method | Endpoint | Notes |
|--------|----------|-------|
| Get account info | `getAccount.aspx` | Top-level account details |
| Get org hierarchy | `getHierarchy.aspx` | Returns node tree for technicians/groups |
| Get user | `getUser.aspx` | Retrieve a technician or admin by node/email |
| Create user | `createUser.aspx` | Create a new technician account |

### Sessions

| Method | Endpoint | Notes |
|--------|----------|-------|
| Start session | `startSession.aspx` | Params: `iSessionID`, `iNodeID` |
| Get sessions | `getSession.aspx` | Multiple versions: `_v2`, `_v3` — v3 is most current |
| Hold session | `holdSession.aspx` | Places an active session on hold |
| Transfer session | `transferSession.aspx` | Transfer to another technician |
| Close session | `closeSession.aspx` | End a session |
| Cancel action | `cancelAction.aspx` | Cancel a pending action on a session |

Use `getSession_v3.aspx` for new code — earlier versions exist for compatibility but are underdocumented.

### Channels

| Method | Endpoint | Notes |
|--------|----------|-------|
| Check channel availability | `isAnyTechAvailableOnChannel.aspx` | Returns whether any tech is online on the channel |

### Reporting

Reporting is two-step: configure the report area, then retrieve.

| Method | Endpoint | Notes |
|--------|----------|-------|
| Set report area | `setReportArea.aspx` | Multiple versions: `_v2`, `_v8` |
| Get report area | `getReportArea.aspx` | Multiple versions: `_v2`, `_v8` |
| Get report | `getReport.aspx` | Retrieves configured report; also `_v2` variant |
| Get report dates | `getReportDate.aspx` | Available date ranges |
| Get report types | `getReportType.aspx` | Valid report categories |
| Set output format | `setOutput.aspx` | XML (default), TEXT, JSON |
| Set delimiter | `setDelimiter.aspx` | For TEXT output |
| Set timezone | `setTimeZone.aspx` | Affects report timestamps |

---

## SAML 2.0 / SSO

**API limitation:** There are no API endpoints for reading or writing SAML/SSO configuration. All setup is done through the Admin Center UI. Probed `getSAMLSettings`, `getSSOConfig`, `getIdentityProvider`, and others — all return the HTML login page (no API surface exists).

Full SSO configuration details: `task-tracker/projects/logmein-rescue-sso/`

---

## Gotchas

**API is ASPX-based, not REST.** It's HTTP-callable but not resource-oriented. Don't assume REST conventions apply — each `.aspx` method is its own thing.

**Multiple versioned endpoints with no clear guidance.** Methods like `getSession`, `getReport`, and `setReportArea` have `_v2`, `_v3`, `_v8` variants. The docs don't always explain what changed. Default to the highest-numbered version; test against a lower version only if the current one fails.

**API token is shown once.** If you lose it, you must regenerate — no way to retrieve the existing token. Keep it in a secrets store immediately.

**Auth code invalidation.** Calling `requestAuthCode` again invalidates all previous auth codes for that account. If multiple scripts share a single account, coordinate auth code generation — don't let them each request their own.

**Session cookie timeout is 20 minutes.** Using `login.aspx` requires re-auth logic for any integration running longer than 20 minutes idle. Use API token or auth code instead.

**Report retrieval rate limit: 60 seconds.** `getReport.aspx` will fail or return cached/empty data if called more frequently than once per minute. Build in a 60-second wait between report polls.

**Limited official support.** GoTo explicitly states that API support is limited because usage is custom in nature. Expect to test and verify behavior yourself; don't rely on support tickets for integration help.

**No official SDK.** Build against raw HTTP. A Ruby gem (`tstachl/logmein-rescue`) exists on GitHub but was archived in 2020 with most methods unimplemented — don't use it as a reference.

**Enterprise vs. standard host.** If your org uses the enterprise variant, the base URL is different but the endpoint structure is the same. Confirm which host applies to your account before testing.

---

## Official Docs

- [API Reference Guide (overview)](https://support.logmein.com/rescue/help/rescue-api-reference-guide)
- [Authentication options](https://secure.logmeinrescue.com/welcome/webhelp/en/rescueapi/API/API_Rescue_tutorial_authentication.html)
- [Session management map](https://secure.logmeinrescue.com/welcome/webhelp/en/rescueapi/API/API_map_session_management.html)
- [Reporting map](https://secure.logmeinrescue.com/welcome/webhelp/en/rescueapi/api/api_map_reporting.html)
- [Generate API token](https://support.logmein.com/rescue/help/generate-api-token)
