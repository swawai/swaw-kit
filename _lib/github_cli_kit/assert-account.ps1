[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\identity.ps1"

try {
    $identity = Get-GithubCliActiveAccount -Executable $env:GH_ID_GH_EXE -HostName $env:GH_HOST
    if (-not (Test-GithubCliExpectedAccount -Identity $identity -ExpectedAccount $env:GH_ID_ACCOUNT)) {
        $actual = if ($identity.Account) { $identity.Account } else { '<none>' }
        throw "Expected GitHub account '$($env:GH_ID_ACCOUNT)', but the active account is '$actual'."
    }
    Write-Host "[OK] Active GitHub account: $($identity.Account)"
    exit 0
} catch {
    Write-Host "[ERROR] GitHub account validation failed: $($_.Exception.Message)"
    exit 1
}
