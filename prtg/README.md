# PRTG API Field Notes

## Connection

| Field | Value |
|-------|-------|
| Base URL | `https://prtg.themyersbriggs.com` |
| API root | `https://prtg.themyersbriggs.com/api/` |
| Credentials file | `~/GitHub/.tokens/prtg` (JSON — see below) |

## Credentials File Format

Store at `~/GitHub/.tokens/prtg`:

```json
{
  "username": "svcclaude",
  "passhash": "<PRTG_PASSHASH>"
}
```

**Get the passhash:** Log into PRTG as the user → My Account → passhash is shown there. It's a 10-digit number. Alternatively use `password=` instead of `passhash=` for plain-text auth (less preferred).

## Auth Parameters

All API calls require auth appended as query params:

```
?username=svcclaude&passhash=<PASSHASH>
```

Or with password (development only):

```
?username=svcclaude&password=<PASSWORD>
```

## Common curl Pattern

```bash
PRTG_CREDS=$(cat ~/GitHub/.tokens/prtg)
PRTG_USER=$(echo "$PRTG_CREDS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['username'])")
PRTG_HASH=$(echo "$PRTG_CREDS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['passhash'])")
BASE="https://prtg.themyersbriggs.com/api"

curl -sk "${BASE}/table.json?content=sensors&output=json&username=${PRTG_USER}&passhash=${PRTG_HASH}"
```

## API Endpoints

### Listing / Status

| Endpoint | Purpose | Key params |
|----------|---------|-----------|
| `/api/table.json` | List objects (sensors, devices, groups, channels) | `content=sensors\|devices\|groups`, `columns=...` |
| `/api/getsensordetails.json` | Sensor detail + channels | `id=<sensorid>` |
| `/api/getobjectstatus.htm` | Object status (running, paused, etc.) | `id=<objid>` |
| `/api/getstatus.htm` | Probe connection status | — |
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

### Search / Lookup

```bash
# List all sensors with status
curl -sk "${BASE}/table.json?content=sensors&output=json&columns=objid,name,status,message,lastvalue&username=${PRTG_USER}&passhash=${PRTG_HASH}" | python3 -m json.tool

# Find sensors by name (filter)
curl -sk "${BASE}/table.json?content=sensors&output=json&filter_name=@sub(<search_term>)&columns=objid,name,device,status&username=${PRTG_USER}&passhash=${PRTG_HASH}" | python3 -m json.tool

# List all devices in a group
curl -sk "${BASE}/table.json?content=devices&output=json&id=<groupid>&columns=objid,name,host,status&username=${PRTG_USER}&passhash=${PRTG_HASH}" | python3 -m json.tool

# Get specific sensor details
curl -sk "${BASE}/getsensordetails.json?id=<sensorid>&username=${PRTG_USER}&passhash=${PRTG_HASH}" | python3 -m json.tool
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

## Gotchas

- `passhash` is a 10-digit integer, not a password hash — it's PRTG's internal token
- JSON responses are at `.json` endpoints; XML at `.xml` or `.htm` — prefer JSON
- `filter_name=@sub(text)` does substring match; `filter_name=exact` is exact match
- `action=0` on `/api/pause.htm` pauses; `action=1` resumes — this is counterintuitive
- Large table responses may need `count=2500` to avoid truncation (default is 500)
- HTTPS with self-signed cert is likely — use `curl -sk`
