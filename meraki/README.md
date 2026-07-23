# Cisco Meraki Dashboard API — field notes

## Access
- **API key:** `~/GitHub/.tokens/meraki` (read + strip whitespace). Generated in the Meraki dashboard → profile → API access.
- **Base URL:** `https://api.meraki.com/api/v1`
- **Auth header:** `X-Cisco-Meraki-API-Key: <key>` — **NOT** `Authorization: Bearer` (Bearer returns `401 "No valid authentication method found"` on this org).
- Always send `-L` (follow redirects; v1 can bounce to a regional shard) and `Accept: application/json`.
- Rate limit: 5 req/sec per org.

```bash
KEY=$(tr -d '[:space:]' < ~/GitHub/.tokens/meraki)
curl -sL -H "X-Cisco-Meraki-API-Key: $KEY" -H "Accept: application/json" \
  "https://api.meraki.com/api/v1/organizations"
```

## Org / inventory (verified 2026-07-21)
- **Org:** `The Myers-Briggs Company` — id **259523** (shard n97, region NA, customer # 26914468).
- **Networks (5):** `TMBC-UKWH` (L_617556098903186085, wireless), `TMBC-PA` (L_617556098903186363, switch+wireless), `TMBC-WH` (L_617556098903186509, switch+wireless), `TMBC-AP` (L_617556098903186878, switch+wireless — **AU/Asia-Pacific**), `TMBC-FR` (N_617556098903186981, wireless).
- **No MX appliances** anywhere — client DHCP/DNS/VLAN routing is done by the PAN firewalls, not Meraki. Meraki here = switches (MS225, L2) + APs (MR57) only.
- Wireless: SSIDs `TheMBC 5G` / `TheMBC 2.4G`, WPA2-Enterprise → **RADIUS `10.70.16.128`** (central NPS) fleet-wide.

## Useful endpoints
| What | Path |
|---|---|
| Orgs | `/organizations` |
| Networks | `/organizations/{orgId}/networks` |
| Devices in a network | `/networks/{netId}/devices` |
| Wireless SSIDs (RADIUS, auth) | `/networks/{netId}/wireless/ssids` |
| Syslog servers | `/networks/{netId}/syslogServers` |
| Switch L3 interfaces | `/devices/{serial}/switch/routing/interfaces` (400 if switch is L2-only) |
| Switch L3 interface DHCP | `/devices/{serial}/switch/routing/interfaces/{id}/dhcp` |
| **Device mgmt interface (static IP/DNS)** | `GET/PUT /devices/{serial}/managementInterface` → `wan1/wan2.staticDns` |
| Device online status | `/organizations/{orgId}/devices/statuses` |
| Org SNMP | `/organizations/{orgId}/snmp` |

## Notes
- MS switch `routing/interfaces` returns **HTTP 400** when the switch has no L3 routing configured — that means L2-only, not an error to fix.
- To find all references to an IP/host, sweep per-network SSIDs + syslog + (switch) L3 DHCP **AND every device's `managementInterface.wan1/wan2.staticDns`** — statically-configured switches/APs point their *own* resolver there, which none of the network-level endpoints reveal. (Learned the hard way on the SVDCAU01 decomm: the first sweep missed 4 AU MS225 switches whose `staticDns` = the DC being retired; they only surfaced in the DC's DNS query log.) There is no single "get full config" endpoint.
- Changing a device's static DNS: **GET the full `wan1`, change only `staticDns`, PUT `{wan1: ...}` back** (preserve `staticIp`/gateway/mask/vlan byte-for-byte — a blind PUT can wipe the static IP). DNS is management-plane only; switching/routing is unaffected. Verify online status before/after via `/organizations/{orgId}/devices/statuses`.
