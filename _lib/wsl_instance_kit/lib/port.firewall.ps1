function Get-WslManagedWindowsFirewallRules {
    $prefix = Get-WslPortRulePrefix
    return @(Get-NetFirewallRule -Name "$prefix-*" -ErrorAction SilentlyContinue)
}


function Get-WslManagedHyperVFirewallRules {
    if (-not (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) {
        return @()
    }

    $prefix = Get-WslPortRulePrefix
    return @(Get-NetFirewallHyperVRule -Name "$prefix-*" -ErrorAction SilentlyContinue)
}


function Set-WslWindowsFirewallRule {
    param(
        [int]$ListenPort,
        [int]$ConnectPort,
        [string]$Protocol,
        [switch]$DryRun
    )

    $ruleName = Get-WslPortRuleName $Protocol $ListenPort
    $displayName = "WSL Kit $($script:Config.Name) $($Protocol.ToUpperInvariant()) $ListenPort -> $ConnectPort"

    if ($DryRun) {
        Write-Host "New-NetFirewallRule -Name $ruleName -DisplayName `"$displayName`" -Group `"WSL Kit`" -Direction Inbound -Action Allow -Protocol $($Protocol.ToUpperInvariant()) -LocalPort $ListenPort -Profile Any"
        return 0
    }

    $existing = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    }

    New-NetFirewallRule -Name $ruleName -DisplayName $displayName -Group "WSL Kit" -Direction Inbound -Action Allow -Protocol $Protocol.ToUpperInvariant() -LocalPort $ListenPort -Profile Any | Out-Null
    return 0
}


function Get-WslHyperVFirewallCreatorId {
    if (-not (Get-Command Get-NetFirewallHyperVVMCreator -ErrorAction SilentlyContinue)) {
        return ""
    }

    $creator = @(Get-NetFirewallHyperVVMCreator -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq "WSL" } | Select-Object -First 1)[0]
    if ($null -ne $creator -and -not [string]::IsNullOrWhiteSpace($creator.VMCreatorId)) {
        return [string]$creator.VMCreatorId
    }

    return "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}"
}


function Set-WslHyperVFirewallRule {
    param(
        [int]$ListenPort,
        [int]$ConnectPort,
        [string]$Protocol,
        [switch]$DryRun
    )

    if (-not (Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) {
        Write-Fail "Hyper-V firewall cmdlets are not available on this Windows build."
        return 1
    }

    $creatorId = Get-WslHyperVFirewallCreatorId
    if ([string]::IsNullOrWhiteSpace($creatorId)) {
        Write-Fail "Could not resolve the WSL Hyper-V firewall creator id."
        return 1
    }

    $ruleName = Get-WslPortRuleName $Protocol $ListenPort
    $displayName = "WSL Kit $($script:Config.Name) $($Protocol.ToUpperInvariant()) $ListenPort"

    if ($DryRun) {
        Write-Host "New-NetFirewallHyperVRule -Name $ruleName -DisplayName `"$displayName`" -Direction Inbound -VMCreatorId $creatorId -Protocol $($Protocol.ToUpperInvariant()) -LocalPorts $ListenPort -Action Allow -Enabled True"
        return 0
    }

    $existing = Get-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Remove-NetFirewallHyperVRule -Name $ruleName -ErrorAction SilentlyContinue
    }

    New-NetFirewallHyperVRule -Name $ruleName -DisplayName $displayName -Direction Inbound -VMCreatorId $creatorId -Protocol $Protocol.ToUpperInvariant() -LocalPorts @([string]$ListenPort) -Action Allow -Enabled True | Out-Null
    return 0
}

