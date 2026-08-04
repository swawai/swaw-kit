$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8
[Console]::OutputEncoding = $Utf8
$OutputEncoding = $Utf8

function Get-RegistryValueState($Path, $Name) {
    $Item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $Item -or $null -eq $Item.PSObject.Properties[$Name]) {
        return [ordered]@{ Present = $false; Value = '' }
    }
    return [ordered]@{ Present = $true; Value = [string]$Item.$Name }
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
$IsAdministrator = $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

$Services = @()
foreach ($Name in @('RpcSs', 'LanmanServer', 'TermService')) {
    $Service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    $Services += [ordered]@{
        Name    = $Name
        Present = $null -ne $Service
        Status  = if ($null -ne $Service) { [string]$Service.Status } else { '' }
    }
}

$NetworkProfiles = @()
$NetworkProfileError = ''
try {
    foreach ($Profile in @(Get-NetConnectionProfile -ErrorAction Stop)) {
        $NetworkProfiles += [ordered]@{
            Name           = [string]$Profile.Name
            InterfaceAlias = [string]$Profile.InterfaceAlias
            Category       = [string]$Profile.NetworkCategory
        }
    }
} catch {
    $NetworkProfileError = $_.Exception.Message
}

$FirewallRules = @()
$FirewallError = ''
try {
    $RuleNames = @(
        'RemoteDesktop-Shadow-In-TCP',
        'swaw-kit-rdp-shadow-transport',
        'FPS-RPCSS-In-TCP',
        'FPS-RPCSS-In-TCP-V2',
        'swaw-kit-rdp-shadow-rpc',
        'FPS-SMB-In-TCP',
        'FPS-SMB-In-TCP-V2',
        'swaw-kit-rdp-shadow-smb'
    )
    foreach ($Name in $RuleNames) {
        foreach ($Rule in @(Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue)) {
            $PortFilter = $Rule | Get-NetFirewallPortFilter
            $AddressFilter = $Rule | Get-NetFirewallAddressFilter
            $RuleProfiles = @([string]$Rule.Profile -split ',\s*')
            $AppliesToActiveProfile = $RuleProfiles -contains 'Any'
            foreach ($ActiveProfile in $NetworkProfiles) {
                if ($RuleProfiles -contains $ActiveProfile.Category) {
                    $AppliesToActiveProfile = $true
                }
            }
            $FirewallRules += [ordered]@{
                Name          = [string]$Rule.Name
                Enabled       = [string]$Rule.Enabled
                Profile       = [string]$Rule.Profile
                ActiveProfile = $AppliesToActiveProfile
                Direction     = [string]$Rule.Direction
                Action        = [string]$Rule.Action
                Protocol      = [string]$PortFilter.Protocol
                LocalPort     = [string]$PortFilter.LocalPort
                RemoteAddress = [string]($AddressFilter.RemoteAddress -join ',')
            }
        }
    }
} catch {
    $FirewallError = $_.Exception.Message
}

$RollbackPresent = $false
$RollbackAllowRemoteRPC = $false
$RollbackShadowPolicy = $false
$RollbackError = ''
try {
    $RollbackPath = 'HKLM:\SOFTWARE\swaw-kit\rollback\rdp-client\shadow'
    if (Test-Path -LiteralPath $RollbackPath) {
        $Rollback = Get-ItemProperty -LiteralPath $RollbackPath -ErrorAction Stop
        if ($null -eq $Rollback.PSObject.Properties['Version'] -or
            $null -eq $Rollback.PSObject.Properties['ManagedBy']) {
            throw "Incomplete rollback record: $RollbackPath"
        }
        if ([int]$Rollback.Version -ne 1) {
            throw "Unsupported rollback record version: $($Rollback.Version)"
        }
        $RollbackPresent = $true
        $RollbackAllowRemoteRPC = (
            $null -ne $Rollback.PSObject.Properties['AllowRemoteRPCOriginalPresent']
        )
        $RollbackShadowPolicy = (
            $null -ne $Rollback.PSObject.Properties['ShadowOriginalPresent']
        )
        if (-not $RollbackAllowRemoteRPC -and -not $RollbackShadowPolicy) {
            throw "Rollback record contains no managed setting: $RollbackPath"
        }
    }
} catch {
    $RollbackError = $_.Exception.Message
}

$Quser = Join-Path $env:SystemRoot 'System32\quser.exe'
$QuserExitCode = -1
if ([IO.File]::Exists($Quser)) {
    $null = & $Quser 2>&1
    $QuserExitCode = $LASTEXITCODE
}

$Payload = [ordered]@{
    Protocol            = 1
    ComputerName        = [string]$env:COMPUTERNAME
    IsAdministrator     = $IsAdministrator
    AllowRemoteRPC      = Get-RegistryValueState `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
        -Name 'AllowRemoteRPC'
    ShadowPolicy        = Get-RegistryValueState `
        -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' `
        -Name 'Shadow'
    Services            = $Services
    NetworkProfiles     = $NetworkProfiles
    NetworkProfileError = $NetworkProfileError
    FirewallRules       = $FirewallRules
    FirewallError       = $FirewallError
    RollbackPresent     = $RollbackPresent
    RollbackAllowRemoteRPC = $RollbackAllowRemoteRPC
    RollbackShadowPolicy = $RollbackShadowPolicy
    RollbackError       = $RollbackError
    QuserPresent        = [IO.File]::Exists($Quser)
    QuserExitCode       = $QuserExitCode
}

$Json = ConvertTo-Json -InputObject $Payload -Depth 8 -Compress
$JsonBase64 = [Convert]::ToBase64String($Utf8.GetBytes($Json))
Write-Output ('RDP_SHADOW_DOCTOR_V1:' + $JsonBase64)
exit 0
