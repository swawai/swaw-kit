[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("ssh", "https")]
    [string]$Protocol
)

$ErrorActionPreference = "Stop"

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $lines = @(& git @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $detail = ($lines | Out-String).Trim()
        if ($detail) {
            throw $detail
        }
        throw "git $($Arguments -join ' ') failed with exit code $exitCode."
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines    = $lines
    }
}

function Get-GitFailureMessage {
    param(
        [object]$Result,
        [string]$Fallback
    )

    $detail = (@($Result.Lines) | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        return $detail
    }
    return $Fallback
}

function Normalize-RepositoryPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if ($Path.StartsWith("/") -or $Path.EndsWith("/") -or $Path.Contains("\") -or $Path -match '\s') {
        return $null
    }

    $normalized = $Path
    if ($normalized.EndsWith(".git", [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    $segments = @($normalized.Split('/'))
    if ($segments | Where-Object { $_ -eq "" -or $_ -eq "." -or $_ -eq ".." }) {
        return $null
    }
    if ($segments.Count -lt 2) {
        return $null
    }

    return $normalized
}

function Test-HostName {
    param([string]$HostName)

    if ([string]::IsNullOrWhiteSpace($HostName) -or $HostName.Length -gt 253) {
        return $false
    }
    foreach ($label in $HostName.Split('.')) {
        if ($label -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') {
            return $false
        }
    }
    return $true
}

function Convert-FromSupportedRemoteUrl {
    param([string]$Url)

    $patterns = @(
        [pscustomobject]@{ Protocol = "https"; Pattern = '^https://(?<host>[^/:@?#]+)/(?<path>[^?#]+)$' },
        [pscustomobject]@{ Protocol = "ssh"; Pattern = '^git@(?<host>[^/:@?#]+):(?<path>[^?#]+)$' },
        [pscustomobject]@{ Protocol = "ssh"; Pattern = '^ssh://git@(?<host>[^/:@?#]+)/(?<path>[^?#]+)$' }
    )

    foreach ($candidate in $patterns) {
        $match = [regex]::Match($Url, $candidate.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) {
            continue
        }

        $hostName = $match.Groups["host"].Value
        $path = Normalize-RepositoryPath $match.Groups["path"].Value
        if (-not (Test-HostName $hostName) -or $null -eq $path) {
            return $null
        }

        return [pscustomobject]@{
            Protocol = $candidate.Protocol
            Host     = $hostName
            Path     = $path
        }
    }

    return $null
}

try {
    $repository = Invoke-Git @("rev-parse", "--git-dir") -AllowFailure
    if ($repository.ExitCode -ne 0) {
        $detail = Get-GitFailureMessage $repository "git rev-parse failed with exit code $($repository.ExitCode)."
        if ($detail -match 'not a git repository') {
            throw "origin URL rewriting must be run inside a Git repository."
        }
        throw $detail
    }

    $origin = Invoke-Git @("config", "--local", "--get-all", "remote.origin.url") -AllowFailure
    $originUrls = @($origin.Lines)
    if ($origin.ExitCode -eq 1 -and $originUrls.Count -eq 0) {
        throw "the current repository does not define remote 'origin'."
    }
    if ($origin.ExitCode -ne 0) {
        throw (Get-GitFailureMessage $origin "git config could not read remote.origin.url (exit $($origin.ExitCode)).")
    }
    if ($originUrls.Count -eq 0) {
        throw "the current repository does not define remote 'origin'."
    }
    if ($originUrls.Count -ne 1) {
        throw "remote 'origin' has multiple fetch URLs; no URL was changed."
    }
    if ([string]::IsNullOrWhiteSpace($originUrls[0])) {
        throw "remote 'origin' has an empty fetch URL; no URL was changed."
    }

    $push = Invoke-Git @("config", "--local", "--get-all", "remote.origin.pushurl") -AllowFailure
    if ($push.ExitCode -eq 0) {
        throw "remote 'origin' has an explicit push URL; no URL was changed."
    }
    if ($push.ExitCode -ne 1 -or $push.Lines.Count -ne 0) {
        throw (Get-GitFailureMessage $push "git config could not read remote.origin.pushurl (exit $($push.ExitCode)).")
    }

    $oldUrl = $originUrls[0]
    $parsed = Convert-FromSupportedRemoteUrl $oldUrl
    if ($null -eq $parsed) {
        throw "origin is not a supported Git HTTPS or SSH URL; no URL was changed."
    }

    if ($parsed.Protocol -eq $Protocol) {
        Write-Host "origin already uses $($Protocol.ToUpperInvariant()) for $($parsed.Host):"
        Write-Host "  $oldUrl"
        exit 0
    }

    $newUrl = if ($Protocol -eq "ssh") {
        "git@$($parsed.Host):$($parsed.Path).git"
    } else {
        "https://$($parsed.Host)/$($parsed.Path).git"
    }

    $null = Invoke-Git @("remote", "set-url", "origin", $newUrl)
    Write-Host "Updated origin:"
    Write-Host "  $oldUrl"
    Write-Host "  -> $newUrl"
    exit 0
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    exit 1
}
