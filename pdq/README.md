# PDQ Deploy & Inventory — Lessons Learned

## Connection

- **Server:** `SVPDQHQ01.cpp-db.com`
- **SSH user:** `claude`
- **Credentials:** `~/GitHub/.tokens/patching` — source this file; use `$PDQ_PASS`

```bash
source ~/GitHub/.tokens/patching
SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "claude@SVPDQHQ01.cpp-db.com" "<command>"
```

---

## Windows paths on SVPDQHQ01

| Variable | Path |
|---|---|
| PDQ Deploy EXE | `C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe` |
| PDQ Deploy DB | `C:\ProgramData\Admin Arsenal\PDQ Deploy\Database.db` |
| PDQ Inventory DB | `C:\ProgramData\Admin Arsenal\PDQ Inventory\Database.db` |
| sqlite3.exe | `C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\sqlite3.exe` |

---

## Querying PDQ Inventory via SQLite

Run sqlite3 queries over SSH using cmd.exe:

```bash
PDQ_INV_DB='C:\ProgramData\Admin Arsenal\PDQ Inventory\Database.db'
PDQ_SQLITE='"C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\sqlite3.exe"'

SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "claude@SVPDQHQ01.cpp-db.com" \
    "$PDQ_SQLITE \"$PDQ_INV_DB\" \"<SQL query>\""
```

### Key tables — PDQ Inventory

| Table | Key columns |
|---|---|
| `Computers` | `ComputerId`, `Name`, `NeedsReboot`, `SuccessfulScanDate` |
| `Collections` | `CollectionId`, `Name` |
| `CollectionComputers` | `ComputerId`, `CollectionId` |

Use `SELECT DISTINCT` on collection membership queries — machines can belong to multiple sub-collections.

### List members of a collection

```sql
SELECT DISTINCT c.Name
FROM Computers c
JOIN CollectionComputers cc ON c.ComputerId = cc.ComputerId
JOIN Collections col ON cc.CollectionId = col.CollectionId
WHERE col.Name = 'Intune Management Extension'
ORDER BY c.Name
```

### Query pending reboots in a collection

```sql
SELECT DISTINCT c.Name
FROM Computers c
JOIN CollectionComputers cc ON c.ComputerId = cc.ComputerId
JOIN Collections col ON cc.CollectionId = col.CollectionId
WHERE col.Name = 'PROD' AND c.NeedsReboot = 1
```

### Key tables — PDQ Deploy

| Table | Key columns |
|---|---|
| `Deployments` | `DeploymentId`, `Status` (`Running`/`Finished`), `Started`, `Finished` |
| `DeploymentComputers` | `DeploymentId`, `Name`, `Status` (`Running`/`Successful`/`Failed`), `Error` |

---

## Collections

| Name | Description |
|---|---|
| `PROD` | Production servers — F5 downtime required before patching |
| `DEV/QA/VDI` | Dev, QA, and VDI machines |
| `Backup` | Backup infrastructure |
| `Intune Management Extension` | Windows endpoints where IME is installed and reporting |

---

## Deploying a package via PDQ Deploy CLI

```bash
PDQ_DEPLOY='"C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\PDQDeploy.exe"'

SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "claude@SVPDQHQ01.cpp-db.com" \
    "$PDQ_DEPLOY Deploy -Package \"Package Name\" -Targets MACHINE01 MACHINE02 -UseScanUserCredentials"
```

### Gotchas

**PDQ Deploy CLI has no `-Collection` flag.** Resolve collection members via SQLite and pass machine names individually via `-Targets`.

**PDQ Deploy CLI returns exit 0 even on package-not-found errors.** Always check output text for `not found`, `error`, or `failed` in addition to the exit code.

**PDQ Deploy CLI is asynchronous.** The command returns immediately after queuing the job. Poll `Deployments.Status` in the Deploy DB until `Finished`.

---

## Running PowerShell on SVPDQHQ01 via SSH

Pass scripts base64-encoded (`-EncodedCommand`) to avoid shell quoting issues:

```bash
encoded=$(printf '%s' "$ps_script" | iconv -t UTF-16LE | base64 | tr -d '\n')
SSHPASS="$PDQ_PASS" sshpass -e ssh -n -q \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "claude@SVPDQHQ01.cpp-db.com" \
    "powershell -NonInteractive -NoProfile -EncodedCommand ${encoded}"
```

Always include `$ProgressPreference = 'SilentlyContinue'` at the top of the script — PowerShell emits CLIXML/progress noise over non-interactive SSH sessions without it.

---

## Related

- Monthly patching automation: `/Users/fperez2nd/GitHub/patching/`
- Patching README: `/Users/fperez2nd/GitHub/patching/README.md`
