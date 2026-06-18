function Show-WslPortStatus {
    param([string[]]$Rest)

    $options = ConvertTo-WslPortOptionMap $Rest
    if ($null -eq $options) {
        return 1
    }

    if ($options.Positionals.Count -gt 1) {
        Write-Fail "Usage: $($script:Config.CommandName) ctl port status [listen-port]"
        return 1
    }

    $filterPort = $null
    if ($options.Positionals.Count -eq 1) {
        $filterPort = Resolve-WslPortNumber $options.Positionals[0] "listen port"
        if ($null -eq $filterPort) {
            return 1
        }
    }

    $mode = Get-WslConfiguredNetworkingMode
    $record = Get-WslDistributionRecord
    [void](Invoke-WslPortMissingInstanceCleanup -InstanceName $script:Config.Name -Quiet)
    $runtime = if ($null -eq $record) { $null } else { Get-WslDistributionRuntimeInfo $record }
    $runtimeState = if ($null -eq $runtime -or [string]::IsNullOrWhiteSpace($runtime.State)) { "unknown" } else { $runtime.State }
    $runtimeIp = if ($runtimeState -ieq "Running") { Get-WslRunningIpAddresses $runtimeState } else { "" }

    Write-Host "WSL port status: $($script:Config.CommandName)"
    Write-Host "  Networking mode: $($mode.Mode) ($($mode.Source))"
    Write-Host "  WSL runtime:     $runtimeState"
    Write-Host "  WSL IP:          $(if ([string]::IsNullOrWhiteSpace($runtimeIp)) { '(not running or unknown)' } else { $runtimeIp })"

    switch ($mode.Mode) {
        "nat" { Write-Host "  Strategy:        portproxy + Windows Firewall" }
        "mirrored" { Write-Host "  Strategy:        Hyper-V Firewall, no portproxy" }
        "none" { Write-Host "  Strategy:        no network connectivity" }
        "virtioproxy" { Write-Host "  Strategy:        not managed by ctl port" }
        "bridged" { Write-Host "  Strategy:        deprecated, not managed by ctl port" }
        default { Write-Host "  Strategy:        unknown mode; expose uses NAT-style portproxy" }
    }

    $proxyEntries = @(Get-WslPortProxyEntries)
    if ($null -ne $filterPort) {
        $proxyEntries = @($proxyEntries | Where-Object { $_.ListenPort -eq $filterPort -and $_.ListenAddress -eq $options.ListenAddress })
    }

    $managedRuleNames = New-Object System.Collections.Generic.HashSet[string]
    foreach ($rule in @(Get-WslManagedWindowsFirewallRules)) {
        [void]$managedRuleNames.Add($rule.Name)
    }
    foreach ($rule in @(Get-WslManagedHyperVFirewallRules)) {
        [void]$managedRuleNames.Add($rule.Name)
    }

    $seen = 0
    foreach ($entry in $proxyEntries) {
        $ruleName = Get-WslPortRuleName $options.Protocol $entry.ListenPort
        if (-not $managedRuleNames.Contains($ruleName)) {
            continue
        }

        Write-Host "  NAT mapping:     $($entry.ListenAddress):$($entry.ListenPort) -> $($entry.ConnectAddress):$($entry.ConnectPort)"
        $seen += 1
    }

    foreach ($ruleName in $managedRuleNames) {
        if ($ruleName -notmatch '-(?<port>\d+)$') {
            continue
        }
        $port = [int]$Matches["port"]
        if ($null -ne $filterPort -and $port -ne $filterPort) {
            continue
        }

        $windowsRule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        if ($null -ne $windowsRule) {
            Write-Host "  Windows firewall: $ruleName ($($windowsRule.Enabled))"
            $seen += 1
        }

        if (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
            $hyperVRule = Get-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue
            if ($null -ne $hyperVRule) {
                Write-Host "  Hyper-V firewall: $ruleName ($($hyperVRule.Enabled))"
                $seen += 1
            }
        }
    }

    if ($seen -eq 0) {
        Write-Host "  Managed ports:   none"
    }

    return 0
}


function Show-WslPortUsage {
    Write-Host "Usage:"
    Write-Host "  $($script:Config.CommandName) ctl port status [listen-port]"
    Write-Host "  $($script:Config.CommandName) ctl port doctor [listen-port]"
    Write-Host "  $($script:Config.CommandName) ctl port expose <listen-port> [connect-port] [--dry-run] [--uac]"
    Write-Host "  $($script:Config.CommandName) ctl port remove <listen-port> [--dry-run] [--uac]"
    Write-Host "  $($script:Config.CommandName) ctl port sync [listen-port] [connect-port] [--dry-run] [--uac]"
    Write-Host "Notes:"
    Write-Host "  NAT uses netsh portproxy plus Windows Firewall."
    Write-Host "  Mirrored uses Hyper-V Firewall and does not remap ports."
    Write-Host "  Port changes require an administrator shell; add --uac to request elevation."
    return 0
}
