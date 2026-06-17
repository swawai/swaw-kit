$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ExitCode {
    param(
        [int]$Actual,
        [int]$Expected,
        [string]$Label
    )

    if ($Actual -ne $Expected) {
        throw "$Label failed: expected exit code $Expected, got $Actual."
    }
}

function Get-SafeToken {
    param([string]$Value)

    $safe = $Value.ToLowerInvariant() -replace '[^a-z0-9]+', "-"
    $safe = $safe.Trim("-")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "distro"
    }

    return $safe
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function ConvertTo-ShSingleQuoted {
    param([AllowNull()] [string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }

    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Get-WslDistributionNames {
    $lines = @(& wsl.exe --list --quiet 2>$null | ForEach-Object { ($_ -replace "`0", "").Trim() })
    return @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-WslDistributionExists {
    param([string]$Name)

    return ($Name -in (Get-WslDistributionNames))
}

function Invoke-LiveCommand {
    param(
        [string]$File,
        [string[]]$CommandArgs,
        [int]$ExpectedExitCode = 0,
        [string]$Label = $File
    )

    $display = @($File) + @($CommandArgs)
    Write-Host ""
    Write-Host (">>> " + ($display -join " ")) -ForegroundColor Cyan
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $File @CommandArgs 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    foreach ($line in $output) {
        Write-Host $line
    }

    Assert-ExitCode $exitCode $ExpectedExitCode $Label
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function New-LiveBase64ShRunner {
    param([string]$Script)

    $normalized = $Script -replace "`r`n", "`n"
    $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($normalized))
    return "printf '%s' '$base64' | base64 -d | sh"
}

function Invoke-WslRootScript {
    param(
        [string]$Name,
        [string]$Script,
        [int]$ExpectedExitCode = 0,
        [string]$Label = "wsl root script"
    )

    $runner = New-LiveBase64ShRunner $Script
    return Invoke-LiveCommand "wsl.exe" @("-d", $Name, "-u", "root", "--", "sh", "-lc", $runner) $ExpectedExitCode $Label
}

function Remove-LiveDistribution {
    param(
        [string]$Name,
        [string]$NamePrefix
    )

    $escapedPrefix = [regex]::Escape($NamePrefix)
    Assert-True ($Name -match "^$escapedPrefix-[a-z0-9.-]+$") "Refusing to remove non-live distribution: $Name"

    if (Test-WslDistributionExists $Name) {
        Write-Host "Removing existing live distribution: $Name" -ForegroundColor Yellow
        & wsl.exe --terminate $Name 2>$null | Out-Null
        & wsl.exe --unregister $Name
        Assert-ExitCode $LASTEXITCODE 0 "wsl unregister $Name"
    }
}

function Remove-SafeDirectory {
    param(
        [string]$Path,
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd("\") + "\"
    if ($fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullPath)) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

function New-LiveSshKey {
    param([string]$TempRoot)

    $privateKey = Join-Path $TempRoot "id_wslkit_live"
    $publicKey = "$privateKey.pub"
    $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($null -ne $sshKeygen) {
        $commandLine = '"{0}" -q -t ed25519 -N "" -C wslkit-live -f "{1}"' -f $sshKeygen.Source, $privateKey
        & cmd.exe /d /c $commandLine
        Assert-ExitCode $LASTEXITCODE 0 "ssh-keygen"
        return [pscustomobject]@{
            PrivateKey = $privateKey
            PublicKey = $publicKey
            CanConnect = $true
        }
    }

    $dummyPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEZha2VLZXlGb3JMaXZlVGVzdFB1YmxpY09ubHk wslkit-live"
    [System.IO.File]::WriteAllText($publicKey, "$dummyPublicKey`r`n", [System.Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        PrivateKey = $privateKey
        PublicKey = $publicKey
        CanConnect = $false
    }
}

function Set-EntryLine {
    param(
        [string]$Content,
        [string]$Name,
        [string]$Value
    )

    $line = 'set "' + $Name + "=" + $Value + '"'
    return [regex]::Replace($Content, '(?m)^set "' + [regex]::Escape($Name) + '=.*"\r?$', [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $line })
}

function New-LiveEntryFile {
    param(
        [string]$RepoRoot,
        [string]$EntryTemplate,
        [string]$Name,
        [string]$Source,
        [int]$Port,
        [string]$SshKeyPath,
        [string]$User
    )

    $entryPath = Join-Path $RepoRoot "$Name.cmd"
    $content = [System.IO.File]::ReadAllText($EntryTemplate)
    $content = Set-EntryLine $content "WSL_name" $Name
    $content = Set-EntryLine $content "WSL_user" $User
    $content = Set-EntryLine $content "WSL_source" $Source
    $content = Set-EntryLine $content "WSL_install_dir" "%~dp0\data\wsl.live\%WSL_name%"
    $content = Set-EntryLine $content "WSL_backup_dir" "%~dp0\data\wsl.live.backup\%WSL_name%"
    $content = Set-EntryLine $content "WSL_default_workdir" "~"
    $content = Set-EntryLine $content "WSL_version" "2"
    $content = Set-EntryLine $content "WSL_export_format" "tar"
    $content = Set-EntryLine $content "WSL_systemd" "enable"
    $content = Set-EntryLine $content "WSL_SSH_port" ([string]$Port)
    $content = Set-EntryLine $content "WSL_SSH_key" $SshKeyPath
    $content = $content -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($entryPath, $content, [System.Text.UTF8Encoding]::new($false))
    return $entryPath
}

function Get-PackageFamily {
    param([string]$Name)

    $script = @'
if command -v apt-get >/dev/null 2>&1; then echo apt; exit 0; fi
if command -v dnf >/dev/null 2>&1; then echo dnf; exit 0; fi
if command -v yum >/dev/null 2>&1; then echo yum; exit 0; fi
if command -v microdnf >/dev/null 2>&1; then echo microdnf; exit 0; fi
echo unknown
'@
    $result = Invoke-WslRootScript $Name $script 0 "detect package manager"
    return (($result.Output | Select-Object -Last 1) -as [string]).Trim()
}

function Get-SshHostCandidates {
    param(
        [string[]]$StatusOutput
    )

    $hosts = New-Object System.Collections.Generic.List[string]
    [void]$hosts.Add("127.0.0.1")
    foreach ($line in @($StatusOutput)) {
        if ($line -match '^\s+WSL IP:\s+(?<ips>.+)$') {
            foreach ($ip in ($Matches["ips"] -split '\s+')) {
                if ($ip -match '^\d+\.\d+\.\d+\.\d+$' -and -not $hosts.Contains($ip)) {
                    [void]$hosts.Add($ip)
                }
            }
        }
    }

    return @($hosts)
}

function Test-SshConnection {
    param(
        [string]$Name,
        [string]$UserName,
        [string]$PrivateKey,
        [int]$Port,
        [string[]]$StatusOutput,
        [switch]$SkipSshConnect
    )

    if ($SkipSshConnect) {
        Write-Host "SSH connection skipped by -SkipSshConnect." -ForegroundColor Yellow
        return
    }

    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($null -eq $ssh) {
        Write-Host "SSH connection skipped: ssh.exe not found." -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path -LiteralPath $PrivateKey -PathType Leaf)) {
        Write-Host "SSH connection skipped: private key not available." -ForegroundColor Yellow
        return
    }

    $knownHosts = Join-Path ([System.IO.Path]::GetDirectoryName($PrivateKey)) "known_hosts"
    $lastOutput = @()
    foreach ($hostName in (Get-SshHostCandidates $StatusOutput)) {
        Write-Host ""
        Write-Host ">>> ssh test $UserName@${hostName}:$Port" -ForegroundColor Cyan
        $args = @(
            "-i", $PrivateKey,
            "-p", ([string]$Port),
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=$knownHosts",
            "$UserName@$hostName",
            "printf wslkit-live-ok"
        )
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $lastOutput = @(& $ssh.Source @args 2>&1 | ForEach-Object { [string]$_ })
            $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        foreach ($line in $lastOutput) {
            Write-Host $line
        }
        if ($exitCode -eq 0 -and (($lastOutput -join "`n") -match "wslkit-live-ok")) {
            Write-Host "SSH connection ok via $hostName." -ForegroundColor Green
            return
        }
    }

    throw "SSH connection failed for $Name. Last output: $($lastOutput -join ' | ')"
}
