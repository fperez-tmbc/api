# `SeServiceLogonRight` and the Defender / Arc agent failures

Written 2026-08-09 after a long incident that started as "Arc agents are disconnected" and
ended up spanning four AD forests, Group Policy, Defender for Endpoint and the MDE sensor.

Two independent root causes, and they look identical from Azure. Diagnose which one you have
before touching anything.

---

## Fault A — `himds` will not start: the service logon right was stripped

**Symptom.** Azure shows the machine `Disconnected` or `Expired`. On the box, `himds` is
`Stopped` with `StartType: Automatic`, and starting it fails:

```
[SC] StartService FAILED 1069: The service did not start due to a logon failure.

Event 7041: The himds service was unable to log on as NT SERVICE\himds ...
  "This service account does not have the required user right 'Log on as a service.'"
```

**Cause.** A GPO defines `SeServiceLogonRight` without `*S-1-5-80-0`
(`NT SERVICE\ALL SERVICES`). User Rights Assignment **replaces** the list, it does not append,
so every virtual service account is stripped — `himds` among them.

**Why it appears at random times.** The right is only evaluated when a service *starts*.
A machine keeps running fine until its next reboot, then loses the service. Machines therefore
break on staggered dates matching their individual reboots, which disguises a single policy
fault as many unrelated ones.

**This is not Arc-specific.** It affects *every* service running as a virtual or built-in
account. Arc is simply the one that reports home to Azure, so it is the one you notice.

### Fixing it

Add `*S-1-5-80-0` to the **front** of the existing value in every GPO that defines the right —
preserve what is already there:

```
SeServiceLogonRight = *S-1-5-80-0,<existing entries unchanged>
```

Three parts, all required:

1. Edit `GptTmpl.inf` under
   `<policy>\Machine\Microsoft\Windows NT\SecEdit\` — **preserve the file encoding**
   (these are UTF-16LE with BOM; writing ASCII silently corrupts them)
2. Bump the computer version in `GPT.INI`
   (`Version = (UserVersion * 65536) + ComputerVersion`, increment the computer half)
3. Bump `versionNumber` on the GPO's AD object to match

**Step 3 is the one that bites.** Setting `versionNumber` via ADSI
(`$de.Put(); $de.SetInfo()`) **silently fails** — no error, value unchanged. Clients compare
the AD version to decide whether to reapply, so without it the SYSVOL edit is simply ignored.
Use `ldapmodify` and verify the read-back.

### Machines with no governing GPO

Some machines have the right set in **local** policy with no GPO defining it. `secedit
/configure` fixes them, but **it does not hold** — the Security CSE reapplies and reverts it
within hours. If a domain looks like it has no GPO defining the right, be suspicious of the
scan before concluding the policy is local-only (see the double-hop trap below).

---

## Fault B — the MDE sensor is too old to start

**Symptom.** Arc is fine, but the `MDE.Windows` extension fails with
`Onboarding script failed with error code 15`. On the box, `Sense` will not start:

```
[SC] StartService FAILED 1053: The service did not respond in a timely fashion
```

and `Microsoft-Windows-SENSE/Operational` is **completely empty** — it dies before it can log.

**Decode error 15 from the onboarding script itself**, which sets its own codes:

| Code | Meaning |
|---|---|
| 5 | (see script) |
| 10 | (see script) |
| **15** | **Unable to start Microsoft Defender for Endpoint Service** |
| 35, 40 | (see script) |
| 65 | insufficient privileges |

So error 15 is a *symptom* — the onboarding config is written fine, then it waits for `Sense`,
which never starts.

**Cause.** The MDE unified agent for downlevel servers is stale. The MDE Client Analyzer names
it directly:

```
[Error] OldVersionDetected 122038:
  Device is running with an old version of the Microsoft Defender for Endpoint EDR sensor.
