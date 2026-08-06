# SSH Field Notes

Patterns, gotchas, and lessons learned for SSH access in the TMBC environment.

---

## ⚠️ svcclaude's AD rights were dismantled (2026-07-27)

**`svcclaude` is not a usable AD identity any more** — but it was not deleted everywhere, so be precise about it. Authentication fails with:

```
Permission denied (publickey,password,keyboard-interactive)
```

**What actually happened on 2026-07-27:** every delegated ACE was removed from all five domain roots, group memberships were stripped in cpp-db.com, the account was **deleted outright** in cpp-web.com / opp.local / oppashapp.local / oppnewapp.local, it was removed from local Administrators on ~26 machines, and **its password was rotated**. In cpp-db.com the account still **exists but is powerless**, retained only so **vCenter and the PAN firewalls** can authenticate it.

So the failure is both a stale password *and* absent rights — which is why it presents as an ordinary bad-password error. `~/GitHub/.tokens/svcclaude` holds the pre-rotation value and is useless. **Do not retry it or burn lockout budget on it.**

**Use instead:**

| Need | Method |
|---|---|
| Windows hosts in `cpp-db.com` | **WinRM as `CPP-DB\2fperez`** — `Invoke-Command -ComputerName <fqdn>`. Proven working 2026-08-02 on Veeam servers, DCs, and member servers. `2fperez` is a Domain Admin in cpp-db.com. |
| Privileged creds | **Azure Key Vault `kv-tmbc-secrets`** — `~/GitHub/.tokens/kv-get.sh <secret>`. See the secret→account table below. |
| Hosts in other domains | Cross-domain WinRM **fails on Kerberos** from the admin workstation (opp.local, oppashapp.local, oppnewapp.local, cpp-web.com). Verify reachability by service port, or run from inside that domain. |

### Key Vault secret → account map (confirmed 2026-08-02)

| Secret | Account | Scope | Tested 2026-08-02 |
|---|---|---|---|
| `da-cpp-db-com` | `ntsupport` | DA, cpp-db.com | ✅ LDAP bind |
| `da-cpp-web-com` | `ntsupport` | DA, cpp-web.com | ✅ LDAP bind |
| `da-opp-local` | `#domain` | DA, opp.local | ✅ LDAP bind |
| `da-oppashapp-local` | `#domain` | DA, oppashapp.local | ✅ LDAP bind |
| `da-oppnewapp-local` | `#domain` | DA, oppnewapp.local | ✅ LDAP bind |
| `local-admin-server-us` | `Administrator` | US servers (cpp-db.com) | ✅ SMB, SVFSHQ01 |
| `local-admin-server-uk` | `2local` | UK servers (**opp.local**) | ✅ SMB, OXPDVSQL01 |
| `local-admin-tmbcadmin` | `tmbcadmin` | LAPS default — VDI / LAPS-excluded only | ✅ SMB, VMDVALONSOP72 |

**The account name is stored in each secret's Azure tags** (added 2026-08-02) so it never has to be reconstructed:

```bash
az keyvault secret list --vault-name kv-tmbc-secrets   --query "sort_by([].{secret:name, username:tags.username, domain:tags.domain, scope:tags.scope, verified:tags.verified}, &secret)" -o table
```

**Gotcha:** the secret *values* are bare password strings, not the `{username,password}` JSON used by older vault entries — `kv-get.sh <name> username` will fail. Read the username from the tags.

The `#` in `#domain` is literal. `ntsupport` and `#domain` are each DA in multiple domains, but **passwords are per-domain** — always pull the secret matching the target host's domain.

**`local-admin-tmbcadmin` is a LAPS account — the KV value is only the *default* password.** `tmbcadmin` is pushed by PDQ then rotated by Windows LAPS on Intune-enrolled machines. **VDI VMs are excluded from the LAPS policy**, so they keep the default and the KV secret works there (verified on VMDVALONSOP72, VMJENKAGENT01). On LAPS-enrolled machines the KV value is stale by design — pull the current password from LAPS/Intune instead.

On VDI VMs `tmbcadmin` is usually the **only** enabled local account (no local `Administrator`) — the inverse of the server estate, where you get `Administrator` and sometimes `2local`. When hunting for an account, sample the right *class* of machine rather than more servers.

