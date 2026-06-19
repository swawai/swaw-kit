function Test-WslDoctorNative {
    Write-WslDoctorSection "Native WSL"

    $command = Get-Command "wsl.exe" -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        Add-WslDoctorFail "wsl.exe" "not found in PATH" "Install or repair WSL before running this entry."
        return [pscustomobject]@{
            Available = $false
            Help = $null
            Status = $null
            Version = $null
            List = $null
        }
    }

    Add-WslDoctorOk "wsl.exe" $command.Source

    $status = Invoke-WslNativeTextCommand @("--status")
    if ($status.ExitCode -eq 0) {
        $detail = Format-WslDoctorLines $status.Output
        Add-WslDoctorOk "wsl --status" "readable" $detail
    } else {
        $detail = Format-WslDoctorLines @($status.Error + $status.Output)
        Add-WslDoctorFail "wsl --status" "failed with exit code $($status.ExitCode)" $detail
    }

    $version = Invoke-WslNativeTextCommand @("--version")
    if ($version.ExitCode -eq 0 -and $version.Output.Count -gt 0) {
        Add-WslDoctorOk "wsl --version" "readable" (Format-WslDoctorLines $version.Output)
    } elseif ($version.ExitCode -eq 0) {
        Add-WslDoctorWarn "wsl --version" "no version text returned" "This can happen with a mock or older WSL build."
    } else {
        Add-WslDoctorWarn "wsl --version" "unavailable" "Older inbox WSL builds may not support --version."
    }

    $list = Invoke-WslNativeTextCommand @("--list", "--verbose")
    $distros = @()
    if ($list.ExitCode -eq 0) {
        $distros = @(ConvertFrom-WslVerboseList $list.Output)
        Add-WslDoctorOk "wsl --list --verbose" "readable; $($distros.Count) instance(s)"
    } else {
        Add-WslDoctorFail "wsl --list --verbose" "failed with exit code $($list.ExitCode)" (Format-WslDoctorLines @($list.Error + $list.Output))
    }

    $help = Invoke-WslNativeTextCommand @("--help")
    if (($help.Output.Count + $help.Error.Count) -gt 0) {
        $helpText = (@($help.Output + $help.Error) -join "`n")
        if ($help.ExitCode -eq 0) {
            Add-WslDoctorOk "wsl --help" "readable"
        } else {
            Add-WslDoctorOk "wsl --help" "readable; returned exit code $($help.ExitCode)"
        }
        foreach ($option in @("--install", "--import", "--export", "--manage")) {
            if ($helpText.IndexOf($option, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Add-WslDoctorOk "wsl capability $option" "listed in --help"
            } else {
                Add-WslDoctorWarn "wsl capability $option" "not listed in --help" "This WSL build may be old; try updating WSL if related commands fail."
            }
        }
    } else {
        Add-WslDoctorWarn "wsl --help" "unavailable" "Capability checks skipped."
    }

    return [pscustomobject]@{
        Available = $true
        Help = $help
        Status = $status
        Version = $version
        List = $list
        Distros = $distros
    }
}

function Add-WslDoctorCommandScriptLineEndingStatus {
    param([pscustomobject]$Status)

    if ($null -eq $Status -or [string]::IsNullOrWhiteSpace($Status.Path) -or $Status.Status -eq "not found") {
        return
    }

    $label = "$($Status.Label) line endings"
    if ($Status.Warning) {
        Add-WslDoctorWarn $label $Status.Message $Status.Path
    } else {
        Add-WslDoctorOk $label $Status.Message $Status.Path
    }
}


