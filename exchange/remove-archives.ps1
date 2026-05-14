#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    Moves archive mailbox content back to primary, disables the archive on-prem,
    triggers an Entra sync, and verifies the result in Exchange Online.

.PARAMETER Users
    One or more UPNs to process. Example:
    ./remove-archives.ps1 -Users 'user1@themyersbriggs.com','user2@themyersbriggs.com'
#>
param(
    [Parameter(Mandatory=$true)]
    [string[]]$Users
)

$ErrorActionPreference = 'Stop'

# ── Config ───────────────────────────────────────────────────────────────────
$AppId      = '69de0375-242d-4b8a-94df-4e095ab81cea'
$CertPath   = "$HOME/GitHub/.tokens/exo-claude/cert.pfx"
$Org        = 'themyersbriggs.com'
$ExchServer = 'SVEXCHDC01.cpp-db.com'
$SyncServer = 'SVAZADSYNCDC01.cpp-db.com'
$SshUser    = 'svcclaude@cpp-db.com'
$OnPremPass = (Get-Content "$HOME/GitHub/.tokens/svcclaude" |
               Select-String '^PASSWORD=').Line.Split('=', 2)[1]

# ── Helper: run a script on SVEXCHDC01 via base64-encoded command ─────────────
function Invoke-OnPremScript([string]$Script) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    & sshpass -p $OnPremPass ssh -o StrictHostKeyChecking=no `
        "${SshUser}@${ExchServer}" "powershell.exe -EncodedCommand $encoded" 2>&1
}

# ── Connect to Exchange Online ────────────────────────────────────────────────
Write-Host "`n[EXO] Connecting..." -ForegroundColor Cyan
Connect-ExchangeOnline -AppId $AppId -CertificateFilePath $CertPath `
    -Organization $Org -ShowBanner:$false

# ── Validate users and build alias map ───────────────────────────────────────
Write-Host "[EXO] Validating users..." -ForegroundColor Cyan
$aliasToUpn      = @{}
$upnToType       = @{}   # UPN -> RecipientTypeDetails
$toProcess       = [System.Collections.Generic.List[string]]::new()

foreach ($upn in $Users) {
    $mbx = Get-Mailbox -Identity $upn -ErrorAction SilentlyContinue
    if (-not $mbx)                        { Write-Warning "  NOT FOUND: $upn"; continue }
    if ($mbx.ArchiveStatus -eq 'None')    { Write-Warning "  NO ARCHIVE: $upn — skipping"; continue }
    $aliasToUpn[$mbx.Alias]        = $upn
    $upnToType[$upn]               = $mbx.RecipientTypeDetails
    $toProcess.Add($upn)
    Write-Host "  OK  $($mbx.DisplayName) ($($mbx.Alias)) [$($mbx.RecipientTypeDetails)] — archive: $($mbx.ArchiveStatus)"
}

if ($toProcess.Count -eq 0) {
    Write-Warning 'No valid users to process.'
    Disconnect-ExchangeOnline -Confirm:$false
    exit
}

$aliases = @($aliasToUpn.Keys)

# ── Phase 1: Create restore requests ─────────────────────────────────────────
Write-Host "`n[Phase 1] Creating restore requests for $($toProcess.Count) user(s)..." -ForegroundColor Cyan

# Clear any pre-existing requests for these users to avoid conflicts
$existing = @(Get-MailboxRestoreRequest | Where-Object { $_.TargetAlias -in $aliases })
if ($existing.Count -gt 0) {
    Write-Host "  Removing $($existing.Count) existing request(s) first..."
    $existing | Remove-MailboxRestoreRequest -Confirm:$false
    Start-Sleep -Seconds 5
}

