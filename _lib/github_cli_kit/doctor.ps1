[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\identity.ps1"

$failures = 0

function Write-Check {
    param(
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Detail
    )
    if ($Passed) {
        Write-Host "[OK]   ${Label}: $Detail" -ForegroundColor Green
    } else {
        $script:failures++
        Write-Host "[FAIL] ${Label}: $Detail" -ForegroundColor Red
    }
}

try {
    $runtimeReady = -not [string]::IsNullOrWhiteSpace($env:GH_ID_GH_EXE) -and
        [IO.File]::Exists($env:GH_ID_GH_EXE)
    $runtimeDetail = if ($runtimeReady) {
        "$($env:GH_ID_RUNTIME_SOURCE): $($env:GH_ID_GH_EXE)"
    } else {
        'gh was not found; run a gh command or .setup to install the portable runtime'
    }
    $portableIntegrityReady = $true
    if ($runtimeReady -and $env:GH_ID_RUNTIME_SOURCE -eq 'portable') {
        & "$PSScriptRoot\runtime.ps1" -Mode Check -Quiet
        $portableIntegrityReady = $LASTEXITCODE -eq 0
        Write-Check $portableIntegrityReady 'Portable integrity' $(if ($portableIntegrityReady) { 'manifest and executable hash match' } else { 'portable runtime validation failed' })
        $runtimeReady = $runtimeReady -and $portableIntegrityReady
        if (-not $runtimeReady) {
            $runtimeDetail = 'portable runtime exists but failed integrity validation; run .setup to repair it'
        }
    }
    Write-Check $runtimeReady 'Runtime' $runtimeDetail

    if ($runtimeReady) {
        $savedPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $versionOutput = @(& $env:GH_ID_GH_EXE --version 2>$null | ForEach-Object { [string]$_ })
            $versionExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedPreference
        }
        $versionReady = $versionExitCode -eq 0 -and $versionOutput.Count -gt 0
        $versionDetail = if ($versionReady) { $versionOutput[0] } else { 'gh --version failed' }
        Write-Check $versionReady 'Executable' $versionDetail

    }

    $profileReady = $false
    $profileDetail = $env:GH_CONFIG_DIR
    $probePath = $null
    try {
        [void][IO.Directory]::CreateDirectory($env:GH_CONFIG_DIR)
        $probePath = Join-Path $env:GH_CONFIG_DIR (".write-test-$([Guid]::NewGuid().ToString('N'))")
        [IO.File]::WriteAllText($probePath, '')
        $profileReady = $true
    } catch {
        $profileDetail = $_.Exception.Message
    } finally {
        if ($probePath -and [IO.File]::Exists($probePath)) {
            [IO.File]::Delete($probePath)
        }
    }
    Write-Check $profileReady 'Profile directory' $profileDetail

    if ($runtimeReady) {
        $identity = Get-GithubCliActiveAccount -Executable $env:GH_ID_GH_EXE -HostName $env:GH_HOST
        $accountReady = Test-GithubCliExpectedAccount -Identity $identity -ExpectedAccount $env:GH_ID_ACCOUNT
        $accountDetail = switch ($identity.State) {
            'authenticated' { "active $($identity.Account); expected $($env:GH_ID_ACCOUNT)" }
            default { $identity.Detail }
        }
        Write-Check $accountReady 'GitHub account' $accountDetail
    }

    if ($failures -gt 0) {
        Write-Host ''
        Write-Host "GitHub CLI doctor found $failures problem(s)." -ForegroundColor Red
        exit 1
    }
    Write-Host ''
    Write-Host 'GitHub CLI doctor: PASS' -ForegroundColor Green
    exit 0
} catch {
    Write-Host "[ERROR] GitHub CLI doctor failed: $($_.Exception.Message)"
    exit 1
}
