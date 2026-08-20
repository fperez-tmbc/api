# PRTG API Field Notes

## Connection

| Field | Value |
|-------|-------|
| Base URL | `https://prtg.themyersbriggs.com` |
| API root | `https://prtg.themyersbriggs.com/api/` |
| Token file | `~/GitHub/.tokens/prtg` (raw API token, one line) |
| PRTG version | 25.1.102.1373+ |

## Auth

API token generated under My Account → API Keys. Three ways to pass it:

```bash
# Query param (simple)
?apitoken=<TOKEN>

# Bearer header (preferred — keeps token out of URLs/logs)
-H "Authorization: Bearer <TOKEN>"

# Username + passhash (legacy)
?username=<user>&passhash=<hash>
```

No separate service account needed — the API token alone provides full access.

## Common curl Pattern

```bash
TOKEN=$(tr -d '[:space:]' < ~/GitHub/.tokens/prtg)
BASE="https://prtg.themyersbriggs.com/api"

# Read (query param)
curl -sk "${BASE}/table.json?content=sensors&output=json&apitoken=${TOKEN}"

# Action (Bearer header, checks HTTP status)
curl -sk -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "${BASE}/acknowledgealarm.htm?id=<id>&ackmsg=<msg>"
```

## HTTP Response Codes (action endpoints)

| Code | Meaning |
|------|---------|
| 200 | Success — data returned |
| 302 | Success — action performed (acknowledge, pause, etc.) |
| 400 | Bad request — check parameters |
| 401 | Unauthorized — bad token |

## API Endpoints

### Listing / Status

| Endpoint | Purpose | Key params |
|----------|---------|-----------|
| `/api/table.json` | List objects | `content=sensors\|devices\|groups\|channels`, `columns=...`, `count=`, `filter_status=` |
| `/api/getsensordetails.json` | Full sensor detail + channels | `id=<sensorid>` |
| `/api/getobjectstatus.htm` | Object status | `id=<objid>` |
| `/api/getstatus.htm` | Probe/system status | — |
| `/api/historicdata.json` | Channel history | `id=<sensorid>`, `avg=0\|300\|3600`, `sdate=YYYY-MM-DD-HH-MM-SS`, `edate=...` |

### Monitoring Control

| Endpoint | Purpose | Key params |
|----------|---------|-----------|
| `/api/acknowledgealarm.htm` | Acknowledge a Down alert | `id=<sensorid>`, `ackmsg=<msg>` |
| `/api/pause.htm` | Pause or resume | `id=<objid>`, `action=0` (pause indefinitely), `action=1` (resume), `pausemsg=<msg>` |
| `/api/pauseobjectfor.htm` | Pause for N minutes (auto-resumes) | `id=<objid>`, `duration=<minutes>`, `pausemsg=<msg>` |
| `/api/scannow.htm` | Force immediate scan | `id=<objid>` |
| `/api/simulate.htm` | Simulate sensor error | `id=<sensorid>`, `action=1` — only works on Up/Warning/Unusual/Unknown sensors |
| `/api/discovernow.htm` | Force auto-discovery | `id=<groupid\|deviceid>`, `template=<filename>` (optional) |

#### Maintenance-window suppression

Pause the **root group (`id=0`)** to suppress the whole tree — used by the `/patching` flow for every patch run.

```bash
TOKEN=$(tr -d '[:space:]' < ~/GitHub/.tokens/prtg)
BASE="https://prtg.themyersbriggs.com/api"
# Suppress (auto-resumes after duration — failsafe if the caller dies)
curl -sk -o /dev/null -w "%{http_code}\n" "${BASE}/pauseobjectfor.htm?id=0&duration=480&pausemsg=Patch%20window&apitoken=${TOKEN}"
# Resume early
curl -sk -o /dev/null -w "%{http_code}\n" "${BASE}/pause.htm?id=0&action=1&apitoken=${TOKEN}"
```

Prefer `pauseobjectfor.htm` over `pause.htm?action=0` for maintenance: an indefinite pause leaves monitoring dark forever if the automation dies. Children with their **own** user-pause keep it when the parent resumes; children that were only "paused by parent" come back. Snapshot the paused set before pausing and diff it after resuming to confirm.

### Object Management

