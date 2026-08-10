# Microsoft Defender for Identity — audit configuration (cpp-db.com)

Written 2026-08-09 after resolving the recurring health alert
*"Directory Services Advanced Auditing is not enabled on svdcdc01.cpp-db.com"*.

The alert had been arriving since at least 2026-04-29 (also 05-19, 08-07) to
`netops@themyersbriggs.com` from `defender-noreply@microsoft.com`.

---

## The single most important fact: these are v3.x sensors

There is **no standalone MDI sensor** on any domain controller here. No `AATPSensor`
service, no sensor product in Add/Remove Programs. MDI runs as part of the **Defender for
Endpoint agent** (`Sense`), which is the v3.x delivery model.

Verify with:

```powershell
Get-Service Sense
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' -Name OnboardingState
# Sense Running + OnboardingState 1, and no AATP* service = v3.x sensor
```

Everything below follows from that.

### v3.x does not use a Directory Service Account

Microsoft's documentation is explicit:

> The sensor v3.x uses LocalSystem for all AD interactions and **doesn't require a gMSA or
> any other Directory Service Account**. LocalSystem is the only supported identity for v3.x.

**Do not create a DSA/gMSA for MDI here.** It is not merely unnecessary — the docs warn that
a workspace-level DSA gets credential-validated against *every* sensor including v3.x, and a
failure raises the recurring *"Directory services user credentials are incorrect"* health
alert. Creating one trades one alert for another.

Checked 2026-08-09: no MDI DSA exists in cpp-db.com. The only gMSAs are SQL and provisioning
accounts (`svc_sql*`, `svc_devgateway`, `provAgentgMSA`). `SVAZADSYNCDC01` runs Entra Connect
(`ADSync`) but has **no v2 sensor** — it is covered by the v3 sensor on MDE.

---

## Applying the configuration

Use Microsoft's own module rather than hand-editing `GptTmpl.inf`. It creates and links the
GPOs properly.

```powershell
Import-Module DefenderForIdentity
Get-MDIConfiguration -Mode Domain -Identity 'cpp-db.com' -Configuration All   # read-only
Set-MDIConfiguration -Mode Domain -Configuration <item> -Force
```

**Run each configuration item individually, not `-Configuration All`.** A single failing item
aborts the whole batch; run them one at a time and a failure only costs you that item.

### `-Identity` does not mean what the error suggests

```
Set-MDIConfiguration -Mode Domain -Configuration All
FAILED: Cannot process command because of one or more missing mandatory parameters: Identity.
```

`-Identity` is **the name of the DSA service account**, required only by `EntraConnectAuditing`
and `RemoteSAM`. It is *not* a domain name. On a v3.x-only deployment there is no DSA, so those
items cannot run and **should not** be made to run.

`Get-MDIConfiguration` also needs `-Identity <domain>` in Domain mode — confusingly, a different
meaning for the same parameter name.

Do not chase this by updating the module. The parameter behaves identically in 1.0.0.4 and
1.0.0.5; the version was never the problem.

---

## State after configuration (2026-08-09)

| Configuration | Status | Note |
|---|---|---|
| `AdvancedAuditPolicyDCs` | **True** | this was the alert |
| `DomainObjectAuditing` | True | |
| `NTLMAuditing` | True | |
| `ConfigurationContainerAuditing` | True | already set |
| `AdfsAuditing` | True | already set |
| `AdRecycleBin` | True | already set |
| `ProcessorPerformance` | True | |
| `CAAuditing` | True | |
| `AdvancedAuditPolicyCAs` | True | |
| `RemoteSAM` | n/a | v2-only, needs DSA |
| `DeletedObjectsContainerPermission` | n/a | grants DSA access |
| `EntraConnectAuditing` | n/a | v2 sensor on Entra Connect only |
| `KdsAuditing` | n/a | surfaced by module 1.0.0.5 |

The four `n/a` items report `False` because `Get-MDIConfiguration` evaluates against the v2
model regardless of deployed sensor version. That is a reporting artefact, not a gap.

### GPOs created

```
Microsoft Defender for Identity - Advanced Audit Policy for DCs
Microsoft Defender for Identity - NTLM Auditing for DCs
Microsoft Defender for Identity - Processor Performance
Microsoft Defender for Identity - Auditing for CAs
Microsoft Defender for Identity - Advanced Audit Policy for CAs
```

The pre-change audit subcategory state was `Directory Service Changes: No Auditing`, which is
what MDI needs at `Success` (event 5136).

---

## Netwrix Auditor coexistence

Netwrix Auditor for AD auto-configures its own audit settings on the DCs. It does **not** use a
GPO — there is no Netwrix GPO in cpp-db.com. Agents on the DC:

```
adcrsvc     Netwrix Auditor for AD Compression Service      (Stopped)
NwxExeSvc   Netwrix Auditor Application Deployment Service  (Running)
```

**They coexist.** Both products want the same audit subcategories at `Success`, and both add
audit ACEs to the domain root SACL rather than replacing them.

Before the change the domain root had **6** audit ACEs, all `Everyone`, scoped to: all objects,
user, group, computer, `msDS-ManagedServiceAccount`, `msDS-GroupManagedServiceAccount` — which
is exactly the set MDI asks for. After `Set-MDIConfiguration` it was **7**. Nothing removed.

The one behavioural change: audit subcategories are now asserted by **GPO**, which outranks
Netwrix's local auto-configuration. Values agree, so collection is unaffected — and GPO-backed
settings survive reboots and rebuilds, which local auto-config does not.

**Cannot be verified from the DC side:** whether Netwrix is still collecting. That check is in
the Netwrix console.

### Backups

Taken before the change on both DCs, at `C:\Windows\Temp\mdi-backup\`:

```
auditpol-<host>-<stamp>.csv     # auditpol /backup, restore with auditpol /restore
domain-sacl-<stamp>.sddl        # domain root SACL, SDDL form
domain-sacl-<stamp>.csv         # human-readable ACE list
```

The GPOs themselves cannot be un-created by the module — removing them is a manual step if the
change needs backing out.

---

## If the health alert persists

Documented known issue: with manual or GPO-based configuration, MDI health alerts about Windows
event auditing **can persist even when auditing is correct**. Detections are unaffected.

The documented resolution is to enable **Automatic Windows auditing configuration**
(Defender portal → Settings → Identities → Advanced features). The sensor then checks and
applies auditing itself every 24 hours.

Note the docs' caveat: *"GPO settings can conflict with local settings set by the sensor."*
Pick one approach. Having applied the GPO route here, only switch to automatic if the alert
does not clear.

---

## Traps encountered

**Read the cmdlet reference before theorising.** The `Identity` error was diagnosed twice by
guesswork (first as a Kerberos double-hop, then as a module bug) and a module was installed on a
DC for no reason. One `microsoft_docs_fetch` on the `Set-MDIConfiguration` page answered it
outright.

**The double-hop theory was wrong here.** Unlike the SYSVOL scan in
`service-logon-right-and-mde.md`, the nested session on the DC could read AD, reach SYSVOL and
enumerate 91 GPOs. Test the hypothesis before acting on it.

**An alert naming one host may apply to several.** The alert named `svdcdc01`, but
`Directory Service Changes` was off on `SVDCMK01` too. MDI reports per sensor.

Related: `service-logon-right-and-mde.md`, `arc-enabled-avs.md`.
