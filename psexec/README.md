# PsExec Field Notes

Used to run commands on remote Windows hosts — typically from SVPDQHQ01 as a jump box when SSH isn't available or not yet set up on the target.

## Authentication

- **Use NetBIOS domain format:** `-u CPP-DB\svcclaude` ✓
- **UPN format fails:** `-u svcclaude@cpp-db.com` → "The user name or password is incorrect" ✗
- Always include `-accepteula` to suppress the interactive EULA prompt

```cmd
psexec \\TARGET -u CPP-DB\svcclaude -p <password> -accepteula cmd /c "command"
```

## Output Gotchas

### PsExec banner goes to stdout, not stderr
`2>/dev/null` (on the calling shell) does NOT suppress PsExec's banner — it writes to stdout. The banner interleaves with command output, making it hard to parse.

### Pipes inside the remote command break execution
Using `|` inside PsExec's `cmd /c "..."` argument causes:
```
The system cannot find the path specified.
```
**Workaround:** Write output to a temp file on the target, then read it separately.

### PowerShell via PsExec often produces no output
PowerShell output may not come through at all, especially with `Format-List` or `Format-Table`.

## Reliable Pattern: Write-Then-Read via C$ Share

The only consistently reliable way to get full output:

**Step 1 — Write output to a temp file on the target:**
```bash
sshpass -p "$PASS" ssh svcclaude@svpdqhq01.cpp-db.com \
  "psexec \\\\TARGET -u CPP-DB\\svcclaude -p $PASS -accepteula cmd /c \"command > C:\\Windows\\Temp\\out.txt 2>&1\""
```

**Step 2 — Read it back via the C$ admin share:**
```bash
sshpass -p "$PASS" ssh svcclaude@svpdqhq01.cpp-db.com \
  "type \\\\TARGET\\C\$\\Windows\\Temp\\out.txt" 2>/dev/null
```

Or from Mac directly (if SVPDQHQ01 is the jump host):
```bash
sshpass -p "$PASS" ssh svcclaude@svpdqhq01.cpp-db.com \
  "type \\\\TARGET\\C\$\\Windows\\Temp\\out.txt"
```

## PowerShell: Use EncodedCommand to Avoid Quoting Hell

For PowerShell commands with special characters, base64-encode them:

```bash
PS_CMD='Get-NetConnectionProfile | Select-Object Name,InterfaceAlias,NetworkCategory | Format-Table -AutoSize | Out-File C:\Windows\Temp\result.txt -Encoding UTF8'
ENCODED=$(echo -n "$PS_CMD" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')

sshpass -p "$PASS" ssh svcclaude@svpdqhq01.cpp-db.com \
  "psexec \\\\TARGET -u CPP-DB\\svcclaude -p $PASS -accepteula powershell -NonInteractive -EncodedCommand $ENCODED" 2>/dev/null
```

Then read the result file via C$ share.

## Netsh for Firewall Queries (More Reliable Than PowerShell)

`netsh advfirewall` works cleanly through PsExec and produces consistent output:

```bash
# Show a specific rule
psexec \\TARGET ... cmd /c "netsh advfirewall firewall show rule name=all > C:\Windows\Temp\allrules.txt"

# Then search the file:
sshpass ... ssh svpdqhq01 "type \\\\TARGET\\C$\\Windows\\Temp\\allrules.txt" | grep -A 14 -i "RuleName"
```

- Rule names with spaces must be quoted: `name="OpenSSH SSH Server (sshd)"`
- Use `name=all` + grep locally rather than piping on the remote side

## Setting Up SSH Key Auth (Preferred Once Accessible)

Once you can reach the target via PsExec, set up svcclaude's SSH key so future access uses SSH directly:

```bash
PUBKEY="ssh-ed25519 AAAA... svcclaude@cpp-db.com"
PASS="WHVfL9h8kk2vbieMfb6Y"

# Write the public key via C$ share
sshpass -p "$PASS" ssh svcclaude@svpdqhq01.cpp-db.com \
  "echo $PUBKEY > \\\\TARGET\\C\$\\ProgramData\\ssh\\administrators_authorized_keys"

# Fix permissions (Windows OpenSSH is strict — no inherited permissions allowed)
sshpass -p "$PASS" ssh svcclaude@svpdqhq01.cpp-db.com \
  "psexec \\\\TARGET -u CPP-DB\\svcclaude -p $PASS -accepteula cmd /c \
  \"icacls C:\\ProgramData\\ssh\\administrators_authorized_keys /inheritance:r /grant SYSTEM:F /grant Administrators:F\""
```

Public key is at `~/GitHub/.tokens/svcclaude-key.pub`.

## SSH via Jump Host (After Key Auth Is Set Up)

```bash
ssh -J svcclaude@svpdqhq01.cpp-db.com \
    -i ~/GitHub/.tokens/svcclaude-key \
    -o StrictHostKeyChecking=no \
    svcclaude@TARGET "command"
```

Note: `-J` ProxyJump uses the local key for the second hop — no password needed end-to-end.

## Elevation / UAC

Even with svcclaude in local Administrators, the SSH session token is **not elevated** by default (UAC). Commands requiring elevation (gpresult, schtasks /create as SYSTEM, etc.) will return exit code 5 (Access Denied) via SSH.

**Workaround:** Use PsExec with `-s` to run as SYSTEM (fully elevated), or use `schtasks /create /ru SYSTEM` via PsExec.
