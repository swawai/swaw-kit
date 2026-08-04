[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('status', 'enable', 'mode', 'restore')]
    [string]$Action,

    [ValidateRange(-1, 4)]
    [int]$Mode = -1,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$SshEntryFile,

    [Parameter(Mandatory = $true)]
    [string]$RdpEntryFile,

    [string]$CommandName = 'rdp',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'shadow-peer.ps1')

$TerminalServerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$ShadowPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$RollbackPath = 'HKLM:\SOFTWARE\swaw-kit\rollback\rdp-client\shadow'
$ManagedRuleNames = @(
    'swaw-kit-rdp-shadow-rpc',
    'swaw-kit-rdp-shadow-smb',
    'swaw-kit-rdp-shadow-transport'
)
$ModeDescriptions = @(
    'disabled',
    'full control with consent',
    'full control without consent',
    'view with consent',
    'view without consent'
)

function Assert-RdpClientShadowEnablePrerequisites {
    param([Parameter(Mandatory = $true)][pscustomobject]$State)

    foreach ($ServiceName in @('RpcSs', 'LanmanServer', 'TermService')) {
        $Service = @($State.Services | Where-Object { $_.Name -eq $ServiceName })
        if ($Service.Count -ne 1 -or
            -not $Service[0].Present -or
            $Service[0].Status -ne 'Running') {
            $Status = if ($Service.Count -eq 1 -and $Service[0].Present) {
                [string]$Service[0].Status
            } else {
                'not found'
            }
            throw "Required service $ServiceName is not running: $Status"
        }
    }
    if (-not [bool]$State.RdpSaPresent) {
        throw 'RdpSa.exe is not installed on the peer.'
    }
}

function Get-RdpClientOriginalText {
    param([Parameter(Mandatory = $true)][pscustomobject]$ValueState)

    if ([bool]$ValueState.Present) {
        return [string][int]$ValueState.Value
    }
    return 'absent'
}

function Get-RdpClientShadowRestoreText {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Rollback,
        [Parameter(Mandatory = $true)][pscustomobject]$Snapshot
    )

    if (-not [bool]$Rollback.Valid) {
        return 'invalid rollback record'
    }
    if (-not [bool]$Snapshot.Managed) {
        return 'unchanged (not managed)'
    }
    if ([bool][int]$Snapshot.Present) {
        return [string][int]$Snapshot.Value
    }
    return 'absent'
}

function Get-RdpClientShadowPresentFirewallRuleNames {
    param([Parameter(Mandatory = $true)][pscustomobject]$State)

    return @($State.FirewallRules | ForEach-Object {
        [string]$_.Name
    })
}

function Get-RdpClientShadowRegistryEnableSource {
    return @"
`$ErrorActionPreference='Stop';`$state='$RollbackPath';`$terminal='$TerminalServerPath'
`$item=Get-ItemProperty -LiteralPath `$terminal -ErrorAction SilentlyContinue
`$present=`$null-ne`$item-and`$null-ne`$item.PSObject.Properties['AllowRemoteRPC'];`$value=if(`$present){[int]`$item.AllowRemoteRPC}else{0}
if(-not`$present-or`$value-ne 1){
  if(-not(Test-Path -LiteralPath `$state)){`$null=New-Item -Path `$state -Force;New-ItemProperty -LiteralPath `$state -Name Version -Value 1 -PropertyType DWord -Force|Out-Null;New-ItemProperty -LiteralPath `$state -Name ManagedBy -Value 'swaw-kit rdp-client' -PropertyType String -Force|Out-Null}
  `$record=Get-ItemProperty -LiteralPath `$state
  if(`$null-eq`$record.PSObject.Properties['AllowRemoteRPCOriginalPresent']){New-ItemProperty -LiteralPath `$state -Name AllowRemoteRPCOriginalPresent -Value ([int]`$present) -PropertyType DWord -Force|Out-Null;New-ItemProperty -LiteralPath `$state -Name AllowRemoteRPCOriginalValue -Value `$value -PropertyType DWord -Force|Out-Null}
  New-ItemProperty -LiteralPath `$terminal -Name AllowRemoteRPC -Value 1 -PropertyType DWord -Force|Out-Null;New-ItemProperty -LiteralPath `$state -Name UpdatedAtUtc -Value ([DateTime]::UtcNow.ToString('o')) -PropertyType String -Force|Out-Null
}
"@
}

