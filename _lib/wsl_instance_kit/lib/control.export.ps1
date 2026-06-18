function Resolve-WslExportFormat {
    $rawFormat = $script:Config.ExportFormat
    if ([string]::IsNullOrWhiteSpace($rawFormat)) {
        return [pscustomobject]@{
            Format = ""
            Extension = "tar"
        }
    }

    $format = $rawFormat.Trim().ToLowerInvariant()
    while ($format.StartsWith(".")) {
        $format = $format.Substring(1)
    }

    switch ($format) {
        "tar" {
            return [pscustomobject]@{ Format = "tar"; Extension = "tar" }
        }
        "tar.gz" {
            return [pscustomobject]@{ Format = "tar.gz"; Extension = "tar.gz" }
        }
        "tgz" {
            return [pscustomobject]@{ Format = "tar.gz"; Extension = "tar.gz" }
        }
        "tar.xz" {
            return [pscustomobject]@{ Format = "tar.xz"; Extension = "tar.xz" }
        }
        "vhd" {
            return [pscustomobject]@{ Format = "vhd"; Extension = "vhdx" }
        }
        "vhdx" {
            return [pscustomobject]@{ Format = "vhd"; Extension = "vhdx" }
        }
        default {
            Write-Fail "WSL_export_format must be tar, tar.gz, tar.xz, vhd, or empty."
            return $null
        }
    }
}


function Test-NoInlineExportFormat {
    param([string[]]$Rest)

    foreach ($item in @($Rest)) {
        if ($item -ieq "--format") {
            Write-Fail "Do not pass --format to ctl export/backup. Set WSL_export_format in the entry file instead."
            return $false
        }
    }

    return $true
}


function Export-WslResource {
    param(
        [string[]]$Rest,
        [switch]$UseDefaultTarget
    )

    if (-not (Test-NoInlineExportFormat $Rest)) {
        return 1
    }

    $format = Resolve-WslExportFormat
    if ($null -eq $format) {
        return 1
    }

    if ($UseDefaultTarget) {
        if ($Rest.Count -gt 0) {
            Write-Fail "ctl backup does not accept extra arguments. Set WSL_export_format in the entry file to change backup format."
            return 1
        }
        $backupDir = Resolve-EntryPath $script:Config.BackupDir
        if ([string]::IsNullOrWhiteSpace($backupDir)) {
            Write-Fail "No export path provided and WSL_backup_dir is empty."
            return 1
        }

        Ensure-Directory $backupDir
        $stamp = Get-Date -Format "yyyyMMddHHmmss"
        $target = Join-Path $backupDir ("Backup_{0}_{1}.{2}" -f $script:Config.Name, $stamp, $format.Extension)
    } else {
        if ($Rest.Count -ne 1 -or [string]::IsNullOrWhiteSpace($Rest[0])) {
            Write-Fail "ctl export requires exactly one target path. Set WSL_export_format in the entry file to change format."
            return 1
        }

        $target = $Rest[0]
        $target = Resolve-OutputPath $target
        Ensure-Directory (Split-Path -Parent $target)
    }

    $nativeArgs = @("--export", $script:Config.Name, $target)
    if (-not [string]::IsNullOrWhiteSpace($format.Format)) {
        $nativeArgs += @("--format", $format.Format)
    }

    $exitCode = Invoke-ControlNativeCommand $nativeArgs
    if ($exitCode -eq 0 -and $UseDefaultTarget) {
        Write-Host "Backup archive: $target"
    }

    return $exitCode
}


function Test-WslBackupArchivePath {
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $lower = $Path.Trim().ToLowerInvariant()
    foreach ($suffix in @(".tar", ".tar.gz", ".tar.xz", ".tgz", ".vhd", ".vhdx")) {
        if ($lower.EndsWith($suffix)) {
            return $true
        }
    }

    return $false
}


function Test-WslVhdArchivePath {
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $lower = $Path.Trim().ToLowerInvariant()
    return ($lower.EndsWith(".vhd") -or $lower.EndsWith(".vhdx"))
}


function Get-WslBackupFiles {
    param([string]$BackupDir)

    if ([string]::IsNullOrWhiteSpace($BackupDir) -or -not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $BackupDir -File -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-WslBackupArchivePath -Path $_.Name } |
        Sort-Object LastWriteTimeUtc, Name -Descending)
}


