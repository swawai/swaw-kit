[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$Context = [pscustomobject]@{
    CommandName = 'sshaccess.test'
}

Write-Host '[TEST] Server uninstall verifies capability ownership before stopping sshd'
$script:CapabilityState = 'NotPresent'
$script:UninstallServiceReads = 0
$script:CapabilityRemoveCalls = 0
$script:FirewallRemoveCalls = 0
function Assert-SshAccessGlobalAdministrator {
}

function Get-SshAccessWindowsCapabilityState {
    param([string]$Name)

    return [pscustomobject]@{
        Name  = $Name
        State = $script:CapabilityState
        Error = ''
    }
}
function Get-Service {
    [CmdletBinding()]
    param([string]$Name)

    $script:UninstallServiceReads++
    return $null
}
function Remove-SshAccessWindowsCapability {
    param([string]$Name)

    $script:CapabilityRemoveCalls++
    return [pscustomobject]@{
        Changed       = $false
        RestartNeeded = $false
    }
}

function Remove-SshAccessOwnedFirewallRules {
    $script:FirewallRemoveCalls++
    return [string[]]@()
}

Uninstall-SshAccessServer
Assert-SshAccessTestEqual `
    $script:UninstallServiceReads `
    0 `
    'A missing Windows capability must not stop an independently installed sshd service.'
Assert-SshAccessTestEqual `
    $script:CapabilityRemoveCalls `
    0 `
    'A missing Windows capability should not invoke capability removal.'
Assert-SshAccessTestEqual `
    $script:FirewallRemoveCalls `
    1 `
    'Explicit uninstall may still clean the tool-owned firewall rule.'

$script:CapabilityState = 'Unknown'
Assert-SshAccessTestThrowsLike `
    { Uninstall-SshAccessServer } `
    "*ownership is uncertain*" `
    'An unknown capability state must fail before touching sshd.'
Assert-SshAccessTestEqual `
    $script:UninstallServiceReads `
    0 `
    'An unknown capability state must not inspect or stop sshd.'
Assert-SshAccessTestEqual `
    $script:FirewallRemoveCalls `
    1 `
    'An unknown capability state must not mutate firewall state.'

Write-Host '[TEST] Failed capability removal restores a previously running sshd'
$script:CapabilityState = 'Installed'
$script:MockServiceStatus = 'Running'
$script:ServiceRestartCalls = 0
$script:CapabilityRemovalAttempts = 0
$script:FailStoppedWait = $true
function Get-Service {
    [CmdletBinding()]
    param([string]$Name)

    $script:UninstallServiceReads++
    return [pscustomobject]@{
        Status = $script:MockServiceStatus
    }
}
function Stop-Service {
    [CmdletBinding()]
    param([string]$Name)

    $script:MockServiceStatus = 'Stopped'
}
function Start-Service {
    [CmdletBinding()]
    param([string]$Name)

    $script:ServiceRestartCalls++
    $script:MockServiceStatus = 'Running'
}
function Wait-SshAccessServerService {
    param(
        [object]$Service,
        [string]$Status
    )

    if ($Status -eq 'Stopped' -and $script:FailStoppedWait) {
        $script:FailStoppedWait = $false
        throw 'mock stopped-state wait failure'
    }
}
function Remove-SshAccessWindowsCapability {
    param([string]$Name)

    $script:CapabilityRemovalAttempts++
    throw 'mock capability removal failure'
}
Assert-SshAccessTestThrowsLike `
    { Uninstall-SshAccessServer } `
    '*original sshd running state was restored*' `
    'A failed stopped-state wait should report service-state recovery.'
Assert-SshAccessTestEqual `
    $script:ServiceRestartCalls `
    1 `
    'A failed stopped-state wait should restart sshd when it was running initially.'
Assert-SshAccessTestEqual `
    $script:CapabilityRemovalAttempts `
    0 `
    'Capability removal must not begin when the stopped state was not confirmed.'

$script:MockServiceStatus = 'Running'
$script:ServiceRestartCalls = 0
Assert-SshAccessTestThrowsLike `
    { Uninstall-SshAccessServer } `
    '*original sshd running state was restored*' `
    'A failed capability removal should report service-state recovery.'
Assert-SshAccessTestEqual `
    $script:ServiceRestartCalls `
    1 `
    'A failed capability removal should restart sshd when it was running initially.'
Assert-SshAccessTestEqual `
    $script:CapabilityRemovalAttempts `
    1 `
    'Capability removal should be attempted only after sshd is confirmed stopped.'

function Get-Service {
    [CmdletBinding()]
    param([string]$Name)

    Write-Error 'mock service-manager access denied' -Category PermissionDenied
}
Assert-SshAccessTestThrowsLike `
    { Get-SshAccessOptionalServerService } `
    '*Unable to query the sshd service*' `
    'Service-manager errors must not be treated as sshd missing.'

Write-Host '[TEST] Server install reports a restart boundary before service mutation'
$script:FirewallEnsureCalls = 0
function Get-Service {
    [CmdletBinding()]
    param([string]$Name)

    $script:UninstallServiceReads++
    return $null
}
function Install-SshAccessWindowsCapability {
    param([string]$Name)

    return [pscustomobject]@{
        Changed       = $true
        RestartNeeded = $true
    }
}

function Ensure-SshAccessServerFirewall {
    param([int]$Port)

    $script:FirewallEnsureCalls++
}
$ServiceReadsBeforePendingInstall = $script:UninstallServiceReads
Install-SshAccessServer -Context $Context
Assert-SshAccessTestEqual `
    $script:UninstallServiceReads `
    ($ServiceReadsBeforePendingInstall + 1) `
    'A pending-restart install should check for the newly created sshd service once.'
Assert-SshAccessTestEqual `
    $script:FirewallEnsureCalls `
    0 `
    'A pending-restart install must not configure the firewall before sshd exists.'

$script:AdminCalls = New-Object Collections.Generic.List[object]
$script:ServerUninstallCalls = 0
$script:ServerInstallCalls = 0
$script:ClientInstallCalls = 0
$script:ShellSetCalls = 0
$script:PortSetCalls = 0
$script:FirewallStatusCalls = 0
$script:FirewallAllowCalls = 0
$script:FirewallCommandRemoveCalls = 0

function Invoke-SshAccessAdminCommand {
    param(
        [pscustomobject]$Context,
        [string[]]$Arguments,
        [bool]$Uac
    )

    $script:AdminCalls.Add([pscustomobject]@{
        Arguments = [string[]]@($Arguments)
        Uac       = $Uac
    })
    return $null
}

function Uninstall-SshAccessServer { $script:ServerUninstallCalls++ }

function Install-SshAccessServer {
    param([pscustomobject]$Context)
    $script:ServerInstallCalls++
}

function Install-SshAccessClient {
    param([pscustomobject]$Context)
    $script:ClientInstallCalls++
}

function Set-SshAccessServerShellPowerShell {
    param([pscustomobject]$Context)
    $script:ShellSetCalls++
}

function Set-SshAccessServerPort {
    param(
        [pscustomobject]$Context,
        [int]$Port
    )

    $script:PortSetCalls++
    $script:LastPortSet = $Port
}

function Show-SshAccessFirewallState {
    param([pscustomobject]$Context)
    $script:FirewallStatusCalls++
}

function Get-SshAccessServerPortConfigurationState {
    param([pscustomobject]$Context)

    return [pscustomobject]@{
        Status = 'Known'
        Port   = 2222
    }
}

function Get-SshAccessRequiredServerService { return [pscustomobject]@{ Status = 'Running' } }

function Assert-SshAccessManagedServerPortState {
    param([pscustomobject]$State)
    return [int]$State.Port
}

function Ensure-SshAccessServerFirewall {
    param([int]$Port)
    $script:FirewallAllowCalls++
    $script:LastFirewallPort = $Port
}

function Remove-SshAccessServerFirewall {
    param([pscustomobject]$Context)
    $script:FirewallCommandRemoveCalls++
}

Write-Host '[TEST] Server uninstall confirmation precedes elevation and mutation'
Assert-SshAccessTestThrowsLike `
    { Invoke-SshAccessGlobalCommand -Context $Context -Arguments @('server', 'uninstall') } `
    '*Uninstall requires --yes*' `
    'Server uninstall should require explicit confirmation.'
Assert-SshAccessTestThrowsLike `
    { Invoke-SshAccessGlobalCommand -Context $Context -Arguments @('server', 'uninstall', '--force') } `
    "*Unexpected argument '--force'*" `
    'Server uninstall should reject unknown options.'
Assert-SshAccessTestThrowsLike `
    { Invoke-SshAccessGlobalCommand -Context $Context -Arguments @('server', 'uninstall', '--yes', '--yes') } `
    "*Duplicate option '--yes'*" `
    'Server uninstall should reject duplicate confirmation.'
Assert-SshAccessTestEqual $script:AdminCalls.Count 0 'Invalid uninstall must not request elevation.'
Assert-SshAccessTestEqual $script:ServerUninstallCalls 0 'Invalid uninstall must not mutate.'

$Code = Invoke-SshAccessGlobalCommand `
    -Context $Context `
    -Arguments @('server', 'uninstall', '--yes', '--uac')
Assert-SshAccessTestEqual $Code 0 'A confirmed server uninstall should dispatch.'
Assert-SshAccessTestEqual $script:AdminCalls.Count 1 'Valid uninstall should cross the admin boundary once.'
Assert-SshAccessTestEqual $script:AdminCalls[0].Uac $true 'Valid uninstall should forward explicit UAC.'
Assert-SshAccessTestEqual `
    ([string]::Join(' ', $script:AdminCalls[0].Arguments)) `
    '.global server uninstall --yes' `
    'The elevated command should omit the transport-only --uac option.'
Assert-SshAccessTestEqual $script:ServerUninstallCalls 1 'Valid uninstall should mutate once after authorization.'

Write-Host '[TEST] Other global mutations reject options before authorization'
$AdminCount = $script:AdminCalls.Count
Assert-SshAccessTestThrowsLike `
    { Invoke-SshAccessGlobalCommand -Context $Context -Arguments @('server', 'install', '--yes') } `
    "*Unexpected argument '--yes'*" `
    'Server install should reject unsupported confirmation.'
Assert-SshAccessTestThrowsLike `
    { Invoke-SshAccessGlobalCommand -Context $Context -Arguments @('client', 'install', '--unknown') } `
    "*Unexpected argument '--unknown'*" `
    'Client install should reject unknown options.'
Assert-SshAccessTestThrowsLike `
    { Invoke-SshAccessGlobalCommand -Context $Context -Arguments @('server', 'shell', 'powershell', '--yes') } `
    "*Unexpected argument '--yes'*" `
    'Shell changes should reject unknown options.'
Assert-SshAccessTestThrowsLike `
    { Invoke-SshAccessGlobalCommand -Context $Context -Arguments @('server', 'shell', 'status') } `
    "*Unknown server shell command 'status'*" `
    'The removed shell status command must stay unavailable.'
Assert-SshAccessTestThrowsLike `
    { Invoke-SshAccessGlobalCommand -Context $Context -Arguments @('server', 'port', 'status') } `
    "*Unknown server port command 'status'*" `
    'Port state should remain part of aggregate server status.'
Assert-SshAccessTestThrowsLike `
    { Invoke-SshAccessGlobalCommand -Context $Context -Arguments @('server', 'port', 'set', '0') } `
    '*must be an integer from 1 to 65535*' `
    'Port set should reject an invalid port before authorization.'
Assert-SshAccessTestThrowsLike `
    { Invoke-SshAccessGlobalCommand -Context $Context -Arguments @('server', 'port', 'set', '22', '23') } `
    '*requires exactly one port*' `
    'Port set should reject multiple values before authorization.'
Assert-SshAccessTestThrowsLike `
    { Invoke-SshAccessGlobalCommand -Context $Context -Arguments @('server', 'firewall', 'allow', '--yes') } `
    "*Unexpected argument '--yes'*" `
    'Firewall mutations should reject unknown options before authorization.'
Assert-SshAccessTestEqual `
    $script:AdminCalls.Count `
    $AdminCount `
    'Invalid global mutations must fail before the admin boundary.'
Assert-SshAccessTestEqual $script:ServerInstallCalls 0 'Invalid server install must not mutate.'
Assert-SshAccessTestEqual $script:ClientInstallCalls 0 'Invalid client install must not mutate.'
Assert-SshAccessTestEqual $script:ShellSetCalls 0 'Invalid shell command must not mutate.'

Write-Host '[TEST] Valid global commands preserve explicit UAC semantics'
$null = Invoke-SshAccessGlobalCommand `
    -Context $Context `
    -Arguments @('server', 'install')
$null = Invoke-SshAccessGlobalCommand `
    -Context $Context `
    -Arguments @('client', 'install', '--uac')
$null = Invoke-SshAccessGlobalCommand `
    -Context $Context `
    -Arguments @('server', 'shell', 'powershell', '--uac')
$null = Invoke-SshAccessGlobalCommand `
    -Context $Context `
    -Arguments @('server', 'port', 'set', '2222', '--uac')
$null = Invoke-SshAccessGlobalCommand `
    -Context $Context `
    -Arguments @('server', 'firewall', 'allow', '--uac')
$null = Invoke-SshAccessGlobalCommand `
    -Context $Context `
    -Arguments @('server', 'firewall', 'remove', '--uac')
$null = Invoke-SshAccessGlobalCommand `
    -Context $Context `
    -Arguments @('server', 'firewall', 'status')
Assert-SshAccessTestEqual $script:ServerInstallCalls 1 'Server install should dispatch once.'
Assert-SshAccessTestEqual $script:ClientInstallCalls 1 'Client install should dispatch once.'
Assert-SshAccessTestEqual $script:ShellSetCalls 1 'Shell change should dispatch once.'
Assert-SshAccessTestEqual $script:PortSetCalls 1 'Port set should dispatch once.'
Assert-SshAccessTestEqual $script:LastPortSet 2222 'Port set should retain the validated port.'
Assert-SshAccessTestEqual $script:FirewallAllowCalls 1 'Firewall allow should dispatch once.'
Assert-SshAccessTestEqual $script:LastFirewallPort 2222 'Firewall allow should use the configured sshd port.'
Assert-SshAccessTestEqual $script:FirewallCommandRemoveCalls 1 'Firewall remove should dispatch once.'
Assert-SshAccessTestEqual $script:FirewallStatusCalls 1 'Firewall status should dispatch once.'
Assert-SshAccessTestEqual $script:AdminCalls[1].Uac $false 'No flag should mean no implicit UAC.'
Assert-SshAccessTestEqual $script:AdminCalls[2].Uac $true 'Client --uac should be explicit.'
Assert-SshAccessTestEqual $script:AdminCalls[3].Uac $true 'Shell --uac should be explicit.'
Assert-SshAccessTestEqual $script:AdminCalls[4].Uac $true 'Port --uac should be explicit.'
Assert-SshAccessTestEqual $script:AdminCalls[5].Uac $true 'Firewall allow --uac should be explicit.'
Assert-SshAccessTestEqual $script:AdminCalls[6].Uac $true 'Firewall remove --uac should be explicit.'

Assert-SshAccessTestThrowsLike `
    { Invoke-SshAccessGlobalCommand -Context $Context -Arguments @('registry') } `
    "*Unknown global command 'registry'*" `
    'Unknown global domains should fail explicitly.'
Assert-SshAccessTestThrowsLike `
    { Invoke-SshAccessGlobalCommand -Context $Context -Arguments @('server', 'restart') } `
    "*Unknown server command 'restart'*" `
    'Unpromised server actions should fail explicitly.'

Write-Host 'ssh access global tests: PASS' -ForegroundColor Green
