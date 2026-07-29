[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$script:CapabilityState = 'Unknown'
$script:AddCapabilityCalls = 0
$script:RemoveCapabilityCalls = 0
function Assert-SshAccessGlobalAdministrator {
}
function Get-Command {
    [CmdletBinding()]
    param(
        [string]$Name,
        [object]$CommandType
    )

    return [pscustomobject]@{ Name = $Name }
}
function Get-SshAccessWindowsCapabilityState {
    param([string]$Name)

    return [pscustomobject]@{
        Name  = $Name
        State = $script:CapabilityState
        Error = ''
    }
}
function Add-WindowsCapability {
    [CmdletBinding()]
    param(
        [switch]$Online,
        [string]$Name
    )

    $script:AddCapabilityCalls++
    return [pscustomobject]@{ RestartNeeded = $false }
}
function Remove-WindowsCapability {
    [CmdletBinding()]
    param(
        [switch]$Online,
        [string]$Name
    )

    $script:RemoveCapabilityCalls++
    return [pscustomobject]@{ RestartNeeded = $false }
}

Write-Host '[TEST] Capability mutations fail closed from unknown or pending states'
Assert-SshAccessTestThrowsLike `
    { Install-SshAccessWindowsCapability -Name 'mock-client' } `
    "*state 'Unknown'*refusing to install*" `
    'Install should not mutate an unknown capability state.'
Assert-SshAccessTestThrowsLike `
    { Remove-SshAccessWindowsCapability -Name 'mock-server' } `
    "*state 'Unknown'*refusing to remove*" `
    'Uninstall should not mutate an unknown capability state.'
$script:CapabilityState = 'InstallPending'
Assert-SshAccessTestThrowsLike `
    { Install-SshAccessWindowsCapability -Name 'mock-client' } `
    "*state 'InstallPending'*refusing to install*" `
    'Install should not stack changes onto a pending capability.'
$script:CapabilityState = 'UninstallPending'
Assert-SshAccessTestThrowsLike `
    { Remove-SshAccessWindowsCapability -Name 'mock-server' } `
    "*state 'UninstallPending'*refusing to remove*" `
    'Uninstall should not stack changes onto a pending capability.'
Assert-SshAccessTestEqual `
    $script:AddCapabilityCalls `
    0 `
    'Rejected install states must not invoke Add-WindowsCapability.'
Assert-SshAccessTestEqual `
    $script:RemoveCapabilityCalls `
    0 `
    'Rejected remove states must not invoke Remove-WindowsCapability.'

Write-Host '[TEST] Capability mutations accept only their explicit source states'
$script:CapabilityState = 'NotPresent'
$InstallResult = Install-SshAccessWindowsCapability -Name 'mock-client'
Assert-SshAccessTestEqual $InstallResult.Changed $true 'NotPresent may transition to Installed.'
Assert-SshAccessTestEqual $script:AddCapabilityCalls 1 'Install should invoke Add once.'
$script:CapabilityState = 'Installed'
$RemoveResult = Remove-SshAccessWindowsCapability -Name 'mock-server'
Assert-SshAccessTestEqual $RemoveResult.Changed $true 'Installed may transition to NotPresent.'
Assert-SshAccessTestEqual $script:RemoveCapabilityCalls 1 'Uninstall should invoke Remove once.'

Write-Host 'ssh access global capability tests: PASS' -ForegroundColor Green
