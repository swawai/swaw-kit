[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $env:GH_ID_GH_EXE auth switch `
            --hostname $env:GH_HOST `
            --user $env:GH_ID_ACCOUNT 2>$null | Out-Null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($exitCode -ne 0) {
        throw "Account '$($env:GH_ID_ACCOUNT)' is not available for $($env:GH_HOST). Run '$($env:GH_ID_ENTRY_COMMAND) auth login'."
    }
    exit 0
} catch {
    Write-Host "[ERROR] Unable to select the GitHub identity: $($_.Exception.Message)"
    exit 1
}
