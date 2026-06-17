function Get-IniSectionLinePattern {
    param([string]$Section)

    $escaped = [regex]::Escape($Section)
    return "^\s*\[$escaped\]\s*(?:[;#].*)?$"
}

function Get-IniAnySectionLinePattern {
    return "^\s*\[[^\]]+\]\s*(?:[;#].*)?$"
}

function Find-IniSectionStart {
    param(
        [string[]]$Lines,
        [string]$Section
    )

    $pattern = Get-IniSectionLinePattern $Section
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $pattern) {
            return $i
        }
    }

    return -1
}

function Find-IniSectionEnd {
    param(
        [string[]]$Lines,
        [int]$Start
    )

    $sectionPattern = Get-IniAnySectionLinePattern
    for ($i = $Start + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $sectionPattern) {
            return ($i - 1)
        }
    }

    return ($Lines.Count - 1)
}

function Test-IniKeyLine {
    param(
        [string]$Line,
        [string]$Key
    )

    $escaped = [regex]::Escape($Key)
    return ($Line -match "^\s*$escaped\s*=")
}

function Update-IniSectionKeys {
    param(
        [string[]]$Lines,
        [string]$Section,
        [System.Collections.IDictionary]$Values
    )

    $result = New-Object System.Collections.ArrayList
    foreach ($line in @($Lines)) {
        [void]$result.Add($line)
    }

    $start = Find-IniSectionStart @($result) $Section
    if ($start -lt 0) {
        if ($result.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($result[$result.Count - 1])) {
            [void]$result.Add("")
        }

        [void]$result.Add("[$Section]")
        foreach ($key in $Values.Keys) {
            [void]$result.Add("$key=$($Values[$key])")
        }
        return @($result)
    }

    $result[$start] = "[$Section]"
    $end = Find-IniSectionEnd @($result) $start
    $seen = @{}
    $insertAt = $end + 1

    for ($i = $start + 1; $i -le $end; $i++) {
        $line = [string]$result[$i]
        $matchedKey = $null
        foreach ($key in $Values.Keys) {
            if (Test-IniKeyLine $line $key) {
                $matchedKey = $key
                break
            }
        }

        if ($null -eq $matchedKey) {
            continue
        }

        if ($seen.ContainsKey($matchedKey)) {
            $result[$i] = $null
            continue
        }

        $result[$i] = "$matchedKey=$($Values[$matchedKey])"
        $seen[$matchedKey] = $true
    }

    foreach ($key in $Values.Keys) {
        if (-not $seen.ContainsKey($key)) {
            $result.Insert($insertAt, "$key=$($Values[$key])")
            $insertAt += 1
        }
    }

    return @($result | Where-Object { $null -ne $_ })
}

function Read-TextFileLinesOrEmpty {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    return @([System.IO.File]::ReadAllLines($Path))
}

function Write-Utf8NoBomLines {
    param(
        [string]$Path,
        [string[]]$Lines
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllLines($Path, @($Lines), $encoding)
}

function New-UniqueBackupPath {
    param([string]$Path)

    for ($i = 0; $i -lt 100; $i++) {
        $stamp = Get-Date -Format "yyyyMMddHHmmssfff"
        $suffix = if ($i -eq 0) { "" } else { ".$i" }
        $candidate = "$Path.bak.$stamp$suffix"
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }

        Start-Sleep -Milliseconds 1
    }

    return "$Path.bak.$([guid]::NewGuid().ToString('N'))"
}

function Remove-OldBackups {
    param(
        [string]$Path,
        [int]$Keep = 3
    )

    if ($Keep -lt 1) {
        return
    }

    $dir = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
        return
    }

    $name = [System.IO.Path]::GetFileName($Path)
    $backups = @(Get-ChildItem -LiteralPath $dir -File -Filter "$name.bak.*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc, Name -Descending)

    if ($backups.Count -le $Keep) {
        return
    }

    foreach ($backup in @($backups | Select-Object -Skip $Keep)) {
        Remove-Item -LiteralPath $backup.FullName -Force
    }
}

function Write-Utf8NoBomLinesAtomic {
    param(
        [string]$Path,
        [string[]]$Lines
    )

    $dir = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $dir = (Get-Location).Path
    }

    Ensure-Directory $dir
    $tempPath = Join-Path $dir (".{0}.tmp.{1}" -f ([System.IO.Path]::GetFileName($Path)), ([guid]::NewGuid().ToString("N")))

    try {
        Write-Utf8NoBomLines $tempPath $Lines
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Update-IniFileSectionKeys {
    param(
        [string]$Path,
        [string]$Section,
        [System.Collections.IDictionary]$Values,
        [switch]$Backup
    )

    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        Ensure-Directory $dir
    }

    $oldLines = Read-TextFileLinesOrEmpty $Path
    $newLines = Update-IniSectionKeys @($oldLines) $Section $Values
    $oldText = ($oldLines -join "`n")
    $newText = ($newLines -join "`n")
    if ($oldText -eq $newText) {
        return [pscustomobject]@{
            Changed = $false
            BackupPath = ""
            Path = $Path
        }
    }

    $backupPath = ""
    if ($Backup -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $backupPath = New-UniqueBackupPath $Path
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
        Remove-OldBackups $Path 3
    }

    Write-Utf8NoBomLinesAtomic $Path $newLines
    return [pscustomobject]@{
        Changed = $true
        BackupPath = $backupPath
        Path = $Path
    }
}
