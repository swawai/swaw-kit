function Normalize-WslRelocatePath {
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return $fullPath.TrimEnd([char[]]@([char]92, [char]47))
}


function Test-WslRelocateTargetDirectory {
    param(
        [string]$SourceDir,
        [string]$TargetDir
    )

    if ([string]::IsNullOrWhiteSpace($TargetDir)) {
        Write-Fail "WSL_install_dir is empty."
        return $false
    }

    if ($SourceDir.Equals($TargetDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Fail "Current install dir already matches WSL_install_dir: $TargetDir"
        Write-Fail "Edit WSL_install_dir in $($script:Config.CommandName).cmd to a new location, then run: $($script:Config.CommandName) .relocate"
        return $false
    }

    $sourceChildPrefix = $SourceDir.TrimEnd([char[]]@([char]92, [char]47)) + "\"
    if ($TargetDir.StartsWith($sourceChildPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Fail "WSL_install_dir cannot be inside the current install dir."
        Write-Fail "  Current: $SourceDir"
        Write-Fail "  Target:  $TargetDir"
        return $false
    }

    if (Test-Path -LiteralPath $TargetDir -PathType Leaf) {
        Write-Fail ".relocate target is a file: $TargetDir"
        return $false
    }

    if (Test-Path -LiteralPath $TargetDir -PathType Container) {
        $items = @(Get-ChildItem -LiteralPath $TargetDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($items.Count -gt 0) {
            Write-Fail ".relocate target directory must be empty: $TargetDir"
            return $false
        }
    }

    return $true
}


function New-WslRelocateArchivePath {
    param([pscustomobject]$Format)

    $backupDir = Resolve-EntryPath $script:Config.BackupDir
    if ([string]::IsNullOrWhiteSpace($backupDir)) {
        Write-Fail "WSL_backup_dir is empty."
        return ""
    }

    $stamp = Get-Date -Format "yyyyMMddHHmmss"
    return (Join-Path $backupDir ("Relocate_{0}_{1}.{2}" -f $script:Config.Name, $stamp, $Format.Extension))
}


function Show-WslRelocatePlan {
    param(
        [string]$SourceDir,
        [string]$TargetDir,
        [string]$ArchivePath
    )

    Write-Host "Relocate source:  $SourceDir"
    Write-Host "Relocate target:  $TargetDir"
    Write-Host "Relocate archive: $ArchivePath"
}


function Invoke-WslRelocateUserRestore {
    param([switch]$DryRun)

    $ensureExit = Ensure-WslConfiguredUser -DryRun:$DryRun -AllowEmpty
    if ($ensureExit -ne 0) {
        return $ensureExit
    }

    if ([string]::IsNullOrWhiteSpace($script:Config.User)) {
        return 0
    }

    $defaultUserArgs = @("--manage", $script:Config.Name, "--set-default-user", $script:Config.User)
    if ($DryRun) {
        Show-NativeCommand "wsl.exe" $defaultUserArgs
        return 0
    }

    return (Invoke-ControlNativeCommand $defaultUserArgs)
}


function Invoke-WslRelocate {
    param([string[]]$Rest)

    $dryRun = $false
    foreach ($item in @($Rest)) {
        if ($null -eq $item) {
            continue
        }

        if ($item -eq "--dry-run") {
            $dryRun = $true
            continue
        }

        if ($item.StartsWith("-")) {
            Write-Fail "Unknown .relocate option: $item"
            return 1
        }

        Write-Fail ".relocate does not accept a target path argument."
        Write-Fail "Edit WSL_install_dir in $($script:Config.CommandName).cmd, then run: $($script:Config.CommandName) .relocate"
        return 1
    }

    $record = Get-WslDistributionRecord
    if ($null -eq $record) {
        Write-Fail "WSL instance is not installed: $($script:Config.Name)"
        return 1
    }

    $sourceDir = Normalize-WslRelocatePath $record.BasePath
    if ([string]::IsNullOrWhiteSpace($sourceDir)) {
        Write-Fail "Current WSL BasePath is not available for: $($script:Config.Name)"
        return 1
    }

    $targetDir = Normalize-WslRelocatePath (Resolve-EntryPath $script:Config.InstallDir)
    if (-not (Test-WslRelocateTargetDirectory -SourceDir $sourceDir -TargetDir $targetDir)) {
        return 1
    }

    $format = Resolve-WslExportFormat
    if ($null -eq $format) {
        return 1
    }

    $archivePath = New-WslRelocateArchivePath -Format $format
    if ([string]::IsNullOrWhiteSpace($archivePath)) {
        return 1
    }

    $terminateArgs = @("--terminate", $script:Config.Name)
    $exportArgs = @("--export", $script:Config.Name, $archivePath)
    if (-not [string]::IsNullOrWhiteSpace($format.Format)) {
        $exportArgs += @("--format", $format.Format)
    }
    $unregisterArgs = @("--unregister", $script:Config.Name)
    $importArgs = New-WslImportArgs -InstallDir $targetDir -ArchivePath $archivePath

    Show-WslRelocatePlan -SourceDir $sourceDir -TargetDir $targetDir -ArchivePath $archivePath

    if ($dryRun) {
        Show-NativeCommand "wsl.exe" $terminateArgs
        Show-NativeCommand "wsl.exe" $exportArgs
        Show-NativeCommand "wsl.exe" $unregisterArgs
        Show-NativeCommand "wsl.exe" $importArgs
        [void](Invoke-WslRelocateUserRestore -DryRun)
        return 0
    }

    Ensure-Directory (Split-Path -Parent $archivePath)
    Ensure-Directory $targetDir

    $terminateExit = Invoke-ControlNativeCommand $terminateArgs
    if ($terminateExit -ne 0) {
        return $terminateExit
    }

    $exportExit = Invoke-ControlNativeCommand $exportArgs
    if ($exportExit -ne 0) {
        return $exportExit
    }

    $unregisterExit = Invoke-ControlNativeCommand $unregisterArgs
    if ($unregisterExit -ne 0) {
        return $unregisterExit
    }

    $importExit = Invoke-ControlNativeCommand $importArgs
    if ($importExit -ne 0) {
        return $importExit
    }

    $userExit = Invoke-WslRelocateUserRestore
    if ($userExit -ne 0) {
        return $userExit
    }

    Write-Host "Relocated WSL instance: $($script:Config.Name)"
    return 0
}