| Endpoint | Purpose | Key params |
|----------|---------|-----------|
| `/api/setobjectproperty.htm` | Set any string/numeric property | `id=<objid>`, `name=<prop>`, `value=<val>`; for channels add `subtype=channel`, `subid=<channelid>` |
| `/api/rename.htm` | Rename an object | `id=<objid>`, `value=<newname>` |
| `/api/setpriority.htm` | Set priority | `id=<objid>`, `prio=1-5` |
| `/api/setposition.htm` | Reorder in tree | `id=<objid>`, `newpos=up\|down\|top\|bottom` |
| `/api/duplicateobject.htm` | Clone an object | `id=<objid>`, `name=<newname>`, `targetid=<parentid>`; devices also need `host=<ip>` — cloned objects start Paused, must resume |
| `/api/deleteobject.htm` | Permanently delete | `id=<objid>`, `approve=1` — irreversible, deletes all subobjects |
| `/api/adddevice2.htm` | Add a device | `name=`, `host=`, `groupid=` |
| `/api/setlonlat.htm` | Set geo location | `id=<objid>`, `location=<name>` or `lonlat=<lon,lat>` |

### Notifications & Reports

| Endpoint | Purpose | Key params |
|----------|---------|-----------|
| `/api/notificationtest.htm` | Trigger test notification | `id=<notification_template_id>` |
| `/api/reportaddsensor.htm` | Add object to report | `id=<reportid>`, `addid=<objid>` |

## Listing / Filter Examples

```bash
TOKEN=$(tr -d '[:space:]' < ~/GitHub/.tokens/prtg)
BASE="https://prtg.themyersbriggs.com/api"

# All down sensors (status 5)
curl -sk "${BASE}/table.json?content=sensors&output=json&filter_status=5&columns=objid,name,device,message&count=2500&apitoken=${TOKEN}" | python3 -m json.tool

# Down acknowledged (status 13 — NOT 14; see status table note)
curl -sk "${BASE}/table.json?content=sensors&output=json&filter_status=13&columns=objid,name,device&count=2500&apitoken=${TOKEN}" | python3 -m json.tool

# Find by name (substring)
curl -sk "${BASE}/table.json?content=sensors&output=json&filter_name=@sub(<term>)&columns=objid,name,device,status&apitoken=${TOKEN}" | python3 -m json.tool

# Devices in a group
curl -sk "${BASE}/table.json?content=devices&output=json&id=<groupid>&columns=objid,name,host,status&apitoken=${TOKEN}" | python3 -m json.tool
```

## Sensor Status Codes (filter_status values)

| Code | Meaning |
|------|---------|
| 1 | Unknown |
| 2 | Scanning |
| 3 | Up |
| 4 | Warning |
| 5 | Down |
| 6 | No Probe |
| 7 | Paused by User |
| 8 | Paused by Dependency |
| 9 | Paused by Schedule |
| 10 | Unusual |
| 11 | Not Licensed |
| 12 | Paused Until |
| 13 | **Down (Acknowledged)** — this is the acknowledged-down code (confirmed in 25.1.x) |
| 14 | Down (Partial) |

> ⚠️ **Acknowledged-down is status 13, not 14.** Earlier notes here had 14 mislabeled as "Down Acknowledged" — that's actually "Down (Partial)". When checking for outages, query **status 5 (Down) AND 13 (Down Acknowledged)**; an acknowledged-down server still shows nothing under `filter_status=5`. Safest is to pull all sensors and bucket by `status_raw` rather than trust a single filter.

## Columns for table.json

- **Sensors:** `objid,name,device,group,status,message,lastvalue,lastcheck`
- **Devices:** `objid,name,host,group,status,message`
- **Groups:** `objid,name,totalsens,downsens,warnsens,pausedsens`

## Object ID Notes

- All PRTG objects share a single numeric `objid` namespace
- Root group is `0`
- To find an ID: open the object in the UI — the URL contains `id=<number>`

## Administration

### Add AD users to PRTG (UI)

PRTG does not support adding individual AD users — access is group-based:

1. **Setup → System Administration → Core & Probes** — confirm your AD domain is set.
2. **Setup → User Groups → Add User Group:**
   - Set **Active Directory or Single Sign-On Integration** to "Use Active Directory integration"
   - Select the AD group from the dropdown
   - Set User Type (Read/write or Read-only)
   - Click Create
3. Users log in with Windows credentials — PRTG creates their local account automatically on first login.

## Diagnosing a stuck WMI sensor (PE015)

`Connection could not be established (code: PE015)` on a WMI sensor usually means the **probe** is wedged, not the target. Confirmed 2026-08-20 on SVSCRIBEPRDDC02 (`Memory 1` 31820, `Disk Free 1` 31821): both sat Down for 8 h while three other WMI sensors on the *same device* kept returning fresh values every 60 s. Two reboots of the target changed nothing; rebooting the PRTG server cleared it instantly.

Work the evidence in this order before touching anything:

1. **Is it really not collecting?** An acknowledged sensor keeps displaying the ack text, so the message tells you nothing. Check `content=channels` (`lastvalue` = `No data`) and `historicdata.json` for the window. Blank channels across every scan is the real signal.
2. **Scope it.** Pull all sensors and bucket by `status_raw`. If PE015 appears on only one or two objects while dozens of WMI sensors on the same probe are Up, credentials and the probe's WMI stack as a whole are fine.
3. **Same-device control.** `getsensordetails.json` gives `sensortype`. `wmimemory` / `wmidiskspace` failing while `wmiprocessor` / `wmiphysicaldiskv2` on the same device succeed does **not** mean a data-source split: check `getobjectproperty.htm?name=wmiorpc`. If it returns `WMI only (default)` then every one of those sensors is on WMI, so a working neighbour proves the target's WMI is healthy.
4. **Reproduce from the probe host as the PRTG account.** This is the step that settles it. Read the account from `getobjectproperty.htm?name=windowsloginusername` (empty means inherited from the parent group), then run the sensor's own classes over DCOM *from the probe*, not from your workstation:

```powershell
$cred = New-Object System.Management.Automation.PSCredential('CPP-DB
tsupport',(ConvertTo-SecureString $pw -AsPlainText -Force))
Invoke-Command -ComputerName SVMONDC02.cpp-db.com -Credential $cred -ScriptBlock {
  param($c)
  $s = New-CimSession -ComputerName 'target.cpp-db.com' -Credential $c -SessionOption (New-CimSessionOption -Protocol Dcom)
  'Win32_PerfRawData_PerfOS_Memory','Win32_OperatingSystem','Win32_LogicalDisk' | ForEach-Object {
    "{0} = {1}" -f $_, @(Get-CimInstance -CimSession $s -ClassName $_).Count }
} -ArgumentList $cred
```

Use `-Protocol Dcom`; plain `Get-CimInstance -ComputerName` goes over WSMan and tests the wrong path. Pass the credential into the scriptblock explicitly so the remote-to-remote hop does not need delegation. Classes: `wmimemory` -> `Win32_PerfRawData_PerfOS_Memory` + `Win32_OperatingSystem`; `wmidiskspace` -> `Win32_LogicalDisk` / `Win32_Volume`; `wmiprocessor` -> `Win32_PerfRawData_PerfOS_Processor`.

If step 4 returns data, the target is healthy and the fix is probe-side. Escalate: `scannow` -> pause/resume the sensor -> restart `PRTGProbeService` -> reboot the probe host.

**Corroborating checks on the target** (all were clean in the 2026-08-20 case, which is what ruled the server out): no 4625 failed logons, no `Microsoft-Windows-WMI-Activity/Operational` 5858 errors whose `ClientMachine` is the probe, and one successful 4624 type-3 logon from the probe IP (DCOM keeps the session alive, so one logon covers many polls; a low count is normal, not a symptom).

**SVMONDC02 is the PRTG core server, not a remote probe.** "Local Probe (SVMONDC02)" is the core's own probe. It runs `PRTGAppServer`, `PRTGCoreService`, and `PRTGProbeService`, so rebooting it takes all sensors, alerting, and the web UI down. Restarting `PRTGProbeService` alone is the contained version and fixes the same wedge. Reboot is ~1 min of downtime; sensors then trickle back over ~5 min and briefly report status `None` with `lastvalue` `-` (SNMP traffic sensors need two samples for a delta). Snapshot `table.json` before and diff after: sensor count and the paused set should both come back identical.

**A recovered sensor may return as Warning, not Up.** Check the channel limits before assuming the fix failed.

## Gotchas

- **Bearer header fails with 401 on action endpoints** (confirmed on `pauseobjectfor.htm`, 25.1.102.1373) even though the same token works fine as `apitoken=` on `table.json`. Use the `apitoken=` query param for actions; treat the "Bearer preferred" note above as read-only guidance.
- Action endpoints usually return **302** on success (not 200) — but `pauseobjectfor.htm` returns **200**. Accept either; verify the resulting object state rather than trusting the code alone.
- `acknowledge.htm` does NOT exist — the correct endpoint is `acknowledgealarm.htm`
- `action=0` on `pause.htm` pauses; `action=1` resumes — counterintuitive
- `simulate.htm` requires `action=1` and only works on Up/Warning/Unusual/Unknown sensors
- `duplicateobject.htm` always creates clones in Paused state — must call `pause.htm?action=1` after
- `deleteobject.htm` requires `approve=1` and is irreversible
- `count` defaults to 500 — use `count=2500` for large environments
- `filter_name=@sub(text)` does substring match; omit `@sub()` for exact match
- `getstatus.htm` returns `(Object not found)` for some fields with API token auth — use `table.json` instead
- HTTPS uses self-signed cert — always `curl -sk`
- Rate limit on historic data: 5 requests/minute
- Raw sensor data retained for up to 40 days; historic reports limited to 500-day range