**UK vs US is decided by domain membership, not site prefix.** `2local` exists only on the `opp.local` estate; `SVFSMK02` sits on the same 10.30.16.x UK subnet but is joined to cpp-db.com and takes the *US* secret. Resolve a host's domain from PDQ Inventory `Computers.ADDomain`; never infer it from the hostname prefix.

**Testing a credential safely** — one attempt, no retries (these are DA accounts across five domains):

```powershell
# Domain account - LDAP bind
$de = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$dc", "$user@$domain", $pw); $null = $de.NativeObject
# Local account - SMB. Local accounts cannot use Kerberos, so WinRM/Negotiate will NOT work.
net use \\$server\IPC$ /user:$server\$account "$pw"
```

Enumerate before guessing an account name:
`Invoke-Command -ComputerName <host> -Credential <verified DA> { Get-LocalUser | ? Enabled }`

**Scope:** the teardown hit **AD rights and the password**. The **PAN-OS local account is untouched and still works** (verified 2026-08-02), and the cpp-db.com object is deliberately retained for **vCenter and PAN** — see below. Everything further down that references `svcclaude` against *Windows/AD* hosts is retained for its transport-level patterns (sshpass on Windows, askpass suppression, `-EncodedCommand`, legacy algorithm flags), which remain correct — just substitute a live account in those examples.

---

## Credentials & Keys

### svcclaude — AD identity unusable, PAN firewall account ALIVE

**Two different identities share this name. Do not conflate them.**

- ❌ **AD account `CPP-DB\svcclaude`** — still exists in cpp-db.com but stripped of all groups and ACEs, removed from local Administrators everywhere, and **password rotated 2026-07-27**. Deleted outright in the other four domains. `~/GitHub/.tokens/svcclaude` holds the pre-rotation password and is useless. Retained purely so **vCenter** and the **PAN firewalls** can still authenticate it — not for general AD or server work.
- ✅ **PAN-OS local account `svcclaude`** — **still valid and working.** Firewalls keep their own local user database, so none of the AD teardown touched it. Verified 2026-08-02 against AVSPAN01 and WHPAN01 — key auth succeeded and returned the `svcclaude@AVSPAN01(active)>` prompt.
  - **Ed25519 key (PAN-OS 11.x — AVSPAN, WHPAN, DCPANORAMA01):** `~/GitHub/.tokens/svcclaude-key`
  - **RSA 4096 key (PAN-OS 10.2.x — AUPAN, FRPAN):** `~/GitHub/.tokens/svcclaude-key-rsa`
  - PAN-OS 10.2.x rejects ed25519 — always use the RSA key for AUPAN and FRPAN

Keep using the PAN keys. See `api/pan/README.md`.

### Frank's personal key
- `~/.ssh/id_ed25519` — used for SVDCDC01 and general domain hosts
- `~/.ssh/id_rsa_svolprodtx01` — RSA key for svolprodtx01 (legacy server, requires legacy algorithm flags)

---

## Choosing an Auth Method

Before defaulting to sshpass, consider whether a better method is appropriate:

| Method | When to use |
|--------|-------------|
| **SSH key auth** | Any host accessed repeatedly — set up once, no PTY issues, works with any SSH binary |
| **sshpass** | One-off commands on hosts where keys aren't deployed; acceptable for infrequent use |
| **SSH_ASKPASS** | When sshpass has PTY compatibility problems (e.g. WinGet sshpass + Git Bash) |

**Rule:** If a host will be accessed more than a few times, or sshpass is proving unreliable, prompt Frank to approve setting up key auth before proceeding. Don't use sshpass by default just because it's documented — use it because it's the right tool for the situation.

---

## Auth Fallback Pattern

**Always try key auth first, then fall back to password with sshpass. Never give up after a publickey failure.**

```bash
# Step 1 — key auth
ssh -o StrictHostKeyChecking=no svcclaude@TARGET "command"

# Step 2 — if "Permission denied (publickey,...)", retry with password
PASS=$(grep '^PASSWORD=' ~/GitHub/.tokens/svcclaude | cut -d'=' -f2-)
SSHPASS="$PASS" sshpass -e /c/Windows/System32/OpenSSH/ssh.exe -o StrictHostKeyChecking=no svcclaude@TARGET "command"
```

