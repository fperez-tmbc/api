# KnowBe4 API

Notes and scripts for the KnowBe4 APIs. Tokens are stored in `~/.tokens/knowbe4`.

Account ID: `631792`  
All tokens expire: `2031-04-28`

---

## APIs

### Reporting API
- **Token section:** `[reporting]`
- **Scope:** `elvis`
- **Base URL:** `https://us.api.knowbe4.com/v1`
- **Auth:** `Authorization: Bearer <token>`
- **Type:** REST
- **Status:** ✅ Verified

#### Useful endpoints
```
GET /v1/users
GET /v1/users/{id}
GET /v1/groups
GET /v1/groups/{id}/members
GET /v1/phishing/campaigns
GET /v1/training/campaigns
```

---

### KSAT (Product / Graph API)
- **Token section:** `[ksat]`
- **Scope:** `public_kmsat`
- **Base URL:** `https://training.knowbe4.com/graphql`
- **Auth:** `Authorization: Bearer <token>`
- **Type:** GraphQL
- **Status:** ✅ Verified — returns real group data

#### Example query
```graphql
{
  groups {
    nodes {
      id
      name
      memberCount
    }
  }
}
```

---

### PhishER
- **Token section:** `[phisher]`
- **Scope:** `phisher`
- **Base URL:** `https://training.knowbe4.com/graphql`
- **Auth:** `Authorization: Bearer <token>`
- **Type:** GraphQL
- **Status:** ✅ Authenticates

---

### KCM (Compliance Manager)
- **Token section:** `[kcm]`
- **Scope:** `kcm`
- **Base URL:** `https://training.knowbe4.com/graphql`
- **Auth:** `Authorization: Bearer <token>`
- **Type:** GraphQL
- **Status:** ✅ Authenticates

---

### PasswordIQ
- **Token section:** `[passwordiq]`
- **Scope:** `piq`
- **Base URL:** `https://training.knowbe4.com/graphql`
- **Auth:** `Authorization: Bearer <token>`
- **Type:** GraphQL
- **Status:** ✅ Authenticates

---

### PasswordIQ Graph API
- **Token section:** `[passwordiq-graph]`
- **Scope:** `public_piq`
- **Base URL:** `https://training.knowbe4.com/graphql`
- **Auth:** `Authorization: Bearer <token>`
- **Type:** GraphQL
- **Status:** ✅ Authenticates

---

### Security Coach
- **Token section:** `[security-coach]`
- **Scope:** `public_security_coach`
- **Base URL:** `https://training.knowbe4.com/graphql`
- **Auth:** `Authorization: Bearer <token>`
- **Type:** GraphQL
- **Status:** ✅ Authenticates

---

### User Event API
- **Token section:** `[user-event]`
- **Scope:** `account` + `key` (different JWT format — HS256)
- **Base URL:** `https://api.events.knowbe4.com`
- **Auth:** ⚠️ **Requires AWS SigV4** — the endpoint sits behind AWS API Gateway and rejects standard Bearer token auth. The JWT encodes `account` + `key` but how it integrates with SigV4 signing is not documented publicly.
- **Type:** REST
- **Status:** ❌ Not yet working — needs KnowBe4 support clarification on signing requirements

---

## Notes

- All GraphQL APIs share the same endpoint (`training.knowbe4.com/graphql`); the token scope gates access per product.
- The Reporting API is the only REST API confirmed so far (`us.api.knowbe4.com/v1`).
- The KSAT GraphQL API uses cursor-based pagination — query `nodes` inside collections (e.g., `groups { nodes { ... } }`).
- The User Event API endpoint (`api.events.knowbe4.com`) sits behind AWS API Gateway; auth flow differs from the others.