$requestIds = @{}  # UPN -> request identity
foreach ($upn in $toProcess) {
    $req = New-MailboxRestoreRequest -SourceMailbox $upn -SourceIsArchive `
        -TargetMailbox $upn -ErrorAction Stop
    $requestIds[$upn] = $req.Identity
    Write-Host "  Queued: $upn"
}

# ── Phase 2: Monitor until all complete ──────────────────────────────────────
Write-Host "`n[Phase 2] Monitoring restore requests (polling every 60s)..." -ForegroundColor Cyan

do {
    Start-Sleep -Seconds 60
    $stats = foreach ($upn in $toProcess) {
        Get-MailboxRestoreRequestStatistics -Identity $requestIds[$upn] -ErrorAction SilentlyContinue |
            Select-Object @{N='UPN';E={$upn}}, TargetAlias, Status, PercentComplete, BytesTransferred
    }

    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')]"
    foreach ($s in $stats) {
        $xfer = if ($s.BytesTransferred) { " — $($s.BytesTransferred)" } else { '' }
        Write-Host "    $($s.TargetAlias): $($s.Status) ($($s.PercentComplete)%$xfer)"
    }

    $pending = @($stats | Where-Object { $_.Status -notin @('Completed', 'Failed') })
} while ($pending.Count -gt 0)

$completed = @($stats | Where-Object { $_.Status -eq 'Completed' })
$failed    = @($stats | Where-Object { $_.Status -eq 'Failed' })

if ($failed.Count -gt 0) {
    Write-Warning "The following restore requests FAILED and will be skipped:"
    $failed | ForEach-Object { Write-Warning "  $($_.UPN)" }
}

# Clean up restore requests
foreach ($upn in $toProcess) {
    Remove-MailboxRestoreRequest -Identity $requestIds[$upn] -Confirm:$false -ErrorAction SilentlyContinue
}

# ── Phase 3: Disable archives ────────────────────────────────────────────────
$completedUpns   = @($completed | ForEach-Object { $_.UPN })
$remoteMailboxes = @($completedUpns | Where-Object { $upnToType[$_] -eq 'RemoteUserMailbox' })
$cloudMailboxes  = @($completedUpns | Where-Object { $upnToType[$_] -ne 'RemoteUserMailbox' })

Write-Host "`n[Phase 3] Disabling archives for $($completedUpns.Count) user(s)..." -ForegroundColor Cyan

# Cloud-hosted UserMailbox — disable directly in Exchange Online
if ($cloudMailboxes.Count -gt 0) {
    Write-Host "  Cloud mailboxes ($($cloudMailboxes.Count)) — disabling via Exchange Online..."
    foreach ($upn in $cloudMailboxes) {
        Disable-Mailbox -Archive -Identity $upn -Confirm:$false
        Write-Host "    Disabled (EXO): $upn"
    }
}

# Hybrid RemoteUserMailbox — disable via on-prem Exchange, then sync
if ($remoteMailboxes.Count -gt 0) {
    Write-Host "  Remote mailboxes ($($remoteMailboxes.Count)) — disabling via on-prem Exchange..."
    $upnList = ($remoteMailboxes | ForEach-Object { "'$_'" }) -join ','

    $onPremScript = @"
`$pass = ConvertTo-SecureString '$OnPremPass' -AsPlainText -Force
`$cred = New-Object System.Management.Automation.PSCredential('CPP-DB\svcclaude', `$pass)
`$opts = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
`$s = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri 'https://$ExchServer/PowerShell/' -Credential `$cred -Authentication Basic -SessionOption `$opts
Import-PSSession `$s -DisableNameChecking | Out-Null
foreach (`$upn in @($upnList)) {
    Disable-RemoteMailbox -Archive -Identity `$upn -Confirm:`$false
    Write-Host "    Disabled (on-prem): `$upn"
}
Remove-PSSession `$s
"@

    Invoke-OnPremScript $onPremScript
}

# ── Phase 4: Entra sync (only needed for RemoteUserMailbox) ──────────────────
if ($remoteMailboxes.Count -gt 0) {
    Write-Host "`n[Phase 4] Triggering Entra delta sync..." -ForegroundColor Cyan
    $syncResult = & sshpass -p $OnPremPass ssh -o ConnectTimeout=15 `
        -o StrictHostKeyChecking=no -l svcclaude $SyncServer `
        "powershell.exe -Command `"Start-ADSyncSyncCycle -PolicyType Delta`"" 2>&1
    Write-Host "  $($syncResult -join ' ')"
} else {
    Write-Host "`n[Phase 4] Skipping Entra sync — no RemoteUserMailbox accounts in this batch." -ForegroundColor DarkGray
}

# ── Phase 5: Wait 15s then verify ────────────────────────────────────────────
Write-Host "`n[Phase 5] Waiting 15 seconds..." -ForegroundColor Cyan
Start-Sleep -Seconds 15

Write-Host "[Phase 5] Verifying archive status in Exchange Online..." -ForegroundColor Cyan
$allGood = $true
foreach ($upn in $completedUpns) {
    $mbx = Get-Mailbox -Identity $upn | Select-Object DisplayName, ArchiveStatus
    if ($mbx.ArchiveStatus -eq 'None') {
        Write-Host "  [OK]   $($mbx.DisplayName)" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] $($mbx.DisplayName): still showing $($mbx.ArchiveStatus)" -ForegroundColor Yellow
        $allGood = $false
    }
}

Disconnect-ExchangeOnline -Confirm:$false

Write-Host ''
if ($allGood) {
    Write-Host '[Done] All archives successfully removed.' -ForegroundColor Green
} else {
    Write-Host '[Done] Completed with warnings — check WARN items above.' -ForegroundColor Yellow
}
