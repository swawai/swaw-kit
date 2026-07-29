function Get-WslPortInstalledSafeNameSet {
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(Get-WslInstalledDistributionNames)) {
        [void]$set.Add((ConvertTo-WslPortSafeName $name))
    }

    return $set
}

function ConvertFrom-WslManagedPortRuleName {
    param([string]$RuleName)

    if ([string]::IsNullOrWhiteSpace($RuleName)) {
        return $null
    }

    if ($RuleName -notmatch (Get-WslPortRuleRegex)) {
        return $null
    }

    $port = 0
    if (-not [int]::TryParse($Matches["port"], [ref]$port)) {
        return $null
    }

    return [pscustomobject]@{
        InstanceSafeName = $Matches["instance"]
        Protocol         = $Matches["protocol"].ToLowerInvariant()
        ListenAddress    = $Matches["address"]
        ListenPort       = $port
    }
}

function ConvertFrom-WslManagedPortRule {
    param(
        [AllowNull()] [object]$Rule,
        [string]$Kind
    )

    if ($null -eq $Rule) {
        return $null
    }

    $parsed = ConvertFrom-WslManagedPortRuleName ([string]$Rule.Name)
    if ($null -eq $parsed) {
        return $null
    }

    return [pscustomobject]@{
        Id               = [string]$Rule.Name
        Kind             = $Kind
        InstanceName     = Get-WslPortRuleInstanceNameFromDisplayName ([string]$Rule.DisplayName)
        InstanceSafeName = $parsed.InstanceSafeName
        Protocol         = $parsed.Protocol
        ListenAddress    = $parsed.ListenAddress
        ListenPort       = $parsed.ListenPort
        FirewallEnabled  = if ($null -eq $Rule.Enabled) { "" } else { [string]$Rule.Enabled }
        NatEntry         = $null
    }
}

function Test-WslManagedPortItemMatchesInstance {
    param(
        [pscustomobject]$Item,
        [string]$InstanceName
    )

    if ([string]::IsNullOrWhiteSpace($InstanceName)) {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($Item.InstanceName) -and $Item.InstanceName -ieq $InstanceName) {
        return $true
    }

    return ($Item.InstanceSafeName -ieq (ConvertTo-WslPortSafeName $InstanceName))
}

function Get-WslManagedPortItems {
    param(
        [AllowNull()] [string]$InstanceName,
        [switch]$All
    )

    $items = New-Object System.Collections.ArrayList
    $windowsRules = if ($All) { Get-WslAllManagedWindowsFirewallRules } else { Get-WslManagedWindowsFirewallRules }
    foreach ($rule in @($windowsRules)) {
        $item = ConvertFrom-WslManagedPortRule -Rule $rule -Kind "windows-firewall"
        if ($null -ne $item -and (Test-WslManagedPortItemMatchesInstance -Item $item -InstanceName $InstanceName)) {
            [void]$items.Add($item)
        }
    }

    $hyperVRules = if ($All) { Get-WslAllManagedHyperVFirewallRules } else { Get-WslManagedHyperVFirewallRules }
    foreach ($rule in @($hyperVRules)) {
        $item = ConvertFrom-WslManagedPortRule -Rule $rule -Kind "hyperv-firewall"
        if ($null -ne $item -and (Test-WslManagedPortItemMatchesInstance -Item $item -InstanceName $InstanceName)) {
            [void]$items.Add($item)
        }
    }

    $proxyEntries = @(Get-WslPortProxyEntries)
    foreach ($item in @($items)) {
        if ($item.Kind -ne "windows-firewall") {
            continue
        }

        $entry = @($proxyEntries | Where-Object {
            $_.ListenAddress -eq $item.ListenAddress -and $_.ListenPort -eq $item.ListenPort
        } | Select-Object -First 1)
        if ($entry.Count -gt 0) {
            $item.NatEntry = $entry[0]
        }
    }

    return @($items | Sort-Object -Property InstanceSafeName, ListenPort, Id)
}

function Test-WslManagedPortItemMissingInstance {
    param(
        [pscustomobject]$Item,
        [AllowNull()] [object]$InstalledNames,
        [AllowNull()] [object]$InstalledSafeNames
    )

    if ($null -eq $InstalledNames) {
        $InstalledNames = Get-WslInstalledDistributionNameSet
    }
    if ($null -eq $InstalledSafeNames) {
        $InstalledSafeNames = Get-WslPortInstalledSafeNameSet
    }

    if (-not [string]::IsNullOrWhiteSpace($Item.InstanceName)) {
        return (-not $InstalledNames.Contains($Item.InstanceName))
    }

    return (-not $InstalledSafeNames.Contains($Item.InstanceSafeName))
}