**Why:** svcclaude's password worked on SVAZADSYNCDC01 even when key auth failed. Time was wasted on WinRM workarounds before trying the obvious fallback.

> **Superseded 2026-08-02.** svcclaude is decommissioned, so this fallback no longer applies to that account. The inverse lesson now holds: when password auth fails on a Windows host, **try WinRM as `2fperez` before assuming a credential problem** — and check whether the account still exists before retrying at all. Repeated failed attempts against a dead or unknown account only risk lockouts.

**Windows sshpass gotcha:** The WinGet sshpass binary (`/c/Users/.../WinGet/Links/sshpass`) is Win32-native and cannot hook into Git Bash's POSIX SSH (`/usr/bin/ssh`). Always point it at the Windows OpenSSH binary: `/c/Windows/System32/OpenSSH/ssh.exe`. Use `SSHPASS="$PASS" sshpass -e` (env var) rather than `-p` — more reliable across platforms.

**Windows askpass GUI-popup gotcha:** When MSYS `/usr/bin/ssh` needs a password but has no interactive TTY (e.g. run from an automation/tool shell) and sshpass isn't injecting, ssh falls back to `SSH_ASKPASS` — which Git for Windows sets to `/mingw64/bin/git-askpass.exe` with `DISPLAY` pre-defined (`needs-to-be-defined`). This pops a **GUI dialog titled "Git for Windows"** on the user's desktop reading `<user>@<host>'s password:` — it looks like a rogue Git credential prompt but it's actually ssh asking for the SSH password. Two fixes, use both: (1) use the Windows OpenSSH binary + `SSHPASS=... sshpass -e` per the gotcha above so the password is injected and the fallback never fires; (2) always prefix Windows ssh calls with `SSH_ASKPASS_REQUIRE=never DISPLAY=` so ssh can never spawn the GUI helper — it fails fast on the terminal instead of popping a dialog on Frank's screen. Confirmed 2026-06-27 (svcclaude → SVVEEAMAVS01).

**UPN usernames:** Windows domain hosts often require UPN format (`user@domain`) rather than bare username. Use `-l "svcclaude@cpp-db.com"` — do NOT combine as `user@host` since the `@` in the username confuses SSH host parsing.

---

## Legacy Algorithm Flags

Some older servers (svolprodtx01, legacy Postfix hosts) reject modern key types and ciphers.

```bash
# Force RSA host key + pubkey acceptance for servers that reject ed25519
ssh -i ~/.ssh/id_rsa_svolprodtx01 \
  -o HostKeyAlgorithms=+ssh-rsa \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  root@svolprodtx01.cpp-db.com
```

Use this pattern any time you see:
- `no matching host key type found`
- `no matching key exchange method found`
- `Unable to negotiate`

---

## End User Laptops

> **Stale-note correction (2026-08-05):** this section previously used `svcclaude`. That AD identity
> was dismantled 2026-07-27 (see the banner at the top of this file) and the PDQ SSH user is
> `claude`, not `svcclaude`. Use the Key Vault DA account for the endpoint hop.

**Why a jump box is required, not merely convenient:** macOS PowerShell has **no WSMan client**.
`Invoke-Command -ComputerName` fails with *"This parameter set requires WSMan, and no supported WSMan
client library was found"*, and `Test-WSMan` is not even a recognized cmdlet. There is also no
`impacket` or `smbclient` on the Mac, so open 135/445 buy nothing. Anything WinRM must originate from
a Windows host.

**Pick the path by where the target is:**

| Target location | Path |
|---|---|
| Same LAN as the Mac | **Direct SSH** — no jump box (see below) |
| On GlobalProtect, elsewhere | SSH to SVPDQHQ01 → `Invoke-Command` to the GP address |
| Corporate LAN | SSH to SVPDQHQ01 → `Invoke-Command` |

### Direct SSH to a laptop on the same LAN (verified 2026-08-05, HQNOFRANKP02)

Works once the NIC's firewall profile allows it — see the firewall-profile gotcha below, which is
what blocks this by default.

