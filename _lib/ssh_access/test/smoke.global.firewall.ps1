[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'support.ps1')
. (Join-Path $script:SshAccessTestKitRoot 'runtime\bootstrap.ps1')

$script:FirewallRules = New-Object Collections.ArrayList
$script:CreatedFirewallPorts = New-Object Collections.Generic.List[int]
$script:RemovedFirewallNames = New-Object Collections.Generic.List[string]

function Add-TestFirewallRule {
    param(
        [string]$Name,
        [int]$Port,
        [string]$Enabled = 'True',
        [string]$Direction = 'Inbound',
        [string]$Action = 'Allow',
        [string]$Profile = 'Any'
    )

    [void]$script:FirewallRules.Add([pscustomobject]@{
        Name      = $Name
        Enabled   = $Enabled
        Direction = $Direction
        Action    = $Action
        Port      = $Port
        Profile   = $Profile
    })
}

function Assert-SshAccessGlobalAdministrator {
}

function Get-NetFirewallRule {
    [CmdletBinding()]
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return @($script:FirewallRules)
    }
    return @($script:FirewallRules | Where-Object Name -eq $Name)
}

function Get-NetFirewallPortFilter {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [object]$InputObject
    )

    process {
        return [pscustomobject]@{
            Protocol  = 'TCP'
            LocalPort = [string]$InputObject.Port
        }
    }
}

function Remove-NetFirewallRule {
    [CmdletBinding()]
    param([string]$Name)

    $script:RemovedFirewallNames.Add($Name)
    for ($Index = $script:FirewallRules.Count - 1; $Index -ge 0; $Index--) {
        if ([string]$script:FirewallRules[$Index].Name -eq $Name) {
            $script:FirewallRules.RemoveAt($Index)
        }
    }
}

function New-NetFirewallRule {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$DisplayName,
        [string]$Description,
        [string]$Group,
        [object]$Enabled,
        [string]$Direction,
        [string]$Action,
        [string]$Protocol,
        [int]$LocalPort,
        [string]$Profile
    )

    $script:CreatedFirewallPorts.Add($LocalPort)
    Add-TestFirewallRule `
        -Name $Name `
        -Port $LocalPort `
        -Enabled ([string]$Enabled) `
        -Direction $Direction `
        -Action $Action `
        -Profile $Profile
    return $script:FirewallRules[$script:FirewallRules.Count - 1]
}

Write-Host '[TEST] Firewall ownership uses one stable machine-global name'
Assert-SshAccessTestEqual `
    (Get-SshAccessManagedFirewallRuleName) `
    'swaw-kit-ssh-access-sshd-inbound-tcp' `
    'The managed rule should use the swaw-kit ownership namespace.'

Write-Host '[TEST] A Windows-owned Private rule does not replace managed coverage'
Add-TestFirewallRule `
    -Name 'OpenSSH-Server-In-TCP' `
    -Port 22 `
    -Profile 'Private'
$State = Get-SshAccessFirewallState -Port 22
Assert-SshAccessTestEqual `
    $State.Status `
    'Missing' `
    'The managed Any-profile rule is the firewall contract.'
Assert-SshAccessTestEqual `
    $State.Canonical.Profile `
    'Private' `
    'The Windows rule profile should remain visible as context.'
Ensure-SshAccessServerFirewall -Port 22
$Managed = @(
    $script:FirewallRules |
        Where-Object Name -eq 'swaw-kit-ssh-access-sshd-inbound-tcp'
)
Assert-SshAccessTestEqual $Managed.Count 1 'The managed rule should be created.'
Assert-SshAccessTestEqual $Managed[0].Profile 'Any' 'The managed rule should cover every profile.'
Assert-SshAccessTestEqual `
    @($script:FirewallRules | Where-Object Name -eq 'OpenSSH-Server-In-TCP').Count `
    1 `
    'Creating managed coverage must preserve the Windows-owned rule.'
$State = Get-SshAccessFirewallState -Port 22
Assert-SshAccessTestEqual $State.Source 'Managed' 'Managed ownership should be explicit.'

Write-Host '[TEST] Ready managed coverage is idempotent beside the Windows rule'
$script:CreatedFirewallPorts.Clear()
Ensure-SshAccessServerFirewall -Port 22
Assert-SshAccessTestEqual `
    $script:CreatedFirewallPorts.Count `
    0 `
    'A ready managed rule should not be recreated.'
Assert-SshAccessTestEqual `
    $script:RemovedFirewallNames.Count `
    0 `
    'A Windows-owned rule must not supersede ready managed coverage.'

Write-Host '[TEST] A managed rule restricted to Private is reconciled'
$Managed[0].Profile = 'Private'
$State = Get-SshAccessFirewallState -Port 22
Assert-SshAccessTestEqual `
    $State.Status `
    'Misconfigured' `
    'A managed Private-only rule does not satisfy the Any-profile contract.'
