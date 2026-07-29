Set-StrictMode -Version 2.0

function Get-SshAccessCanonicalFirewallRuleName {
    return 'OpenSSH-Server-In-TCP'
}

function Get-SshAccessManagedFirewallRuleName {
    return 'SwawKit-SSHAccess-OpenSSH-Server-In-TCP'
}

function New-SshAccessUnknownFirewallRuleState {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Error
    )

    return [pscustomobject]@{
        Name   = $Name
        Status = 'Unknown'
        Error  = $Error
    }
}

function Test-SshAccessFirewallRuleEnabled {
    param([Parameter(Mandatory = $true)][object]$Rule)

    $Enabled = [string]$Rule.Enabled
    return $Enabled -eq 'True' -or $Enabled -eq '1'
}

function Test-SshAccessFirewallPortFilter {
    param([Parameter(Mandatory = $true)][object]$Filter)

    $Protocol = ([string]$Filter.Protocol).ToUpperInvariant()
    if ($Protocol -ne 'TCP' -and $Protocol -ne '6') {
        return $false
    }

    foreach ($Port in @($Filter.LocalPort)) {
        if ([string]$Port -eq '22') {
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
        [object[]]$AllRules
    )

    $Rules = @($AllRules | Where-Object { [string]$_.Name -eq $Name })
    if ($Rules.Count -eq 0) {
        return [pscustomobject]@{
            Name   = $Name
            Status = 'Missing'
            Error  = $null
        }
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
            if (Test-SshAccessFirewallPortFilter -Filter $Filter) {
                return [pscustomobject]@{
                    Name   = $Name
                    Status = 'Ready'
                    Error  = $null
                }
            }
        }
    }

    return [pscustomobject]@{
        Name   = $Name
        Status = 'Misconfigured'
        Error  = $null
    }
}

function Get-SshAccessFirewallState {
    $CanonicalName = Get-SshAccessCanonicalFirewallRuleName
    $ManagedName = Get-SshAccessManagedFirewallRuleName

    $RuleCommand = Get-Command 'Get-NetFirewallRule' -CommandType Function,Cmdlet -ErrorAction SilentlyContinue
    $FilterCommand = Get-Command 'Get-NetFirewallPortFilter' -CommandType Function,Cmdlet -ErrorAction SilentlyContinue
    if ($null -eq $RuleCommand -or $null -eq $FilterCommand) {
        $Reason = 'Windows firewall cmdlets are unavailable.'
        return [pscustomobject]@{
            Status    = 'Unknown'
            Source    = $null
            RuleName  = $null
            Canonical = New-SshAccessUnknownFirewallRuleState -Name $CanonicalName -Error $Reason
            Managed   = New-SshAccessUnknownFirewallRuleState -Name $ManagedName -Error $Reason
            Error     = $Reason
        }
    }

    try {
        $AllRules = @(Get-NetFirewallRule -ErrorAction Stop)
    } catch {
        $Reason = Get-SshAccessErrorText -ErrorRecord $_
        return [pscustomobject]@{
            Status    = 'Unknown'
            Source    = $null
            RuleName  = $null
            Canonical = New-SshAccessUnknownFirewallRuleState -Name $CanonicalName -Error $Reason
            Managed   = New-SshAccessUnknownFirewallRuleState -Name $ManagedName -Error $Reason
            Error     = $Reason
        }
    }

    $Canonical = Get-SshAccessFirewallRuleState -Name $CanonicalName -AllRules $AllRules
    $Managed = Get-SshAccessFirewallRuleState -Name $ManagedName -AllRules $AllRules

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
    } elseif ($Canonical.Status -eq 'Unknown' -or $Managed.Status -eq 'Unknown') {
        $Status = 'Unknown'
        $ErrorText = if (-not [string]::IsNullOrWhiteSpace($Canonical.Error)) {
            $Canonical.Error
        } else {
            $Managed.Error
        }
    } elseif ($Canonical.Status -eq 'Misconfigured' -or $Managed.Status -eq 'Misconfigured') {
        $Status = 'Misconfigured'
    }

    return [pscustomobject]@{
        Status    = $Status
        Source    = $Source
        RuleName  = $RuleName
        Canonical = $Canonical
        Managed   = $Managed
        Error     = $ErrorText
    }
}

function Remove-SshAccessManagedFirewallRule {
    Assert-SshAccessGlobalAdministrator
    $ManagedName = Get-SshAccessManagedFirewallRuleName

    $GetCommand = Get-Command 'Get-NetFirewallRule' -CommandType Function,Cmdlet -ErrorAction SilentlyContinue
    $RemoveCommand = Get-Command 'Remove-NetFirewallRule' -CommandType Function,Cmdlet -ErrorAction SilentlyContinue
    if ($null -eq $GetCommand -or $null -eq $RemoveCommand) {
        throw 'Windows firewall cmdlets are unavailable.'
    }

    $Rules = @(Get-NetFirewallRule -ErrorAction Stop |
        Where-Object { [string]$_.Name -eq $ManagedName })
    if ($Rules.Count -eq 0) {
        return $false
    }

    Remove-NetFirewallRule -Name $ManagedName -ErrorAction Stop
    return $true
}

function Ensure-SshAccessServerFirewall {
    Assert-SshAccessGlobalAdministrator

    $NewCommand = Get-Command 'New-NetFirewallRule' -CommandType Function,Cmdlet -ErrorAction SilentlyContinue
    if ($null -eq $NewCommand) {
        throw 'New-NetFirewallRule is unavailable.'
    }

    $State = Get-SshAccessFirewallState
    if ($State.Canonical.Status -eq 'Ready') {
        if ($State.Managed.Status -ne 'Missing') {
            $null = Remove-SshAccessManagedFirewallRule
        }
        Write-Host "Using the Windows OpenSSH firewall rule '$($State.Canonical.Name)'."
        return
    }
    if ($State.Managed.Status -eq 'Ready') {
        Write-Host "Using the SSH Access firewall rule '$($State.Managed.Name)'."
        return
    }
    if ($State.Status -eq 'Unknown') {
        throw "Cannot inspect Windows firewall state. $($State.Error)"
    }

    if ($State.Managed.Status -ne 'Missing') {
        $null = Remove-SshAccessManagedFirewallRule
    }

    $ManagedName = Get-SshAccessManagedFirewallRuleName
    New-NetFirewallRule `
        -Name $ManagedName `
        -DisplayName $ManagedName `
        -Description 'Inbound TCP port 22 for Swaw Kit SSH Access.' `
        -Group 'Swaw Kit SSH Access' `
        -Enabled True `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort 22 `
        -Profile Any `
        -ErrorAction Stop |
        Out-Null
    Write-Host "Created SSH Access firewall rule '$ManagedName'."
}