```bash
SSHPASS=$(~/GitHub/.tokens/kv-get.sh da-cpp-db-com) sshpass -e ssh -n -q \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  ntsupport@<laptop-ip> '<command>'
```

Use the **UPN form** `ntsupport@cpp-db.com` or bare `ntsupport`; the `CPP-DB\ntsupport` form works for
ssh but the backslash gets mangled by the local shell, so avoid it. Windows 11 ships
`OpenSSH_for_Windows_9.5`.

### Pattern — SSH to SVPDQHQ01, then Invoke-Command to endpoint

PDQ SSH creds: `~/GitHub/.tokens/patching` → `$PDQ_PASS`, user `claude` (see `api/pdq/`).

```bash
source ~/GitHub/.tokens/patching
SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q -o StrictHostKeyChecking=no \
  claude@SVPDQHQ01.cpp-db.com "powershell -NoProfile -EncodedCommand <b64>"
```

Build the payload so **no secret ever lands in a command line**, and target the endpoint's **GP
address** when it is remote:

```bash
# template with __DAPW__ / __KEY__ placeholders, substituted in python, then UTF-16LE + base64
B64=$(python3 -c "import base64,sys;print(base64.b64encode(open(sys.argv[1]).read().replace('__DAPW__',sys.argv[2]).encode('utf-16-le')).decode())" tpl.ps1 "$DAPW")
```

**Gotchas learned the hard way (2026-08-05):**
- `powershell -Command -` **does** read stdin over SSH, but the session can close before a
  long-running remote command finishes, yielding **silent empty output**. Use `-EncodedCommand` for
  anything slow.
- `-EncodedCommand` output is prefixed with `#< CLIXML` progress noise — filter with
  `grep -vE 'CLIXML|^<Objs|Objs>'`.
- cmd.exe caps the remote command line at ~8191 chars; a UTF-16LE+base64 payload is ~2× the script
  size, so keep scripts small (a 1.5 KB script encoded to ~2.8 KB, comfortably under).
- Unquoted bash heredocs mangle `\`-escapes in PowerShell. Use a **quoted** heredoc plus placeholder
  substitution.

**Note:** `Enter-PSSession` is interactive — Frank drives those manually. Use `Invoke-Command` for anything I'm running.

---

## Jump Hosts / ProxyJump

SVPDQHQ01 (10.70.16.209) is the primary jump box for servers and other hosts reachable via SSH on the internal network.

```bash
# Single hop via jump host
ssh -J svcclaude@svpdqhq01.cpp-db.com \
    -i ~/GitHub/.tokens/svcclaude-key \
    -o StrictHostKeyChecking=no \
    svcclaude@TARGET "command"

# With sshpass (if key auth fails on either hop)
PASS=$(grep '^PASSWORD=' ~/GitHub/.tokens/svcclaude | cut -d'=' -f2-)
sshpass -p "$PASS" ssh \
    -o ProxyJump="svcclaude@svpdqhq01.cpp-db.com" \
    -o StrictHostKeyChecking=no \
    svcclaude@TARGET "command"
```

Note: `-J` ProxyJump uses the **local** key for the second hop — no separate password needed for the target if key auth is configured there.

---

## Running Remote Commands

### Basic remote command
```bash
ssh -o StrictHostKeyChecking=no user@host "command"
```

### Quoting gotchas
Variables expand **locally** unless you escape or single-quote the outer command:

```bash
# This expands $VAR locally before sending:
ssh user@host "echo $VAR"

# This sends $VAR literally to the remote shell:
ssh user@host 'echo $VAR'

