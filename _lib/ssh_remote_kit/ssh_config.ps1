<#
.SYNOPSIS
  Generate and include embedded OpenSSH config blocks from entry scripts.
#>

param(
    [ValidateSet("write","install","ensure","remove")]
    [string]$Action = "write",
    [string]$EntryFile,
    [string]$HostAlias,
    [string]$RepoRoot,
    [string]$UserProfile = $env:USERPROFILE
)

$script:RemoteKitSshConfigIncludeId = "8f6a9d72-4a7e-4b42-95cb-8bc20d9f5c31"
$script:RemoteKitSshConfigBegin = "# remote-kit ssh-config begin"
$script:RemoteKitSshConfigEnd = "# remote-kit ssh-config end"
$script:RemoteKitSshConfigAfterLabel = "REMOTE_KIT_AFTER_SSH_CONFIG"

function ConvertTo-RemoteKitLfText {
    param([AllowNull()] [string]$Text)

    if ($null -eq $Text) {
        $Text = ""
    }

    if ($Text.Length -gt 0 -and [int][char]$Text[0] -eq 0xFEFF) {
        $Text = $Text.Substring(1)
    }

    $textLf = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $textLf.EndsWith("`n")) {
        $textLf += "`n"
    }

    return $textLf
}

function ConvertTo-RemoteKitSshConfigPath {
    param([Parameter(Mandatory=$true)] [string]$Path)

    return ([System.IO.Path]::GetFullPath($Path)).Replace("\", "/")
}

function ConvertTo-RemoteKitSafeConfigName {
    param([Parameter(Mandatory=$true)] [string]$HostAlias)

    $safe = $HostAlias -replace '[^A-Za-z0-9._-]', '_'
    if ([string]::IsNullOrWhiteSpace($safe)) {
        throw "Host alias produces an empty config file name: $HostAlias"
    }

    return $safe
}

function Protect-RemoteKitSshConfigFile {
    param([Parameter(Mandatory=$true)] [string]$Path)

    if (-not $IsWindows -and $null -ne $IsWindows) {
        return
    }

    $currentUserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path /inheritance:r /grant:r "${currentUserName}:F" "SYSTEM:F" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to protect SSH config ACL: $Path"
    }
}

function Get-RemoteKitEmbeddedSshConfigText {
    param([Parameter(Mandatory=$true)] [string]$EntryFile)

    if (-not (Test-Path -LiteralPath $EntryFile -PathType Leaf)) {
        throw "Entry file not found: $EntryFile"
    }

    $text = [System.IO.File]::ReadAllText($EntryFile)
    $text = ConvertTo-RemoteKitLfText $text
    $lines = $text -split "`n"
    $inside = $false
    $foundBegin = $false
    $foundEnd = $false
    $selected = New-Object System.Collections.Generic.List[string]

    foreach ($rawLine in $lines) {
        $line = $rawLine.TrimEnd("`r")
        if ($line.Trim() -ieq $script:RemoteKitSshConfigBegin) {
            $inside = $true
            $foundBegin = $true
            continue
        }

        if ($line.Trim() -ieq $script:RemoteKitSshConfigEnd) {
            $inside = $false
            $foundEnd = $true
            break
        }

        if ($inside) {
            $selected.Add($line)
        }
    }

    if (-not $foundBegin -or -not $foundEnd) {
        $inside = $false
        $foundBegin = $false
        $foundEnd = $false
        $selected.Clear()

        foreach ($rawLine in $lines) {
            $line = $rawLine.TrimEnd("`r")
            if (-not $inside -and $line -match "^\s*goto\s+:$script:RemoteKitSshConfigAfterLabel\s*$") {
                $inside = $true
                $foundBegin = $true
                continue
            }

            if ($inside -and $line -match "^\s*:$script:RemoteKitSshConfigAfterLabel\s*$") {
                $inside = $false
                $foundEnd = $true
                break
            }

            if ($inside) {
                $selected.Add($line)
            }
        }
    }

    if (-not $foundBegin -or -not $foundEnd) {
        throw "Embedded ssh_config block not found in entry file: $EntryFile"
    }

    $configText = ($selected.ToArray() -join "`n")
    $configText = [Environment]::ExpandEnvironmentVariables($configText)
    return (ConvertTo-RemoteKitLfText $configText)
}