function Get-WslManagedPortItemState {
    param(
        [pscustomobject]$Item,
        [AllowNull()] [object]$InstalledNames,
        [AllowNull()] [object]$InstalledSafeNames
    )

    if (Test-WslManagedPortItemMissingInstance -Item $Item -InstalledNames $InstalledNames -InstalledSafeNames $InstalledSafeNames) {
        return "missing-instance"
    }

    if ($Item.Kind -eq "windows-firewall" -and $null -eq $Item.NatEntry) {
        return "missing-portproxy"
    }

    return "ok"
}

function Remove-WslManagedPortItem {
    param(
        [pscustomobject]$Item,
        [switch]$DryRun,
        [switch]$Quiet
    )

    if ($null -eq $Item) {
        return 0
    }

    if (-not $DryRun -and -not (Test-WslKitAdmin)) {
        return 1
    }

    if ($Item.Kind -eq "windows-firewall") {
        $proxyExit = Remove-WslNatPortProxy -ListenPort $Item.ListenPort -ListenAddress $Item.ListenAddress -DryRun:$DryRun
        if ($proxyExit -ne 0) {
            return $proxyExit
        }
    }

    if ($DryRun) {
        if ($Item.Kind -eq "windows-firewall") {
            Write-Host "Remove-NetFirewallRule -Name $($Item.Id)"
        } else {
            Write-Host "Remove-NetFirewallHyperVRule -Name $($Item.Id)"
        }
        return 0
    }

    if ($Item.Kind -eq "windows-firewall") {
        Remove-NetFirewallRule -Name $Item.Id -ErrorAction SilentlyContinue
    } elseif (Get-Command Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
        Remove-NetFirewallHyperVRule -Name $Item.Id -ErrorAction SilentlyContinue
    }

    if (-not $Quiet) {
        Write-Host "Removed WSL port rule: $($Item.Id)"
    }

    return 0
}

function Invoke-WslPortMissingInstanceCleanup {
    param(
        [AllowNull()] [string]$InstanceName,
        [switch]$All,
        [switch]$Quiet
    )

    $removed = 0
    if (-not (Test-WslKitAdmin)) {
        return [pscustomobject]@{
            ExitCode = 0
            Removed  = 0
        }
    }

    $installedNames = Get-WslInstalledDistributionNameSet
    $installedSafeNames = Get-WslPortInstalledSafeNameSet
    $items = @(Get-WslManagedPortItems -InstanceName $InstanceName -All:$All)
    foreach ($item in $items) {
        if (-not (Test-WslManagedPortItemMissingInstance -Item $item -InstalledNames $installedNames -InstalledSafeNames $installedSafeNames)) {
            continue
        }

        $exitCode = Remove-WslManagedPortItem -Item $item -Quiet:$Quiet
        if ($exitCode -ne 0) {
            return [pscustomobject]@{
                ExitCode = $exitCode
                Removed  = $removed
            }
        }

        $removed += 1
    }

    return [pscustomobject]@{
        ExitCode = 0
        Removed  = $removed
    }
}

function Remove-WslManagedPortRulesForInstance {
    param(
        [string]$InstanceName,
        [switch]$Quiet
    )

    if (-not (Test-WslKitAdmin)) {
        return 1
    }

    $items = @(Get-WslManagedPortItems -InstanceName $InstanceName)
    foreach ($item in $items) {
        $exitCode = Remove-WslManagedPortItem -Item $item -Quiet:$Quiet
        if ($exitCode -ne 0) {
            return $exitCode
        }
    }

    return 0
}

function Get-WslPortStatusSummary {
    [void](Invoke-WslPortMissingInstanceCleanup -InstanceName $script:Config.Name -Quiet)

    $mode = Get-WslConfiguredNetworkingMode
    $items = @(Get-WslManagedPortItems -InstanceName $script:Config.Name)
    if ($items.Count -eq 0) {
        return "$($mode.Mode), no managed rules"
    }

    $installedNames = Get-WslInstalledDistributionNameSet
    $installedSafeNames = Get-WslPortInstalledSafeNameSet
    $states = @($items | ForEach-Object {
        Get-WslManagedPortItemState -Item $_ -InstalledNames $installedNames -InstalledSafeNames $installedSafeNames
    } | Sort-Object -Unique)
    return "$($mode.Mode), $($items.Count) managed rule(s), $($states -join '/')"
}

function Format-WslManagedPortItemTarget {
    param([pscustomobject]$Item)

    $source = "$($Item.ListenAddress):$($Item.ListenPort)"
    if ($Item.Kind -eq "windows-firewall") {
        if ($null -ne $Item.NatEntry) {
            return "$source -> $($Item.NatEntry.ConnectAddress):$($Item.NatEntry.ConnectPort)"
        }

        return "$source -> (missing portproxy)"
    }

    return "$source (Hyper-V firewall)"
}
