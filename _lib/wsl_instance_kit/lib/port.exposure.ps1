function Remove-WslPortRules {
    param(
        [int]$ListenPort,
        [string]$Protocol,
        [string]$ListenAddress,
        [switch]$DryRun
    )

    if (-not $DryRun -and -not (Test-WslKitAdmin)) {
        return 1
    }

    $ruleName = Get-WslPortRuleName $Protocol $ListenPort
    $windowsRule = if ($DryRun) { $null } else { Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue }
    $hyperVRule = $null
    if (-not $DryRun -and (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) {
        $hyperVRule = Get-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue
    }
    $removePortProxy = $DryRun -or $null -ne $windowsRule -or $null -eq $hyperVRule
    $exitCode = 0
    if ($removePortProxy) {
        $exitCode = Remove-WslNatPortProxy -ListenPort $ListenPort -ListenAddress $ListenAddress -DryRun:$DryRun
    }

    if ($DryRun) {
        Write-Host "Remove-NetFirewallRule -Name $ruleName"
        Write-Host "Remove-NetFirewallHyperVRule -Name $ruleName"
        return $exitCode
    }

    Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if (Get-Command Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
        Remove-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue
    }

    if ($exitCode -eq 0) {
        Write-Host "Removed WSL port rule: $($Protocol.ToUpperInvariant()) $ListenAddress`:$ListenPort"
    }

    return $exitCode
}


function Add-WslNatPortExposure {
    param(
        [int]$ListenPort,
        [int]$ConnectPort,
        [string]$ListenAddress,
        [string]$Protocol,
        [switch]$DryRun
    )

    if (-not $DryRun -and -not (Test-WslKitAdmin)) {
        return 1
    }

    $targetIp = "<WSL-IP>"
    if (-not $DryRun) {
        $targetIp = Get-WslPortTargetIpAddress
        if ([string]::IsNullOrWhiteSpace($targetIp)) {
            Write-Fail "Could not resolve a WSL IPv4 address for $($script:Config.Name)."
            Write-Fail "Start the instance and try again: $($script:Config.CommandName)"
            return 1
        }
    }

    $proxyCode = Set-WslNatPortProxy -ListenPort $ListenPort -ConnectPort $ConnectPort -ConnectAddress $targetIp -ListenAddress $ListenAddress -DryRun:$DryRun
    if ($proxyCode -ne 0) {
        return $proxyCode
    }

    $firewallCode = Set-WslWindowsFirewallRule -ListenPort $ListenPort -ConnectPort $ConnectPort -Protocol $Protocol -DryRun:$DryRun
    if ($firewallCode -ne 0) {
        return $firewallCode
    }

    Write-Host "Exposed NAT port: $ListenAddress`:$ListenPort -> $targetIp`:$ConnectPort"
    return 0
}


function Add-WslMirroredPortExposure {
    param(
        [int]$ListenPort,
        [int]$ConnectPort,
        [string]$Protocol,
        [switch]$DryRun
    )

    if ($ListenPort -ne $ConnectPort) {
        Write-Fail "mirrored networking does not use host-to-guest port remapping."
        Write-Fail "Use the same port on Windows and WSL, or switch to NAT for portproxy mapping."
        return 1
    }

    if (-not $DryRun -and -not (Test-WslKitAdmin)) {
        return 1
    }

    $code = Set-WslHyperVFirewallRule -ListenPort $ListenPort -ConnectPort $ConnectPort -Protocol $Protocol -DryRun:$DryRun
    if ($code -ne 0) {
        return $code
    }

    Write-Host "Allowed mirrored WSL port via Hyper-V firewall: $($Protocol.ToUpperInvariant()) $ListenPort"
    return 0
}


function Add-WslPortExposure {
    param([string[]]$Rest)

    $options = ConvertTo-WslPortOptionMap $Rest
    if ($null -eq $options) {
        return 1
    }

    if ($options.Positionals.Count -lt 1 -or $options.Positionals.Count -gt 2) {
        Write-Fail "Usage: $($script:Config.CommandName) .port expose <listen-port> [connect-port] [--dry-run] [--uac]"
        return 1
    }

    $listenPort = Resolve-WslPortNumber $options.Positionals[0] "listen port"
    if ($null -eq $listenPort) {
        return 1
    }

    $connectPort = $listenPort
    if ($options.Positionals.Count -eq 2) {
        $connectPort = Resolve-WslPortNumber $options.Positionals[1] "connect port"
        if ($null -eq $connectPort) {
            return 1
        }
    }

    $mode = Get-WslConfiguredNetworkingMode
    switch ($mode.Mode) {
        "nat" {
            $elevatedExitCode = Invoke-WslPortElevationOrRequireAdmin -Action "expose" -Rest $Rest -DryRun:($options.DryRun) -Uac:($options.Uac)
            if ($null -ne $elevatedExitCode) {
                return $elevatedExitCode
            }

            return Add-WslNatPortExposure -ListenPort $listenPort -ConnectPort $connectPort -ListenAddress $options.ListenAddress -Protocol $options.Protocol -DryRun:($options.DryRun)
        }
        "mirrored" {
            if ($listenPort -eq $connectPort) {
                $elevatedExitCode = Invoke-WslPortElevationOrRequireAdmin -Action "expose" -Rest $Rest -DryRun:($options.DryRun) -Uac:($options.Uac)
                if ($null -ne $elevatedExitCode) {
                    return $elevatedExitCode
                }
            }

            return Add-WslMirroredPortExposure -ListenPort $listenPort -ConnectPort $connectPort -Protocol $options.Protocol -DryRun:($options.DryRun)
        }
        "none" {
            Write-Fail "WSL networkingMode=none has no network connectivity to expose."
            return 1
        }
        "virtioproxy" {
            Write-Fail "WSL networkingMode=virtioproxy is not supported by port automation yet."
            Write-Fail "Use .vm to switch to NAT or mirrored for managed exposure."
            return 1
        }
        "bridged" {
            Write-Fail "WSL networkingMode=bridged is deprecated and is not managed by port."
            Write-Fail "Use .vm to switch to NAT or mirrored."
            return 1
        }
        default {
            Write-Warn "Unknown WSL networkingMode '$($mode.Mode)'; using NAT-style portproxy."
            $elevatedExitCode = Invoke-WslPortElevationOrRequireAdmin -Action "expose" -Rest $Rest -DryRun:($options.DryRun) -Uac:($options.Uac)
            if ($null -ne $elevatedExitCode) {
                return $elevatedExitCode
            }

            return Add-WslNatPortExposure -ListenPort $listenPort -ConnectPort $connectPort -ListenAddress $options.ListenAddress -Protocol $options.Protocol -DryRun:($options.DryRun)
        }
    }
}


function Remove-WslPortExposure {
    param([string[]]$Rest)

    $options = ConvertTo-WslPortOptionMap $Rest
    if ($null -eq $options) {
        return 1
    }

    if ($options.Positionals.Count -ne 1) {
        Write-Fail "Usage: $($script:Config.CommandName) .port del <listen-port> [--dry-run] [--uac]"
        return 1
    }

    $listenPort = Resolve-WslPortNumber $options.Positionals[0] "listen port"
    if ($null -eq $listenPort) {
        return 1
    }

    $elevatedExitCode = Invoke-WslPortElevationOrRequireAdmin -Action "del" -Rest $Rest -DryRun:($options.DryRun) -Uac:($options.Uac)
    if ($null -ne $elevatedExitCode) {
        return $elevatedExitCode
    }

    return Remove-WslPortRules -ListenPort $listenPort -Protocol $options.Protocol -ListenAddress $options.ListenAddress -DryRun:($options.DryRun)
}


function Sync-WslPortExposure {
    param([string[]]$Rest)

    $options = ConvertTo-WslPortOptionMap $Rest
    if ($null -eq $options) {
        return 1
    }

    $mode = Get-WslConfiguredNetworkingMode
    if ($mode.Mode -ne "nat") {
        Write-Fail ".port sync is only needed for NAT networking."
        Write-Fail "Current networkingMode: $($mode.Mode)"
        return 1
    }

    if ($options.Positionals.Count -gt 2) {
        Write-Fail "Usage: $($script:Config.CommandName) .port sync [listen-port] [connect-port] [--dry-run] [--uac]"
        return 1
    }

    $elevatedExitCode = Invoke-WslPortElevationOrRequireAdmin -Action "sync" -Rest $Rest -DryRun:($options.DryRun) -Uac:($options.Uac)
    if ($null -ne $elevatedExitCode) {
        return $elevatedExitCode
    }

    if ($options.Positionals.Count -gt 0) {
        return Add-WslPortExposure $Rest
    }

    if (-not $options.DryRun -and -not (Test-WslKitAdmin)) {
        return 1
    }

    $targetIp = "<WSL-IP>"
    if (-not $options.DryRun) {
        $targetIp = Get-WslPortTargetIpAddress
        if ([string]::IsNullOrWhiteSpace($targetIp)) {
            Write-Fail "Could not resolve a WSL IPv4 address for $($script:Config.Name)."
            return 1
        }
    }

    $entries = @(Get-WslPortProxyEntries)
    $synced = 0
    foreach ($entry in $entries) {
        $ruleName = Get-WslPortRuleName $options.Protocol $entry.ListenPort
        $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        if ($null -eq $rule) {
            continue
        }

        $code = Set-WslNatPortProxy -ListenPort $entry.ListenPort -ConnectPort $entry.ConnectPort -ConnectAddress $targetIp -ListenAddress $entry.ListenAddress -DryRun:($options.DryRun)
        if ($code -ne 0) {
            return $code
        }

        $synced += 1
        Write-Host "Synced NAT port: $($entry.ListenAddress):$($entry.ListenPort) -> $targetIp`:$($entry.ConnectPort)"
    }

    if ($synced -eq 0) {
        Write-Host "No managed NAT port mappings found."
    }

    return 0
}
