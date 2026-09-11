[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Get-GitAuthorizationConfigEntries {
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
        $lines = @(& $gitCommand.Path config --show-scope --show-origin --name-only --list 2>$null |
            ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "git config inspection failed with exit code $exitCode."
    }

    foreach ($line in $lines) {
        $match = [regex]::Match(
            $line,
            '^(?<scope>\S+)\s+(?<origin>.+?)\s+(?<key>\S+)$',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if (-not $match.Success) {
            throw "git config returned an unrecognized authorization entry."
        }
        [pscustomobject]@{
            Scope  = $match.Groups["scope"].Value
            Origin = $match.Groups["origin"].Value
            Key    = $match.Groups["key"].Value
        }
    }
}

function Test-UnsafeAuthorizationConfigEntry {
    param([Parameter(Mandatory = $true)][object]$Entry)

    if ($Entry.Key -imatch '^http(?:\..+)?\.(?:extraheader|cookiefile|sslcert|sslkey|delegation)$') {
        return $true
    }
    if ($Entry.Scope -iin @("local", "worktree") -and
        $Entry.Key -imatch '^credential\..+\.helper$') {
        return $true
    }
    return $false
}

function Get-AuthorizationConfigKeyDisplayName {
    param([Parameter(Mandatory = $true)][string]$Key)

    return [regex]::Replace($Key, '(?i)(https?://)[^/@\s]+@', '$1<redacted>@')
}

if ($MyInvocation.InvocationName -ne ".") {
    try {
        $unsafeEntries = @(Get-GitAuthorizationConfigEntries |
            Where-Object { Test-UnsafeAuthorizationConfigEntry $_ })
        if ($unsafeEntries.Count -eq 0) {
            exit 0
        }

        Write-Host "[ERROR] Git config contains hidden HTTPS authorization that can bypass this identity."
        foreach ($entry in $unsafeEntries) {
            $displayKey = Get-AuthorizationConfigKeyDisplayName $entry.Key
            Write-Host "  $($entry.Scope): $displayKey ($($entry.Origin))"
        }
        Write-Host "Remove HTTP credential headers, cookies, client certificates, and repository-local URL-scoped credential helpers before using this entry."
        exit 1
    } catch {
        Write-Host "[ERROR] Git configuration could not be inspected for HTTPS authorization bypasses: $($_.Exception.Message)"
        exit 1
    }
}