function Test-WslDoctorEntryConfig {
    Write-WslDoctorSection "Entry config"

    if ([string]::IsNullOrWhiteSpace($script:Config.EntryFile)) {
        Add-WslDoctorWarn "WSL_ENTRY_FILE" "not set" "The kit is not running from an entry file."
    } elseif (Test-Path -LiteralPath $script:Config.EntryFile -PathType Leaf) {
        Add-WslDoctorOk "WSL_ENTRY_FILE" $script:Config.EntryFile
        Add-WslDoctorCommandScriptLineEndingStatus (Get-CommandScriptLineEndingStatus "WSL_ENTRY_FILE" $script:Config.EntryFile)
    } else {
        Add-WslDoctorFail "WSL_ENTRY_FILE" "not found: $($script:Config.EntryFile)"
    }

    $protocolMajor = Get-WslKitProtocolMajor $script:Config.Protocol
    if ([string]::IsNullOrWhiteSpace($script:Config.Protocol)) {
        Add-WslDoctorFail "WSL_KIT_PROTOCOL" "empty"
    } elseif ($protocolMajor -in (Get-SupportedWslKitProtocolMajors)) {
        Add-WslDoctorOk "WSL_KIT_PROTOCOL" $script:Config.Protocol
    } else {
        Add-WslDoctorFail "WSL_KIT_PROTOCOL" "unsupported: $($script:Config.Protocol)"
    }

    $kitPath = (Get-EnvOrEmpty "WSL_KIT").Trim()
    if ([string]::IsNullOrWhiteSpace($kitPath)) {
        $kitPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\kit.cmd"))
    } else {
        $kitPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($kitPath))
    }

    if (Test-Path -LiteralPath $kitPath -PathType Leaf) {
        Add-WslDoctorOk "WSL_KIT" $kitPath
        Add-WslDoctorCommandScriptLineEndingStatus (Get-CommandScriptLineEndingStatus "WSL_KIT" $kitPath)
    } else {
        Add-WslDoctorFail "WSL_KIT" "kit.cmd not found: $kitPath"
    }

    if ([string]::IsNullOrWhiteSpace($script:Config.Name)) {
        Add-WslDoctorFail "WSL_name" "empty"
    } elseif ($script:Config.Name -match '[<>:"/\\|?*\x00-\x1F]') {
        Add-WslDoctorFail "WSL_name" "contains characters Windows paths and WSL names should avoid"
    } else {
        Add-WslDoctorOk "WSL_name" $script:Config.Name
    }

    if ([string]::IsNullOrWhiteSpace($script:Config.User)) {
        Add-WslDoctorWarn "WSL_user" "empty; native default user will be used"
    } else {
        Add-WslDoctorOk "WSL_user" $script:Config.User
    }

    $installDir = Resolve-EntryPath $script:Config.InstallDir
    if ([string]::IsNullOrWhiteSpace($installDir)) {
        Add-WslDoctorFail "WSL_install_dir" "empty"
    } else {
        Add-WslDoctorOk "WSL_install_dir" $installDir
    }

    $backupDir = Resolve-EntryPath $script:Config.BackupDir
    if ([string]::IsNullOrWhiteSpace($backupDir)) {
        Add-WslDoctorWarn "WSL_backup_dir" "empty; backup needs an explicit path"
    } else {
        Add-WslDoctorOk "WSL_backup_dir" $backupDir
    }

    if ([string]::IsNullOrWhiteSpace($script:Config.Version)) {
        Add-WslDoctorOk "WSL_version" "system default"
    } elseif ($script:Config.Version -in @("1", "2")) {
        Add-WslDoctorOk "WSL_version" $script:Config.Version
    } else {
        Add-WslDoctorFail "WSL_version" "must be 1, 2, or empty"
    }

    $format = $script:Config.ExportFormat.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($format)) {
        Add-WslDoctorOk "WSL_export_format" "native default"
    } elseif ($format -in @("tar", "tar.gz", "tgz", "tar.xz", "vhd", "vhdx")) {
        Add-WslDoctorOk "WSL_export_format" $script:Config.ExportFormat
    } else {
        Add-WslDoctorFail "WSL_export_format" "must be tar, tar.gz, tar.xz, vhd, or empty"
    }

    if ([string]::IsNullOrWhiteSpace($script:Config.SshPublicKey)) {
        Add-WslDoctorWarn "WSL_SSH_public_key" "empty; .sshd enable will not install a public key"
    } else {
        $expanded = [Environment]::ExpandEnvironmentVariables($script:Config.SshPublicKey.Trim())
        if (-not [System.IO.Path]::IsPathRooted($expanded)) {
            $expanded = [System.IO.Path]::GetFullPath((Join-Path $script:Config.EntryDir $expanded))
        } else {
            $expanded = [System.IO.Path]::GetFullPath($expanded)
        }

        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            try {
                $line = @([System.IO.File]::ReadAllLines($expanded) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)[0]
                if ($line -match '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)\s+\S+') {
                    Add-WslDoctorOk "WSL_SSH_public_key" $expanded
                } else {
                    Add-WslDoctorWarn "WSL_SSH_public_key" "file exists but does not look like an OpenSSH public key" $expanded
                }
            } catch {
                Add-WslDoctorWarn "WSL_SSH_public_key" "file exists but could not be read" $expanded
            }
        } else {
            Add-WslDoctorWarn "WSL_SSH_public_key" "not found" $expanded
        }
    }

    return [pscustomobject]@{
        InstallDir = $installDir
        BackupDir = $backupDir
    }
}


