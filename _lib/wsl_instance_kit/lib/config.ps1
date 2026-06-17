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
        EntryDir       = [System.IO.Path]::GetFullPath($entryDir)
        CommandName    = $commandName
        Verbose        = (Test-Truthy (Get-EnvOrEmpty "WSL_KIT_verbose"))
    }
}

function Get-SupportedWslKitProtocolMajors {
    return @("1")
}

function Get-WslKitProtocolMajor {
    param([string]$Protocol)

    if ([string]::IsNullOrWhiteSpace($Protocol)) {
        return ""
    }

    return ($Protocol.Trim() -split '\.', 2)[0]
}

function Test-WslKitConfig {
    param([pscustomobject]$Config)

    if ([string]::IsNullOrWhiteSpace($Config.Protocol)) {
        Write-Fail "WSL_KIT_PROTOCOL is required in the entry file. Add: set ""WSL_KIT_PROTOCOL=1"""
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
    foreach ($suffix in @(".tar", ".tar.gz", ".tar.xz", ".tgz")) {
        if ($lower.EndsWith($suffix)) {
            return $true
        }
    }

    return $false
}