$script:CreatedFirewallPorts.Clear()
Ensure-SshAccessServerFirewall -Port 22
$Managed = @(
    $script:FirewallRules |
        Where-Object Name -eq 'swaw-kit-ssh-access-sshd-inbound-tcp'
)
Assert-SshAccessTestEqual $Managed.Count 1 'Profile reconciliation should leave one managed rule.'
Assert-SshAccessTestEqual $Managed[0].Profile 'Any' 'Profile reconciliation should restore Any.'

Write-Host '[TEST] A custom port replaces a misconfigured managed rule'
$script:CreatedFirewallPorts.Clear()
$State = Get-SshAccessFirewallState -Port 2222
Assert-SshAccessTestEqual `
    $State.Status `
    'Misconfigured' `
    'A managed rule for the wrong port should require reconciliation.'
Ensure-SshAccessServerFirewall -Port 2222
Assert-SshAccessTestEqual `
    ([string]::Join(',', [int[]]@($script:CreatedFirewallPorts))) `
    '2222' `
    'Custom port reconciliation should create one managed rule.'
$Managed = @(
    $script:FirewallRules |
        Where-Object Name -eq 'swaw-kit-ssh-access-sshd-inbound-tcp'
)
Assert-SshAccessTestEqual $Managed.Count 1 'Exactly one managed rule should remain.'
Assert-SshAccessTestEqual $Managed[0].Port 2222 'The managed rule content should carry the port.'
Assert-SshAccessTestEqual $Managed[0].Profile 'Any' 'The replacement should retain Any-profile coverage.'

Write-Host '[TEST] Owned-rule removal never deletes the Windows rule'
$Removed = @(Remove-SshAccessOwnedFirewallRules)
Assert-SshAccessTestEqual `
    ([string]::Join(',', [string[]]$Removed)) `
    'swaw-kit-ssh-access-sshd-inbound-tcp' `
    'Removal should report only the SSH Access-owned rule.'
Assert-SshAccessTestEqual `
    @($script:FirewallRules | Where-Object Name -eq 'OpenSSH-Server-In-TCP').Count `
    1 `
    'The Windows-owned OpenSSH rule must survive SSH Access cleanup.'

Write-Host '[TEST] Server install creates managed coverage for the default SSH port'
$script:InstallStartupType = $null
$script:InstallStartCalls = 0
function Install-SshAccessWindowsCapability {
    param([string]$Name)

    return [pscustomobject]@{
        Changed       = $false
        RestartNeeded = $false
    }
}

function Get-SshAccessOptionalServerService {
    return [pscustomobject]@{ Status = 'Stopped' }
}

function Set-Service {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$StartupType
    )

    $script:InstallStartupType = $StartupType
}

function Start-Service {
    [CmdletBinding()]
    param([string]$Name)

    $script:InstallStartCalls++
}

function Get-SshAccessRequiredServerService {
    return [pscustomobject]@{ Status = 'Running' }
}

function Wait-SshAccessServerService {
    param(
        [object]$Service,
        [string]$Status
    )
}

function Get-SshAccessServerPortConfigurationState {
    param([pscustomobject]$Context)

    return [pscustomobject]@{
        Status = 'Known'
        Port   = 22
        Source = 'Default'
    }
}

function Assert-SshAccessManagedServerPortState {
    param([pscustomobject]$State)

    return [int]$State.Port
}

$script:CreatedFirewallPorts.Clear()
Install-SshAccessServer -Context ([pscustomobject]@{})
Assert-SshAccessTestEqual `
    $script:InstallStartupType `
    'Automatic' `
    'Server install should configure automatic startup.'
Assert-SshAccessTestEqual `
    $script:InstallStartCalls `
    1 `
    'Server install should start a stopped sshd service.'
Assert-SshAccessTestEqual `
    ([string]::Join(',', [int[]]@($script:CreatedFirewallPorts))) `
    '22' `
    'Server install should request managed coverage for the default SSH port.'
$Managed = @(
    $script:FirewallRules |
        Where-Object Name -eq 'swaw-kit-ssh-access-sshd-inbound-tcp'
)
Assert-SshAccessTestEqual $Managed.Count 1 'Server install should create one managed rule.'
Assert-SshAccessTestEqual $Managed[0].Port 22 'Server install should cover the default SSH port.'
Assert-SshAccessTestEqual $Managed[0].Profile 'Any' 'Server install should cover every profile.'

Write-Host 'ssh access global firewall tests: PASS' -ForegroundColor Green
