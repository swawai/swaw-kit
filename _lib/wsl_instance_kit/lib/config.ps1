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
        Systemd        = (Get-EnvOrEmpty "WSL_systemd").Trim()
        SshPort        = (Get-EnvOrEmpty "WSL_SSH_port").Trim()
        SshKey         = (Get-EnvOrEmpty "WSL_SSH_key").Trim()
        NetworkMode    = (Get-EnvOrEmpty "WSL_network_mode").Trim()
        NetworkDnsTunneling = (Get-EnvOrEmpty "WSL_network_dns_tunneling").Trim()
        NetworkAutoProxy    = (Get-EnvOrEmpty "WSL_network_auto_proxy").Trim()
        NetworkHostLoopback = (Get-EnvOrEmpty "WSL_network_host_loopback").Trim()
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
