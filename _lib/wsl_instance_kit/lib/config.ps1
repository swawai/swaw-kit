function Expand-WslEntryBatchValue {
    param(
        [string]$Value,
        [string]$EntryFile,
        [System.Collections.IDictionary]$Values
    )

    $entryDir = Split-Path -Parent $EntryFile
    if (-not $entryDir.EndsWith("\")) {
        $entryDir = "$entryDir\"
    }

    $expanded = [regex]::Replace($Value, '(?i)%~dp0', {
        param($Match)
        return $entryDir
    })
    $expanded = [regex]::Replace($expanded, '(?i)%~f0', {
        param($Match)
        return $EntryFile
    })

    return [regex]::Replace($expanded, '%([^%]+)%', {
        param($Match)

        $name = $Match.Groups[1].Value
        if ($Values.Contains($name)) {
            return [string]$Values[$name]
        }

        $envValue = [Environment]::GetEnvironmentVariable($name, "Process")
        if ($null -ne $envValue) {
            return $envValue
        }

        return ""
    })
}

function Import-WslEntryFileEnvironment {
    if (-not (Test-Truthy (Get-EnvOrEmpty "WSL_KIT_PARSE_ENTRY_FILE"))) {
        return
    }

    $entryFile = (Get-EnvOrEmpty "WSL_ENTRY_FILE").Trim()
    if ([string]::IsNullOrWhiteSpace($entryFile)) {
        return
    }

    $entryFile = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($entryFile))
    if (-not (Test-Path -LiteralPath $entryFile -PathType Leaf)) {
        Write-Fail "Entry file not found: $entryFile"
        return
    }

    $values = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    $runtimeNames = @(
        "WSL_ENTRY_FILE",
        "WSL_KIT",
        "WSL_KIT_ARGS_READY",
        "WSL_KIT_ARG_COUNT",
        "WSL_KIT_PARSE_ENTRY_FILE"
    )

    foreach ($line in [System.IO.File]::ReadAllLines($entryFile)) {
        if ($line -match '不要修改下面|DO NOT MODIFY|Do not modify below') {
            break
        }

        foreach ($segment in @($line -split '\s*&\s*')) {
            $name = ""
            $rawValue = ""
            if ($segment -match '(?i)^\s*set\s+"([^=]+)=(.*)"\s*$') {
                $name = $Matches[1]
                $rawValue = $Matches[2]
            } elseif ($segment -match '(?i)^\s*set\s+([^=\s]+)=(.*)$') {
                $name = $Matches[1]
                $rawValue = $Matches[2]
            } else {
                continue
            }

            if (-not $name.StartsWith("WSL_", [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            if ($runtimeNames -contains $name -or $name -like "WSL_KIT_ARG_*") {
                continue
            }

            $values[$name] = Expand-WslEntryBatchValue $rawValue $entryFile $values
        }
    }

    foreach ($key in $values.Keys) {
        [Environment]::SetEnvironmentVariable([string]$key, [string]$values[$key], "Process")
    }
}

function Resolve-WslEnvironmentFilePath {
    $rawPath = (Get-EnvOrEmpty "WSL_env_file").Trim()
    if ([string]::IsNullOrWhiteSpace($rawPath)) {
        return ""
    }

    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($rawPath)
        if ([System.IO.Path]::IsPathRooted($expanded)) {
            return [System.IO.Path]::GetFullPath($expanded)
        }

        $entryFile = (Get-EnvOrEmpty "WSL_ENTRY_FILE").Trim()
        $entryDir = if (-not [string]::IsNullOrWhiteSpace($entryFile)) {
            Split-Path -Parent ([System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($entryFile)))
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
        }

        return [System.IO.Path]::GetFullPath((Join-Path $entryDir $expanded))
    } catch {
        Write-Fail "Invalid WSL_env_file path: $rawPath"
        $reason = if ($null -ne $_.Exception.InnerException) {
            $_.Exception.InnerException.Message
        } else {
            $_.Exception.Message
        }
        Write-Fail $reason
        return $null
    }
}

function Import-WslEnvironmentFile {
    $envFile = Resolve-WslEnvironmentFilePath
    if ($null -eq $envFile) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($envFile)) {
        return $true
    }
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        Write-Fail "Environment file not found: $envFile"
        return $false
    }

    $lineNumber = 0
    foreach ($rawLine in [System.IO.File]::ReadAllLines($envFile)) {
        $lineNumber += 1
        $line = ([string]$rawLine -replace "^\uFEFF", "").Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }

        $equalsIndex = $line.IndexOf("=")
        if ($equalsIndex -le 0) {
            Write-Fail "Invalid environment file line $lineNumber in $envFile. Expected KEY=value."
            return $false
        }

        $name = $line.Substring(0, $equalsIndex).Trim()
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            Write-Fail "Invalid environment variable name on line $lineNumber in ${envFile}: $name"
            return $false
        }

        if ($null -ne [Environment]::GetEnvironmentVariable($name, "Process")) {
            continue
        }

        $value = $line.Substring($equalsIndex + 1).Trim()
        [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }

    return $true
}