function Get-RdpClientShadowModeSource {
    param([Parameter(Mandatory = $true)][int]$Value)

    return @"
`$ErrorActionPreference='Stop';`$state='$RollbackPath';`$policy='$ShadowPolicyPath';`$desired=$Value
`$keyPresent=Test-Path -LiteralPath `$policy
`$item=Get-ItemProperty -LiteralPath `$policy -ErrorAction SilentlyContinue
`$present=`$null-ne`$item-and`$null-ne`$item.PSObject.Properties['Shadow'];`$value=if(`$present){[int]`$item.Shadow}else{0}
if(-not`$present-or`$value-ne`$desired){
  if(-not(Test-Path -LiteralPath `$state)){`$null=New-Item -Path `$state -Force;New-ItemProperty -LiteralPath `$state -Name Version -Value 1 -PropertyType DWord -Force|Out-Null;New-ItemProperty -LiteralPath `$state -Name ManagedBy -Value 'swaw-kit rdp-client' -PropertyType String -Force|Out-Null}
  `$record=Get-ItemProperty -LiteralPath `$state
  if(`$null-eq`$record.PSObject.Properties['ShadowOriginalPresent']){New-ItemProperty -LiteralPath `$state -Name ShadowOriginalPresent -Value ([int]`$present) -PropertyType DWord -Force|Out-Null;New-ItemProperty -LiteralPath `$state -Name ShadowOriginalValue -Value `$value -PropertyType DWord -Force|Out-Null;New-ItemProperty -LiteralPath `$state -Name ShadowOriginalKeyPresent -Value ([int]`$keyPresent) -PropertyType DWord -Force|Out-Null}
  if(-not(Test-Path -LiteralPath `$policy)){`$null=New-Item -Path `$policy -Force};New-ItemProperty -LiteralPath `$policy -Name Shadow -Value `$desired -PropertyType DWord -Force|Out-Null;New-ItemProperty -LiteralPath `$state -Name UpdatedAtUtc -Value ([DateTime]::UtcNow.ToString('o')) -PropertyType String -Force|Out-Null
}
"@
}

function Get-RdpClientShadowFirewallEnableSource {
    param([Parameter(Mandatory = $true)][string]$AllowedSource)

    $SourceLiteral = "'" + $AllowedSource.Replace("'", "''") + "'"
    return @"
`$ErrorActionPreference='Stop';`$source=$SourceLiteral
`$rules=@(
  @{n='swaw-kit-rdp-shadow-rpc';d='swaw-kit RDP Shadow - RPC Endpoint Mapper';p=`"`$env:SystemRoot\System32\svchost.exe`";s='RpcSs';l='135'},
  @{n='swaw-kit-rdp-shadow-smb';d='swaw-kit RDP Shadow - SMB';p='System';s='';l='445'},
  @{n='swaw-kit-rdp-shadow-transport';d='swaw-kit RDP Shadow - RdpSa transport';p=`"`$env:SystemRoot\System32\RdpSa.exe`";s='';l=''}
)
foreach(`$r in `$rules){Remove-NetFirewallRule -Name `$r.n -ErrorAction SilentlyContinue;`$x=@{Name=`$r.n;DisplayName=`$r.d;Description='Owned by swaw-kit rdp-client; remove with .peer shadow restore.';Group='swaw-kit RDP Shadow';Enabled='True';Profile='Any';Direction='Inbound';Action='Allow';EdgeTraversalPolicy='Block';RemoteAddress=`$source;Protocol='TCP';Program=`$r.p};if(`$r.s){`$x.Service=`$r.s};if(`$r.l){`$x.LocalPort=`$r.l};New-NetFirewallRule @x|Out-Null}
"@
}

function Get-RdpClientShadowFirewallRestoreSource {
    $Names = @($ManagedRuleNames | ForEach-Object { "'$_'" }) -join ','
    return "`$ErrorActionPreference='Stop';Remove-NetFirewallRule -Name @($Names) -ErrorAction SilentlyContinue"
}

