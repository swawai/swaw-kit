. (Join-Path $PSScriptRoot "..\..\editor_kit\launch.ps1")

function Get-WslEditorLaunchArguments {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("code", "cursor")]
        [string]$Editor,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RemoteAuthority,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetPath,

        [switch]$ReuseBootstrapWindow
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    if ($Editor -eq "cursor") {
        $arguments.Add("--classic")
    }
    if ($ReuseBootstrapWindow) {
        $arguments.Add("--reuse-window")
    }
    $arguments.Add("--remote=$RemoteAuthority")
    $arguments.Add($TargetPath)
    return @($arguments)
}

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

    if (Test-Truthy (Get-EnvOrEmpty "WSL_KIT_PARSE_ENTRY_FILE")) {
        Write-Fail ".$Editor cannot run through kit.cmd --entry-file because that mode only reads the entry configuration."
        Write-Fail "Run $($script:Config.EntryFileName) .$Editor so its clean editor bootstrap executes."
        return 1
    }

    if ((Get-EnvOrEmpty "WSL_KIT_ARGS_READY") -ne "1") {
        Write-Fail ".$Editor must run through the configured WSL entry, not the internal kit directly."
        Write-Fail "Run $($script:Config.EntryFileName) .$Editor so its clean editor bootstrap executes."
        return 1
    }

    if ((Get-WslKitProtocolMajor $script:Config.Protocol) -ne "2") {
        Write-Fail "This WSL entry uses protocol $($script:Config.Protocol), which predates the clean editor bootstrap."
        Write-Fail "Update its header from Favorites\template.wsl01.cmd before using .$Editor."
        return 1
    }

    $editorCommand = Get-Command `
        -Name $Editor `
        -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $editorCommand) {
        Write-Fail "Editor command not found: $Editor"
        return 1
    }

    try {
        Assert-EditorKitCommandSupported `
            -Tool $Editor `
            -EditorCommand ([string]$editorCommand.Source)
    } catch {
        Write-Fail $_.Exception.Message
        return 1
    }

    $targetPath = if ($EditorArgs.Count -eq 0) { Resolve-LinuxRemotePath "" } else { Resolve-LinuxRemotePath $EditorArgs[0] }
    $remoteAuthority = "wsl+$($script:Config.Name)"
    $reuseBootstrapWindow = ([string]$env:WIN_RUN_EDITOR_BOOTSTRAP).Equals(
        $Editor,
        [System.StringComparison]::OrdinalIgnoreCase
    )
    $nativeArgs = Get-WslEditorLaunchArguments `
        -Editor $Editor `
        -RemoteAuthority $remoteAuthority `
        -TargetPath $targetPath `
        -ReuseBootstrapWindow:$reuseBootstrapWindow
    return Start-ExternalDetached ([string]$editorCommand.Source) $nativeArgs
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

function Get-WslSettingsExecutablePath {
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
            return $candidate
        }
    }

    return ""
}

function Get-WslSettingsExpectedPath {
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        return (Join-Path $env:ProgramFiles "WSL\wslsettings\wslsettings.exe")
    }

    return "%ProgramFiles%\WSL\wslsettings\wslsettings.exe"
}

function Open-WslSettings {
    $settingsPath = Get-WslSettingsExecutablePath
    if (-not [string]::IsNullOrWhiteSpace($settingsPath)) {
        return Start-ExternalDetached $settingsPath @()
    }

    $expected = Get-WslSettingsExpectedPath
    Write-Fail "WSL Settings app not found: $expected"
    Write-Fail "Install or update WSL, then try: $($script:Config.CommandName) .vm"
    return 1
}

function Open-WslWelcome {
    $settingsPath = Get-WslSettingsExecutablePath
    if (-not [string]::IsNullOrWhiteSpace($settingsPath)) {
        return Start-ExternalDetached $settingsPath @("----ms-protocol:wsl-settings://oobe")
    }

    $expected = Get-WslSettingsExpectedPath
    Write-Fail "WSL Settings app not found: $expected"
    Write-Fail "Install or update WSL, then try: $($script:Config.CommandName) .vm show"
    return 1
}
