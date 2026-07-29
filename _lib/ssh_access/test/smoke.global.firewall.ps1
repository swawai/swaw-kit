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
        [string]$Action = 'Allow'
    )

    [void]$script:FirewallRules.Add([pscustomobject]@{
        Name      = $Name
        Enabled   = $Enabled
        Direction = $Direction
        Action    = $Action
        Port      = $Port
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
        -Action $Action
    return $script:FirewallRules[$script:FirewallRules.Count - 1]
}

Write-Host '[TEST] Firewall ownership uses one stable machine-global name'
Assert-SshAccessTestEqual `
    (Get-SshAccessManagedFirewallRuleName) `
    'swaw-kit-ssh-access-sshd-inbound-tcp' `
    'The managed rule should use the swaw-kit ownership namespace.'

Write-Host '[TEST] Windows-owned coverage wins on its matching port'
Add-TestFirewallRule -Name 'OpenSSH-Server-In-TCP' -Port 22
$State = Get-SshAccessFirewallState -Port 22
Assert-SshAccessTestEqual $State.Status 'Ready' 'The Windows OpenSSH rule should cover TCP/22.'
Assert-SshAccessTestEqual $State.Source 'Canonical' 'Windows ownership should be reported honestly.'

Write-Host '[TEST] A custom port replaces a misconfigured managed rule'
Add-TestFirewallRule `
    -Name 'swaw-kit-ssh-access-sshd-inbound-tcp' `
    -Port 2200
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

Write-Host 'ssh access global firewall tests: PASS' -ForegroundColor Green
