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

## Root account — what the CLI can and can't see

- **`list-virtual-mfa-devices` under-reports root MFA.** It returns virtual TOTP
  devices only. Passkeys and FIDO security keys are invisible to it, so an account
  can show one device on the CLI while the console lists three. Never conclude
  "root has only one MFA device" from this call — confirm on the root **Security
  credentials** page.
- **`get-credential-report` is cached for up to 4 hours.** `generate-credential-report`
  returns `COMPLETE` while still serving the stale copy, so a root password change made
  minutes ago won't show in `password_last_changed`. Not evidence the change failed.
- **The root email is not readable via CLI for a standalone account.**
  `account get-primary-email` only works from an AWS Organizations management or
  delegated-admin account. For a standalone account it's visible only on the console
  Account page while signed in **as root**.
- **Root email and password changes are root-only and console-only.** No IAM policy
  grants them; the "Update email address and password" action is greyed out for every
  IAM user, including `AdministratorAccess`. That is by design, not a permissions gap.
- **`iam:DeactivateMFADevice` simulates as `allowed` for admins but fails against root.**
  AWS blocks IAM principals from managing the root user's MFA at the service level.
  `simulate-principal-policy` only evaluates IAM policy, so it can't see this.

### Root recovery when the MFA device is unavailable

Self-service, no support case needed (used on `433597029398` 2026-07-09 and
`954945276385` 2026-07-27):

1. Set the primary contact phone to a number you can answer — IAM admin, no root:
   `aws account put-contact-information` (all fields required, phone as `+1XXXXXXXXXX`,
   no spaces or leading zeros). Capture the current record first so it can be restored.
2. Root sign-in → **Forgot password** → reset link goes to the current root email.
3. Sign in → **Troubleshoot MFA** → **Sign in using alternative factors** → verification
   email from `recover-mfa-no-reply@verify.signin.aws`, then **Call me now** to the phone
   from step 1. Both factors are required.
4. Once in, register your own MFA (root supports up to 8 devices, so existing devices
   don't need removing), then restore the contact phone if it was only changed for recovery.

Reference: <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa_lost-or-broken.html#root-mfa-lost-or-broken>

## Outbound port 25 / SMTP

AWS restricts outbound port 25 on all new accounts, EC2 and Lightsail alike. Removal is
requested via the **"Request to remove email sending limitations"** form, which **must be
submitted while signed in as the account root user** — there is no IAM path. Supply the
static IP and any rDNS record you want associated with it. Turnaround is typically 24–48h.

Reference: <https://repost.aws/knowledge-center/lightsail-port-25-throttle>
