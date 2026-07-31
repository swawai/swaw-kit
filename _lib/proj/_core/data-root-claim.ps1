Set-StrictMode -Version 2.0

function New-ProjDataRootClaim {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$ActionRoot
    )

    return [pscustomobject][ordered]@{
        Kind = [string]$Plan.Kind
        ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
        ActionRoot = [IO.Path]::GetFullPath($ActionRoot)
        EntryName = [string]$Plan.EntryName
        EntryFile = [string]$Plan.EntryFile
        VolumeId = [string]$Plan.Identity.VolumeId
        FileId = [string]$Plan.Identity.FileId
        DataRoot = [string]$Plan.DataRoot
        SourceDataRoot = [string]$Plan.SourceDataRoot
        Reason = [string]$Plan.Reason
    }
}

function Read-ProjTimedClaimAnswerCore {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [ValidateRange(1, 300)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][scriptblock]$ReadKey
    )

    Write-Host -NoNewline "$Prompt (${TimeoutSeconds}s timeout): "
    $Answer = [Text.StringBuilder]::new()
    $Stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($Stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $Key = & $ReadKey
            if ($null -eq $Key) {
                Start-Sleep -Milliseconds 50
                continue
            }

            if ($Key.Key -eq [ConsoleKey]::Enter) {
                Write-Host
                return $Answer.ToString()
            }
            if ($Key.Key -eq [ConsoleKey]::Backspace) {
                if ($Answer.Length -gt 0) {
                    [void]$Answer.Remove($Answer.Length - 1, 1)
                    Write-Host -NoNewline "`b `b"
                }
                continue
            }
            if (-not [char]::IsControl($Key.KeyChar)) {
                [void]$Answer.Append($Key.KeyChar)
                Write-Host -NoNewline $Key.KeyChar
            }
        }
    } finally {
        $Stopwatch.Stop()
    }
    Write-Host
    return $null
}

function Read-ProjTimedClaimAnswer {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 20
    )

    if ([Console]::IsInputRedirected) {
        return $null
    }
    try {
        [void][Console]::KeyAvailable
    } catch {
        return $null
    }

    return Read-ProjTimedClaimAnswerCore `
        -Prompt $Prompt `
        -TimeoutSeconds $TimeoutSeconds `
        -ReadKey {
            if (-not [Console]::KeyAvailable) {
                return $null
            }
            return [Console]::ReadKey($true)
        }
}

function Confirm-ProjDataRootClaim {
    param(
        [Parameter(Mandatory = $true)][object]$Claim,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 20
    )

    Write-Host '[CLAIM] Project DataRoot requires explicit ownership.' `
        -ForegroundColor Yellow
    Write-Host "  SWAWKIT_PROJ_DIR:         $($Claim.ProjectRoot)"
    Write-Host "  SWAWKIT_PROJ_ACTION_ROOT: $($Claim.ActionRoot)"
    Write-Host "  entry:                    $($Claim.EntryFile)"
    Write-Host "  volumeId:                 $($Claim.VolumeId)"
    Write-Host "  fileId:                   $($Claim.FileId)"
    Write-Host "  target:                   $($Claim.DataRoot)"
    if (-not [string]::IsNullOrWhiteSpace($Claim.SourceDataRoot)) {
        Write-Host "  rename:                   $($Claim.SourceDataRoot)"
    }
    Write-Host "  reason:                   $($Claim.Reason)"
    if ([Console]::IsInputRedirected) {
        Write-Host (
            '[CLAIM FAILED] Confirmation input is redirected; no ownership ' +
            'change was made.'
        ) -ForegroundColor Red
        throw (
            'DataRoot claim requires an interactive terminal. Re-run the ' +
            'entry directly and review the claim details.'
        )
    }
    $Answer = Read-ProjTimedClaimAnswer `
        -Prompt "Type entry name '$($Claim.EntryName)' to confirm" `
        -TimeoutSeconds $TimeoutSeconds
    if ($null -eq $Answer) {
        Write-Host (
            "[CLAIM FAILED] No confirmation was received within " +
            "$TimeoutSeconds seconds; no ownership change was made."
        ) -ForegroundColor Red
        throw 'Project DataRoot claim timed out.'
    }
    if ([string]$Answer -cne [string]$Claim.EntryName) {
        Write-Host (
            '[CLAIM FAILED] Confirmation did not match the entry name; no ' +
            'ownership change was made.'
        ) -ForegroundColor Red
        throw 'Project DataRoot claim was not confirmed.'
    }
    return $true
}
