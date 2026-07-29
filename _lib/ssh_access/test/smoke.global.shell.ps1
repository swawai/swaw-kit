[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$Context = [pscustomobject]@{
    WindowsRoot = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Windows
    )
}

Write-Host '[TEST] Shell state treats companion registry values as one aggregate'
function Test-Path {
    [CmdletBinding()]
    param(
        [string]$LiteralPath,
        [string]$PathType
    )

    return $true
}
function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath)

    return [pscustomobject]@{
        DefaultShell                = 'C:\tools\custom-shell.exe'
        DefaultShellCommandOption   = '-lc'
        DefaultShellEscapeArguments = 1
    }
}

$State = Get-SshAccessShellState -Context $Context
Assert-SshAccessTestEqual $State.Kind 'Custom' 'A non-built-in shell should remain custom.'
Assert-SshAccessTestEqual `
    $State.CommandOption `
    '-lc' `
    'Shell status should expose the companion command option.'
Assert-SshAccessTestEqual `
    $State.EscapeArguments `
    1 `
    'Shell status should expose the companion escape policy.'
Assert-SshAccessTestEqual `
    $State.CompanionConfigured `
    $true `
    'Shell status should flag companion values that affect remote commands.'

Write-Host '[TEST] Shell changes clear incompatible companion values'
$script:RemovedShellValues = New-Object Collections.Generic.List[string]
$script:SetShellValues = New-Object Collections.Generic.List[string]
$script:ShellMutationOrder = New-Object Collections.Generic.List[string]
function Assert-SshAccessGlobalAdministrator {
}
function Remove-ItemProperty {
    [CmdletBinding()]
    param(
        [string]$LiteralPath,
        [string]$Name
    )

    $script:RemovedShellValues.Add($Name)
    $script:ShellMutationOrder.Add("remove:$Name")
}
function New-Item {
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$Force
    )

    return [pscustomobject]@{}
}
function New-ItemProperty {
    [CmdletBinding()]
    param(
        [string]$LiteralPath,
        [string]$Name,
        [object]$Value,
        [string]$PropertyType,
        [switch]$Force
    )

    $script:SetShellValues.Add($Name)
    $script:ShellMutationOrder.Add("set:$Name")
    return [pscustomobject]@{}
}

$CmdChangeOutput = (
    & { Set-SshAccessServerShellCmd -Context $Context } 6>&1 |
        Out-String
)
Assert-SshAccessTestEqual `
    ([string]::Join(',', [string[]]$script:RemovedShellValues)) `
    'DefaultShellCommandOption,DefaultShellEscapeArguments,DefaultShell' `
    'Restoring cmd should clear the complete shell registry aggregate.'
Assert-SshAccessTestContains `
    $CmdChangeOutput `
    'DefaultShellCommandOption, DefaultShellEscapeArguments' `
    'The cmd change result should disclose cleared companion options.'

$script:RemovedShellValues.Clear()
$script:ShellMutationOrder.Clear()
$PowerShellChangeOutput = (
    & { Set-SshAccessServerShellPowerShell -Context $Context } 6>&1 |
        Out-String
)
Assert-SshAccessTestEqual `
    ([string]::Join(',', [string[]]$script:SetShellValues)) `
    'DefaultShell' `
    'Selecting Windows PowerShell should set only DefaultShell.'
Assert-SshAccessTestEqual `
    ([string]::Join(',', [string[]]$script:RemovedShellValues)) `
    'DefaultShellCommandOption,DefaultShellEscapeArguments' `
    'Selecting Windows PowerShell should clear incompatible companion values.'
Assert-SshAccessTestEqual `
    ([string]::Join(',', [string[]]$script:ShellMutationOrder)) `
    'remove:DefaultShellCommandOption,remove:DefaultShellEscapeArguments,set:DefaultShell' `
    'Selecting PowerShell should commit DefaultShell only after cleanup succeeds.'
Assert-SshAccessTestContains `
    $PowerShellChangeOutput `
    'DefaultShellCommandOption, DefaultShellEscapeArguments' `
    'The PowerShell change result should disclose cleared companion options.'

Write-Host 'ssh access global shell tests: PASS' -ForegroundColor Green
