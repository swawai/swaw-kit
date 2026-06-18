function Open-WslInstallDir {
    param([string[]]$Rest)

    if ($Rest.Count -ne 0) {
        Write-Fail ".dir install does not accept extra arguments."
        return 1
    }

    $installDir = Resolve-EntryPath $script:Config.InstallDir
    if ([string]::IsNullOrWhiteSpace($installDir)) {
        Write-Fail "WSL_install_dir is empty."
        return 1
    }

    Ensure-Directory $installDir
    return (Open-WindowsFolder $installDir)
}

function Resolve-WslInstallArchivePath {
    param([string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }

    $candidates = New-Object System.Collections.ArrayList
    [void]$candidates.Add([System.IO.Path]::GetFullPath((Join-Path (Get-Location) $expanded)))

    $backupDir = Resolve-EntryPath $script:Config.BackupDir
    if (-not [string]::IsNullOrWhiteSpace($backupDir)) {
        [void]$candidates.Add([System.IO.Path]::GetFullPath((Join-Path $backupDir $expanded)))
    }

    foreach ($candidate in @($candidates)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return [string]$candidates[0]
}

function New-WslImportArgs {
    param(
        [string]$InstallDir,
        [string]$ArchivePath
    )

    $importArgs = @("--import", $script:Config.Name, $InstallDir, $ArchivePath)
    if (Test-WslVhdArchivePath $ArchivePath) {
        $importArgs += @("--vhd")
    }

    if (-not [string]::IsNullOrWhiteSpace($script:Config.Version)) {
        $importArgs += @("--version", $script:Config.Version)
    }

    return $importArgs
}

function Install-WslResourceFromArchive {
    param(
        [string]$ArchivePath,
        [switch]$DryRun,
        [switch]$Yes
    )

    $installDir = Resolve-EntryPath $script:Config.InstallDir
    if ([string]::IsNullOrWhiteSpace($installDir)) {
        Write-Fail "WSL_install_dir is empty."
        return 1
    }

    if (-not (Test-WslBackupArchivePath $ArchivePath)) {
        Write-Fail ".install supports .tar, .tar.gz, .tar.xz, .tgz, .vhd, and .vhdx archives."
        return 1
    }

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        Write-Fail "Install archive not found: $ArchivePath"
        return 1
    }

    $record = Get-WslDistributionRecord
    $hasExisting = ($null -ne $record)
    if ($hasExisting -and -not $DryRun -and -not $Yes) {
        Write-Fail ".install would unregister the existing instance '$($script:Config.Name)'. Add --yes to rebuild it."
        return 1
    }

    $importArgs = New-WslImportArgs -InstallDir $installDir -ArchivePath $ArchivePath

    if ($DryRun) {
        if ($hasExisting) {
            Show-NativeCommand "wsl.exe" @("--unregister", $script:Config.Name)
        }
        Show-NativeCommand "wsl.exe" $importArgs
        [void](Ensure-WslConfiguredUser -DryRun -AllowEmpty)
        return 0
    }

    if ($hasExisting) {
        Write-Warn "Unregistering existing WSL instance before install: $($script:Config.Name)"
        $removeExit = Invoke-ControlNativeCommand @("--unregister", $script:Config.Name)
        if ($removeExit -ne 0) {
            return $removeExit
        }
    }

    Ensure-Directory $installDir
    $importExit = Invoke-ControlNativeCommand $importArgs
    if ($importExit -ne 0) {
        return $importExit
    }

    return (Ensure-WslConfiguredUser -AllowEmpty)
}

function Install-WslResource {
    param([string[]]$Rest)

    $dryRun = $false
    $yes = $false
    $sourceArgs = New-Object System.Collections.ArrayList
    foreach ($item in @($Rest)) {
        if ($null -eq $item) {
            continue
        }

        if ($item -eq "--dry-run") {
            $dryRun = $true
            continue
        }

        if ($item -eq "--yes") {
            $yes = $true
            continue
        }

        if ($item.StartsWith("-")) {
            Write-Fail "Unknown .install option: $item"
            return 1
        }

        [void]$sourceArgs.Add($item)
    }

    if ($sourceArgs.Count -gt 1) {
        Write-Fail ".install accepts at most one archive path."
        return 1
    }

    if ($sourceArgs.Count -eq 1) {
        $archivePath = Resolve-WslInstallArchivePath ([string]$sourceArgs[0])
        return (Install-WslResourceFromArchive -ArchivePath $archivePath -DryRun:$dryRun -Yes:$yes)
    }

    $source = Resolve-WslSource $script:Config.Source
    if ([string]::IsNullOrWhiteSpace($source)) {
        Write-Fail "WSL_source is empty. Set it to an archive path or an online distro name."
        return 1
    }

    if (Test-ArchiveSource $source) {
        return (Install-WslResourceFromArchive -ArchivePath $source -DryRun:$dryRun -Yes:$yes)
    }

    $installDir = Resolve-EntryPath $script:Config.InstallDir

    if ([string]::IsNullOrWhiteSpace($installDir)) {
        Write-Fail "WSL_install_dir is empty."
        return 1
    }

    $record = Get-WslDistributionRecord
    $hasExisting = ($null -ne $record)
    if ($hasExisting -and -not $dryRun -and -not $yes) {
        Write-Fail ".install would unregister the existing instance '$($script:Config.Name)'. Add --yes to rebuild it."
        return 1
    }

    $parentDir = Split-Path -Parent $installDir
    $nativeArgs = @("--install", $source, "--name", $script:Config.Name, "--location", $installDir, "--no-launch")
    if (-not [string]::IsNullOrWhiteSpace($script:Config.Version)) {
        $nativeArgs += @("--version", $script:Config.Version)
    }

    if ($dryRun) {
        if ($hasExisting) {
            Show-NativeCommand "wsl.exe" @("--unregister", $script:Config.Name)
        }
        Show-NativeCommand "wsl.exe" $nativeArgs
        Write-Host "If native install fails, .install will automatically try fallback install from DistributionInfo.json."
        [void](Ensure-WslConfiguredUser -DryRun -AllowEmpty)
        return 0
    }

    if ($hasExisting) {
        Write-Warn "Unregistering existing WSL instance before install: $($script:Config.Name)"
        $removeExit = Invoke-ControlNativeCommand @("--unregister", $script:Config.Name)
        if ($removeExit -ne 0) {
            return $removeExit
        }
    }

    Ensure-Directory $parentDir
    $exitCode = Invoke-External "wsl.exe" $nativeArgs
    if ($exitCode -ne 0) {
        Write-Warn "Native wsl --install failed. Trying fallback install..."
        return (Install-WslResourceFallback)
    }

    return (Ensure-WslConfiguredUser -AllowEmpty)
}
