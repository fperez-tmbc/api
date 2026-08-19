# Vercel REST API

Hosting for the B2C platform (`app.mbti.com`). Team **The Myers Briggs Company**, Pro plan.

## Auth

Token file: `.tokens/vercel` (bare single-line value, mode 600). Documented in 1Password,
**Employee** vault → "Vercel API - claude-automation".

```bash
T=$(cat ~/GitHub/.tokens/vercel)
curl -H "Authorization: Bearer $T" 'https://api.vercel.com/v9/projects?slug=the-myers-briggs-company'
```

Base URL is `https://api.vercel.com`. Endpoints are individually versioned (`/v2/`, `/v5/`,
`/v6/`, `/v9/`, `/v10/`), and the version is not consistent between related endpoints.

## The gotcha that will waste your time

The token is **Full Account** scope, not team scope. Team-targeted requests therefore
**must** carry `?teamId=` or `?slug=`. Without it you get a valid `HTTP 200` with an
empty result set, not an error:

```bash
curl -H "Authorization: Bearer $T" https://api.vercel.com/v9/projects
# {"projects":[],"pagination":{"count":0}}   <- looks like "no projects exist"

curl -H "Authorization: Bearer $T" 'https://api.vercel.com/v9/projects?slug=the-myers-briggs-company'
# the real answer
```

A team- or project-scoped token would infer the team and need no parameter. This one does
not. Assume any empty Vercel result is a missing scope parameter until proven otherwise.

## Identifiers

| Field | Value |
|-------|-------|
| Team | The Myers Briggs Company (`the-myers-briggs-company`) |
| Team ID | `team_r1o4xR0FnNhWLAyxArieqxaV` |
| Project | `tmbc-b2c` |
| Project ID | `prj_b6SY2IcwhKJkmG2DpwEYOZ23xVq5` |
| Repo | `themyersbriggs/b2c-platform`, production branch `main` |

## Useful calls

```bash
T=$(cat ~/GitHub/.tokens/vercel)
TID=team_r1o4xR0FnNhWLAyxArieqxaV
PID=prj_b6SY2IcwhKJkmG2DpwEYOZ23xVq5
api() { curl -s -H "Authorization: Bearer $T" "https://api.vercel.com$1"; }

api "/v2/teams"                              # teams this token can see
api "/v2/teams/$TID"                         # team detail   (NOT /v2/team, that 404s)
api "/v2/teams/$TID/members"                 # members and roles
api "/v9/projects?teamId=$TID"               # projects
api "/v9/projects/$PID?teamId=$TID"          # project detail
api "/v9/projects/$PID/domains?teamId=$TID"  # project domains
api "/v10/projects/$PID/env?teamId=$TID"     # env vars (see warning below)
api "/v5/domains?teamId=$TID"                # team domains
api "/v6/deployments?teamId=$TID&limit=10"   # recent deployments
api "/v5/user/tokens"                        # this token's own record, incl. expiry
```

## Environment variables: read keys, not values

`/v10/projects/{id}/env` covers 95 variables holding live Stripe, Supabase, AWS SES and
Sentry credentials for a production platform that takes payments. Enumerate **keys and
targets only**. There is no reason to decrypt a value to answer a question about what is
configured, and doing so drags production secrets into a transcript.

The token can also **write** these. Treat any env var change as a production change.

## Gotchas

- `/v2/team?slug=...` returns `404 not found`. The working form is `/v2/teams/{teamId}`.
  The singular endpoint exists in older docs.
- The token page only renders under your **personal** account context. If the dashboard
  scope selector is set to a team, the settings path for tokens is not reachable.
- Choosing a team in the Scope dropdown and then **All Projects** yields a team-scoped
  token; drilling into a single project silently yields a project-scoped one.
- Token values are shown once at creation and begin with `vcp_`.
- Creating further tokens via API or CLI requires a Full Account token; a scoped one
  cannot mint tokens.

## Landscape

Findings live in the `knowledge-base` repo at `landscape/vercel.md`.