function Get-RdpClientShadowRegistryRestoreSource {
    return @"
`$ErrorActionPreference='Stop';`$state='$RollbackPath';`$terminal='$TerminalServerPath';`$policy='$ShadowPolicyPath';`$record=Get-ItemProperty -LiteralPath `$state -ErrorAction Stop
if(`$null-ne`$record.PSObject.Properties['AllowRemoteRPCOriginalPresent']){if([bool][int]`$record.AllowRemoteRPCOriginalPresent){New-ItemProperty -LiteralPath `$terminal -Name AllowRemoteRPC -Value ([int]`$record.AllowRemoteRPCOriginalValue) -PropertyType DWord -Force|Out-Null}else{Remove-ItemProperty -LiteralPath `$terminal -Name AllowRemoteRPC -ErrorAction SilentlyContinue}}
if(`$null-ne`$record.PSObject.Properties['ShadowOriginalPresent']){if([bool][int]`$record.ShadowOriginalPresent){if(-not(Test-Path -LiteralPath `$policy)){`$null=New-Item -Path `$policy -Force};New-ItemProperty -LiteralPath `$policy -Name Shadow -Value ([int]`$record.ShadowOriginalValue) -PropertyType DWord -Force|Out-Null}else{Remove-ItemProperty -LiteralPath `$policy -Name Shadow -ErrorAction SilentlyContinue;if(-not[bool][int]`$record.ShadowOriginalKeyPresent-and(Test-Path -LiteralPath `$policy)){`$i=Get-Item -LiteralPath `$policy;if(@(`$i.GetValueNames()).Count-eq 0-and@(Get-ChildItem -LiteralPath `$policy).Count-eq 0){Remove-Item -LiteralPath `$policy -Force}}}}
Remove-Item -LiteralPath `$state -Recurse -Force
foreach(`$p in 'HKLM:\SOFTWARE\swaw-kit\rollback\rdp-client','HKLM:\SOFTWARE\swaw-kit\rollback','HKLM:\SOFTWARE\swaw-kit'){if(Test-Path -LiteralPath `$p){`$i=Get-Item -LiteralPath `$p;if(@(`$i.GetValueNames()).Count-eq 0-and@(Get-ChildItem -LiteralPath `$p).Count-eq 0){Remove-Item -LiteralPath `$p -Force}}}
"@
}

function Write-RdpClientShadowPeerHeader {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [Parameter(Mandatory = $true)][string]$Title
    )

    Write-Host "[RDP] Peer Shadow $Title$(if ($DryRun) { ' plan' })"
    Write-Host "  Peer: $($State.ComputerName) ($($State.PeerAddress) via SSH)"
}

function Show-RdpClientShadowStatus {
    param([Parameter(Mandatory = $true)][pscustomobject]$State)

    Write-Host '[RDP] Peer Shadow status'
    Write-Host ('  {0,-16}{1}' -f `
        'Peer:', "$($State.ComputerName) ($($State.PeerAddress) via SSH)")
    $Account = if ([bool]$State.IsAdministrator) {
        'administrator token'
    } else {
        'not an administrator token'
    }
    Write-Host ('  {0,-16}{1}' -f 'SSH account:', $Account)
    Write-Host ''
    Write-Host ('  {0,-52}{1,-32}{2}' -f 'Setting', 'Current', 'Restore')
    $AllowRemoteRPC = if ($State.AllowRemoteRPC.Present) {
        [string][int]$State.AllowRemoteRPC.Value
    } else {
        'absent'
    }
    $AllowRemoteRPCRestore = Get-RdpClientShadowRestoreText `
        -Rollback $State.Rollback `
        -Snapshot $State.Rollback.AllowRemoteRPC
    Write-Host ('  {0,-52}{1,-32}{2}' -f `
        'AllowRemoteRPC', $AllowRemoteRPC, $AllowRemoteRPCRestore)

    if ($State.ShadowPolicy.Present) {
        $Value = [int]$State.ShadowPolicy.Value
        $Description = if ($Value -ge 0 -and $Value -lt $ModeDescriptions.Count) {
            $ModeDescriptions[$Value]
        } else {
            'unknown value'
        }
        $ShadowMode = "$Value ($Description)"
    } else {
        $ShadowMode = 'absent (system default)'
    }
    $ShadowRestore = Get-RdpClientShadowRestoreText `
        -Rollback $State.Rollback `
        -Snapshot $State.Rollback.ShadowPolicy
    Write-Host ('  {0,-52}{1,-32}{2}' -f `
        'Shadow', $ShadowMode, $ShadowRestore)

    foreach ($Name in $ManagedRuleNames) {
        $MatchingRules = @($State.FirewallRules | Where-Object {
            [string]$_.Name -eq $Name
        })
        if ($MatchingRules.Count -eq 1) {
            $Rule = $MatchingRules[0]
            $RuleState = if ([bool]$Rule.Enabled) {
                'present'
            } else {
                'present disabled'
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$Rule.RemoteAddress)) {
                $RuleState += " remote=$($Rule.RemoteAddress)"
            }
        } else {
            $RuleState = 'absent'
        }
        Write-Host ('  {0,-52}{1,-32}{2}' -f `
            "Firewall\$Name", $RuleState, 'remove')
    }

    if (-not [bool]$State.Rollback.Valid) {
        Write-Host "  Rollback error: $($State.Rollback.Error)"
        return $false
    }
    return $true
}

