#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
    Recursively merges '_0' folders (created by archive restore) into their
    corresponding primary folders, then deletes the now-empty '_0' folders.

.PARAMETER Users
    One or more UPNs to process.

.PARAMETER WhatIf
    Preview what would happen without making changes.
#>
param(
    [Parameter(Mandatory=$true)]
    [string[]]$Users,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$AppId    = '69de0375-242d-4b8a-94df-4e095ab81cea'
$CertPath = "$HOME/GitHub/.tokens/exo-claude/cert.pfx"
$TenantId = 'd5c15341-dfce-470a-bfdf-72c3dab91e7c'

# ── Get Graph API token via MSAL (bundled with EXO module) ────────────────────
function Get-GraphToken {
    $msalDll = '/Users/fperez2nd/.local/share/powershell/Modules/ExchangeOnlineManagement/3.9.2/netCore/Microsoft.Identity.Client.dll'
    Add-Type -Path $msalDll -ErrorAction SilentlyContinue
    $cert    = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertPath)
    $builder = [Microsoft.Identity.Client.ConfidentialClientApplicationBuilder]::Create($AppId)
    $builder = $builder.WithCertificate($cert)
    $builder = $builder.WithAuthority("https://login.microsoftonline.com/$TenantId")
    $result  = $builder.Build().AcquireTokenForClient([string[]]@('https://graph.microsoft.com/.default')).ExecuteAsync().GetAwaiter().GetResult()
    return $result.AccessToken
}

# ── Graph REST helper with retry and token refresh ────────────────────────────
function Invoke-Graph {
    param([string]$Uri, [string]$Method = 'GET', $Body = $null)
    $params = @{
        Uri     = $Uri
        Method  = $Method
        Headers = @{ Authorization = "Bearer $script:token"; 'Content-Type' = 'application/json' }
    }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Compress -Depth 5) }
    $attempts = 0
    do {
        try {
            return Invoke-RestMethod @params
        } catch {
            $attempts++
            if ($attempts -ge 4) { throw }
            if ($_ -match 'InvalidAuthenticationToken|token is expired') {
                Write-Host "      [Token expired — refreshing...]" -ForegroundColor DarkYellow
                $script:token = Get-GraphToken
                $params.Headers.Authorization = "Bearer $script:token"
            } else {
                $wait = $attempts * 5
                Write-Host "      [Retry $attempts] Waiting ${wait}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
            }
        }
    } while ($true)
}

# ── Get all child folders of a given folder (paginated) ───────────────────────
function Get-ChildFolders([string]$Upn, [string]$FolderId) {
    $results = @()
    $uri = "https://graph.microsoft.com/v1.0/users/$Upn/mailFolders/$FolderId/childFolders?`$top=100"
    do {
        $resp    = Invoke-Graph -Uri $uri
        $results += $resp.value
        $uri     = $resp.'@odata.nextLink'
    } while ($uri)
    return $results
}

# ── Move all messages from source folder to target folder (paginated) ─────────
function Move-AllMessages([string]$Upn, [string]$SourceId, [string]$TargetId, [string]$Indent) {
    $moved = 0
    do {
        $resp = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/users/$Upn/mailFolders/$SourceId/messages?`$select=id&`$top=100"
        if ($resp.value.Count -eq 0) { break }
        foreach ($msg in $resp.value) {
            if (-not $WhatIf) {
                Invoke-Graph -Method POST `
                    -Uri "https://graph.microsoft.com/v1.0/users/$Upn/messages/$($msg.id)/move" `
                    -Body @{ destinationId = $TargetId } | Out-Null
            }
            $moved++
        }
    } while ($resp.value.Count -gt 0)
    if ($moved -gt 0) { Write-Host "${Indent}  Moved $moved messages" }
    return $moved
}

# ── Recursively merge source folder into target folder ────────────────────────
function Merge-Folder([string]$Upn, $Src, $Tgt, [string]$Indent = '') {
    $srcName = $Src.displayName
    $tgtName = $Tgt.displayName
    $label   = if ($WhatIf) { '[WHATIF] ' } else { '' }

    Write-Host "${Indent}${label}$srcName → $tgtName ($($Src.totalItemCount) msgs, $($Src.childFolderCount) subfolders)"

    # Move messages
    Move-AllMessages -Upn $Upn -SourceId $Src.id -TargetId $Tgt.id -Indent $Indent | Out-Null

    # Process child folders
    if ($Src.childFolderCount -gt 0) {
        $srcChildren = Get-ChildFolders -Upn $Upn -FolderId $Src.id
        $tgtChildren = Get-ChildFolders -Upn $Upn -FolderId $Tgt.id
        $tgtMap      = @{}
        foreach ($f in $tgtChildren) { $tgtMap[$f.displayName] = $f }

        foreach ($child in $srcChildren) {
            if ($tgtMap.ContainsKey($child.displayName)) {
                # Conflict — recurse into the matching folder
                Merge-Folder -Upn $Upn -Src $child -Tgt $tgtMap[$child.displayName] -Indent "$Indent  "
            } else {
                # No conflict — move the whole folder
                Write-Host "$Indent  ${label}Move folder: $($child.displayName)"
                if (-not $WhatIf) {
                    Invoke-Graph -Method POST `
                        -Uri "https://graph.microsoft.com/v1.0/users/$Upn/mailFolders/$($child.id)/move" `
                        -Body @{ destinationId = $Tgt.id } | Out-Null
                }
            }
        }
    }

    # Delete source (now empty)
    if (-not $WhatIf) {
        try {
            Invoke-Graph -Method DELETE -Uri "https://graph.microsoft.com/v1.0/users/$Upn/mailFolders/$($Src.id)"
            Write-Host "${Indent}  Deleted: $srcName" -ForegroundColor Green
        } catch {
            Write-Host "${Indent}  [WARN] Could not delete $srcName — may still have items" -ForegroundColor Yellow
        }
    }
}

# ── Get all top-level mail folders (paginated) ────────────────────────────────
function Get-TopLevelFolders([string]$Upn) {
    $results = @()
    $uri = "https://graph.microsoft.com/v1.0/users/$Upn/mailFolders?`$top=100&includeHiddenFolders=true"
    do {
        $resp    = Invoke-Graph -Uri $uri
        $results += $resp.value
        $uri     = $resp.'@odata.nextLink'
    } while ($uri)
    return $results
}

# ── Main ──────────────────────────────────────────────────────────────────────
Write-Host "`n[Auth] Getting Graph API token..." -ForegroundColor Cyan
$script:token = Get-GraphToken
Write-Host "  OK"

foreach ($upn in $Users) {
    Write-Host "`n[User] $upn" -ForegroundColor Cyan

    $folders   = Get-TopLevelFolders -Upn $upn
    $folderMap = @{}
    foreach ($f in $folders) { $folderMap[$f.displayName] = $f }

    $zeroFolders = @($folders | Where-Object { $_.displayName -like '*_0' })

    if ($zeroFolders.Count -eq 0) {
        Write-Host "  No '_0' folders found — skipping." -ForegroundColor DarkGray
        continue
    }

    foreach ($src in $zeroFolders) {
        $targetName = $src.displayName -replace '_0$', ''
        $tgt        = $folderMap[$targetName]

        if (-not $tgt) {
            Write-Host "  [SKIP] $($src.displayName) — no matching '$targetName' folder" -ForegroundColor Yellow
            continue
        }

        Merge-Folder -Upn $upn -Src $src -Tgt $tgt -Indent '  '
    }

    Write-Host "  Done: $upn" -ForegroundColor Green
}

Write-Host "`n[Done]" -ForegroundColor Green
