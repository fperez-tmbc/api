# ============================================================================
# WARNING: uses `svcclaude`, whose AD rights were DISMANTLED 2026-07-27.
# The account still EXISTS in cpp-db.com but has zero group memberships, zero
# delegated ACEs, and was removed from local Administrators on ~26 machines.
# It was DELETED outright in cpp-web.com, opp.local, oppashapp.local and
# oppnewapp.local. Its password was ROTATED 2026-07-27, so the value in
# ~/GitHub/.tokens/svcclaude is stale.
# => This script will fail as written.
# Use instead: WinRM as CPP-DB\2fperez, or a Key Vault domain-admin cred
#   (~/GitHub/.tokens/kv-get.sh <secret>; usernames are in the secrets' tags).
# STILL WORKING: the PAN-OS local account named svcclaude (key auth, verified
# 2026-08-02) and svcclaude's vCenter login - the account is retained for those two.
# See api/ssh/README.md.
# ============================================================================

# grant-dns-acl.ps1 - Grant svcclaude Full Control on all AD-integrated DNS zones
#
# Run once as a domain admin on any DC in the target domain.
# This lets svcclaude add, update, and delete DNS records via dnscmd without
# needing local admin access on the DC.
#
# Usage:
#   .\grant-dns-acl.ps1
#   .\grant-dns-acl.ps1 -WhatIf    # dry run - shows what would change

param([switch]$WhatIf)

# Derive domain info from the local machine
$domain    = (Get-ADDomain).DistinguishedName
$netbios   = (Get-ADDomain).NetBIOSName
$principal = "$netbios\svcclaude"
$rights    = [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
$type      = [System.Security.AccessControl.AccessControlType]::Allow
$inherit   = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All

$rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    [System.Security.Principal.NTAccount]$principal,
    $rights, $type, $inherit
)

Write-Host "Domain:    $domain"
Write-Host "Principal: $principal"
Write-Host ""

# DNS zones can live in any of these three AD partitions
$containers = @(
    "CN=MicrosoftDNS,DC=DomainDnsZones,$domain",
    "CN=MicrosoftDNS,DC=ForestDnsZones,$domain",
    "CN=MicrosoftDNS,CN=System,$domain"
)

$granted = 0
$failed  = 0

foreach ($container in $containers) {
    $zones = $null
    try {
        $zones = Get-ADObject -Filter { objectClass -eq "dnsZone" } `
                              -SearchBase $container `
                              -ErrorAction Stop
    } catch {
        Write-Host ("Skipping container " + $container + " - " + $_.Exception.Message) -ForegroundColor Yellow
        continue
    }

    foreach ($zone in $zones) {
        $adPath = "AD:" + $zone.DistinguishedName
        try {
            if ($WhatIf) {
                Write-Host ("[WhatIf] Would grant Full Control on: " + $zone.Name) -ForegroundColor Cyan
            } else {
                $acl = Get-Acl $adPath -ErrorAction Stop
                $acl.AddAccessRule($rule)
                Set-Acl -AclObject $acl $adPath
                Write-Host ("Granted: " + $zone.Name) -ForegroundColor Green
            }
            $granted++
        } catch {
            Write-Host ("Failed (" + $zone.Name + "): " + $_.Exception.Message) -ForegroundColor Red
            $failed++
        }
    }
}

Write-Host ""
if ($WhatIf) {
    Write-Host ($granted.ToString() + " zone(s) would be updated.")
} else {
    Write-Host ($granted.ToString() + " zone(s) updated, " + $failed.ToString() + " failed.")
}
