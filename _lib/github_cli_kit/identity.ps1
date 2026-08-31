Set-StrictMode -Version 2.0

function Get-GithubCliActiveAccount {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$HostName
    )

    if (-not [IO.File]::Exists($Executable)) {
        return [pscustomobject]@{ State = 'unavailable'; Account = ''; Detail = 'gh executable is missing' }
    }
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Executable api user --hostname $HostName --jq '.login' 2>$null |
            ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($exitCode -ne 0 -or $output.Count -eq 0 -or [string]::IsNullOrWhiteSpace($output[0])) {
        return [pscustomobject]@{ State = 'unauthenticated'; Account = ''; Detail = 'login required or credential check failed' }
    }
    return [pscustomobject]@{ State = 'authenticated'; Account = $output[0].Trim(); Detail = '' }
}

function Test-GithubCliExpectedAccount {
    param(
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][string]$ExpectedAccount
    )

    return $Identity.State -eq 'authenticated' -and
        $Identity.Account.Equals($ExpectedAccount, [StringComparison]::OrdinalIgnoreCase)
}