function Show-WslBackupList {
    param([string[]]$Rest)

    if ($Rest.Count -ne 0) {
        Write-Fail "ctl backup list does not accept extra arguments."
        return 1
    }

    $backupDir = Resolve-EntryPath $script:Config.BackupDir
    if ([string]::IsNullOrWhiteSpace($backupDir)) {
        Write-Fail "WSL_backup_dir is empty."
        return 1
    }

    Write-Host "WSL backups: $($script:Config.CommandName)"
    Write-Host "  Directory: $backupDir"

    $files = @(Get-WslBackupFiles $backupDir)
    if ($files.Count -eq 0) {
        Write-Host "  No backup files found."
        return 0
    }

    Write-Host "  Latest first:"
    Write-Host ("  {0,-19} {1,10}  {2}" -f "Modified", "Size", "File")
    foreach ($file in $files) {
        Write-Host ("  {0,-19} {1,10}  {2}" -f $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"), (Format-WslByteSize $file.Length), $file.FullName)
    }

    return 0
}


function Resolve-WslRestoreArchivePath {
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


function Restore-WslResource {
    param([string[]]$Rest)

    $dryRun = $false
    $yes = $false
    $archiveArgs = New-Object System.Collections.ArrayList

    foreach ($item in @($Rest)) {
        if ($item -eq "--dry-run") {
            $dryRun = $true
            continue
        }

        if ($item -eq "--yes") {
            $yes = $true
            continue
        }

        if ($item.StartsWith("-")) {
            Write-Fail "Unknown ctl restore option: $item"
            return 1
        }

        [void]$archiveArgs.Add($item)
    }

    if ($archiveArgs.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$archiveArgs[0])) {
        Write-Fail "ctl restore requires exactly one backup archive path."
        return 1
    }

    $installDir = Resolve-EntryPath $script:Config.InstallDir
    if ([string]::IsNullOrWhiteSpace($installDir)) {
        Write-Fail "WSL_install_dir is empty."
        return 1
    }

    $archivePath = Resolve-WslRestoreArchivePath ([string]$archiveArgs[0])
    if (-not (Test-WslBackupArchivePath $archivePath)) {
        Write-Fail "ctl restore supports .tar, .tar.gz, .tar.xz, .tgz, .vhd, and .vhdx archives."
        return 1
    }

    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        Write-Fail "Backup archive not found: $archivePath"
        return 1
    }

    $record = Get-WslDistributionRecord
    $hasExisting = ($null -ne $record)
    if ($hasExisting -and -not $dryRun -and -not $yes) {
        Write-Fail "ctl restore would unregister the existing instance '$($script:Config.Name)'. Add --yes to confirm."
        return 1
    }

    $importArgs = @("--import", $script:Config.Name, $installDir, $archivePath)
    if (Test-WslVhdArchivePath $archivePath) {
        $importArgs += @("--vhd")
    }

    if (-not [string]::IsNullOrWhiteSpace($script:Config.Version)) {
        $importArgs += @("--version", $script:Config.Version)
    }

    if ($dryRun) {
        if ($hasExisting) {
            Show-NativeCommand "wsl.exe" @("--unregister", $script:Config.Name)
        }
        Show-NativeCommand "wsl.exe" $importArgs
        [void](Ensure-WslConfiguredUser -DryRun -AllowEmpty)
        return 0
    }

    if ($hasExisting) {
        Write-Warn "Unregistering existing WSL instance before restore: $($script:Config.Name)"
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


function Open-WslBackupDir {
    param([string[]]$Rest)

    if ($Rest.Count -ne 0) {
        Write-Fail "ctl backup dir does not accept extra arguments."
        return 1
    }

    $backupDir = Resolve-EntryPath $script:Config.BackupDir
    if ([string]::IsNullOrWhiteSpace($backupDir)) {
        Write-Fail "WSL_backup_dir is empty."
        return 1
    }

    Ensure-Directory $backupDir
    return (Open-WindowsFolder $backupDir)
}


function Invoke-BackupControl {
    param([string[]]$Rest)

    if ($Rest.Count -gt 0 -and $Rest[0].ToLowerInvariant() -eq "dir") {
        return (Open-WslBackupDir -Rest (Get-Slice $Rest 1))
    }

    if ($Rest.Count -gt 0 -and $Rest[0].ToLowerInvariant() -eq "list") {
        return (Show-WslBackupList -Rest (Get-Slice $Rest 1))
    }

    return (Export-WslResource $Rest -UseDefaultTarget)
}