function Get-RemoteKitGeneratedSshConfigPath {
    param(
        [Parameter(Mandatory=$true)] [string]$RepoRoot,
        [Parameter(Mandatory=$true)] [string]$HostAlias
    )

    $safeName = ConvertTo-RemoteKitSafeConfigName $HostAlias
    $root = [System.IO.Path]::GetFullPath($RepoRoot)
    return Join-Path (Join-Path $root "data\ssh_config") "$safeName.config"
}

function New-RemoteKitSshConfigIncludeLine {
    param(
        [Parameter(Mandatory=$true)] [string]$ConfigPath,
        [Parameter(Mandatory=$true)] [string]$HostAlias
    )

    $sshPath = ConvertTo-RemoteKitSshConfigPath $ConfigPath
    return "Include `"$sshPath`" # win-run-toolbox host=$HostAlias id=$script:RemoteKitSshConfigIncludeId"
}

function Test-RemoteKitManagedIncludeLine {
    param(
        [AllowNull()] [string]$Line,
        [Parameter(Mandatory=$true)] [string]$HostAlias
    )

    if ([string]::IsNullOrWhiteSpace($Line) -or -not $Line.Contains($script:RemoteKitSshConfigIncludeId)) {
        return $false
    }

    $hostPattern = "(^|\s)host=$([regex]::Escape($HostAlias))(?=\s|$)"
    return $Line -match $hostPattern
}

function Ensure-RemoteKitSshConfigInclude {
    param(
        [Parameter(Mandatory=$true)] [string]$UserConfigPath,
        [Parameter(Mandatory=$true)] [string]$IncludeLine,
        [Parameter(Mandatory=$true)] [string]$HostAlias
    )

    $dir = Split-Path -Parent $UserConfigPath
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $lines = @()
    if (Test-Path -LiteralPath $UserConfigPath -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $UserConfigPath)
    }

    $filtered = @($lines | Where-Object {
        -not (Test-RemoteKitManagedIncludeLine -Line $_ -HostAlias $HostAlias)
    })
    $newLines = @($IncludeLine) + $filtered

    $newText = ($newLines -join "`r`n") + "`r`n"
    $oldText = if (Test-Path -LiteralPath $UserConfigPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($UserConfigPath)
    } else {
        $null
    }

    if ($oldText -ne $newText) {
        if ($null -ne $oldText) {
            $stamp = Get-Date -Format "yyyyMMddHHmmss"
            Copy-Item -LiteralPath $UserConfigPath -Destination "$UserConfigPath.remote-kit-bak-$stamp" -Force
        }

        [System.IO.File]::WriteAllText($UserConfigPath, $newText, [System.Text.UTF8Encoding]::new($false))
        Protect-RemoteKitSshConfigFile $UserConfigPath
    }
}

function Remove-RemoteKitSshConfigInclude {
    param(
        [Parameter(Mandatory=$true)] [string]$UserConfigPath,
        [Parameter(Mandatory=$true)] [string]$HostAlias
    )

    if (-not (Test-Path -LiteralPath $UserConfigPath -PathType Leaf)) {
        return
    }

    $lines = @(Get-Content -LiteralPath $UserConfigPath)
    $filtered = @($lines | Where-Object {
        -not (Test-RemoteKitManagedIncludeLine -Line $_ -HostAlias $HostAlias)
    })

    if ($filtered.Count -ne $lines.Count) {
        [System.IO.File]::WriteAllText($UserConfigPath, (($filtered -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($false))
        Protect-RemoteKitSshConfigFile $UserConfigPath
    }
}

function Write-RemoteKitEmbeddedSshConfig {
    param(
        [Parameter(Mandatory=$true)] [string]$EntryFile,
        [Parameter(Mandatory=$true)] [string]$HostAlias,
        [Parameter(Mandatory=$true)] [string]$RepoRoot,
        [Parameter(Mandatory=$true)] [string]$UserProfile
    )

    $configText = Get-RemoteKitEmbeddedSshConfigText -EntryFile $EntryFile
    $configText = $configText.Replace("%HOST%", $HostAlias).Replace("%REMOTE_SSH_HOST%", $HostAlias)
    $configPath = Get-RemoteKitGeneratedSshConfigPath -RepoRoot $RepoRoot -HostAlias $HostAlias
    $configDir = Split-Path -Parent $configPath
    if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($configPath, $configText, [System.Text.UTF8Encoding]::new($false))
    Protect-RemoteKitSshConfigFile $configPath

    $userConfigPath = Join-Path (Join-Path $UserProfile ".ssh") "config"
    $includeLine = New-RemoteKitSshConfigIncludeLine -ConfigPath $configPath -HostAlias $HostAlias

    return [pscustomobject]@{
        HostAlias      = $HostAlias
        ConfigPath     = $configPath
        UserConfigPath = $userConfigPath
        IncludeLine    = $includeLine
    }
}

function Install-RemoteKitEmbeddedSshConfig {
    param(
        [Parameter(Mandatory=$true)] [string]$EntryFile,
        [Parameter(Mandatory=$true)] [string]$HostAlias,
        [Parameter(Mandatory=$true)] [string]$RepoRoot,
        [Parameter(Mandatory=$true)] [string]$UserProfile
    )

    $result = Write-RemoteKitEmbeddedSshConfig `
        -EntryFile $EntryFile `
        -HostAlias $HostAlias `
        -RepoRoot $RepoRoot `
        -UserProfile $UserProfile
    Ensure-RemoteKitSshConfigInclude `
        -UserConfigPath $result.UserConfigPath `
        -IncludeLine $result.IncludeLine `
        -HostAlias $HostAlias
    return $result
}

