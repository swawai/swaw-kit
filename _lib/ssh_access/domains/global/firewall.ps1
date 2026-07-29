Set-StrictMode -Version 2.0

function Get-SshAccessCanonicalFirewallRuleName {
    return 'OpenSSH-Server-In-TCP'
}

function Get-SshAccessManagedFirewallRuleName {
    return 'swaw-kit-ssh-access-sshd-inbound-tcp'
}

function New-SshAccessUnknownFirewallRuleState {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Error
    )

    return [pscustomobject]@{
        Name   = $Name
        Status = 'Unknown'
        Port   = $null
        Error  = $Error
    }
}

function New-SshAccessMissingFirewallRuleState {
    param([Parameter(Mandatory = $true)][string]$Name)

    return [pscustomobject]@{
        Name   = $Name
        Status = 'Missing'
        Port   = $null
        Error  = $null
    }
}

function New-SshAccessUnavailableFirewallState {
    param([Parameter(Mandatory = $true)][string]$Reason)

    $CanonicalName = Get-SshAccessCanonicalFirewallRuleName
    $ManagedName = Get-SshAccessManagedFirewallRuleName
    return [pscustomobject]@{
        Status    = 'Unknown'
        Source    = $null
        RuleName  = $null
        Port      = $null
        Canonical = New-SshAccessUnknownFirewallRuleState `
            -Name $CanonicalName `
            -Error $Reason
        Managed   = New-SshAccessUnknownFirewallRuleState `
            -Name $ManagedName `
            -Error $Reason
        Error     = $Reason
    }
}

function Test-SshAccessFirewallRuleEnabled {
    param([Parameter(Mandatory = $true)][object]$Rule)

    $Enabled = [string]$Rule.Enabled
    return $Enabled -eq 'True' -or $Enabled -eq '1'
}

function Test-SshAccessFirewallPortFilter {
    param(
        [Parameter(Mandatory = $true)][object]$Filter,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port
    )

    $Protocol = ([string]$Filter.Protocol).ToUpperInvariant()
    if ($Protocol -ne 'TCP' -and $Protocol -ne '6') {
        return $false
    }

    foreach ($LocalPort in @($Filter.LocalPort)) {
        if ([string]$LocalPort -eq [string]$Port) {
            return $true
        }
    }
    return $false
}

function Get-SshAccessFirewallRuleState {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$AllRules,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port
    )

    $Rules = @($AllRules | Where-Object { [string]$_.Name -eq $Name })
    if ($Rules.Count -eq 0) {
        return New-SshAccessMissingFirewallRuleState -Name $Name
    }

    foreach ($Rule in $Rules) {
        if (-not (Test-SshAccessFirewallRuleEnabled -Rule $Rule) -or
            [string]$Rule.Direction -ne 'Inbound' -or
            [string]$Rule.Action -ne 'Allow') {
            continue
        }

        try {
            $Filters = @($Rule | Get-NetFirewallPortFilter -ErrorAction Stop)
        } catch {
            return New-SshAccessUnknownFirewallRuleState `
                -Name $Name `
                -Error (Get-SshAccessErrorText -ErrorRecord $_)
        }
        foreach ($Filter in $Filters) {
            if (Test-SshAccessFirewallPortFilter -Filter $Filter -Port $Port) {
                return [pscustomobject]@{
                    Name   = $Name
                    Status = 'Ready'
                    Port   = $Port
                    Error  = $null
                }
            }
        }
    }

    return [pscustomobject]@{
        Name   = $Name
        Status = 'Misconfigured'
        Port   = $null
        Error  = $null
    }
}

function Get-SshAccessFirewallState {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    $RuleCommand = Get-Command `
        'Get-NetFirewallRule' `
        -CommandType Function,Cmdlet `
        -ErrorAction SilentlyContinue
    $FilterCommand = Get-Command `
        'Get-NetFirewallPortFilter' `
        -CommandType Function,Cmdlet `
        -ErrorAction SilentlyContinue
    if ($null -eq $RuleCommand -or $null -eq $FilterCommand) {
        return New-SshAccessUnavailableFirewallState `
            -Reason 'Windows firewall cmdlets are unavailable.'
    }

    try {
        $AllRules = @(Get-NetFirewallRule -ErrorAction Stop)
    } catch {
        return New-SshAccessUnavailableFirewallState `
            -Reason (Get-SshAccessErrorText -ErrorRecord $_)
    }

    $Canonical = Get-SshAccessFirewallRuleState `
        -Name (Get-SshAccessCanonicalFirewallRuleName) `
        -AllRules $AllRules `
        -Port $Port
    $Managed = Get-SshAccessFirewallRuleState `
        -Name (Get-SshAccessManagedFirewallRuleName) `
        -AllRules $AllRules `
        -Port $Port

    $Status = 'Missing'
    $Source = $null
    $RuleName = $null
    $ErrorText = $null
    if ($Canonical.Status -eq 'Ready') {
        $Status = 'Ready'
        $Source = 'Canonical'
        $RuleName = $Canonical.Name
    } elseif ($Managed.Status -eq 'Ready') {
        $Status = 'Ready'
        $Source = 'Managed'
        $RuleName = $Managed.Name
    } else {
        $States = @($Canonical, $Managed)
        $Unknown = @($States | Where-Object Status -eq 'Unknown')
        $Misconfigured = @(
            $States | Where-Object Status -eq 'Misconfigured'
        )
        if ($Unknown.Count -gt 0) {
            $Status = 'Unknown'
            $ErrorText = [string]$Unknown[0].Error
        } elseif ($Misconfigured.Count -gt 0) {
            $Status = 'Misconfigured'
        }
    }

    return [pscustomobject]@{
        Status    = $Status
        Source    = $Source
        RuleName  = $RuleName
        Port      = $Port
        Canonical = $Canonical
        Managed   = $Managed
        Error     = $ErrorText
    }
}

