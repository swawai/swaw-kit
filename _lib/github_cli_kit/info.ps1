[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\identity.ps1"

function New-InfoRow {
    param([string]$Label, [string]$Value)
    return [pscustomobject]@{ Label = $Label; Value = $Value }
}

function Write-InfoRows {
    param([object[]]$Rows)
    $width = ($Rows | ForEach-Object { ($_.Label + ':').Length } | Measure-Object -Maximum).Maximum
    foreach ($row in $Rows) {
        Write-Host "  $(($row.Label + ':').PadRight($width))  $($row.Value)"
    }
}

try {
    $runtimePath = if ($env:GH_ID_GH_EXE) { $env:GH_ID_GH_EXE } else { '<missing>' }
    $runtimeSource = if ($env:GH_ID_RUNTIME_SOURCE) { $env:GH_ID_RUNTIME_SOURCE } else { 'missing' }
    $authState = 'not checked (gh is missing)'
    $runtimeSafeToExecute = -not [string]::IsNullOrWhiteSpace($env:GH_ID_GH_EXE)
    if ($runtimeSafeToExecute -and $runtimeSource -eq 'portable') {
        & "$PSScriptRoot\runtime.ps1" -Mode Check -Quiet
        $runtimeSafeToExecute = $LASTEXITCODE -eq 0
        if (-not $runtimeSafeToExecute) {
            $runtimeSource = 'portable-invalid'
            $authState = 'not checked (portable runtime integrity failed)'
        }
    }
    if ($runtimeSafeToExecute) {
        $identity = Get-GithubCliActiveAccount -Executable $env:GH_ID_GH_EXE -HostName $env:GH_HOST
        switch ($identity.State) {
            'authenticated' {
                if (Test-GithubCliExpectedAccount -Identity $identity -ExpectedAccount $env:GH_ID_ACCOUNT) {
                    $authState = "authenticated as $($identity.Account)"
                } else {
                    $authState = "MISMATCH: active $($identity.Account), expected $($env:GH_ID_ACCOUNT)"
                }
            }
            default { $authState = $identity.Detail }
        }
    }

    Write-Host 'GitHub identity:'
    Write-InfoRows @(
        New-InfoRow 'Entry' $env:GH_ID_ENTRY_FILE
        New-InfoRow 'Host' $env:GH_HOST
        New-InfoRow 'Expected account' $env:GH_ID_ACCOUNT
        New-InfoRow 'Git protocol' $env:GH_ID_GIT_PROTOCOL
        New-InfoRow 'Profile directory' $env:GH_CONFIG_DIR
        New-InfoRow 'Authorization' $authState
    )
    Write-Host ''
    Write-Host 'GitHub CLI runtime:'
    Write-InfoRows @(
        New-InfoRow 'Source' $runtimeSource
        New-InfoRow 'Executable' $runtimePath
    )
    exit 0
} catch {
    Write-Host "[ERROR] Unable to show GitHub identity info: $($_.Exception.Message)"
    exit 1
}