```

**Why it cannot self-heal.** EDR sensor updates are delivered through the MDE service to
*onboarded* machines. An unonboarded machine never receives one, and it cannot onboard until
the sensor works. Windows Update does not offer it either.

### Fixing it — the MSI refuses to upgrade

```
Microsoft Defender for Endpoint has been updated since initial installation and MSI upgrades
are not supported in this case. Apply further update packages or uninstall before attempting
to install.
MainEngineThread is returning 1603
```

This is by design when the installed product has been serviced past its MSI baseline. The only
route is **uninstall, then install**:

```powershell
msiexec /x <ProductCode> /quiet /norestart      # exit 0
msiexec /i md4ws.msi /quiet /norestart          # exit 0
# then run the local onboarding script
```

`md4ws.msi` comes from the Defender portal: Settings → Endpoints → Onboarding → **Windows
Server 2012 R2 and 2016** → *Download installation package* (~238 MB). The *onboarding* package
is a separate, smaller download and its script is **byte-identical** to the Windows 10/11 one.

**Risk worth stating before you do it:** on Server 2012 R2 the unified agent supplies both AV
and EDR, so between uninstall and install the machine has **no antivirus**. Snapshot first.

**Expect the sensor version to go backwards** (e.g. 10.8800 → 10.8775). That is correct — you
are returning to the MSI baseline from a serviced state. It updates forward again once onboarded.

---

## The onboarding script loops forever unattended

`WindowsDefenderATPLocalOnboardingScript.cmd` prompts:

```
:USER_CONSENT
set /p shouldContinue= "Press (Y) to confirm and continue or (N) to cancel and exit: "
...
GOTO USER_CONSENT     <-- infinite loop when stdin is EOF
```

With no console, `set /p` gets nothing, the value stays empty, and it loops **forever** burning
CPU. Piping `echo Y|` is unreliable through nested remoting. Patch a copy instead:

```
set shouldContinue=Y          # replaces the set /p line
rem pause removed             # the trailing `pause` also blocks
```

Leaves the onboarding blob untouched. Run the patched copy, and always bound it with a job
timeout so a hang cannot run unattended.

**"Error 15" after a successful reinstall may be a false alarm** — the script's wait can expire
while `Sense` is still starting. Check `OnboardingState` and the service afterwards rather than
trusting the exit code.

---

## Traps that produced wrong answers

**Kerberos double-hop silently returns empty.** A SYSVOL scan run inside
`Mac → jumpbox → target` is a third hop with no delegated credentials. `Test-Path
\\domain\SysVol` returns **False** and a scan loop reports **zero policies** — indistinguishable
from "this domain has no GPOs defining the right." It caused a completely wrong conclusion here.
Scan from the jumpbox with an explicit credential instead:

```powershell
New-PSDrive -Name SV -PSProvider FileSystem -Root '\\<dc-fqdn>\SysVol' -Credential $cred
```

Use the **DC FQDN**, not `\\domain\SysVol` — the DFS root does not resolve cross-domain.

**Always assert the scan worked before trusting an empty result.** Print the policy count and
`Test-Path` on the root. Zero findings and zero visibility look the same.

**Azure Resource Graph lags ARM by minutes.** After any state change, read the resource
directly (`az resource show`). Resource Graph reported `Disconnected` for a machine that ARM
and the agent both showed as `Connected`.

**`UserDirectory.RetrieveUserGroups()` via `Get-View` lies.** Called as `cloudadmin` it returns
empty for *every* principal including known-good ones. Use
`New-VIPermission -WhatIf -Principal "<DOMAIN>\<name>"` — it gives a specific
`Could not find VIAccount` on failure.

**PRTG/Defender "healthy" is not proof.** A machine can show `MDE.Windows: Succeeded` in Azure
while the sensor is not reporting, and `Onboarded` in Defender while the Arc extension is
absent. Check the layer you actually care about.

**zsh does not word-split unquoted variables.** `for e in "NAME IP"; do set -- $e` leaves `$1`
holding the whole string and `$2` empty — a health check then runs against an empty host and
reports everything as down. Same family as the reserved-variable traps in `CLAUDE.md`.

**`himds` is `Automatic (Delayed)`.** After a reboot it takes ~60s to appear. Poll before
declaring a failure.

---

## State as of 2026-08-09

Four forests audited and corrected — **0 GPOs missing `S-1-5-80-0`, 0 defined-but-empty**:

| Domain | GPOs defining the right | Fixed |
|---|---|---|
| cpp-db.com | 6 | 3 |
| oppashapp.local | 17 | 15 |
| oppnewapp.local | 28 | 24 |
| opp.local | 29 | 28 |

Five defined-but-empty entries were **removed** rather than populated (an empty value grants the
right to nobody). Four were archived and unlinked; one, `Test Web Servers OU GPO` in
oppnewapp.local, was live and linked.

Verified persistent across a full reboot of all nine Arc-managed `opp.local` servers, including
both domain controllers: right present from GPO, `himds` starting unassisted.

Backups of every edited `GptTmpl.inf` and `GPT.INI` are on SVPDQHQ01 under
`C:\Windows\Temp\gpo-backup\` and `C:\Windows\Temp\gpo-backup-opp\`.

Related: `arc-enabled-avs.md`, `avs-identity-source.md`.