function Ensure-RemoteKitEmbeddedSshConfig {
    param(
        [Parameter(Mandatory=$true)] [string]$EntryFile,
        [Parameter(Mandatory=$true)] [string]$HostAlias,
        [Parameter(Mandatory=$true)] [string]$RepoRoot,
        [Parameter(Mandatory=$true)] [string]$UserProfile
    )

    return Install-RemoteKitEmbeddedSshConfig `
        -EntryFile $EntryFile `
        -HostAlias $HostAlias `
        -RepoRoot $RepoRoot `
        -UserProfile $UserProfile
}

function Remove-RemoteKitEmbeddedSshConfig {
    param(
        [Parameter(Mandatory=$true)] [string]$HostAlias,
        [Parameter(Mandatory=$true)] [string]$RepoRoot,
        [Parameter(Mandatory=$true)] [string]$UserProfile
    )

    $userConfigPath = Join-Path (Join-Path $UserProfile ".ssh") "config"
    Remove-RemoteKitSshConfigInclude -UserConfigPath $userConfigPath -HostAlias $HostAlias

    $configPath = Get-RemoteKitGeneratedSshConfigPath -RepoRoot $RepoRoot -HostAlias $HostAlias
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Remove-Item -LiteralPath $configPath -Force
    }
}

function Invoke-RemoteKitSshConfigCli {
    if ([string]::IsNullOrWhiteSpace($HostAlias)) {
        throw "-HostAlias is required."
    }

    if ([string]::IsNullOrWhiteSpace($UserProfile)) {
        throw "-UserProfile is required."
    }

    if ($Action -eq "remove") {
        if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
            throw "-RepoRoot is required for remove."
        }

        Remove-RemoteKitEmbeddedSshConfig `
            -HostAlias $HostAlias `
            -RepoRoot $RepoRoot `
            -UserProfile $UserProfile
        return
    }

    foreach ($required in @("EntryFile","RepoRoot")) {
        $value = Get-Variable -Name $required -ValueOnly
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "-$required is required for $Action."
        }
    }

    if ($Action -eq "install" -or $Action -eq "ensure") {
        $result = Install-RemoteKitEmbeddedSshConfig `
            -EntryFile $EntryFile `
            -HostAlias $HostAlias `
            -RepoRoot $RepoRoot `
            -UserProfile $UserProfile
    } else {
        $result = Write-RemoteKitEmbeddedSshConfig `
            -EntryFile $EntryFile `
            -HostAlias $HostAlias `
            -RepoRoot $RepoRoot `
            -UserProfile $UserProfile
    }

    Write-Output $result.ConfigPath
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-RemoteKitSshConfigCli
}
