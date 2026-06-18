function Get-WslDistributionRecord {
    $items = @(Get-WslDistributionRecords)
    return @($items | Where-Object { $_.DistributionName -eq $script:Config.Name } | Select-Object -First 1)[0]
}

function Get-WslDistributionRecords {
    try {
        $items = Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss\*" -ErrorAction SilentlyContinue
        return @($items | Where-Object { -not [string]::IsNullOrWhiteSpace($_.DistributionName) })
    } catch {
        return @()
    }
}

function Get-WslInstalledDistributionNames {
    return @((Get-WslDistributionRecords) | ForEach-Object { [string]$_.DistributionName })
}

function Get-WslInstalledDistributionNameSet {
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(Get-WslInstalledDistributionNames)) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            [void]$set.Add($name)
        }
    }

    return $set
}

function Get-WslBaseArgs {
    param(
        [switch]$NoUser,
        [string]$WorkDir,
        [switch]$NoCd
    )

    $nativeArgs = @("-d", $script:Config.Name)

    if (-not $NoUser -and -not [string]::IsNullOrWhiteSpace($script:Config.User)) {
        $nativeArgs += @("-u", $script:Config.User)
    }

    if (-not $NoCd) {
        $cd = $WorkDir
        if (-not $PSBoundParameters.ContainsKey("WorkDir")) {
            $cd = $script:Config.DefaultWorkdir
        }

        if (-not [string]::IsNullOrWhiteSpace($cd)) {
            $nativeArgs += @("--cd", $cd)
        }
    }

    return $nativeArgs
}

function Invoke-WslShell {
    $nativeArgs = Get-WslBaseArgs
    return Invoke-External "wsl.exe" $nativeArgs
}

function Invoke-WslNativePassthrough {
    param([string[]]$NativeArgs)

    $argsToRun = Get-WslBaseArgs
    $argsToRun += @($NativeArgs)
    return Invoke-External "wsl.exe" $argsToRun
}