function Show-RdpClientShadowEnablePlan {
    param([Parameter(Mandatory = $true)][pscustomobject]$State)

    Write-RdpClientShadowPeerHeader -State $State -Title 'enable'
    Write-Host "  Source: $($State.SourceAddress) (from SSH_CONNECTION)"
    if (-not $State.AllowRemoteRPC.Present -or [int]$State.AllowRemoteRPC.Value -ne 1) {
        if (-not [bool]$State.Rollback.AllowRemoteRPC.Managed) {
            Write-Host "  BACKUP $RollbackPath <= AllowRemoteRPC=$(Get-RdpClientOriginalText $State.AllowRemoteRPC)"
        }
        Write-Host "  SET    $TerminalServerPath\AllowRemoteRPC=1"
    }
    $PresentRuleNames = @(Get-RdpClientShadowPresentFirewallRuleNames -State $State)
    foreach ($Name in $ManagedRuleNames) {
        $Verb = if ($PresentRuleNames -contains $Name) { 'REPLACE' } else { 'ADD' }
        Write-Host ('  {0,-7} Firewall\{1} remote={2}' -f $Verb, $Name, $State.SourceAddress)
    }
}

function Show-RdpClientShadowModePlan {
    param([Parameter(Mandatory = $true)][pscustomobject]$State)

    Write-RdpClientShadowPeerHeader -State $State -Title 'mode'
    if ($State.ShadowPolicy.Present -and [int]$State.ShadowPolicy.Value -eq $Mode) {
        Write-Host '  Nothing to change.'
        return
    }
    if (-not [bool]$State.Rollback.ShadowPolicy.Managed) {
        Write-Host "  BACKUP $RollbackPath <= Shadow=$(Get-RdpClientOriginalText $State.ShadowPolicy)"
    }
    Write-Host "  SET    $ShadowPolicyPath\Shadow=$Mode ($($ModeDescriptions[$Mode]))"
}

function Show-RdpClientShadowRestorePlan {
    param([Parameter(Mandatory = $true)][pscustomobject]$State)

    Write-RdpClientShadowPeerHeader -State $State -Title 'restore'
    $PresentRuleNames = @(Get-RdpClientShadowPresentFirewallRuleNames -State $State)
    foreach ($Name in $PresentRuleNames) {
        Write-Host "  REMOVE  Firewall\$Name"
    }
    if ([bool]$State.Rollback.AllowRemoteRPC.Managed) {
        $Original = $State.Rollback.AllowRemoteRPC
        if ([bool][int]$Original.Present) {
            Write-Host "  RESTORE $TerminalServerPath\AllowRemoteRPC=$([int]$Original.Value)"
        } else {
            Write-Host "  REMOVE  $TerminalServerPath\AllowRemoteRPC (originally absent)"
        }
    }
    if ([bool]$State.Rollback.ShadowPolicy.Managed) {
        $Original = $State.Rollback.ShadowPolicy
        if ([bool][int]$Original.Present) {
            Write-Host "  RESTORE $ShadowPolicyPath\Shadow=$([int]$Original.Value)"
        } else {
            Write-Host "  REMOVE  $ShadowPolicyPath\Shadow (originally absent)"
        }
    }
    if ([bool]$State.Rollback.Present) {
        Write-Host "  REMOVE  $RollbackPath"
    }
    if ($PresentRuleNames.Count -eq 0 -and -not [bool]$State.Rollback.Present) {
        Write-Host '  Nothing to restore.'
    }
}

