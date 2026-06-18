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
            Write-Fail "Do not pass --format to ctl backup. Set WSL_export_format in the entry file instead."
            return $false
        }
    }

    return $true
}


function Export-WslResource {
    param(
        [string[]]$Rest
    )

    if (-not (Test-NoInlineExportFormat $Rest)) {
        return 1
    }

    $format = Resolve-WslExportFormat
    if ($null -eq $format) {
        return 1
    }

    $useGeneratedTarget = $false
    if ($Rest.Count -eq 0) {
        $useGeneratedTarget = $true
        $backupDir = Resolve-EntryPath $script:Config.BackupDir
        if ([string]::IsNullOrWhiteSpace($backupDir)) {
            Write-Fail "No backup path provided and WSL_backup_dir is empty."
            return 1
        }

        Ensure-Directory $backupDir
        $stamp = Get-Date -Format "yyyyMMddHHmmss"
        $target = Join-Path $backupDir ("Backup_{0}_{1}.{2}" -f $script:Config.Name, $stamp, $format.Extension)
    } else {
        if ($Rest.Count -ne 1 -or [string]::IsNullOrWhiteSpace($Rest[0])) {
            Write-Fail "ctl backup accepts either no path or exactly one target path. Set WSL_export_format in the entry file to change format."
            return 1
        }

        $target = $Rest[0]
        $target = Resolve-OutputPath $target
        if (-not (Test-WslBackupArchivePath $target)) {
            Write-Fail "ctl backup target path must end with .tar, .tar.gz, .tar.xz, .tgz, .vhd, or .vhdx."
            return 1
        }
        Ensure-Directory (Split-Path -Parent $target)
    }

    $nativeArgs = @("--export", $script:Config.Name, $target)
    if (-not [string]::IsNullOrWhiteSpace($format.Format)) {
        $nativeArgs += @("--format", $format.Format)
    }

    $exitCode = Invoke-ControlNativeCommand $nativeArgs
    if ($exitCode -eq 0 -and $useGeneratedTarget) {
        Write-Host "Backup archive: $target"
    }

    return $exitCode
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


function Open-WslBackupDir {
    param([string[]]$Rest)

    if ($Rest.Count -ne 0) {
        Write-Fail "ctl dir backup does not accept extra arguments."
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

    if ($Rest.Count -gt 0 -and $Rest[0].ToLowerInvariant() -eq "list") {
        return (Show-WslBackupList -Rest (Get-Slice $Rest 1))
    }

    return (Export-WslResource $Rest)
}
