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
        Name    = $Name
        Status  = 'Unknown'
        Port    = $null
        Profile = $null
        Error   = $Error
    }
}

function New-SshAccessMissingFirewallRuleState {
    param([Parameter(Mandatory = $true)][string]$Name)

    return [pscustomobject]@{
        Name    = $Name
        Status  = 'Missing'
        Port    = $null
        Profile = $null
        Error   = $null
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

function Get-SshAccessFirewallProfileText {
    param([Parameter(Mandatory = $true)][object]$Rule)

    $Profile = ([string]$Rule.Profile).Trim()
    if ([string]::IsNullOrWhiteSpace($Profile)) {
        return 'Unknown'
    }
    return $Profile
}

function Test-SshAccessFirewallProfileAny {
    param([Parameter(Mandatory = $true)][object]$Rule)

    $Profile = (Get-SshAccessFirewallProfileText -Rule $Rule).Replace(' ', '')
    if ($Profile -eq 'Any' -or $Profile -eq '0') {
        return $true
    }

    $Profiles = @($Profile.Split(',') | ForEach-Object {
        $_.ToLowerInvariant()
    })
    return $Profiles -contains 'domain' -and
        $Profiles -contains 'private' -and
        $Profiles -contains 'public'
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
                    Name    = $Name
                    Status  = 'Ready'
                    Port    = $Port
                    Profile = Get-SshAccessFirewallProfileText -Rule $Rule
                    Error   = $null
                }
            }
        }
    }

    $Profiles = @($Rules | ForEach-Object {
        Get-SshAccessFirewallProfileText -Rule $_
    } | Sort-Object -Unique)
    return [pscustomobject]@{
        Name    = $Name
        Status  = 'Misconfigured'
        Port    = $null
        Profile = [string]::Join(', ', [string[]]$Profiles)
        Error   = $null
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
    if ($Managed.Status -eq 'Ready' -and
        -not (Test-SshAccessFirewallProfileAny -Rule $Managed)) {
        $Managed.Status = 'Misconfigured'
        $Managed.Port = $null
    }

    $Status = 'Missing'
    $Source = $null
    $RuleName = $null
    $ErrorText = $null
    if ($Managed.Status -eq 'Ready') {
        $Status = 'Ready'
        $Source = 'Managed'
        $RuleName = $Managed.Name
    } elseif ($Managed.Status -eq 'Unknown') {
        $Status = 'Unknown'
        $ErrorText = [string]$Managed.Error
    } elseif ($Managed.Status -eq 'Misconfigured') {
        $Status = 'Misconfigured'
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

    if ($State.Status -eq 'Ready') {
        Write-Host "Using the SSH Access firewall rule '$($State.RuleName)' for TCP/$Port."
        return
    }

    $Removed = @(Remove-SshAccessOwnedFirewallRules)
    New-SshAccessManagedFirewallRule -Port $Port
    if ($Removed.Count -gt 0) {
        Write-Host "Replaced SSH Access rule(s): $($Removed -join ', ')"
    }
}

function Format-SshAccessFirewallRuleState {
    param([Parameter(Mandatory = $true)][object]$State)

    $Text = "$($State.Status): $($State.Name)"
    if (-not [string]::IsNullOrWhiteSpace([string]$State.Profile)) {
        return "$Text [$($State.Profile)]"
    }
    return $Text
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
        -Value (Format-SshAccessFirewallRuleState -State $State.Canonical)
    Write-SshAccessField `
        -Name 'Managed rule' `
        -Value (Format-SshAccessFirewallRuleState -State $State.Managed)
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
            "The Windows-owned rule '$($State.Canonical.Name)' still allows " +
            "TCP/$($PortState.Port) on firewall profile(s) " +
            "'$($State.Canonical.Profile)'."
        )
    }
}
