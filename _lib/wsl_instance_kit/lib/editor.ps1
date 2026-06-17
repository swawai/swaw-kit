function Get-WslHome {
    $nativeArgs = Get-WslBaseArgs -NoCd
    $nativeArgs += @("--", "sh", "-lc", 'printf "%s" "$HOME"')

    try {
        $output = & wsl.exe @nativeArgs 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($output)) {
            return (($output -join "")).Trim()
        }
    } catch {
    }

    return "~"
}

function Join-LinuxPath {
    param(
        [string]$Base,
        [string]$Relative
    )

    if ([string]::IsNullOrWhiteSpace($Base)) {
        $Base = "~"
    }

    $cleanRelative = $Relative -replace '^[.]/', ''
    if ($cleanRelative -eq ".") {
        return $Base
    }

    if ($Base.EndsWith("/")) {
        return "$Base$cleanRelative"
    }

    return "$Base/$cleanRelative"
}

function Resolve-LinuxWorkdir {
    $workdir = $script:Config.DefaultWorkdir
    if ([string]::IsNullOrWhiteSpace($workdir) -or $workdir -eq "~") {
        return Get-WslHome
    }

    if ($workdir.StartsWith("~/")) {
        return Join-LinuxPath (Get-WslHome) $workdir.Substring(2)
    }

    if ($workdir.StartsWith("/")) {
        return $workdir
    }

    return Join-LinuxPath (Get-WslHome) $workdir
}

function Resolve-LinuxRemotePath {
    param([string]$InputPath)

    if ([string]::IsNullOrWhiteSpace($InputPath)) {
        return Resolve-LinuxWorkdir
    }

    $remoteInput = $InputPath.Trim()
    if ($remoteInput.StartsWith(":")) {
        $remoteInput = $remoteInput.Substring(1)
    }

    if ([string]::IsNullOrWhiteSpace($remoteInput) -or $remoteInput -eq ".") {
        return Resolve-LinuxWorkdir
    }

    if ($remoteInput -eq "~") {
        return Get-WslHome
    }

    if ($remoteInput.StartsWith("~/")) {
        return Join-LinuxPath (Get-WslHome) $remoteInput.Substring(2)
    }

    if ($remoteInput.StartsWith("/")) {
        return $remoteInput
    }

    return Join-LinuxPath (Resolve-LinuxWorkdir) $remoteInput
}

function Open-Editor {
    param(
        [string]$Editor,
        [string[]]$EditorArgs
    )

    if ($EditorArgs.Count -gt 1) {
        Write-Fail "$Editor accepts at most one WSL path in this kit version."
        return 1
    }

    if (-not (Get-Command -Name $Editor -ErrorAction SilentlyContinue)) {
        Write-Fail "Editor command not found: $Editor"
        return 1
    }

    $targetPath = if ($EditorArgs.Count -eq 0) { Resolve-LinuxRemotePath "" } else { Resolve-LinuxRemotePath $EditorArgs[0] }
    $remoteAuthority = "wsl+$($script:Config.Name)"
    $nativeArgs = @("--remote=$remoteAuthority", $targetPath)
    return Start-ExternalDetached $Editor $nativeArgs
}

function Open-WindowsFolder {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Fail "No folder path provided."
        return 1
    }

    return Start-ExternalDetached "explorer.exe" @($Path)
}

function Open-WslInstanceConfig {
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", "test -e /etc/wsl.conf || : > /etc/wsl.conf")
    $exitCode = Invoke-External "wsl.exe" $nativeArgs
    if ($exitCode -ne 0) {
        return $exitCode
    }

    $candidates = @(
        "\\wsl.localhost\$($script:Config.Name)\etc",
        ('\\wsl$\' + $script:Config.Name + '\etc')
    )

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            return Open-WindowsFolder $path
        }
    }

    return Open-WindowsFolder $candidates[0]
}

function Open-WslSettings {
    $candidates = @()
    foreach ($root in @($env:ProgramFiles, $env:ProgramW6432)) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $candidate = Join-Path $root "WSL\wslsettings\wslsettings.exe"
            if ($candidate -notin $candidates) {
                $candidates += $candidate
            }
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return Start-ExternalDetached $candidate @()
        }
    }

    $expected = if ($candidates.Count -gt 0) { $candidates[0] } else { "%ProgramFiles%\WSL\wslsettings\wslsettings.exe" }
    Write-Fail "WSL Settings app not found: $expected"
    Write-Fail "Install or update WSL, then try: $($script:Config.CommandName) ctl settings"
    return 1
}
