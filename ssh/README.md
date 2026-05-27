# SSH Field Notes

Patterns, gotchas, and lessons learned for SSH access in the TMBC environment.

---

## Credentials & Keys

### svcclaude service account
- **Creds file:** `~/GitHub/.tokens/svcclaude` (key=value format)
- **Parse password safely:** `grep '^PASSWORD=' ~/GitHub/.tokens/svcclaude | cut -d'=' -f2-`
  - Never `cat` the file and pass it whole — you'll get `PASSWORD=xxx` as the value, not just the password
- **Ed25519 key (PAN-OS 11.x hosts):** `~/GitHub/.tokens/svcclaude-key`
- **RSA 4096 key (PAN-OS 10.2.x hosts):** `~/GitHub/.tokens/svcclaude-key-rsa`
  - PAN-OS 10.2.x rejects ed25519 — always use the RSA key for AUPAN and FRPAN

### Frank's personal key
- `~/.ssh/id_ed25519` — used for SVDCDC01 and general domain hosts
- `~/.ssh/id_rsa_svolprodtx01` — RSA key for svolprodtx01 (legacy server, requires legacy algorithm flags)

---

## Auth Fallback Pattern

**Always try key auth first, then fall back to password with sshpass. Never give up after a publickey failure.**

```bash
# Step 1 — key auth
ssh -o StrictHostKeyChecking=no svcclaude@TARGET "command"

# Step 2 — if "Permission denied (publickey,...)", retry with password
PASS=$(grep '^PASSWORD=' ~/GitHub/.tokens/svcclaude | cut -d'=' -f2-)
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no svcclaude@TARGET "command"
```

**Why:** svcclaude's password worked on SVAZADSYNCDC01 even when key auth failed. Time was wasted on WinRM workarounds before trying the obvious fallback.

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

End user endpoints are **not directly routable** from Frank's GlobalProtect connection. The pattern is:
1. SSH into SVPDQHQ01 (10.70.16.209) — jump onto the internal network
2. From SVPDQHQ01, use `Invoke-Command` over WinRM to reach the endpoint

**svcclaude does not have standing local admin on endpoints.** Before running any commands, provide Frank with the `net` command to add svcclaude, and wait for confirmation that it's been added:

```
net localgroup administrators CPP-DB\svcclaude /add
```

After the session, Frank removes it:
```
net localgroup administrators CPP-DB\svcclaude /delete
```

### Pattern — SSH to SVPDQHQ01, then Invoke-Command to endpoint

```bash
PASS=$(grep '^PASSWORD=' ~/GitHub/.tokens/svcclaude | cut -d'=' -f2-)

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no svcclaude@svpdqhq01.cpp-db.com \
  "powershell -Command \"Invoke-Command -ComputerName TARGET -Credential (New-Object PSCredential('CPP-DB\svcclaude', (ConvertTo-SecureString '$PASS' -AsPlainText -Force))) -ScriptBlock { COMMAND }\""
```

For multi-line or complex scripts, use `-EncodedCommand` for the outer PowerShell call (see PowerShell via SSH section below) and embed the `Invoke-Command` block inside.

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

### Windows: Firewall profile gotcha

SSH (and WinRM) inbound rules created by Windows default to `Profile=Private`. If the target connects via GlobalProtect VPN, its PANGP adapter is classified as `DomainAuthenticated` — traffic arrives on a Domain-profile interface and is silently dropped even though sshd is listening on `0.0.0.0`.

**Symptoms:** SSH times out, `bytes_received=0` in firewall logs, sshd listening correctly, no explicit deny rule.

**Fix:**
```cmd
netsh advfirewall firewall set rule name="OpenSSH SSH Server (sshd)" new profile=domain,private
```

Proper fix: ensure the GPO pushing the SSH rule defines `Profile=Domain|Profile=Private`. See `knowledge-base/troubleshoot/fraudreyl02-ssh-gpo-2026-05-27.md` for the full case.

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

---

## Known Hosts in the Environment

| Host | Address | User | Auth | Notes |
|------|---------|------|------|-------|
| svpdqhq01.cpp-db.com | 10.70.16.209 | svcclaude | sshpass | Primary jump box; also PDQ server; use for Invoke-Command to endpoints |
| svazadsyncdc01.cpp-db.com | — | svcclaude | sshpass | ADSyncOperators group; use for `Start-ADSyncSyncCycle` |
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
| Sudo prompts for password over SSH | No TTY allocated | Add `-t` flag to allocate a pseudo-TTY |
