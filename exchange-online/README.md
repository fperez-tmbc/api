# Exchange Online API Notes

## Exchange Online PowerShell — Unattended / App-Only Auth

Basic auth and user-delegated auth are not viable on macOS for non-interactive use. App-only auth via a registered Entra app + certificate is the correct approach.

### App Registration

| Field | Value |
|---|---|
| App name | `claude-exo` |
| App ID | `69de0375-242d-4b8a-94df-4e095ab81cea` |
| SP Object ID | `176b0e4e-4237-4381-bc4e-cbad24852ab6` |
| Tenant | `d5c15341-dfce-470a-bfdf-72c3dab91e7c` (themyersbriggs.com) |
| API permission | `Office 365 Exchange Online → Exchange.ManageAsApp` (application) |
| Exchange role group | `Recipient Management` (on-prem registration via `New-ServicePrincipal`) |
| Entra role | `Exchange Administrator` |
| Cert expiry | 2027-05-13 |

Credentials: `~/.tokens/exo-claude/` — `cert.pfx`, `cert.pem`, `key.pem`, `config.json`

### Connection Snippet

```powershell
Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline `
    -AppId '69de0375-242d-4b8a-94df-4e095ab81cea' `
    -CertificateFilePath '/Users/fperez2nd/GitHub/.tokens/exo-claude/cert.pfx' `
    -Organization 'themyersbriggs.com' `
    -ShowBanner:$false
```

No device code, no browser, no interactive prompt.

### Setup Steps (one-time, already completed)

1. `az ad app create` — create app registration
2. `az ad sp create` — create service principal
3. `openssl` — generate self-signed cert + PFX
4. `az ad app credential reset --cert` — upload cert to app
5. `az ad app permission add` + `az ad app permission admin-consent` — grant `Exchange.ManageAsApp`
6. `az rest` — assign Exchange Administrator Entra role to SP
7. Exchange Online PowerShell (one-time device auth):
   ```powershell
   New-ServicePrincipal -AppId <appId> -ServiceId <spId> -DisplayName 'claude-exo'
   Add-RoleGroupMember -Identity 'Recipient Management' -Member 'claude-exo'
   ```

### Gotchas

- `Connect-ExchangeOnline` without `-Device` fails on macOS with a `PlatformNotSupportedException` — browser auth is not supported. Always use the app/cert approach for unattended access.
- `Get-MailboxRestoreRequest` in Exchange Online does not support `-Mailbox` parameter — filter with `Where-Object { $_.TargetAlias -in $aliases }` instead.
- `-AllowLegacyDNMMismatch` is an on-prem-only parameter; omit it for Exchange Online cmdlets.
- `-SourceIsArchive` is a switch parameter — do not pass `$true`, just use the flag.

---

## On-Premises Exchange (Hybrid) — Remote PowerShell via SSH

For hybrid environments where mailboxes are `RemoteUserMailbox`, on-prem Exchange cmdlets must be run on the Exchange server. Direct WinRM from macOS is not available (no WSMan client in PowerShell Core on macOS).

**Server:** `SVEXCHDC01.cpp-db.com`  
**Account:** `svcclaude@cpp-db.com` (member of Organization Management)  
**Credentials:** `~/.tokens/svcclaude`

### Connection Pattern

SSH to SVEXCHDC01, then create a `New-PSSession` to the Exchange PowerShell HTTPS endpoint with explicit credentials and Basic auth. This avoids the Kerberos double-hop problem inherent to SSH logon sessions.

```powershell
$pass = ConvertTo-SecureString '<password>' -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('CPP-DB\svcclaude', $pass)
$opts = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
$s = New-PSSession `
    -ConfigurationName Microsoft.Exchange `
    -ConnectionUri 'https://SVEXCHDC01.cpp-db.com/PowerShell/' `
    -Credential $cred `
    -Authentication Basic `
    -SessionOption $opts
Import-PSSession $s -DisableNameChecking | Out-Null
# ... run Exchange cmdlets ...
Remove-PSSession $s
```

To run this non-interactively from macOS, encode the script as base64 and pass via SSH:

```powershell
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
& sshpass -p $pass ssh -o StrictHostKeyChecking=no "svcclaude@cpp-db.com@SVEXCHDC01.cpp-db.com" `
    "powershell.exe -EncodedCommand $encoded"
```

### Gotchas

- **Kerberos double-hop:** SSH creates a logon session with no Kerberos TGT. Any attempt to use Kerberos auth from within that session (including `RemoteExchange.ps1`, `Connect-ExchangeServer -auto`, or `New-PSSession -Authentication Kerberos`) will fail with `A specified logon session does not exist`. Fix: always pass explicit credentials with `-Authentication Basic` over HTTPS.
- **`Add-PSSnapin` fails non-interactively:** The snap-in loads but AD operations fail under the SSH logon context. Use the PSSession approach instead.
- **HTTP endpoint returns wrong content type:** The Exchange PowerShell VDir does not respond to WinRM over HTTP. Always use HTTPS (`https://`).
- **`Disable-Mailbox` vs `Disable-RemoteMailbox`:** Hybrid users with cloud-hosted mailboxes are `RemoteUserMailbox`. Use `Disable-RemoteMailbox -Archive`, not `Disable-Mailbox -Archive`.
- **`-SkipCACheck -SkipCNCheck -SkipRevocationCheck`** required in `New-PSSessionOption` when Exchange is using a self-signed or internal CA cert.
