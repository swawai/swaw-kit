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

    return (Invoke-ControlNativeCommand $nativeArgs)
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

    return (Export-WslResource $Rest -UseDefaultTarget)
}

