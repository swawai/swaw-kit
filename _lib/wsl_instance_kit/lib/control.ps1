function Show-WslResourceStatus {
    $source = Resolve-WslSource $script:Config.Source
    $installDir = Resolve-EntryPath $script:Config.InstallDir
    $backupDir = Resolve-EntryPath $script:Config.BackupDir
    $record = Get-WslDistributionRecord

    Write-Host "WSL resource: $($script:Config.CommandName)"
    Write-Host "  WSL_KIT_PROTOCOL:    $($script:Config.Protocol)"
    if (-not [string]::IsNullOrWhiteSpace($script:Config.EntryFile)) {
        Write-Host "  WSL_ENTRY_FILE:      $($script:Config.EntryFile)"
    }
    Write-Host "  WSL_name:            $($script:Config.Name)"
    Write-Host "  WSL_user:            $(if ([string]::IsNullOrWhiteSpace($script:Config.User)) { '(default)' } else { $script:Config.User })"
    Write-Host "  WSL_source:          $source"
    Write-Host "  WSL_install_dir:     $installDir"
    Write-Host "  WSL_backup_dir:      $backupDir"
    Write-Host "  WSL_default_workdir: $(if ([string]::IsNullOrWhiteSpace($script:Config.DefaultWorkdir)) { '(home)' } else { $script:Config.DefaultWorkdir })"
    Write-Host "  WSL_version:         $(if ([string]::IsNullOrWhiteSpace($script:Config.Version)) { '(system default)' } else { $script:Config.Version })"

    if ($null -eq $record) {
        Write-Host "  Installed:           no" -ForegroundColor Yellow
    } else {
        Write-Host "  Installed:           yes" -ForegroundColor Green
        $registryBasePath = if ($record.BasePath) { [System.IO.Path]::GetFullPath($record.BasePath).TrimEnd("\") } else { "" }
        $configuredInstallDir = if ($installDir) { [System.IO.Path]::GetFullPath($installDir).TrimEnd("\") } else { "" }
        if ($registryBasePath -and $registryBasePath -ne $configuredInstallDir) {
            Write-Host "  Registry BasePath:   $($record.BasePath)"
        }
    }

    return 0
}

function Invoke-ControlNativeCommand {
    param(
        [string[]]$NativeArgs
    )

    return (Invoke-External "wsl.exe" $NativeArgs)
}

function Install-WslResource {
    param([string[]]$Rest)

    $dryRun = $Rest -contains "--dry-run"
    $nativeExtra = New-Object System.Collections.ArrayList
    foreach ($item in @($Rest)) {
        if ($null -eq $item -or $item -eq "--dry-run") {
            continue
        }

        [void]$nativeExtra.Add($item)
    }
    $source = Resolve-WslSource $script:Config.Source
    $installDir = Resolve-EntryPath $script:Config.InstallDir

    if ([string]::IsNullOrWhiteSpace($source)) {
        Write-Fail "WSL_source is empty. Set it to a .tar path or an online distro name."
        return 1
    }

    if ([string]::IsNullOrWhiteSpace($installDir)) {
        Write-Fail "WSL_install_dir is empty."
        return 1
    }

    if (Test-ArchiveSource $source) {
        $nativeArgs = @("--import", $script:Config.Name, $installDir, $source)
        if (-not [string]::IsNullOrWhiteSpace($script:Config.Version)) {
            $nativeArgs += @("--version", $script:Config.Version)
        }
        $directoryToEnsure = $installDir
    } else {
        $parentDir = Split-Path -Parent $installDir
        $nativeArgs = @("--install", $source, "--name", $script:Config.Name, "--location", $installDir, "--no-launch")
        if (-not [string]::IsNullOrWhiteSpace($script:Config.Version)) {
            $nativeArgs += @("--version", $script:Config.Version)
        }
        $directoryToEnsure = $parentDir
    }

    $nativeArgs += @($nativeExtra)

    if ($dryRun) {
        Show-NativeCommand "wsl.exe" $nativeArgs
        [void](Ensure-WslConfiguredUser -DryRun -AllowEmpty)
        return 0
    }

    Ensure-Directory $directoryToEnsure
    $exitCode = Invoke-External "wsl.exe" $nativeArgs
    if ($exitCode -ne 0) {
        return $exitCode
    }

    return (Ensure-WslConfiguredUser -AllowEmpty)
}

function Export-WslResource {
    param([string[]]$Rest)

    $target = ""
    $targetIndex = -1
    $nativeExtra = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        if (-not $Rest[$i].StartsWith("-")) {
            $target = $Rest[$i]
            $targetIndex = $i
            break
        }
    }

    for ($i = 0; $i -lt $Rest.Count; $i++) {
        if ($i -eq $targetIndex) {
            continue
        }

        [void]$nativeExtra.Add($Rest[$i])
    }

    if ([string]::IsNullOrWhiteSpace($target)) {
        $backupDir = Resolve-EntryPath $script:Config.BackupDir
        if ([string]::IsNullOrWhiteSpace($backupDir)) {
            Write-Fail "No export path provided and WSL_backup_dir is empty."
            return 1
        }

        Ensure-Directory $backupDir
        $stamp = Get-Date -Format "yyyyMMddHHmmss"
        $target = Join-Path $backupDir ("Backup_{0}_{1}.tar" -f $script:Config.Name, $stamp)
    } else {
        $target = Resolve-OutputPath $target
        Ensure-Directory (Split-Path -Parent $target)
    }

    $nativeArgs = @("--export", $script:Config.Name, $target)
    $nativeArgs += @($nativeExtra)
    return (Invoke-ControlNativeCommand $nativeArgs)
}

function Set-WslDefaultUser {
    param([string[]]$Rest)

    $user = if ($Rest.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Rest[0])) { $Rest[0] } else { $script:Config.User }
    if ([string]::IsNullOrWhiteSpace($user)) {
        Write-Fail "No user provided and WSL_user is empty."
        return 1
    }

    $nativeArgs = @("--manage", $script:Config.Name, "--set-default-user", $user)
    return (Invoke-ControlNativeCommand $nativeArgs)
}

function Require-Yes {
    param(
        [string]$Action,
        [string[]]$Rest
    )

    if ($Rest -contains "--yes") {
        return $true
    }

    Write-Fail "$Action requires --yes."
    return $false
}

function Stop-WslResource {
    $nativeArgs = @("--terminate", $script:Config.Name)
    return (Invoke-ControlNativeCommand $nativeArgs)
}

function Stop-WslGlobal {
    return (Invoke-ControlNativeCommand @("--shutdown"))
}

function Show-ControlUsage {
    param([string]$Verb = "ctl")

    Write-Host "Usage:"
    Write-Host "  $($script:Config.CommandName) $Verb status"
    Write-Host "  $($script:Config.CommandName) $Verb install [--dry-run] [native wsl options...]"
    Write-Host "  $($script:Config.CommandName) $Verb backup"
    Write-Host "  $($script:Config.CommandName) $Verb export <path.tar>"
    Write-Host "  $($script:Config.CommandName) $Verb config"
    Write-Host "  $($script:Config.CommandName) $Verb global config"
    Write-Host "  $($script:Config.CommandName) $Verb user ensure [username]"
    Write-Host "  $($script:Config.CommandName) $Verb user default [username]"
    Write-Host "  $($script:Config.CommandName) $Verb default"
    Write-Host "  $($script:Config.CommandName) $Verb terminate | -t"
    Write-Host "  $($script:Config.CommandName) $Verb global shutdown | global -t"
    Write-Host "  $($script:Config.CommandName) $Verb global network"
    Write-Host "  $($script:Config.CommandName) $Verb systemd enable | disable"
    Write-Host "  $($script:Config.CommandName) $Verb ssh enable [port] | disable"
    Write-Host "  $($script:Config.CommandName) $Verb remove --yes"
    return 0
}

function Invoke-Control {
    param(
        [string[]]$Rest,
        [string]$Verb = "ctl"
    )

    if ($Rest.Count -eq 0 -or $Rest[0] -in @("-h", "--help", "/?", "help")) {
        return Show-ControlUsage $Verb
    }

    $action = $Rest[0].ToLowerInvariant()
    $tail = @(Get-Slice $Rest 1)

    switch ($action) {
        "-t" {
            return Stop-WslResource
        }
        "status" {
            return Show-WslResourceStatus
        }
        "install" {
            return Install-WslResource $tail
        }
        "backup" {
            return Export-WslResource $tail
        }
        "export" {
            return Export-WslResource $tail
        }
        "config" {
            return Open-WslInstanceConfig
        }
        "global" {
            if ($tail.Count -eq 0) {
                [void](Show-ControlUsage $Verb)
                return 1
            }

            $globalAction = $tail[0].ToLowerInvariant()
            switch ($globalAction) {
                "config" {
                    return Open-WslGlobalConfig
                }
                "-t" {
                    return Stop-WslGlobal
                }
                "shutdown" {
                    return Stop-WslGlobal
                }
                "network" {
                    return Set-WslGlobalNetwork
                }
                default {
                    Write-Fail "Unknown control command: $action $globalAction"
                    [void](Show-ControlUsage $Verb)
                    return 1
                }
            }
        }
        "user" {
            if ($tail.Count -eq 0) {
                [void](Show-ControlUsage $Verb)
                return 1
            }

            $userAction = $tail[0].ToLowerInvariant()
            $userTail = @(Get-Slice $tail 1)
            switch ($userAction) {
                "ensure" {
                    return Ensure-WslConfiguredUser $userTail
                }
                "default" {
                    return Set-WslDefaultUser $userTail
                }
                default {
                    Write-Fail "Unknown control command: $action $userAction"
                    [void](Show-ControlUsage $Verb)
                    return 1
                }
            }
        }
        "ssh" {
            if ($tail.Count -eq 0) {
                [void](Show-ControlUsage $Verb)
                return 1
            }

            $sshAction = $tail[0].ToLowerInvariant()
            $sshTail = @(Get-Slice $tail 1)
            switch ($sshAction) {
                "enable" {
                    return Enable-WslSsh $sshTail
                }
                "disable" {
                    return Disable-WslSsh
                }
            }

            Write-Fail "Unknown control command: $action $sshAction"
            [void](Show-ControlUsage $Verb)
            return 1
        }
        "systemd" {
            if ($tail.Count -eq 0) {
                [void](Show-ControlUsage $Verb)
                return 1
            }

            $systemdAction = $tail[0].ToLowerInvariant()
            if ($systemdAction -in @("enable", "disable")) {
                return Set-WslSystemd $systemdAction
            }

            Write-Fail "Unknown control command: $action $systemdAction"
            [void](Show-ControlUsage $Verb)
            return 1
        }
        "default" {
            $nativeArgs = @("--set-default", $script:Config.Name)
            return (Invoke-ControlNativeCommand $nativeArgs)
        }
        "terminate" {
            return Stop-WslResource
        }
        "remove" {
            if (-not (Require-Yes "$Verb remove" $tail)) {
                return 1
            }
            $nativeArgs = @("--unregister", $script:Config.Name)
            return (Invoke-ControlNativeCommand $nativeArgs)
        }
        default {
            Write-Fail "Unknown control command: $action"
            [void](Show-ControlUsage $Verb)
            return 1
        }
    }
}
