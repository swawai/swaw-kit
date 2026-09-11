[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    if ([string]::IsNullOrWhiteSpace($env:GH_HOST)) {
        throw 'GH_HOST is required.'
    }
    if ($env:GH_HOST -ne $env:GH_HOST.Trim() -or
        $env:GH_HOST.Length -gt 253 -or
        $env:GH_HOST -match '[\s/@\\]' -or
        $env:GH_HOST -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?$') {
        throw "Invalid GH_HOST '$($env:GH_HOST)'. Use a hostname without a URL scheme or path."
    }

    if ([string]::IsNullOrWhiteSpace($env:GH_ID_ACCOUNT)) {
        throw 'GH_ID_ACCOUNT is required.'
    }
    if ($env:GH_ID_ACCOUNT -ne $env:GH_ID_ACCOUNT.Trim() -or
        $env:GH_ID_ACCOUNT.Length -gt 100 -or
        $env:GH_ID_ACCOUNT -match '[\s/@:\\]' -or
        $env:GH_ID_ACCOUNT -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        throw "Invalid GH_ID_ACCOUNT '$($env:GH_ID_ACCOUNT)'."
    }

    if ([string]::IsNullOrWhiteSpace($env:GH_CONFIG_DIR) -or
        -not [IO.Path]::IsPathRooted($env:GH_CONFIG_DIR)) {
        throw 'GH_CONFIG_DIR must be an absolute path.'
    }
    if ([IO.File]::Exists($env:GH_CONFIG_DIR)) {
        throw "GH_CONFIG_DIR points to a file: $($env:GH_CONFIG_DIR)"
    }

    if ($env:GH_ID_GIT_PROTOCOL -notin @('https', 'ssh')) {
        throw "GH_ID_GIT_PROTOCOL must be https or ssh. Current value: '$($env:GH_ID_GIT_PROTOCOL)'"
    }

    $tokenNames = @(
        'GH_TOKEN',
        'GITHUB_TOKEN',
        'GH_ENTERPRISE_TOKEN',
        'GITHUB_ENTERPRISE_TOKEN'
    )
    foreach ($name in $tokenNames) {
        if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name))) {
            throw "$name is already set and would override the identity stored for this entry. Clear it before using $($env:GH_ID_ENTRY_COMMAND)."
        }
    }

    exit 0
} catch {
    Write-Host "[ERROR] Invalid GitHub identity configuration: $($_.Exception.Message)"
    exit 1
}
