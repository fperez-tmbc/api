# AWS CLI — Field Notes

AWS access for TMBC and VitaNavis via the authenticated `aws` CLI. Credentials live in `~/GitHub/.tokens/aws` (per the tokens-location rule), **not** the default `~/.aws/credentials`.

## Accounts / Profiles

| Profile (account ID) | Org | IAM user | Default region |
|----------------------|-----|----------|----------------|
| `954945276385` | TMBC | `fperez@themyersbriggs.com` | `us-east-1` |
| `433597029398` | VitaNavis | `fperez` | `us-west-2` |

- **TMBC (`954945276385`) is the preferred account for new app hosting.**
- Region + output (`json`) per profile are set in `~/.aws/config` (`[profile <id>]` blocks).
- The profile name **is** the account ID — there are no friendly aliases.

## Auth

Credentials are in a non-default location, so every invocation must point the CLI at it:

```bash
export AWS_SHARED_CREDENTIALS_FILE=~/GitHub/.tokens/aws
aws sts get-caller-identity --profile 954945276385   # TMBC
aws sts get-caller-identity --profile 433597029398   # VitaNavis
```

The tokens file uses bare `[<account-id>]` section headers (a credentials file), while `~/.aws/config` uses `[profile <account-id>]` headers (region/output). The CLI joins them by matching `--profile <id>` to both.

## Common Commands

```bash
export AWS_SHARED_CREDENTIALS_FILE=~/GitHub/.tokens/aws
P=954945276385   # or 433597029398

aws sts get-caller-identity --profile $P
aws s3 ls --profile $P
aws ec2 describe-instances --profile $P \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType,Name:Tags[?Key==`Name`]|[0].Value}' --output table
aws iam list-users --profile $P
aws ce get-cost-and-usage --profile $P \
  --time-period Start=2026-06-01,End=2026-06-30 --granularity MONTHLY --metrics UnblendedCost
```

## Gotchas

- **Always set `AWS_SHARED_CREDENTIALS_FILE`** — without it the CLI looks in `~/.aws/credentials`, which doesn't exist, and falls back to no credentials / an unintended profile.
- **Always pass `--profile`** — there is no default profile, so an unqualified command errors out or hits the wrong account. Confirm with `sts get-caller-identity` before any change.
- Profiles are account IDs, not names — easy to mix up TMBC vs VitaNavis. Double-check the account in the ARN.
- These are long-lived IAM access keys, not SSO/STS sessions — no token refresh needed, but rotate periodically.
- Never echo the secret keys into output, scripts, or commits.