function Remove-SshAccessOwnedFirewallRules {
    Assert-SshAccessGlobalAdministrator

    $GetCommand = Get-Command `
        'Get-NetFirewallRule' `
        -CommandType Function,Cmdlet `
        -ErrorAction SilentlyContinue
    $RemoveCommand = Get-Command `
        'Remove-NetFirewallRule' `
        -CommandType Function,Cmdlet `
        -ErrorAction SilentlyContinue
    if ($null -eq $GetCommand -or $null -eq $RemoveCommand) {
        throw 'Windows firewall cmdlets are unavailable.'
    }

    $ManagedName = Get-SshAccessManagedFirewallRuleName
    $Rules = @(Get-NetFirewallRule -ErrorAction Stop | Where-Object {
        [string]$_.Name -eq $ManagedName
    })
    $Removed = New-Object Collections.Generic.List[string]
    foreach ($Name in @($Rules | ForEach-Object Name | Sort-Object -Unique)) {
        Remove-NetFirewallRule -Name $Name -ErrorAction Stop
        $Removed.Add([string]$Name)
    }
    return [string[]]@($Removed)
}

function New-SshAccessManagedFirewallRule {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    $NewCommand = Get-Command `
        'New-NetFirewallRule' `
        -CommandType Function,Cmdlet `
        -ErrorAction SilentlyContinue
    if ($null -eq $NewCommand) {
        throw 'New-NetFirewallRule is unavailable.'
    }

    $Name = Get-SshAccessManagedFirewallRuleName
    New-NetFirewallRule `
        -Name $Name `
        -DisplayName 'Swaw Kit SSH Access: sshd inbound TCP' `
        -Description "Inbound TCP port $Port for Swaw Kit SSH Access." `
        -Group 'Swaw Kit SSH Access' `
        -Enabled True `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -Profile Any `
        -ErrorAction Stop |
        Out-Null
    Write-Host "Created SSH Access firewall rule '$Name' for TCP/$Port."
}

function Ensure-SshAccessServerFirewall {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    Assert-SshAccessGlobalAdministrator
    $State = Get-SshAccessFirewallState -Port $Port
    if ($State.Status -eq 'Unknown') {
        throw "Cannot inspect Windows firewall state. $($State.Error)"
    }

    if ($State.Canonical.Status -eq 'Ready') {
        $Removed = @(Remove-SshAccessOwnedFirewallRules)
        Write-Host "Using the Windows OpenSSH firewall rule '$($State.Canonical.Name)' for TCP/$Port."
        if ($Removed.Count -gt 0) {
            Write-Host "Removed superseded SSH Access rule(s): $($Removed -join ', ')"
        }
        return
    }
    if ($State.Managed.Status -eq 'Ready') {
        Write-Host "Using the SSH Access firewall rule '$($State.Managed.Name)' for TCP/$Port."
        return
    }

    $Removed = @(Remove-SshAccessOwnedFirewallRules)
    New-SshAccessManagedFirewallRule -Port $Port
    if ($Removed.Count -gt 0) {
        Write-Host "Replaced SSH Access rule(s): $($Removed -join ', ')"
    }
}

function Show-SshAccessFirewallState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $PortState = Get-SshAccessServerPortConfigurationState -Context $Context
    Write-SshAccessHeading -Text 'Windows Firewall for sshd'
    if ($PortState.Status -ne 'Known') {
        Write-SshAccessField -Name 'SSH port' -Value 'Unknown'
        Write-SshAccessField -Name 'State' -Value 'Unknown'
        foreach ($Issue in @($PortState.Issues)) {
            Write-SshAccessField -Name 'Port note' -Value $Issue
        }
        return
    }

    $State = Get-SshAccessFirewallState -Port $PortState.Port
    Write-SshAccessField -Name 'SSH port' -Value $PortState.Port
    Write-SshAccessField -Name 'State' -Value $State.Status
    Write-SshAccessField -Name 'Source' -Value $State.Source
    Write-SshAccessField -Name 'Active rule' -Value $State.RuleName
    Write-SshAccessField `
        -Name 'Windows rule' `
        -Value "$($State.Canonical.Status): $($State.Canonical.Name)"
    Write-SshAccessField `
        -Name 'Managed rule' `
        -Value "$($State.Managed.Status): $($State.Managed.Name)"
    if (-not [string]::IsNullOrWhiteSpace($State.Error)) {
        Write-SshAccessField -Name 'Firewall note' -Value $State.Error
    }
}

function Remove-SshAccessServerFirewall {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $Removed = @(Remove-SshAccessOwnedFirewallRules)
    if ($Removed.Count -eq 0) {
        Write-Host 'No SSH Access firewall rule needed removal.'
    } else {
        Write-Host "Removed SSH Access firewall rule(s): $($Removed -join ', ')"
    }

    $PortState = Get-SshAccessServerPortConfigurationState -Context $Context
    if ($PortState.Status -ne 'Known') {
        Write-SshAccessWarning -Message (
            'The effective sshd port is unknown; other firewall rules were not changed.'
        )
        return
    }
    $State = Get-SshAccessFirewallState -Port $PortState.Port
    if ($State.Canonical.Status -eq 'Ready') {
        Write-SshAccessWarning -Message (
            "TCP/$($PortState.Port) remains allowed by the Windows-owned rule " +
            "'$($State.Canonical.Name)'."
        )
    }
}