# To pass a local variable to a remote command, use printf or heredoc:
ssh user@host "VAR='$LOCAL_VAR'; echo \$VAR"
```

### TTY for interactive or sudo commands
Some commands require a TTY (sudo, less, vim, etc.):
```bash
ssh -t user@host "sudo command"
```

### Windows: authorized_keys location for admin accounts

Standard users store authorized keys in `C:\Users\<username>\.ssh\authorized_keys`.
Admin accounts use a **different location**: `C:\ProgramData\ssh\administrators_authorized_keys`.

`ssh-copy-id` writes to the user's home directory and won't work for admin accounts. Append the key manually:
```cmd
echo <public-key-content> >> C:\ProgramData\ssh\administrators_authorized_keys
```

Use `type` not `cat` for file operations on Windows.

### Windows: UPN format for domain accounts

Use UPN format (`user@domain`) as the SSH username for domain accounts:
```bash
ssh -i ~/.ssh/id_ed25519 "2fperez@themyersbriggs.com"@server.cpp-db.com
```

### Windows: Firewall profile gotcha — THE most common "port is closed" cause

SSH and WinRM inbound rules created by Windows default to **`Profile=Private`**. Any interface not
classified Private then drops the traffic, even though sshd listens on `0.0.0.0` and there is no
explicit deny rule.

**Symptoms:** port shows closed / SSH times out, `bytes_received=0` in firewall logs, sshd listening
correctly, no deny rule anywhere.

**Diagnose — do not guess, these two commands settle it:**
```powershell
Get-NetIPAddress -AddressFamily IPv4 | Select IPAddress,InterfaceAlias   # which IP is on which NIC
Get-NetConnectionProfile | Select InterfaceAlias,NetworkCategory         # which NIC is which profile
Get-NetFirewallRule -Name OpenSSH-Server-In-TCP | Select Enabled,Profile # what the rule covers
```
Then compare: the profile of the NIC holding the IP you are dialing must appear in the rule's
`Profile`. Test the port **from the actual source host**, since results differ per interface.

**Two real cases, and they behaved differently — do not over-generalize from either:**

| Case | Rule profile | Target NIC / category | Result |
|---|---|---|---|
| FRAUDREYL02, 2026-05-27 | `Private` | GP adapter, `DomainAuthenticated` | **dropped** |
| HQNOFRANKP02, 2026-08-05 | `Private` | GP adapter `Ethernet 5`, `DomainAuthenticated` | **worked** (reachable from SVPDQHQ01) |
| HQNOFRANKP02, 2026-08-05 | `Private` | home LAN `Ethernet`, **`Public`** | **dropped** |

The `Public` case is unambiguous and was the real blocker on Frank's laptop. Why the GP/Domain path
worked on one host and not the other is **not explained** — same Private-only rule, same
`DomainAuthenticated` category. Treat "Domain adapter + Private rule" as *unpredictable* and verify
per host rather than assuming either outcome.

**Fix — prefer reclassifying the network over widening the rule:**
```powershell
# best: a home/office LAN should be Private, not Public (narrower than editing the rule)
Set-NetConnectionProfile -InterfaceIndex <ifIndex> -NetworkCategory Private
```
Windows 11 25H2 exposes this in the GUI (network properties → Private), which is the quickest route.

Alternative, if the classification must stay Public:
```powershell
Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -Profile Private,Public
```

For GPO-managed endpoints, ensure the GPO pushing the SSH rule defines `Profile=Domain|Private`.
Full earlier case: `knowledge-base/troubleshoot/fraudreyl02-ssh-gpo-2026-05-27.md`.

### Windows: Exchange Management Shell via SSH

Exchange cmdlets (`Get-MessageTrackingLog`, etc.) require Kerberos credential delegation, which non-interactive SSH sessions don't provide. Workaround: parse the Exchange log CSV files directly instead.

Exchange message tracking logs:
```
C:\Program Files\Microsoft\Exchange Server\V15\TransportRoles\Logs\MessageTracking\MSGTRK*.LOG
```

Log files have `#` comment lines — skip them with `Where-Object { $_ -notmatch '^#' }` before piping to `ConvertFrom-Csv`.

### PowerShell via SSH (Windows hosts)
**Always use `-EncodedCommand`, never pipe a script via stdin.**

```bash
PASS=$(grep '^PASSWORD=' ~/GitHub/.tokens/svcclaude | cut -d'=' -f2-)
PS_CMD='Get-Service | Where-Object Status -eq Running | Select-Object Name | Format-Table -AutoSize | Out-File C:\Windows\Temp\result.txt -Encoding UTF8'
ENCODED=$(printf '%s' "$PS_CMD" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no svcclaude@TARGET \
  "powershell -NonInteractive -EncodedCommand $ENCODED"
```

**Why:** `powershell -` reading from stdin silently fails through SSH — PowerShell gets no input and exits with no output and no error. `-EncodedCommand` is argument-based and works reliably.

