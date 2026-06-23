function Test-PortInventoryDryRun {
    . (Join-Path $kitRoot "lib\common.ps1")
    . (Join-Path $kitRoot "lib\port.netsh.ps1")
    . (Join-Path $kitRoot "lib\port.inventory.ps1")

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
        Id            = "wsl_instance_kit-demo-port-tcp-0.0.0.0-2222"
        ListenAddress = "0.0.0.0"
        ListenPort    = 2222
    }
    $script:SmokePortProxyCalls = 0
    & { [void](Remove-WslManagedPortItem -Item $hyperVItem -DryRun) } 6>$null
    Assert-True ($script:SmokePortProxyCalls -eq 0) "Hyper-V port dry-run should not delete NAT portproxy."

    $windowsItem = [pscustomobject]@{
        Kind          = "windows-firewall"
        Id            = "wsl_instance_kit-demo-port-tcp-0.0.0.0-2223"
        ListenAddress = "0.0.0.0"
        ListenPort    = 2223
    }
    $script:SmokePortProxyCalls = 0
    & { [void](Remove-WslManagedPortItem -Item $windowsItem -DryRun) } 6>$null
    Assert-True ($script:SmokePortProxyCalls -eq 1) "Windows firewall port dry-run should delete NAT portproxy."
}
