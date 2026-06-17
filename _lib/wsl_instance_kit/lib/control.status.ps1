function Get-WslDistributionRuntimeInfo {
    param([AllowNull()] [pscustomobject]$Record)

    $fallbackState = "unknown"
    $fallbackVersion = ""
    if ($null -ne $Record) {
        if ($null -ne $Record.Version) {
            $fallbackVersion = [string]$Record.Version
        }

        if ($null -ne $Record.State) {
            switch ([int]$Record.State) {
                1 { $fallbackState = "Stopped" }
                2 { $fallbackState = "Running" }
                default { $fallbackState = "unknown ($($Record.State))" }
            }
        }
    }

    try {
        $lines = @(& wsl.exe --list --verbose 2>$null | ForEach-Object { ($_ -replace "`0", "").Trim() })
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^(?i)NAME\s+STATE\s+VERSION$') {
                continue
            }

            if ($line -match '^\*?\s*(?<name>.+?)\s{2,}(?<state>\S+)\s+(?<version>\d+)\s*$') {
                if ($Matches["name"] -eq $script:Config.Name) {
                    return [pscustomobject]@{
                        State = $Matches["state"]
                        Version = $Matches["version"]
                    }
                }
            }
        }
    } catch {
    }

    return [pscustomobject]@{
        State = $fallbackState
        Version = $fallbackVersion
    }
}


function Get-WslRunningIpAddresses {
    param([string]$State)

    if ($State -ine "Running") {
        return ""
    }

    $scriptText = @'
ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^fe80:' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
if [ -n "$ips" ]; then
    printf '%s\n' "$ips"
    exit 0
fi
if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show scope global 2>/dev/null |
        while IFS= read -r line || [ -n "$line" ]; do
            set -- $line
            addr="$4"
            printf '%s\n' "${addr%%/*}"
        done |
        tr '\n' ' ' |
        sed 's/[[:space:]]*$//'
fi
'@
    $runner = New-Base64ShRunner $scriptText
    $nativeArgs = @("-d", $script:Config.Name, "-u", "root", "--", "sh", "-lc", $runner)
    try {
        $output = & wsl.exe @nativeArgs 2>$null
        if ($LASTEXITCODE -eq 0 -and $null -ne $output) {
            return (($output | ForEach-Object { ($_ -replace "`0", "").Trim() }) -join " ").Trim()
        }
    } catch {
    }

    return ""
}


function Get-WslBackupRoot {
    param([string]$BackupDir)

    if ([string]::IsNullOrWhiteSpace($BackupDir)) {
        return ""
    }

    $parent = Split-Path -Parent $BackupDir
    if ([string]::IsNullOrWhiteSpace($parent)) {
        return ""
    }

    return [System.IO.Path]::GetFullPath($parent)
}


function Get-WslDirectorySizeBytes {
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd("\")
    if ($fullPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [int64]0
    }

    try {
        $total = [int64]0
        Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $total += [int64]$_.Length }
        return $total
    } catch {
        return $null
    }
}


function Format-WslByteSize {
    param([AllowNull()] [object]$Bytes)

    if ($null -eq $Bytes) {
        return "(unknown)"
    }

    $value = [double]([int64]$Bytes)
    $units = @("B", "KB", "MB", "GB", "TB")
    $unitIndex = 0
    while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $value = $value / 1024
        $unitIndex += 1
    }

    if ($unitIndex -eq 0) {
        return ("{0} {1}" -f ([int64]$value), $units[$unitIndex])
    }

    return ("{0:0.0} {1}" -f $value, $units[$unitIndex])
}


function Format-WslDirectorySize {
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return "(not configured)"
    }

    return (Format-WslByteSize (Get-WslDirectorySizeBytes $Path))
}


function Show-WslStorageStatus {
    param([string]$BackupDir)

    $backupRoot = Get-WslBackupRoot $BackupDir
    $downloadDir = Get-WslDownloadDir

    Write-Host "  Backup size:         $(Format-WslDirectorySize $BackupDir) (this instance)"
    Write-Host "  Backup root size:    $(Format-WslDirectorySize $backupRoot) (all instances)"
    Write-Host "  Download cache size: $(Format-WslDirectorySize $downloadDir) (global)"
}


function Show-WslResourceStatus {
    $source = Resolve-WslSource $script:Config.Source
    $installDir = Resolve-EntryPath $script:Config.InstallDir
    $backupDir = Resolve-EntryPath $script:Config.BackupDir
    $record = Get-WslDistributionRecord
    $runtime = $null
    $runtimeIp = ""
    if ($null -ne $record) {
        $runtime = Get-WslDistributionRuntimeInfo $record
        $runtimeIp = Get-WslRunningIpAddresses $runtime.State
    }

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
    Write-Host "  WSL_export_format:   $(if ([string]::IsNullOrWhiteSpace($script:Config.ExportFormat)) { '(native default)' } else { $script:Config.ExportFormat })"

    if ($null -eq $record) {
        Write-Host "  Installed:           no" -ForegroundColor Yellow
    } else {
        Write-Host "  Installed:           yes" -ForegroundColor Green
        if ($null -ne $runtime) {
            $runtimeState = if ([string]::IsNullOrWhiteSpace($runtime.State)) { "unknown" } else { $runtime.State }
            if ($runtimeState -ieq "Running") {
                Write-Host "  Runtime State:       $runtimeState" -ForegroundColor Green
            } elseif ($runtimeState -ieq "Stopped") {
                Write-Host "  Runtime State:       $runtimeState" -ForegroundColor Yellow
            } else {
                Write-Host "  Runtime State:       $runtimeState"
            }

            if (-not [string]::IsNullOrWhiteSpace($runtimeIp)) {
                Write-Host "  Runtime IP:          $runtimeIp"
            } elseif ($runtimeState -ieq "Running") {
                Write-Host "  Runtime IP:          (unknown)"
            } else {
                Write-Host "  Runtime IP:          (not running)"
            }
        }

        $registryBasePath = if ($record.BasePath) { [System.IO.Path]::GetFullPath($record.BasePath).TrimEnd("\") } else { "" }
        $configuredInstallDir = if ($installDir) { [System.IO.Path]::GetFullPath($installDir).TrimEnd("\") } else { "" }
        if ($registryBasePath -and $registryBasePath -ne $configuredInstallDir) {
            Write-Host "  Registry BasePath:   $($record.BasePath)"
        }
    }

    Show-WslStorageStatus $backupDir
    Write-Host "  More status:        $($script:Config.CommandName) status ssh | port | systemd"

    return 0
}


function Show-CommandHelpHint {
    param([AllowNull()] [string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        Write-Fail $Message
    }

    Write-Fail "Run: $($script:Config.CommandName) --help"
    return 1
}


function Invoke-Status {
    param([string[]]$Rest)

    if ($Rest.Count -eq 0) {
        return Show-WslResourceStatus
    }

    $action = $Rest[0].ToLowerInvariant()
    $tail = @(Get-Slice $Rest 1)

    switch ($action) {
        "ssh" {
            if ($tail.Count -ne 0) {
                return Show-CommandHelpHint "status ssh does not accept extra arguments."
            }

            return Show-WslSshStatus
        }
        "port" {
            return Show-WslPortStatus $tail
        }
        "systemd" {
            if ($tail.Count -ne 0) {
                return Show-CommandHelpHint "status systemd does not accept extra arguments."
            }

            return Show-WslSystemdStatus
        }
        default {
            return Show-CommandHelpHint "Unknown status command: $action"
        }
    }
}