### Windows: Veeam B&R v13 cmdlets require PowerShell 7 (not 5.1)

The Veeam B&R **v13** PowerShell module (`Veeam.Backup.PowerShell`) has `PowerShellVersion = 7.0` in its manifest. Invoking it from Windows PowerShell 5.1 (the default `powershell` over SSH) fails: the module "imports" but exposes **0 cmdlets** (`Connect-VBRServer`/`Get-VBRJob` "not recognized", `[Veeam.Backup.Core.CBackupSession]` type not found). Invoke `pwsh` (PowerShell 7, at `C:\Program Files\PowerShell\7\pwsh.exe`) instead — it also accepts `-EncodedCommand`. Confirmed on SVVEEAMAVS01 (Veeam 13.0.1.180), 2026-06-27.

```bash
# Veeam v13 read-only query over SSH (svcclaude is local admin on SVVEEAMAVS01):
ssh ... "pwsh -NonInteractive -NoProfile -EncodedCommand $ENCODED"
# inside the script: Import-Module Veeam.Backup.PowerShell; Connect-VBRServer -Server localhost; ...
```

---

## Known Hosts in the Environment

| Host | Address | User | Auth | Notes |
|------|---------|------|------|-------|
| svpdqhq01.cpp-db.com | 10.70.16.209 | svcclaude | sshpass | Primary jump box; also PDQ server; use for Invoke-Command to endpoints |
| svazadsyncdc01.cpp-db.com | — | svcclaude@cpp-db.com (UPN) | sshpass | ADSyncOperators group; use for `Start-ADSyncSyncCycle`; UPN required, use `-l "svcclaude@cpp-db.com"` |
| sql-badc01 | 10.70.16.191 | 2fperez@themyersbriggs.com | key | SQL Server 2016; `ssh sql-badc01 -l 2fperez@themyersbriggs.com` |
| svolprodtx01.cpp-db.com | 10.70.16.28 | root | `id_rsa_svolprodtx01` + legacy algo flags | Oracle/Postfix relay server |
| PAN firewalls (11.x) | see pan README | svcclaude | `svcclaude-key` (ed25519) | avspan01, whpan, aupan (PAN-OS 11+) |
| PAN firewalls (10.2.x) | see pan README | svcclaude | `svcclaude-key-rsa` (RSA) | aupan (10.2.x), frpan |

---

## Common Failure Modes

| Error | Cause | Fix |
|-------|-------|-----|
| `Permission denied (publickey,...)` | Key not authorized on target | Retry with sshpass password auth |
| `no matching host key type found` | Server only supports ssh-rsa | Add `-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa` |
| `Unable to negotiate` | Cipher/kex mismatch on legacy host | Add `-o KexAlgorithms=+diffie-hellman-group14-sha1` or similar |
| `Host key verification failed` | Host key changed or not in known_hosts | Add `-o StrictHostKeyChecking=no` (internal hosts only) |
| PowerShell via SSH returns nothing | Stdin pipe to `powershell -` doesn't work | Use `-EncodedCommand` with base64-encoded script |
| `Connection refused` | SSH not running or wrong port | Check if host needs PsExec access first; see psexec README |
| sshpass sends password but server still rejects | WinGet sshpass can't hook Git Bash SSH PTY | Use `/c/Windows/System32/OpenSSH/ssh.exe` explicitly; use `SSHPASS=... sshpass -e` |
| GUI dialog titled "Git for Windows" pops asking for `<user>@<host>'s password` | MSYS ssh fell back to `SSH_ASKPASS=git-askpass.exe` (no TTY + sshpass not injecting) | Prefix ssh with `SSH_ASKPASS_REQUIRE=never DISPLAY=`; also use Windows OpenSSH binary + `SSHPASS=... sshpass -e` |
| Veeam v13 cmdlets "not recognized" after Import-Module | Veeam B&R v13 module needs PowerShell 7 | Invoke `pwsh` not `powershell` over SSH |
| sshpass password rejected on domain account | Bare username rejected; UPN required | Use `-l "user@domain"` not `user@host`; confirmed on svazadsyncdc01 |
| Sudo prompts for password over SSH | No TTY allocated | Add `-t` flag to allocate a pseudo-TTY |
