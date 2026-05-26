# PRTG API Field Notes

## Connection

| Field | Value |
|-------|-------|
| Base URL | `https://prtg.themyersbriggs.com` |
| API root | `https://prtg.themyersbriggs.com/api/` |
| Token file | `~/GitHub/.tokens/prtg` (raw API token, one line) |
| PRTG version | 25.1.102.1373+ |

## Auth

Uses a PRTG API token (generated under My Account → API Keys). Pass as:

```
?apitoken=<TOKEN>
```

The token file contains the raw token string (no JSON wrapper):

```
<PRTG_API_TOKEN>
```

## Common curl Pattern

```bash
TOKEN=$(tr -d '[:space:]' < ~/GitHub/.tokens/prtg)
BASE="https://prtg.themyersbriggs.com/api"

curl -sk "${BASE}/table.json?content=sensors&output=json&apitoken=${TOKEN}"
```

## API Endpoints

### Listing / Status

| Endpoint | Purpose | Key params |
|----------|---------|-----------|
| `/api/table.json` | List objects (sensors, devices, groups, channels) | `content=sensors\|devices\|groups`, `columns=...` |
| `/api/getsensordetails.json` | Sensor detail + channels | `id=<sensorid>` |
| `/api/getobjectstatus.htm` | Object status (running, paused, etc.) | `id=<objid>` |
| `/api/getstatus.htm` | Probe/system status | — |
| `/api/historicdata.json` | Historical data for a channel | `id=<sensorid>`, `avg=0\|300\|3600`, `sdate`, `edate` |

### Actions

| Endpoint | Purpose | Key params |
|----------|---------|-----------|
| `/api/acknowledge.htm` | Acknowledge an alert | `id=<sensorid>`, `ackmsg=<msg>` |
| `/api/pause.htm` | Pause a sensor/device/group | `id=<objid>`, `action=0` (pause), `action=1` (resume) |
| `/api/pauseobjectfor.htm` | Pause for N minutes | `id=<objid>`, `pausemsg=<msg>`, `duration=<minutes>` |
| `/api/resume.htm` | Resume paused sensor | `id=<objid>` |
| `/api/simulate.htm` | Simulate error on sensor (testing) | `id=<sensorid>` |
| `/api/setobjectproperty.htm` | Set a property on any object | `id=<objid>`, `name=<prop>`, `value=<val>` |
| `/api/adddevice2.htm` | Add a device | `name`, `host`, `groupid` |

### Search / Lookup Examples

```bash
TOKEN=$(tr -d '[:space:]' < ~/GitHub/.tokens/prtg)
BASE="https://prtg.themyersbriggs.com/api"

# List all sensors with status
curl -sk "${BASE}/table.json?content=sensors&output=json&columns=objid,name,device,status,message,lastvalue&apitoken=${TOKEN}" | python3 -m json.tool

# Find sensors by name (substring match)
curl -sk "${BASE}/table.json?content=sensors&output=json&filter_name=@sub(<search_term>)&columns=objid,name,device,status&apitoken=${TOKEN}" | python3 -m json.tool

# List all devices in a group
curl -sk "${BASE}/table.json?content=devices&output=json&id=<groupid>&columns=objid,name,host,status&apitoken=${TOKEN}" | python3 -m json.tool

# Get specific sensor details
curl -sk "${BASE}/getsensordetails.json?id=<sensorid>&apitoken=${TOKEN}" | python3 -m json.tool
```

## Status Codes

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
| 14 | Down Acknowledged |

## Object ID Notes

- All PRTG objects (groups, devices, probes, sensors) have a numeric `objid`
- The root group is typically `0`
- To find an object's ID: navigate to it in the UI → the URL contains `id=<number>`
- Devices and sensors share the same ID namespace

## Columns for table.json

Common useful column sets:

- **Sensors:** `objid,name,device,group,status,message,lastvalue,lastcheck`
- **Devices:** `objid,name,host,group,status,message`
- **Groups:** `objid,name,totalsens,downsens,warnsens,pausedsens`

## Administration

### Add AD user to PRTG (UI)

**Setup (gear icon) → User Accounts → Add User**

1. Login Name: AD username (sAMAccountName, e.g. `jdoe`)
2. User Type: **Active Directory User**
3. Domain: `themyersbriggs.com` (or `cpp-db`)
4. Primary Group: assign appropriate PRTG group
5. Save — user authenticates with their domain password; no PRTG password is set

### Add AD group to PRTG (UI)

**Setup → User Groups → Add Group** → set type to Active Directory, enter group name.

## Gotchas

- Auth uses `apitoken=` parameter (not `username=`/`passhash=`)
- JSON responses are at `.json` endpoints; XML at `.xml` or `.htm` — prefer JSON
- `filter_name=@sub(text)` does substring match; `filter_name=exact` is exact match
- `action=0` on `/api/pause.htm` pauses; `action=1` resumes — counterintuitive
- Large table responses may need `count=2500` to avoid truncation (default is 500)
- HTTPS uses self-signed cert — always use `curl -sk`
- New API accounts may show `(Object not found)` for sensor counts until group permissions are scoped
