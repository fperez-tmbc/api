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

## FIRST: prefer direct password SSH — you usually do NOT need PsExec (learned 2026-07-18)

svcclaude is added to the target's **local Administrators** group before you troubleshoot it, and a **direct password SSH session comes back elevated** (High Mandatory Level). It can read `CBS.log`/`C:\Config.Msi`, run `DISM`/servicing, rename `catroot2`, launch `setup.exe`, etc. — with commands returning **stdout directly**, no double-hop, no `net use`, no EncodedCommand. So **reach for direct SSH first; reserve PsExec for the rare true-SYSTEM-only need.** Do NOT try key auth (keys aren't distributed) — password only. See [[feedback-ssh-pw-fallback]].

```bash
export SSHPASS=$(grep '^PASSWORD=' ~/GitHub/.tokens/svcclaude | cut -d= -f2-)
sshpass -e ssh -o StrictHostKeyChecking=no \
  -o ProxyCommand="sshpass -e ssh -o StrictHostKeyChecking=no -W %h:%p svcclaude@svpdqhq01.cpp-db.com" \
  svcclaude@TARGET.cpp-db.com "dism /online /cleanup-image /checkhealth"
```

(The elevation note that used to say "SSH sessions aren't elevated" was wrong for svcclaude here.)

## If you DO use PsExec: Diagnostics That Write Output Files (learned 2026-07-18)

Fallback pattern for the rare true-SYSTEM case — "run a PowerShell diagnostic on the target and read the result back," across the double-hop:

1. **Don't stage a `.ps1` on the target.** `scp` from Mac → jump host **fails silently** (Windows OpenSSH path quirk), so the file isn't there to copy onward. Instead pass the script inline with `powershell -EncodedCommand <base64 UTF-16LE>`:
   ```bash
   ENC=$(iconv -f UTF-8 -t UTF-16LE script.ps1 | base64 | tr -d '\n')
   sshpass -p "$PASS" ssh svcclaude@svpdqhq01.cpp-db.com \
     "psexec \\\\TARGET -u CPP-DB\\svcclaude -p $PASS -h -accepteula powershell -NonInteractive -NoProfile -EncodedCommand $ENC"
   ```
   **`-EncodedCommand` has an ~8191-char command-line limit.** If the base64 exceeds it, split the script into 2+ runs that append to the same output file.

2. **Have the script write output to `C:\Temp\out.txt` (not `C:\Windows\Temp`)** and end it with `icacls C:\Temp\out.txt /grant *S-1-1-0:R | Out-Null` (grants Everyone read).

3. **Read it back via `net use` over the C$ share** (the double-hop otherwise = "Access is denied"):
   ```bash
   sshpass -p "$PASS" ssh svcclaude@svpdqhq01.cpp-db.com \
     "net use \\\\TARGET\\C\$ /user:CPP-DB\\svcclaude \"$PASS\" >nul 2>&1 & type \\\\TARGET\\C\$\\Temp\\out.txt & net use \\\\TARGET\\C\$ /delete >nul 2>&1"
   ```

### Gotchas behind that pattern
- **Double-hop:** the jump-host SSH session has **no network credentials** to the target's `C$` — plain `copy`/`type \\TARGET\C$\...` returns **"Access is denied."** Always `net use \\TARGET\C$ /user:CPP-DB\svcclaude "$PASS"` first. If it still fails, the box has **persistent (remembered) connections** — prepend `net use \\TARGET\C$ /delete /y` to clear a stale/conflicting session, then reconnect with `/persistent:no`.
- **SYSTEM (`-s`) output files are unreadable by the `net use` (svcclaude) session** → "Access is denied" on read-back. Fix: run the diagnostic with **`-h`** (elevated svcclaude, so the file is svcclaude-owned) *or* have the script `icacls ... /grant *S-1-1-0:R`. Use `-s` only when the task truly needs SYSTEM (renaming `catroot2`/`SoftwareDistribution`, deleting `C:\Config.Msi\*`, reading `C:\$WINDOWS.~BT`).
- **`psexec ... cmd /c type file` truncates stdout** (often only the first line comes back). Don't read files through PsExec stdout — use the `net use` + `type` read above.
- **Rapid back-to-back SSH connections to the jump host get `Permission denied (publickey,password,keyboard-interactive)`** — a throttle, not a credential failure. Space connections out (a few seconds) and it recovers.

## Long-Running Remote Operations (detached + poll)

For anything long (DISM `/RestoreHealth`, `sfc`, `setup.exe /auto Upgrade`, `rd /s /q C:\Windows.old`, large downloads), **launch detached and poll a done-marker** — the operation then runs server-side and survives connection drops / local background-task reaping:
```bash
# launch (script ends by writing C:\Temp\<name>_done.txt)
psexec \\TARGET -u CPP-DB\svcclaude -p $PASS -s -d -accepteula powershell ... -EncodedCommand $ENC
# poll (spaced ~90-120s):
net use \\TARGET\C$ ... & if exist \\TARGET\C$\Temp\<name>_done.txt (type ...) else (echo NOTYET) & net use ... /delete
```
`-d` returns immediately with the PID; the process keeps running. Capture DISM's real exit code with `$r = & dism ... 2>&1; $ec = $LASTEXITCODE` — **not** `$LASTEXITCODE` after a `| Out-File` pipeline (that captures Out-File's code, always 0).
