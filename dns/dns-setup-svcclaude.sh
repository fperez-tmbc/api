#!/usr/bin/env zsh
# ============================================================================
# RETIRED 2026-08-06 — DO NOT RUN. Kept for historical reference only.
#
# This script's entire purpose was to DELEGATE DNS rights to `svcclaude`. Those
# rights were deliberately torn down on 2026-07-27: every delegated ACE removed
# from all five domain roots, group memberships stripped in cpp-db.com, and the
# account DELETED outright in cpp-web.com / opp.local / oppashapp.local /
# oppnewapp.local. Running this would UNDO that teardown and re-create a
# privileged path that was removed on purpose. It would also fail partway: the
# account no longer exists in four of the five domains.
#
# svcclaude is retained for PAN-OS and vCenter ONLY.
#
# There is nothing to replace this with: DNS work now authenticates as the
# target domain's Domain Admin from Azure Key Vault, which already holds the
# rights this script used to grant. No delegation step is needed.
# See api/dns/README.md and api/ssh/README.md.
# ============================================================================

# dns-setup-svcclaude.sh — Grant svcclaude DNS management rights on remote domains
#
# For each target domain, this script:
#   1. Adds svcclaude to the DnsAdmins group
#   2. Grants svcclaude Full Control on all AD-integrated DNS zones
#
# Run as a domain admin account that has rights in each target domain.
# Requires: sshpass (brew install hudochenkov/sshpass/sshpass)

set -o pipefail

if ! command -v sshpass &>/dev/null; then
  echo "ERROR: sshpass is required. Install with: brew install hudochenkov/sshpass/sshpass" >&2
  exit 1
fi

# Prompt once
print -n "SAM account name: "
read DOMAIN_ADMIN_USER
print -n "Password: "
read -s PASSWORD
echo
export SSHPASS="$PASSWORD"

# domain -> primary DC IP
typeset -A TARGETS
TARGETS=(
  "cpp-web.com"      "10.70.48.191"
  "opp.local"        "10.30.16.20"
  "oppashapp.local"  "192.168.207.1"
  "oppnewapp.local"  "192.168.212.1"
)

# Inline PowerShell — derives NetBIOS name and DN dynamically so it works on any domain
PS_SCRIPT='
$domain    = Get-ADDomain
$netbios   = $domain.NetBIOSName
$dn        = $domain.DistinguishedName
$principal = "$netbios\svcclaude"

Write-Host "Domain:    $($domain.DNSRoot)"
Write-Host "Principal: $principal"
Write-Host ""

# Add svcclaude to DnsAdmins
try {
    Add-ADGroupMember -Identity "DnsAdmins" -Members "svcclaude" -ErrorAction Stop
    Write-Host "[OK] Added svcclaude to DnsAdmins" -ForegroundColor Green
} catch {
    if ($_.Exception.Message -match "already a member") {
        Write-Host "[OK] svcclaude already in DnsAdmins" -ForegroundColor Cyan
    } else {
        Write-Host "[FAIL] DnsAdmins: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Grant Full Control on all AD-integrated DNS zone objects
$rights  = [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
$type    = [System.Security.AccessControl.AccessControlType]::Allow
$inherit = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All
$rule    = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    [System.Security.Principal.NTAccount]$principal, $rights, $type, $inherit
)

$containers = @(
    "CN=MicrosoftDNS,DC=DomainDnsZones,$dn",
    "CN=MicrosoftDNS,DC=ForestDnsZones,$dn",
    "CN=MicrosoftDNS,CN=System,$dn"
)

$granted = 0; $failed = 0
foreach ($container in $containers) {
    try {
        $zones = Get-ADObject -Filter { objectClass -eq "dnsZone" } `
                              -SearchBase $container -ErrorAction Stop
    } catch {
        Write-Host "  Skipping $container`: $($_.Exception.Message)" -ForegroundColor Yellow
        continue
    }
    foreach ($zone in $zones) {
        try {
            $acl = Get-Acl ("AD:" + $zone.DistinguishedName) -ErrorAction Stop
            $acl.AddAccessRule($rule)
            Set-Acl -AclObject $acl ("AD:" + $zone.DistinguishedName)
            Write-Host "  Granted: $($zone.Name)" -ForegroundColor Green
            $granted++
        } catch {
            Write-Host "  Failed ($($zone.Name)): $($_.Exception.Message)" -ForegroundColor Red
            $failed++
        }
    }
}

Write-Host ""
Write-Host "$granted zone(s) updated, $failed failed."
'

ENCODED=$(printf '%s' "$PS_SCRIPT" | iconv -t UTF-16LE | base64 | tr -d '\n')

for domain dc_ip in "${(@kv)TARGETS}"; do
  echo ""
  echo "══════════════════════════════════════════"
  echo "  $domain  →  $dc_ip"
  echo "══════════════════════════════════════════"

  sshpass -e ssh \
    -l "${DOMAIN_ADMIN_USER}@${domain}" \
    -o BatchMode=no \
    -o PasswordAuthentication=yes \
    -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "$dc_ip" \
    "powershell -NonInteractive -EncodedCommand $ENCODED"

  if [[ $? -ne 0 ]]; then
    echo "" >&2
    echo "[ERROR] SSH failed for $domain ($dc_ip)." >&2
    echo "        Verify OpenSSH is running on the DC and your account has remote access." >&2
  fi
done

echo ""
echo "All domains processed."