function New-WslKitConfig {
    $entryFile = (Get-EnvOrEmpty "WSL_ENTRY_FILE").Trim()
    if (-not [string]::IsNullOrWhiteSpace($entryFile)) {
        $entryFile = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($entryFile))
    }

    $entryDir = if (-not [string]::IsNullOrWhiteSpace($entryFile)) {
        Split-Path -Parent $entryFile
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
    }

    $commandName = if (-not [string]::IsNullOrWhiteSpace($entryFile)) {
        [System.IO.Path]::GetFileNameWithoutExtension($entryFile)
    } else {
        "wsl_instance_kit"
    }
    $entryFileName = if (-not [string]::IsNullOrWhiteSpace($entryFile)) {
        [System.IO.Path]::GetFileName($entryFile)
    } else {
        "$commandName.cmd"
    }

    return [pscustomobject]@{
        Protocol       = (Get-EnvOrEmpty "WSL_KIT_PROTOCOL").Trim()
        EntryFile      = $entryFile
        Name           = (Get-EnvOrEmpty "WSL_name").Trim()
        User           = (Get-EnvOrEmpty "WSL_user").Trim()
        Source         = (Get-EnvOrEmpty "WSL_source").Trim()
        InstallDir     = (Get-EnvOrEmpty "WSL_install_dir").Trim()
        BackupDir      = (Get-EnvOrEmpty "WSL_backup_dir").Trim()
        DefaultWorkdir = (Get-EnvOrEmpty "WSL_default_workdir").Trim()
        Version        = (Get-EnvOrEmpty "WSL_version").Trim()
        ExportFormat   = (Get-EnvOrEmpty "WSL_export_format").Trim()
        SshPublicKey   = (Get-EnvOrEmpty "WSL_SSH_public_key").Trim()
        EnvFile        = (Get-EnvOrEmpty "WSL_env_file").Trim()
        EntryDir       = [System.IO.Path]::GetFullPath($entryDir)
        CommandName    = $commandName
        EntryFileName  = $entryFileName
        Verbose        = (Test-Truthy (Get-EnvOrEmpty "WSL_KIT_verbose"))
    }
}

function Get-SupportedWslKitProtocolMajors {
    return @("1", "2")
}

function Get-WslKitProtocolMajor {
    param([string]$Protocol)

    if ([string]::IsNullOrWhiteSpace($Protocol)) {
        return ""
    }

    return ($Protocol.Trim() -split '\.', 2)[0]
}

function Test-WslDistributionName {
    param([AllowNull()] [string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    return $Name -match '^[A-Za-z0-9._-]+$'
}

function Test-WslKitConfig {
    param([pscustomobject]$Config)

    if ([string]::IsNullOrWhiteSpace($Config.Protocol)) {
        Write-Fail "WSL_KIT_PROTOCOL is required in the entry file. Add: set ""WSL_KIT_PROTOCOL=2"""
        return $false
    }

    $protocolMajor = Get-WslKitProtocolMajor $Config.Protocol
    if ($protocolMajor -notin (Get-SupportedWslKitProtocolMajors)) {
        Write-Fail "Unsupported WSL_KIT_PROTOCOL: $($Config.Protocol). Supported major version(s): $((Get-SupportedWslKitProtocolMajors) -join ', ')."
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Config.Name)) {
        Write-Fail "WSL_name is required in the entry file."
        return $false
    }
    if (-not (Test-WslDistributionName $Config.Name)) {
        Write-Fail "Invalid WSL_name: use only A-Z a-z 0-9 . _ -"
        return $false
    }

    return $true
}

function Resolve-WslSource {
    param([AllowNull()] [string]$Source)

    if ([string]::IsNullOrWhiteSpace($Source)) {
        return ""
    }

    if (Test-WindowsPathLike $Source) {
        return Resolve-EntryPath $Source
    }

    return $Source.Trim()
}

function Test-ArchiveSource {
    param([string]$Source)

    $lower = $Source.ToLowerInvariant()
    foreach ($suffix in @(".tar", ".tar.gz", ".tar.xz", ".tgz", ".vhd", ".vhdx")) {
        if ($lower.EndsWith($suffix)) {
            return $true
        }
    }

    return $false
}
