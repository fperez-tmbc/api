# Patch Collections Registry

Maps each PDQ collection to its patching requirements. Read this file at the start of every patch run.

**PDQ Deploy output format (post-update):** Deploy output now uses `ID     : 246401` (colon-separated). Always parse the deployment ID with `awk '/^ID/{print $NF}'` — NOT `$2` (which grabs the colon).

**F5 rule:** Only the collections explicitly listed as "Yes" below require F5 commands. No other collection or list of computers needs F5 involvement unless explicitly stated at the time of the request.

**Collection resolution:** Collection names are NOT unique across PDQ — e.g. there are two collections named `PROD` (the real patch group `CPP Patch Groups\PROD` id 3236, and an empty `cpp-db.com\…\Servers\DC\PROD` id 3412). The patch loop resolves the target by `CollectionId` scoped to the `CPP Patch Groups` tree (`Name = '<collection>' AND Path LIKE 'CPP Patch Groups%'`) and aborts unless exactly one row matches. All patch groups live under `CPP Patch Groups`; names are unique within it. CollectionIds below are for reference — they can change if a collection is deleted and recreated, so the skill always re-resolves by name+path at runtime rather than trusting a hardcoded id.

| Collection | CollectionId | F5 Required | F5 Config Key |
|---|---|---|---|
| `Backup` | 3238 | No | — |
| `DEV/QA/VDI` | 3233 | No | — |
| `Domain Controllers - Group 1` | 3239 | No | — |
| `Domain Controllers - Group 2` | 3528 | No | — |
| `Web Staggered - Group 1` | 3246 | Yes | `web-staggered-first-group` |
| `Web Staggered - Group 2` | 3545 | Yes | `web-staggered-second-group` |
| `PROD` | 3236 | Yes | `prod-downtime` |

---

## F5 Configurations

- **Host:** `mkf5prod01.cpp-db.com`
- **Credentials:** `F5_PASS` from `~/GitHub/.tokens/patching`
- **Method:** REST API — `curl -sk -u "admin:${F5_PASS}" -X PATCH "https://mkf5prod01.cpp-db.com/mgmt/tm/<path>" -H "Content-Type: application/json" -d '<body>'`

### `web-staggered-first-group`

**Disable (run before patching):**

| Pool | Member |
|---|---|
| `ELEVATESERVICES` | `SVAXQUOPRDDC02:80` |
| `REPGEN` | `SVREPGENPRDDC02:80` |
| `SVWCFPRDDC` | `SVWCFPRDDC02:80` |

Body: `{"session":"user-disabled"}`

**Enable (run after patching):**

Same pool/member pairs — body: `{"session":"user-enabled","state":"user-up"}`

---

### `web-staggered-second-group`

**Disable (run before patching):**

| Pool | Member |
|---|---|
| `ELEVATESERVICES` | `SVAXQUOPRDDC03:80` |
| `REPGEN` | `SVREPGENPRDDC01:80` |
| `SVWCFPRDDC` | `SVWCFPRDDC01:80` |

Body: `{"session":"user-disabled"}`

**Enable (run after patching):**

Same pool/member pairs — body: `{"session":"user-enabled","state":"user-up"}`

---

### `prod-downtime`

**Apply downtime (run before patching):**

| Object | API path | Body |
|---|---|---|
| Virtual `WWW.SKILLSONE.COM_HTTP` | `ltm/virtual/~Common~WWW.SKILLSONE.COM_HTTP` | `{"rules":["/Common/DOWNTIME"]}` |
| Virtual `WWW.SKILLSONE.COM_HTTPS` | `ltm/virtual/~Common~WWW.SKILLSONE.COM_HTTPS` | `{"rules":["/Common/DOWNTIME"]}` |
| Pool `WWW.SKILLSONE.COM` | `ltm/pool/~Common~WWW.SKILLSONE.COM` | `{"monitor":"/Common/gateway_icmp"}` |

**Remove downtime (run after patching):**

| Object | API path | Body |
|---|---|---|
| Virtual `WWW.SKILLSONE.COM_HTTP` | `ltm/virtual/~Common~WWW.SKILLSONE.COM_HTTP` | `{"rules":["/Common/WSS_CHECK-REDIRECT"]}` |
| Virtual `WWW.SKILLSONE.COM_HTTPS` | `ltm/virtual/~Common~WWW.SKILLSONE.COM_HTTPS` | `{"rules":["/Common/WSS_CHECK-REDIRECT"]}` |
| Pool `WWW.SKILLSONE.COM` | `ltm/pool/~Common~WWW.SKILLSONE.COM` | `{"monitor":"/Common/gateway_icmp and /Common/WWW.SKILLSONE.COM"}` |

**Note:** Unlike Web Staggered groups (pool member disable/enable), PROD applies a downtime iRule to the virtual servers and swaps the pool health monitor. The combined monitor API format requires full `/Common/` paths space-separated — differs from tmsh syntax.
