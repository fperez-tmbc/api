# Windows DNS — Field Notes

> ## ⚠️ `svcclaude` (AD account) was DECOMMISSIONED 2026-08-02
>
> Every `svcclaude` example below that authenticates to **Windows/AD** is dead. The plaintext
> `~/GitHub/.tokens/svcclaude` file is dead too. Auth fails with
> `Permission denied` / `The user name or password is incorrect`, which reads like a stale
> password but is a removed account — **do not retry it, and do not burn lockout budget on it.**
>
> **Use instead:**
> - **WinRM as `CPP-DB\2fperez`** — `Invoke-Command -ComputerName <fqdn> -ScriptBlock {...}`.
>   `2fperez` is a Domain Admin in cpp-db.com. This is the proven day-to-day path.
> - **Azure Key Vault `kv-tmbc-secrets`** for privileged creds — `~/GitHub/.tokens/kv-get.sh <secret>`.
>   Account names are stored in each secret's Azure **tags** (`username`, `scope`).
>   DA per domain: `ntsupport` (cpp-db.com, cpp-web.com), `#domain` (opp.local, oppashapp.local, oppnewapp.local).
>
> Not every `svcclaude` reference is dead: the **PAN-OS local account of the same name still works**
> (firewalls have their own user database). See `api/pan/README.md`.
>
> The transport-level patterns below (sshpass on Windows, `-EncodedCommand`, NetBIOS-vs-UPN,
> loopback workarounds) remain correct — substitute a live account in the examples.
> Full detail: `api/ssh/README.md`.



Internal DNS updates via SSH + PowerShell DnsServer cmdlets.

## Setup Requirements

### On SVDCDC01
1. **OpenSSH Server** must be installed and running (`sshd` service) ✓
2. **svcclaude** must be a member of the **DnsAdmins** group in AD ✓
3. **SSH key auth** — deploy `~/.ssh/id_ed25519.pub` to svcclaude's authorized_keys ✓
   - Key lives at `C:\Users\svcclaude\.ssh\authorized_keys` (standard user location)
4. **Zone ACL** — DnsAdmins alone doesn't grant write access to AD-integrated zone records.
   Run `grant-dns-acl.ps1` once as a domain admin to grant svcclaude Full Control on all zones:
   ```powershell
   .\grant-dns-acl.ps1          # apply
   .\grant-dns-acl.ps1 -WhatIf  # dry run
   ```
   The script covers all three AD partitions (DomainDnsZones, ForestDnsZones, System).
   Re-run if new zones are added.
   - `CNF:` entries (replication conflict objects) will always fail with "bad syntax" — expected and harmless, ignore them.

### Verifying access
```bash
zsh -c '
ENCODED=$(printf "dnscmd SVDCDC01.cpp-db.com /enumzones" | iconv -t UTF-16LE | base64 | tr -d "\n")
ssh -i ~/.ssh/id_ed25519 -o BatchMode=yes "cpp-db\\svcclaude"@SVDCDC01.cpp-db.com \
  "powershell -NonInteractive -EncodedCommand $ENCODED"
'
```

## Credentials

- **File:** `/Users/fperez2nd/GitHub/.tokens/svcclaude`
- **Format:** `USERNAME=svcclaude@cpp-db.com` / `PASSWORD=...`
- **SSH key:** `~/.ssh/id_ed25519`

## Default Server

`SVDCDC01.cpp-db.com` — override with `DNS_SERVER=other-dc.cpp-db.com`

## Script

`dns-update.sh` — wraps common DnsServer cmdlet operations.

| Operation | What it does |
|-----------|-------------|
| `add-cname` | Add a new CNAME record |
| `update-cname` | Update an existing CNAME's target (get/clone/set pattern) |
| `add-a` | Add a new A record |
| `update-a` | Update an existing A record's IP |
| `delete` | Delete a record (pass record type as target arg) |

TTL defaults to 3600 if not specified. Pass `0` to inherit zone default.

## How the Script Works

PowerShell commands are encoded as UTF-16LE base64 and passed via `-EncodedCommand` to avoid shell quoting conflicts between zsh and PowerShell.

## Update Pattern (get/clone/set)

Windows DNS requires the old record object for updates — you can't just overwrite by name. The pattern:
```powershell
$old = Get-DnsServerResourceRecord -ZoneName 'zone' -Name 'host' -RRType CName
$new = $old.Clone()
$new.RecordData.HostNameAlias = 'newtarget.com.'   # trailing dot required
Set-DnsServerResourceRecord -ZoneName 'zone' -OldInputObject $old -NewInputObject $new
```

## CNAME Target Trailing Dot

CNAME targets must be fully-qualified (trailing dot). The script appends it automatically if missing.

## Zones

Any zone hosted on the DNS server. Frank specifies the zone at request time. Common zones:
- `themyersbriggs.com`
- `cpp-db.com`

## Known Servers

| Server | Hostname | Notes |
|--------|----------|-------|
| Primary DC | SVDCDC01.cpp-db.com | Default |
