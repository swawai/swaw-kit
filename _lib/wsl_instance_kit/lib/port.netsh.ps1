function Get-WslPortProxyEntries {
    $entries = New-Object System.Collections.ArrayList
    try {
        $lines = @(& netsh.exe interface portproxy show v4tov4 2>$null)
        foreach ($line in $lines) {
            $text = ([string]$line).Trim()
            if ($text -match '^(?<listenAddress>\S+)\s+(?<listenPort>\d+)\s+(?<connectAddress>\S+)\s+(?<connectPort>\d+)$') {
                [void]$entries.Add([pscustomobject]@{
                    ListenAddress = $Matches["listenAddress"]
                    ListenPort = [int]$Matches["listenPort"]
                    ConnectAddress = $Matches["connectAddress"]
                    ConnectPort = [int]$Matches["connectPort"]
                })
            }
        }
    } catch {
    }

    return @($entries)
}


function Invoke-WslPortNetsh {
    param(
        [string[]]$CommandArgs,
        [switch]$DryRun
    )

    if ($DryRun) {
        Show-NativeCommand "netsh.exe" $CommandArgs
        return 0
    }

    & netsh.exe @CommandArgs
    if ($null -eq $LASTEXITCODE) {
        return 0
    }

    return [int]$LASTEXITCODE
}


function Remove-WslNatPortProxy {
    param(
        [int]$ListenPort,
        [string]$ListenAddress,
        [switch]$DryRun
    )

    $existing = @(Get-WslPortProxyEntries | Where-Object { $_.ListenPort -eq $ListenPort -and $_.ListenAddress -eq $ListenAddress })
    if ($existing.Count -eq 0 -and -not $DryRun) {
        return 0
    }

    return (Invoke-WslPortNetsh @("interface", "portproxy", "delete", "v4tov4", "listenaddress=$ListenAddress", "listenport=$ListenPort") -DryRun:$DryRun)
}


function Set-WslNatPortProxy {
    param(
        [int]$ListenPort,
        [int]$ConnectPort,
        [string]$ConnectAddress,
        [string]$ListenAddress,
        [switch]$DryRun
    )

    $deleteCode = Remove-WslNatPortProxy -ListenPort $ListenPort -ListenAddress $ListenAddress -DryRun:$DryRun
    if ($deleteCode -ne 0) {
        return $deleteCode
    }

    return (Invoke-WslPortNetsh @("interface", "portproxy", "add", "v4tov4", "listenaddress=$ListenAddress", "listenport=$ListenPort", "connectaddress=$ConnectAddress", "connectport=$ConnectPort") -DryRun:$DryRun)
}

