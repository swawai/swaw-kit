$ErrorActionPreference = 'Stop'
$Utf8 = New-Object Text.UTF8Encoding($false)

function Get-RegistryValueState($Path, $Name) {
    $Item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $Item -or $null -eq $Item.PSObject.Properties[$Name]) {
        return [ordered]@{ Present = $false; Value = 0 }
    }
    return [ordered]@{ Present = $true; Value = [int]$Item.$Name }
}

function Get-Snapshot($Record, $PresentName, $ValueName) {
    if ($null -eq $Record.PSObject.Properties[$PresentName]) {
        return [ordered]@{ Managed = $false; Present = 0; Value = 0 }
    }
    if ($null -eq $Record.PSObject.Properties[$ValueName]) {
        throw "Missing rollback field: $ValueName"
    }
    $Present = [int]$Record.$PresentName
    if (@(0, 1) -notcontains $Present) {
        throw "Invalid rollback field: $PresentName=$Present"
    }
    return [ordered]@{
        Managed = $true
        Present = $Present
        Value   = [int]$Record.$ValueName
    }
}

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
$IsAdministrator = $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

$SourceAddress = ''
$PeerAddress = ''
$ConnectionError = ''
try {
    if ([string]::IsNullOrWhiteSpace($env:SSH_CONNECTION)) {
        throw 'SSH_CONNECTION is unavailable.'
    }
    $Parts = @($env:SSH_CONNECTION -split '\s+')
    if ($Parts.Count -lt 4) {
        throw "Invalid SSH_CONNECTION: $env:SSH_CONNECTION"
    }
    $SourceIp = $null
    $PeerIp = $null
    if (-not [Net.IPAddress]::TryParse($Parts[0], [ref]$SourceIp) -or
        -not [Net.IPAddress]::TryParse($Parts[2], [ref]$PeerIp)) {
        throw "SSH_CONNECTION has an invalid address: $env:SSH_CONNECTION"
    }
    $SourceAddress = $SourceIp.ToString()
    $PeerAddress = $PeerIp.ToString()
} catch {
    $ConnectionError = $_.Exception.Message
}

$Services = @()
foreach ($Name in @('RpcSs', 'LanmanServer', 'TermService')) {
    $Service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    $Services += [ordered]@{
        Name    = $Name
        Present = $null -ne $Service
        Status  = if ($null -ne $Service) { [string]$Service.Status } else { '' }
    }
}

$RollbackPath = 'HKLM:\SOFTWARE\swaw-kit\rollback\rdp-client\shadow'
$Rollback = [ordered]@{
    Present        = $false
    Valid          = $true
    Error          = ''
    Version        = 0
    AllowRemoteRPC = [ordered]@{
        Managed = $false; Present = 0; Value = 0
    }
    ShadowPolicy   = [ordered]@{
        Managed = $false; Present = 0; Value = 0
    }
}
try {
    if (Test-Path -LiteralPath $RollbackPath) {
        $Record = Get-ItemProperty -LiteralPath $RollbackPath -ErrorAction Stop
        foreach ($Name in @('Version', 'ManagedBy')) {
            if ($null -eq $Record.PSObject.Properties[$Name]) {
                throw "Missing rollback field: $Name"
            }
        }
        if ([int]$Record.Version -ne 1) {
            throw "Invalid rollback version: $($Record.Version)"
        }
        if ([string]$Record.ManagedBy -ne 'swaw-kit rdp-client') {
            throw "Invalid rollback owner: $($Record.ManagedBy)"
        }
        $Rollback.Present = $true
        $Rollback.Version = [int]$Record.Version
        $Rollback.AllowRemoteRPC = Get-Snapshot $Record `
            'AllowRemoteRPCOriginalPresent' 'AllowRemoteRPCOriginalValue'
        $Rollback.ShadowPolicy = Get-Snapshot $Record `
            'ShadowOriginalPresent' 'ShadowOriginalValue'
        if ($Rollback.ShadowPolicy.Managed) {
            if ($null -eq $Record.PSObject.Properties['ShadowOriginalKeyPresent']) {
                throw 'Missing rollback field: ShadowOriginalKeyPresent'
            }
        }
        if (-not $Rollback.AllowRemoteRPC.Managed -and
            -not $Rollback.ShadowPolicy.Managed) {
            throw 'Rollback record is empty.'
        }
    }
} catch {
    $Rollback.Valid = $false
    $Rollback.Error = $_.Exception.Message
}

$ManagedRuleNames = @(
    'swaw-kit-rdp-shadow-rpc',
    'swaw-kit-rdp-shadow-smb',
    'swaw-kit-rdp-shadow-transport'
)
$FirewallRules = @()
foreach ($Name in $ManagedRuleNames) {
    $Rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $Rule) { continue }
    $FirewallRules += [ordered]@{
        Name          = $Name
        Enabled       = [string]$Rule.Enabled -eq 'True'
        RemoteAddress = [string](
            ($Rule | Get-NetFirewallAddressFilter).RemoteAddress -join ','
        )
    }
}

$Payload = [ordered]@{
    ComputerName    = [string]$env:COMPUTERNAME
    IsAdministrator = $IsAdministrator
    SourceAddress   = $SourceAddress
    PeerAddress     = $PeerAddress
    ConnectionError = $ConnectionError
    Services        = $Services
    RdpSaPresent    = [IO.File]::Exists("$env:SystemRoot\System32\RdpSa.exe")
    AllowRemoteRPC  = Get-RegistryValueState `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
        -Name 'AllowRemoteRPC'
    ShadowPolicy    = Get-RegistryValueState `
        -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' `
        -Name 'Shadow'
    Rollback        = $Rollback
    FirewallRules   = $FirewallRules
}

$Json = ConvertTo-Json -InputObject $Payload -Depth 8 -Compress
$JsonBase64 = [Convert]::ToBase64String($Utf8.GetBytes($Json))
Write-Output ('RDP_SHADOW_MANAGE_STATE_V3:' + $JsonBase64)
exit 0
