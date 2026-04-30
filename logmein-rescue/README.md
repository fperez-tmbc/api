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

> **API limitation:** There are no API endpoints for reading or writing SAML/SSO configuration. All SAML setup is done through the Admin Center UI and two internal web forms (links below). The API returns an HTML login page for any attempted SSO-related endpoint — probed `getSAMLSettings`, `getSSOConfig`, `getIdentityProvider`, etc., all 404.

### SP Endpoints (configure these in your IdP)

| Field | Value |
|-------|-------|
| Entity ID / Identifier | `https://secure.logmeinrescue.com/` |
| ACS URL | `https://secure.logmeinrescue.com/sso/saml2/receive` |
| Binding | HTTP POST (recommended) or HTTP Redirect (GET) |
| Hash algorithm | SHA-256 |

### Required SAML Assertion Attributes

| Attribute | Required | Notes |
|-----------|----------|-------|
| `NameID` | Yes | Technician's Rescue **Email** or **SSO ID** — pick one, they are mutually exclusive. NameID format is not restricted by Rescue. |
| `LMIRescue.CompanyID` | Yes | TMBC value: `2619315`. Used by Rescue to look up the correct certificate/config. |
| `LMIRescue.Language` | No | IETF tag (e.g. `en-US`) — sets UI language on login. |

Both the Assertion **and** the Response must be signed with the **same** private key.
Response encryption is optional — Rescue auto-detects it.

**Sample assertion snippets:**

```xml
<!-- NameID by email -->
<saml:NameID Format="urn:oasis:names:tc:SAML:2.0:nameid-format:emailAddress">
  user@themyersbriggs.com
</saml:NameID>

<!-- Required CompanyID attribute -->
<saml:Attribute Name="LMIRescue.CompanyID"
  NameFormat="urn:oasis:names:tc:SAML:2.0:attrname-format:unspecified">
  <saml:AttributeValue xsi:type="xs:anyType">2619315</saml:AttributeValue>
</saml:Attribute>
```

### Rescue-Side Config (Admin Center + internal pages)

Rescue SAML settings are split across the Admin Center UI and two internal pages that require MAH login. GoTo Support may need to assist with the internal page steps.

| Step | Where |
|------|-------|
| Enable SAML, set IdP URL and Issuer, set Binding/LoginType | `https://secure.logmeinrescue.com/SSO/Saml2/Settings` |
| Upload IdP signing certificate (Base64, no header/footer lines) | `https://secure.logmeinrescue.com/SSO/Saml2/CertSettings` |
| Per-technician SSO ID | Admin Center → Organization tab → edit user → SSO ID field |
| Company ID (needed for assertion) | Admin Center → Global Settings → Single Sign-On (shown in sample code) |

**Fields on `/SSO/Saml2/Settings`:**
- `SAML2Active` — must be checked to enable SSO
- `SAML2IDPUrl` — paste IdP Login URL here
- `SAML2IDPIssuer` — paste IdP Issuer / Entity ID here
- `Binding` — `httppost (1)` for POST binding
- `LoginType` — `email (1)` to match users by email address

### Azure AD / Entra ID — Configuration Summary

1. Create a new Enterprise App (Non-gallery) in Azure Portal
2. Single sign-on → SAML-based → Basic SAML Configuration:
   - Entity ID: `https://secure.logmeinrescue.com/`
   - Reply URL (ACS): `https://secure.logmeinrescue.com/Sso/Saml2/Receive`
3. User Attributes & Claims → Add new claim:
   - Name: `LMIRescue.CompanyID`
   - Source attribute: `"2619315"` (literal string in quotes)
4. Assign users/groups
5. Download SAML Signing Certificate (Base64)
6. Paste cert value (without `-----BEGIN/END CERTIFICATE-----` lines) into `/SSO/Saml2/CertSettings`
7. Copy Login URL → paste into `SAML2IDPUrl`; copy Azure AD Identifier → paste into `SAML2IDPIssuer`
8. Test: Azure Portal → bottom of SSO page → Test → Sign in as current user

### ADFS 2.0 — Claim Rules Summary

Three claim rules required on the Relying Party (identifier: `https://secure.logmeinrescue.com`):

| Order | Rule type | Config |
|-------|-----------|--------|
| 1 | Send LDAP Attribute as Claims | AD → E-Mail-Addresses → E-Mail Address |
| 2 | Transform Incoming Claim | E-Mail Address → Name ID (Email format), pass through all values |
| 3 | Custom Rule | `=> issue(Type = "LMIRescue.CompanyID", Value = "2619315");` |

Endpoint: type = SAML Assertion Consumer, binding = POST, URL = `https://secure.logmeinrescue.com/sso/saml2/receive`
Advanced tab: set Secure hash algorithm to **SHA-256**.

### SAML Error Codes

**Basic SAML errors** (appear as result/subcode at client):

| Code | Meaning |
|------|---------|
| 1 | RelayStateMissing — IdP didn't provide relay state |
| 2 | RelayStateExpired — login took too long |
| 3 | ResponseRelayStateIsWrong — response for a different request |
| 4 | ResponseNotSuccess — authentication failed |
| 5 | ResponseDestinationIsWrong — destination URL mismatch |
| 6 | ResponseExpired — login took too long |
| 7 | ResponseNotContainAssertion — fatal: no assertion in response |
| 8 | ResponseIssuerIsEmpty — IdP must provide issuer |
| 9 | AssertionExpired — login took too long |
| 15 | IDPConfigurationIsWrong — Rescue-side config error; check subcode |
| 16 | ResponseSignatureNotValid — wrong public key configured |
| 17 | AssertionSignatureNotValid — wrong public key configured |
| 18 | NameIDNotFound — NameID missing from response |
| 254 | SAMLComponentError — internal Rescue issue |

**Rescue-specific SAML errors:**

| Code | Meaning |
|------|---------|
| 1 | RescueCompanyIDMissing — `LMIRescue.CompanyID` attribute not in assertion |
| 2 | ResponseIssuerIsWrong — issuer value doesn't match configured value (case-sensitive) |
| 3 | AssertionIssuerIsWrong — same as above, at assertion level |
| 4 | NameIDPolicyFormatMismatch — NameID format doesn't match configured LoginType |

**Rescue login errors:**

| Code | Meaning |
|------|---------|
| 999 | loginSAML_UnknownError |
| 1120 | loginSAML_InvalidLogin |

### Common Mistakes

**Wrong issuer.** The `SAML2IDPIssuer` value must be **byte-for-byte identical** to what the IdP sends. Case-sensitive. A single character difference causes error 2 or 3.

**Wrong CompanyID.** SAML config is stored per company ID. If the assertion sends the wrong value, Rescue can't find the matching cert/config. TMBC's ID is `2619315`.

**NameID format mismatch.** Email and SSO ID are mutually exclusive. Set `LoginType` to match what the IdP sends; if you pick email, the NameID must be the technician's Rescue email address.

**Wrong certificate.** The cert uploaded to `/SSO/Saml2/CertSettings` must be the IdP's signing cert (the one that signs the assertion/response). A mismatch causes errors 16 or 17.

**IDP URL length.** When using HTTP Redirect binding, encrypted query strings can exceed default URL limits. IIS: set Maximum URL length and Maximum query string to **≥ 4096 bytes** in Request Filtering. Apache Tomcat: check `maxHttpHeaderSize` (default 4096, should suffice).

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
