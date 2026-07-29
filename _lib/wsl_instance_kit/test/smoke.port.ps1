function Test-PortInventoryDryRun {
    . (Join-Path $kitRoot "lib\common.ps1")
    . (Join-Path $kitRoot "lib\port.common.ps1")
    . (Join-Path $kitRoot "lib\port.netsh.ps1")
    . (Join-Path $kitRoot "lib\port.inventory.ps1")

    $parsed = ConvertFrom-WslManagedPortRuleName "swaw-kit-wsl-instance-demo-port-tcp-0.0.0.0-2222"
    Assert-True ($null -ne $parsed) "canonical WSL port rule names should be parseable."
    Assert-True ($parsed.InstanceSafeName -eq "demo") "canonical WSL port rules should preserve the instance identity."
    Assert-True (Test-WslPortRuleName "swaw-kit-wsl-instance-demo-port-tcp-0.0.0.0-2222") "canonical WSL port rule names should pass identity validation."

    $oldConfig = $script:Config
    try {
        $script:Config = [pscustomobject]@{ Name = "demo" }
        $windowsDisplayName = Get-WslPortRuleDisplayName -Protocol "tcp" -ListenPort 2222 -ConnectPort 22
        $hyperVDisplayName = Get-WslPortRuleDisplayName -Protocol "tcp" -ListenPort 2222
        Assert-True ((Get-WslPortRuleInstanceNameFromDisplayName $windowsDisplayName) -eq "demo") "Windows firewall display names should round-trip through the shared format."
        Assert-True ((Get-WslPortRuleInstanceNameFromDisplayName $hyperVDisplayName) -eq "demo") "Hyper-V firewall display names should round-trip through the shared format."
    } finally {
        $script:Config = $oldConfig
    }

    function Get-WslPortProxyEntries {
        return @()
    }
    $script:SmokePortProxyCalls = 0
    function Remove-WslNatPortProxy {
        param(
            [int]$ListenPort,
            [string]$ListenAddress,
            [switch]$DryRun
        )

        $script:SmokePortProxyCalls += 1
        return 0
    }

    $hyperVItem = [pscustomobject]@{
        Kind          = "hyperv-firewall"
        Id            = "swaw-kit-wsl-instance-demo-port-tcp-0.0.0.0-2222"
        ListenAddress = "0.0.0.0"
        ListenPort    = 2222
    }
    $script:SmokePortProxyCalls = 0
    & { [void](Remove-WslManagedPortItem -Item $hyperVItem -DryRun) } 6>$null
    Assert-True ($script:SmokePortProxyCalls -eq 0) "Hyper-V port dry-run should not delete NAT portproxy."

    $windowsItem = [pscustomobject]@{
        Kind          = "windows-firewall"
        Id            = "swaw-kit-wsl-instance-demo-port-tcp-0.0.0.0-2223"
        ListenAddress = "0.0.0.0"
        ListenPort    = 2223
    }
    $script:SmokePortProxyCalls = 0
    & { [void](Remove-WslManagedPortItem -Item $windowsItem -DryRun) } 6>$null
    Assert-True ($script:SmokePortProxyCalls -eq 1) "Windows firewall port dry-run should delete NAT portproxy."
}