try {
    $Utf8NoBom = New-Object Text.UTF8Encoding($false)
    [Console]::InputEncoding = $Utf8NoBom
    [Console]::OutputEncoding = $Utf8NoBom
    $OutputEncoding = $Utf8NoBom

    if ($Action -eq 'mode' -and $Mode -lt 0) {
        throw 'Peer Shadow mode must be between 0 and 4.'
    }
    $ResolvedSshEntry = Resolve-RdpClientPeerSshEntryPath -Value $SshEntryFile
    $ResolvedRdpEntry = [IO.Path]::GetFullPath($RdpEntryFile)
    Assert-RdpClientPeerSshEntryIsSeparate `
        -SshEntryPath $ResolvedSshEntry `
        -RdpEntryPath $ResolvedRdpEntry
    $State = Get-RdpClientShadowManageState -SshEntryPath $ResolvedSshEntry
    Assert-RdpClientShadowPeerIdentity -State $State -EntryPath $ResolvedRdpEntry

    if ($Action -eq 'status') {
        if ($DryRun) {
            throw 'Peer Shadow status is already read-only and does not accept --dry-run.'
        }
        $StatusValid = Show-RdpClientShadowStatus -State $State
        if ($StatusValid) { exit 0 }
        exit 1
    }
    Assert-RdpClientShadowPeerMutationState -State $State

    if ($Action -eq 'enable') {
        Assert-RdpClientShadowEnablePrerequisites -State $State
        Show-RdpClientShadowEnablePlan -State $State
        if (-not $DryRun) {
            if (-not $State.AllowRemoteRPC.Present -or [int]$State.AllowRemoteRPC.Value -ne 1) {
                $null = Invoke-RdpClientShadowRemoteSource -SshEntryPath $ResolvedSshEntry `
                    -RemoteSource (Get-RdpClientShadowRegistryEnableSource) `
                    -Operation 'Shadow registry enable'
            }
            $null = Invoke-RdpClientShadowRemoteSource -SshEntryPath $ResolvedSshEntry `
                -RemoteSource (Get-RdpClientShadowFirewallEnableSource -AllowedSource $State.SourceAddress) `
                -Operation 'Shadow firewall enable'
            Write-Host "[RDP] Peer Shadow network enabled for $($State.SourceAddress)."
        }
    } elseif ($Action -eq 'mode') {
        Show-RdpClientShadowModePlan -State $State
        $NeedsChange = -not $State.ShadowPolicy.Present -or [int]$State.ShadowPolicy.Value -ne $Mode
        if (-not $DryRun -and $NeedsChange) {
            $null = Invoke-RdpClientShadowRemoteSource -SshEntryPath $ResolvedSshEntry `
                -RemoteSource (Get-RdpClientShadowModeSource -Value $Mode) `
                -Operation 'Shadow mode update'
            Write-Host "[RDP] Peer Shadow mode set to $Mode ($($ModeDescriptions[$Mode]))."
        }
    } else {
        Show-RdpClientShadowRestorePlan -State $State
        if (-not $DryRun) {
            $PresentRuleNames = @(
                Get-RdpClientShadowPresentFirewallRuleNames -State $State
            )
            if ($PresentRuleNames.Count -gt 0) {
                $null = Invoke-RdpClientShadowRemoteSource -SshEntryPath $ResolvedSshEntry `
                    -RemoteSource (Get-RdpClientShadowFirewallRestoreSource) `
                    -Operation 'Shadow firewall restore'
            }
            if ([bool]$State.Rollback.Present) {
                $null = Invoke-RdpClientShadowRemoteSource -SshEntryPath $ResolvedSshEntry `
                    -RemoteSource (Get-RdpClientShadowRegistryRestoreSource) `
                    -Operation 'Shadow registry restore'
            }
            Write-Host '[RDP] Peer Shadow changes restored.'
        }
    }
    if ($DryRun) {
        Write-Host '[RDP] Dry run: no peer changes were made.'
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    [Console]::Error.WriteLine(
        "[ERROR] Run `"$CommandName .help`" for Peer Shadow guidance."
    )
    exit 1
}