function Test-WslDoctorSource {
    Write-WslDoctorSection "Install source"

    $source = Resolve-WslSource $script:Config.Source
    if ([string]::IsNullOrWhiteSpace($source)) {
        Add-WslDoctorFail "WSL_source" "empty"
        return [pscustomobject]@{
            Source = ""
            Type = "empty"
            DistributionInfo = $null
            FallbackDownload = $null
        }
    }

    $type = "distro"
    if (Test-ArchiveSource $source) {
        $type = "archive"
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $size = Format-WslDoctorByteSize ([int64](Get-Item -LiteralPath $source).Length)
            Add-WslDoctorOk "WSL_source" "archive file: $source ($size)"
        } else {
            Add-WslDoctorFail "WSL_source" "archive file not found: $source"
        }
    } elseif (Test-WindowsPathLike $source) {
        $type = "path"
        Add-WslDoctorFail "WSL_source" "looks like a Windows path but is not a supported archive" "Supported archive suffixes: .tar, .tar.gz, .tar.xz, .tgz"
    } else {
        Add-WslDoctorOk "WSL_source" "online distribution name: $source"
    }

    $distributionInfo = Read-WslDoctorDistributionInfo
    if ($null -eq $distributionInfo) {
        Add-WslDoctorFail "DistributionInfo.json" "not readable: $script:WslDistributionInfoPath"
    } else {
        Add-WslDoctorOk "DistributionInfo.json" $script:WslDistributionInfoPath
    }

    $fallbackDownload = $null
    if ($type -eq "distro") {
        $archKey = Get-WslDoctorInstallArchitectureKey
        if ([string]::IsNullOrWhiteSpace($archKey)) {
            Add-WslDoctorFail "fallback architecture" "unsupported Windows architecture"
        } else {
            Add-WslDoctorOk "fallback architecture" $archKey
        }

        $fallbackDownload = Get-WslDoctorFallbackDownload $distributionInfo $source
        if ($null -eq $fallbackDownload) {
            Add-WslDoctorWarn "install fallback" "distribution not found in DistributionInfo.json"
        } else {
            $detail = "URL: $($fallbackDownload.Url)"
            if (-not [string]::IsNullOrWhiteSpace($fallbackDownload.Sha256)) {
                $detail = "$detail`nSHA256: $(Normalize-Sha256Text $fallbackDownload.Sha256)"
            }
            Add-WslDoctorOk "install fallback" "$($fallbackDownload.Name)" $detail

            $downloadDir = Get-WslDownloadDir
            $fileName = "{0}_{1}" -f (Get-SafeFileName $fallbackDownload.Name), (Get-FileNameFromUrl $fallbackDownload.Url)
            $cachePath = Join-Path $downloadDir $fileName
            if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
                $size = Format-WslDoctorByteSize ([int64](Get-Item -LiteralPath $cachePath).Length)
                $sidecar = Get-WslImageHashPath $cachePath
                if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
                    Add-WslDoctorOk "fallback cache" "$cachePath ($size)"
                } else {
                    Add-WslDoctorWarn "fallback cache" "image exists but .sha256 sidecar is missing" $cachePath
                }
            } else {
                Add-WslDoctorOk "fallback cache" "no cached image yet"
            }
        }
    } else {
        Add-WslDoctorOk "install fallback" "not needed for archive source"
    }

    return [pscustomobject]@{
        Source = $source
        Type = $type
        DistributionInfo = $distributionInfo
        FallbackDownload = $fallbackDownload
    }
}


