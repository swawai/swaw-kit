function Normalize-WslNetworkMode {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $lower = $Value.Trim().ToLowerInvariant()
    switch ($lower) {
        "mirrored" { return "mirrored" }
        "nat" { return "NAT" }
        default { return $null }
    }
}

function Normalize-WslBooleanConfig {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $lower = $Value.Trim().ToLowerInvariant()
    switch ($lower) {
        { $_ -in @("1", "true", "yes", "on", "enable", "enabled") } { return "true" }
        { $_ -in @("0", "false", "no", "off", "disable", "disabled") } { return "false" }
        default {
            Write-Fail "$Name must be true/false or empty."
            return $null
        }
    }
}

function Set-WslGlobalNetwork {
    $mode = Normalize-WslNetworkMode $script:Config.NetworkMode
    if ($null -eq $mode) {
        Write-Fail "WSL_network_mode must be mirrored, nat, or empty."
        return 1
    }

    if ([string]::IsNullOrWhiteSpace($mode)) {
        Write-Fail "WSL_network_mode is empty. Set it to mirrored or nat before running ctl global network."
        return 1
    }

    $dnsTunneling = Normalize-WslBooleanConfig "WSL_network_dns_tunneling" $script:Config.NetworkDnsTunneling
    if ($null -eq $dnsTunneling) { return 1 }

    $autoProxy = Normalize-WslBooleanConfig "WSL_network_auto_proxy" $script:Config.NetworkAutoProxy
    if ($null -eq $autoProxy) { return 1 }

    $hostLoopback = Normalize-WslBooleanConfig "WSL_network_host_loopback" $script:Config.NetworkHostLoopback
    if ($null -eq $hostLoopback) { return 1 }

    $wsl2Values = [ordered]@{
        networkingMode = $mode
    }
    if (-not [string]::IsNullOrWhiteSpace($dnsTunneling)) {
        $wsl2Values.dnsTunneling = $dnsTunneling
    }
    if (-not [string]::IsNullOrWhiteSpace($autoProxy)) {
        $wsl2Values.autoProxy = $autoProxy
    }

    $path = Join-Path $env:USERPROFILE ".wslconfig"
    $hadExistingConfig = Test-Path -LiteralPath $path -PathType Leaf
    $result = Update-IniFileSectionKeys $path "wsl2" $wsl2Values -Backup
    $changed = $result.Changed
    $backupPath = $result.BackupPath

    if (-not [string]::IsNullOrWhiteSpace($hostLoopback)) {
        $shouldBackupExperimental = $hadExistingConfig -and [string]::IsNullOrWhiteSpace($backupPath)
        $experimentalResult = Update-IniFileSectionKeys $path "experimental" ([ordered]@{
            hostAddressLoopback = $hostLoopback
        }) -Backup:($shouldBackupExperimental)
        $changed = $changed -or $experimentalResult.Changed
        if ([string]::IsNullOrWhiteSpace($backupPath) -and -not [string]::IsNullOrWhiteSpace($experimentalResult.BackupPath)) {
            $backupPath = $experimentalResult.BackupPath
        }
    }

    if ($changed) {
        Write-Host "Updated $path"
    } else {
        Write-Host "$path is already up to date."
    }

    if (-not [string]::IsNullOrWhiteSpace($backupPath)) {
        Write-Host "Backup: $backupPath"
    }

    Write-Host "Restart WSL to apply: $($script:Config.CommandName) ctl global shutdown"
    return 0
}