function Test-WslDoctorInstance {
    param([string]$InstallDir)

    Write-WslDoctorSection "Instance runtime"

    $record = Get-WslDistributionRecord
    if ($null -eq $record) {
        Add-WslDoctorWarn "installed instance" "not registered: $($script:Config.Name)" "Run: $($script:Config.CommandName) .install"
        if (-not [string]::IsNullOrWhiteSpace($InstallDir) -and (Test-Path -LiteralPath $InstallDir -PathType Container)) {
            $children = @(Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($children.Count -gt 0) {
                Add-WslDoctorWarn "WSL_install_dir" "directory exists but instance is not registered" $InstallDir
            }
        }
        return [pscustomobject]@{
            Record = $null
            Runtime = $null
            RuntimeIp = ""
        }
    }

    Add-WslDoctorOk "installed instance" "registered"

    if (-not [string]::IsNullOrWhiteSpace($record.BasePath)) {
        $registryBasePath = [System.IO.Path]::GetFullPath($record.BasePath).TrimEnd("\")
        $configuredInstallDir = if ([string]::IsNullOrWhiteSpace($InstallDir)) { "" } else { [System.IO.Path]::GetFullPath($InstallDir).TrimEnd("\") }
        if (-not [string]::IsNullOrWhiteSpace($configuredInstallDir) -and $registryBasePath -ne $configuredInstallDir) {
            Add-WslDoctorWarn "Registry BasePath" "does not match WSL_install_dir" "Registry: $registryBasePath`nConfig:   $configuredInstallDir"
        } else {
            Add-WslDoctorOk "Registry BasePath" $registryBasePath
        }
    }

    $runtime = Get-WslDistributionRuntimeInfo $record
    $state = if ($null -eq $runtime -or [string]::IsNullOrWhiteSpace($runtime.State)) { "unknown" } else { $runtime.State }
    if ($state -ieq "Running") {
        Add-WslDoctorOk "runtime state" $state
    } elseif ($state -ieq "Stopped") {
        Add-WslDoctorOk "runtime state" $state
    } else {
        Add-WslDoctorWarn "runtime state" $state
    }

    if ($null -ne $runtime -and -not [string]::IsNullOrWhiteSpace($runtime.Version)) {
        Add-WslDoctorOk "runtime WSL version" "WSL$($runtime.Version)"
    }

    $runtimeIp = ""
    if ($state -ieq "Running") {
        $runtimeIp = Get-WslRunningIpAddresses $state
        if ([string]::IsNullOrWhiteSpace($runtimeIp)) {
            Add-WslDoctorWarn "runtime IP" "running but IP was not readable"
        } else {
            Add-WslDoctorOk "runtime IP" $runtimeIp
        }
    } else {
        Add-WslDoctorWarn "runtime IP" "not checked because the instance is not running"
    }

    return [pscustomobject]@{
        Record = $record
        Runtime = $runtime
        RuntimeIp = $runtimeIp
    }
}


function Test-WslDoctorDirectory {
    param(
        [string]$Label,
        [AllowNull()] [string]$Path,
        [switch]$Required,
        [switch]$ShowSize
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        if ($Required) {
            Add-WslDoctorFail $Label "not configured"
        } else {
            Add-WslDoctorWarn $Label "not configured"
        }
        return
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $exists = Test-Path -LiteralPath $fullPath -PathType Container
    $probeDir = if ($exists) { $fullPath } else { Get-WslDoctorNearestExistingDirectory (Split-Path -Parent $fullPath) }

    if ([string]::IsNullOrWhiteSpace($probeDir)) {
        Add-WslDoctorFail $Label "no existing parent directory" $fullPath
        return
    }

    $writable = Test-WslDoctorDirectoryWritable $probeDir
    if (-not $writable) {
        Add-WslDoctorFail $Label "not writable" "Path: $fullPath`nProbe directory: $probeDir"
        return
    }

    $free = Get-WslDoctorDriveFreeSpace $fullPath
    $freeText = if ($null -eq $free) { "free space unknown" } else { "$(Format-WslDoctorByteSize $free) free" }
    $state = if ($exists) { "exists" } else { "can be created" }
    $message = "$state; $freeText"

    if ($ShowSize) {
        $size = Format-WslDirectorySize $fullPath
        $message = "$message; size $size"
    }

    Add-WslDoctorOk $Label $message $fullPath
}


function Test-WslDoctorStorage {
    param([pscustomobject]$EntryInfo)

    Write-WslDoctorSection "Storage"

    Test-WslDoctorDirectory "install directory" $EntryInfo.InstallDir -Required
    Test-WslDoctorDirectory "backup directory" $EntryInfo.BackupDir -ShowSize

    $backupRoot = Get-WslBackupRoot $EntryInfo.BackupDir
    Test-WslDoctorDirectory "backup root" $backupRoot -ShowSize

    $downloadDir = Get-WslDownloadDir
    Test-WslDoctorDirectory "download cache" $downloadDir -ShowSize
}


function Test-WslDoctorPlatform {
    Write-WslDoctorSection "Windows platform"

    $hypervisorPresent = $null
    $hypervisorError = ""
    try {
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $hypervisorPresent = [bool]$computer.HypervisorPresent
    } catch {
        $hypervisorError = $_.Exception.Message
    }

    $isAdmin = Test-WslDoctorCurrentUserIsAdmin
    if ($isAdmin) {
        Add-WslDoctorOk "elevation" "running as administrator"
    } else {
        Add-WslDoctorOk "elevation" "not elevated; only feature changes require an administrator shell"
    }

    $wslFeature = Get-WslDoctorFeatureState "Microsoft-Windows-Subsystem-Linux"
    if ([string]::IsNullOrWhiteSpace($wslFeature.State)) {
        if ($wslFeature.NeedsElevation) {
            Add-WslDoctorOk "Windows feature WSL" "not checked; elevation required to read optional feature state" $wslFeature.Reason
        } else {
            Add-WslDoctorWarn "Windows feature WSL" "state unavailable" $wslFeature.Reason
        }
    } elseif ($wslFeature.State -ieq "Enabled") {
        Add-WslDoctorOk "Windows feature WSL" $wslFeature.State
    } else {
        Add-WslDoctorFail "Windows feature WSL" $wslFeature.State "Enable in an elevated shell:`ndism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart"
    }

    $vmpFeature = Get-WslDoctorFeatureState "VirtualMachinePlatform"
    $needsWsl2 = ([string]::IsNullOrWhiteSpace($script:Config.Version) -or $script:Config.Version -eq "2")
    if ([string]::IsNullOrWhiteSpace($vmpFeature.State)) {
        if ($vmpFeature.NeedsElevation) {
            Add-WslDoctorOk "Windows feature VirtualMachinePlatform" "not checked; elevation required to read optional feature state" $vmpFeature.Reason
        } else {
            Add-WslDoctorWarn "Windows feature VirtualMachinePlatform" "state unavailable" $vmpFeature.Reason
        }
    } elseif ($vmpFeature.State -ieq "Enabled") {
        Add-WslDoctorOk "Windows feature VirtualMachinePlatform" $vmpFeature.State
    } elseif ($needsWsl2) {
        Add-WslDoctorFail "Windows feature VirtualMachinePlatform" $vmpFeature.State "Enable in an elevated shell:`ndism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart"
    } else {
        Add-WslDoctorWarn "Windows feature VirtualMachinePlatform" "$($vmpFeature.State); required for WSL2"
    }

    $hyperVFeature = Get-WslDoctorFeatureState "Microsoft-Hyper-V-All"
    if ([string]::IsNullOrWhiteSpace($hyperVFeature.State)) {
        if ($hyperVFeature.NeedsElevation) {
            Add-WslDoctorOk "Windows feature Hyper-V" "not checked; full Hyper-V is not required for normal WSL2" $hyperVFeature.Reason
        } else {
            Add-WslDoctorWarn "Windows feature Hyper-V" "state unavailable; full Hyper-V is not always required for WSL2" $hyperVFeature.Reason
        }
    } elseif ($hyperVFeature.State -ieq "Enabled") {
        Add-WslDoctorOk "Windows feature Hyper-V" "$($hyperVFeature.State)"
    } else {
        Add-WslDoctorOk "Windows feature Hyper-V" "$($hyperVFeature.State); full Hyper-V is not required for normal WSL2"
    }

    $rebootSignals = @(Get-WslDoctorRebootPendingSignals)
    if ($rebootSignals.Count -gt 0) {
        Add-WslDoctorWarn "pending reboot" "Windows reports a reboot may be pending" ($rebootSignals -join "`n")
    } else {
        Add-WslDoctorOk "pending reboot" "none detected"
    }

    try {
        $processors = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
        $virtValues = @($processors | ForEach-Object { $_.VirtualizationFirmwareEnabled })
        $slatValues = @($processors | ForEach-Object { $_.SecondLevelAddressTranslationExtensions })

        if ($virtValues.Count -gt 0 -and ($virtValues -notcontains $false) -and ($virtValues -notcontains $null)) {
            Add-WslDoctorOk "CPU virtualization" "enabled in firmware"
        } elseif ($virtValues -contains $false) {
            Add-WslDoctorFail "CPU virtualization" "disabled in firmware" "Enable Intel VT-x / AMD-V in BIOS/UEFI for WSL2."
        } else {
            Add-WslDoctorWarn "CPU virtualization" "unreadable via CIM" "If WSL2 fails, check Intel VT-x / AMD-V in BIOS/UEFI."
        }

        if ($slatValues.Count -gt 0 -and ($slatValues -notcontains $false) -and ($slatValues -notcontains $null)) {
            Add-WslDoctorOk "CPU SLAT" "available"
        } elseif ($hypervisorPresent -eq $true) {
            # Some systems report this CIM field incorrectly after the hypervisor is active.
        } else {
            Add-WslDoctorWarn "CPU SLAT" "not available or unreadable via CIM" "SLAT is required for WSL2/Hyper-V, but this CIM field is not a strong signal by itself."
        }
    } catch {
        Add-WslDoctorWarn "CPU virtualization" "CIM query failed" $_.Exception.Message
    }

    if ($hypervisorPresent -eq $true) {
        Add-WslDoctorOk "Windows hypervisor" "present"
    } elseif ($hypervisorPresent -eq $false) {
        Add-WslDoctorWarn "Windows hypervisor" "not currently present" "If WSL2 fails after enabling features, reboot Windows."
    } else {
        Add-WslDoctorWarn "Windows hypervisor" "CIM query failed" $hypervisorError
    }
}


function Test-WslDoctorNetworking {
    param([pscustomobject]$InstanceInfo)

    Write-WslDoctorSection "Networking and ports"

    $network = Get-WslConfiguredNetworkingMode
    switch ($network.Mode) {
        "nat" {
            Add-WslDoctorOk "networkingMode" "nat ($($network.Source))" $network.Path
        }
        "mirrored" {
            if (Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
                Add-WslDoctorOk "networkingMode" "mirrored ($($network.Source)); Hyper-V firewall cmdlets available" $network.Path
            } else {
                Add-WslDoctorWarn "networkingMode" "mirrored but Hyper-V firewall cmdlets are unavailable" $network.Path
            }
        }
        "none" {
            Add-WslDoctorWarn "networkingMode" "none; WSL networking is disabled" $network.Path
        }
        "virtioproxy" {
            Add-WslDoctorWarn "networkingMode" "virtioproxy; port automation does not manage this mode yet" $network.Path
        }
        "bridged" {
            Add-WslDoctorWarn "networkingMode" "bridged is deprecated and not managed by port" $network.Path
        }
        default {
            Add-WslDoctorWarn "networkingMode" "unknown value: $($network.Mode)" $network.Path
        }
    }

    $managedRuleNames = New-Object System.Collections.Generic.HashSet[string]
    if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
        foreach ($rule in @(Get-WslManagedWindowsFirewallRules)) {
            [void]$managedRuleNames.Add($rule.Name)
        }
    } else {
        Add-WslDoctorWarn "Windows firewall cmdlets" "Get-NetFirewallRule is unavailable"
    }

    foreach ($rule in @(Get-WslManagedHyperVFirewallRules)) {
        [void]$managedRuleNames.Add($rule.Name)
    }

    $proxyEntries = @(Get-WslPortProxyEntries)
    $managedProxyEntries = New-Object System.Collections.ArrayList
    foreach ($entry in $proxyEntries) {
        $ruleName = Get-WslPortRuleName "tcp" $entry.ListenPort
        if ($managedRuleNames.Contains($ruleName)) {
            [void]$managedProxyEntries.Add($entry)
        }
    }

    if ($managedRuleNames.Count -eq 0 -and $managedProxyEntries.Count -eq 0) {
        Add-WslDoctorOk "managed port rules" "none"
        return
    }

    Add-WslDoctorOk "managed firewall rules" "$($managedRuleNames.Count)"
    Add-WslDoctorOk "managed NAT portproxy entries" "$($managedProxyEntries.Count)"

    if ($network.Mode -eq "nat" -and -not [string]::IsNullOrWhiteSpace($InstanceInfo.RuntimeIp)) {
        $runtimeIps = @($InstanceInfo.RuntimeIp -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        foreach ($entry in @($managedProxyEntries)) {
            if ($runtimeIps -notcontains $entry.ConnectAddress) {
                Add-WslDoctorWarn "NAT portproxy $($entry.ListenPort)" "connect address is stale or unexpected" "$($entry.ConnectAddress) -> current WSL IP: $($runtimeIps -join ', ')`nRun: $($script:Config.CommandName) .port sync"
            }
        }
    }
}


function Invoke-WslDoctorNetworkChecks {
    param(
        [pscustomobject]$NativeInfo,
        [pscustomobject]$SourceInfo
    )

    Write-WslDoctorSection "Network checks"

    $githubDistributionInfoUrl = "https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json"
    Add-WslDoctorOk "GitHub WSL distribution index" "probing $githubDistributionInfoUrl"
    $githubProbe = Invoke-WslDoctorUrlProbe $githubDistributionInfoUrl
    if ($githubProbe.Success) {
        Add-WslDoctorOk "GitHub WSL distribution index response" "$($githubProbe.Method) HTTP $($githubProbe.StatusCode) $($githubProbe.Reason)"
    } else {
        $githubMessage = if ($githubProbe.StatusCode -gt 0) { "$($githubProbe.Method) HTTP $($githubProbe.StatusCode) $($githubProbe.Reason)" } else { "request failed" }
        Add-WslDoctorWarn "GitHub WSL distribution index response" $githubMessage "If raw.githubusercontent.com is blocked, native online WSL install/list operations may fail.`n$($githubProbe.Error)"
    }

    if ($null -eq $NativeInfo -or -not $NativeInfo.Available) {
        Add-WslDoctorWarn "native online list" "skipped because wsl.exe is unavailable"
    } else {
        $online = Invoke-WslNativeTextCommand @("--list", "--online")
        if ($online.ExitCode -eq 0 -and ($online.Output.Count -gt 0 -or $online.Error.Count -gt 0)) {
            if ($SourceInfo.Type -eq "distro") {
                if (Test-WslDoctorOnlineListContainsSource $online.Output $SourceInfo.Source) {
                    Add-WslDoctorOk "native online source" "$($SourceInfo.Source) appears in wsl --list --online"
                } else {
                    Add-WslDoctorWarn "native online source" "$($SourceInfo.Source) was not found in wsl --list --online" (Format-WslDoctorLines $online.Output 8)
                }
            } else {
                Add-WslDoctorOk "native online list" "readable"
            }
        } else {
            Add-WslDoctorWarn "native online list" "wsl --list --online failed or returned no data" (Format-WslDoctorLines @($online.Error + $online.Output))
        }
    }

    if ($SourceInfo.Type -eq "archive") {
        Add-WslDoctorOk "fallback URL" "skipped for archive source"
        return
    }

    if ($SourceInfo.Type -ne "distro") {
        Add-WslDoctorWarn "fallback URL" "skipped because WSL_source is not an online distribution name"
        return
    }

    if ($null -eq $SourceInfo.FallbackDownload -or [string]::IsNullOrWhiteSpace($SourceInfo.FallbackDownload.Url)) {
        Add-WslDoctorWarn "fallback URL" "no fallback URL available for this source"
        return
    }

    Add-WslDoctorOk "fallback URL" "probing $($SourceInfo.FallbackDownload.Url)"
    $probe = Invoke-WslDoctorUrlProbe $SourceInfo.FallbackDownload.Url
    if ($probe.Success) {
        Add-WslDoctorOk "fallback URL response" "$($probe.Method) HTTP $($probe.StatusCode) $($probe.Reason)"
    } else {
        $message = if ($probe.StatusCode -gt 0) { "$($probe.Method) HTTP $($probe.StatusCode) $($probe.Reason)" } else { "request failed" }
        Add-WslDoctorWarn "fallback URL response" $message $probe.Error
        return
    }

    Add-WslDoctorOk "fallback image download sample" "reading for 15 seconds; data is discarded"
    $sample = Invoke-WslDoctorDownloadSample $SourceInfo.FallbackDownload.Url 15
    $rate = Format-WslDoctorByteSize ([int64]$sample.BytesPerSecond)
    $bytes = Format-WslDoctorByteSize $sample.Bytes
    $duration = "{0:0.0}s" -f $sample.Seconds
    if ($sample.Success) {
        $completion = if ($sample.Completed) { "; file completed before timeout" } else { "" }
        $assessment = Get-WslDoctorDownloadSpeedAssessment $sample.BytesPerSecond
        $message = "$bytes in $duration ($rate/s$completion); $($assessment.Message)"
        if ($assessment.Level -eq "OK") {
            Add-WslDoctorOk "fallback image download sample result" $message $assessment.Detail
        } else {
            Add-WslDoctorWarn "fallback image download sample result" $message $assessment.Detail
        }
    } else {
        $sampleMessage = if ($sample.StatusCode -gt 0) { "HTTP $($sample.StatusCode) $($sample.Reason)" } else { "request failed" }
        Add-WslDoctorWarn "fallback image download sample result" $sampleMessage $sample.Error
    }
}
