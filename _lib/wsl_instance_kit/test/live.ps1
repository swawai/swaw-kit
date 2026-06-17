[CmdletBinding()]
param(
    [switch]$Yes,
    [string[]]$Sources = @("Debian", "FedoraLinux-43"),
    [string]$NamePrefix = "wslkit-live",
    [string]$User = "wslkit",
    [switch]$Keep,
    [switch]$SkipSshConnect
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "live.lib.ps1")

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$entryTemplate = Join-Path $repoRoot "wsl.1.cmd"
$liveRoot = Join-Path $repoRoot "data\wsl.live"
$liveBackupRoot = Join-Path $repoRoot "data\wsl.live.backup"

function New-ScenarioEntryFile {
    param(
        [string]$Name,
        [string]$Source,
        [string]$SshPublicKeyPath
    )

    return New-LiveEntryFile `
        -RepoRoot $repoRoot `
        -EntryTemplate $entryTemplate `
        -Name $Name `
        -Source $Source `
        -SshPublicKeyPath $SshPublicKeyPath `
        -User $User
}

function Remove-ScenarioDistribution {
    param([string]$Name)

    Remove-LiveDistribution -Name $Name -NamePrefix $NamePrefix
}

function Get-LiveBackupFiles {
    param([string]$BackupDir)

    if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $BackupDir -File -Filter "*.tar" -ErrorAction SilentlyContinue)
}

function Get-NewBackupFile {
    param(
        [string]$EntryFile,
        [string]$BackupDir,
        [string]$Source
    )

    $before = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in (Get-LiveBackupFiles $BackupDir)) {
        [void]$before.Add($file.FullName)
    }

    Invoke-LiveCommand $EntryFile @("ctl", "backup") 0 "backup $Source" | Out-Null

    $newFiles = @(Get-LiveBackupFiles $BackupDir | Where-Object { -not $before.Contains($_.FullName) } | Sort-Object LastWriteTimeUtc -Descending)
    Assert-True ($newFiles.Count -ge 1) "Expected ctl backup to create a new .tar file for $Source."
    Assert-True ($newFiles[0].Length -gt 0) "Backup file is empty: $($newFiles[0].FullName)"
    return $newFiles[0].FullName
}

function Write-LiveMarker {
    param(
        [string]$Name,
        [string]$Source
    )

    $markerPath = "/home/$User/.wslkit-live-marker"
    $quotedMarker = ConvertTo-ShSingleQuoted $markerPath
    $quotedUser = ConvertTo-ShSingleQuoted $User
    $quotedContent = ConvertTo-ShSingleQuoted "source=$Source;name=$Name"
    $script = @"
set -eu
marker=$quotedMarker
target_user=$quotedUser
owner="`${target_user}:`${target_user}"
mkdir -p "`$(dirname "`$marker")"
printf '%s\n' $quotedContent > "`$marker"
chown "`$owner" "`$marker" 2>/dev/null || true
cat "`$marker"
"@
    Invoke-WslRootScript $Name $script 0 "write export marker $Source" | Out-Null
}

function Assert-LiveMarker {
    param(
        [string]$Name,
        [string]$ExpectedContent,
        [string]$Label
    )

    $markerPath = "/home/$User/.wslkit-live-marker"
    $quotedMarker = ConvertTo-ShSingleQuoted $markerPath
    $quotedExpected = ConvertTo-ShSingleQuoted $ExpectedContent
    $script = @"
set -eu
test -f $quotedMarker
actual=`$(cat $quotedMarker)
test "`$actual" = $quotedExpected
printf '%s\n' "`$actual"
"@
    Invoke-WslRootScript $Name $script 0 $Label | Out-Null
}

function Invoke-LiveRemoveAndAssertGone {
    param(
        [string]$EntryFile,
        [string]$Name,
        [string]$Label
    )

    Invoke-LiveCommand $EntryFile @("ctl", "remove", "--yes") 0 $Label | Out-Null
    Assert-True (-not (Test-WslDistributionExists $Name)) "Expected distribution to be removed: $Name"
}

function Test-ExportRoundTrip {
    param(
        [string]$Name,
        [string]$Source,
        [string]$EntryFile,
        [string]$BackupDir,
        [pscustomobject]$SshKey
    )

    Write-Host ""
    Write-Host "===== EXPORT ROUND TRIP $Source -> $Name =====" -ForegroundColor Magenta

    $markerContent = "source=$Source;name=$Name"
    Write-LiveMarker $Name $Source
    Invoke-LiveCommand $EntryFile @("ctl", "terminate") 0 "terminate before export $Source" | Out-Null

    $backupPath = Get-NewBackupFile $EntryFile $BackupDir $Source
    Write-Host "Backup file: $backupPath" -ForegroundColor Green

    $exportPath = Join-Path $BackupDir ("Export_{0}.tar" -f $Name)
    if (Test-Path -LiteralPath $exportPath) {
        Remove-Item -LiteralPath $exportPath -Force
    }
    Invoke-LiveCommand $EntryFile @("ctl", "export", $exportPath) 0 "explicit export $Source" | Out-Null
    Assert-True (Test-Path -LiteralPath $exportPath -PathType Leaf) "Expected explicit export file: $exportPath"
    Assert-True ((Get-Item -LiteralPath $exportPath).Length -gt 0) "Explicit export file is empty: $exportPath"

    $restoreName = "$Name-restore"
    $restoreEntryFile = New-ScenarioEntryFile $restoreName $exportPath $SshKey.PublicKey
    $restoreInstallDir = Join-Path $liveRoot $restoreName
    $restoreBackupDir = Join-Path $liveBackupRoot $restoreName

    try {
        Remove-ScenarioDistribution $restoreName
        Remove-SafeDirectory $restoreInstallDir $liveRoot
        Remove-SafeDirectory $restoreBackupDir $liveBackupRoot

        Invoke-LiveCommand $restoreEntryFile @("ctl", "install") 0 "restore install from export $Source" | Out-Null
        Assert-LiveMarker $restoreName $markerContent "verify marker after restore $Source"

        if ($Keep) {
            Write-Host "Keeping restore distribution and entry: $restoreName" -ForegroundColor Yellow
        } else {
            Invoke-LiveRemoveAndAssertGone $restoreEntryFile $restoreName "remove restored distribution $Source"
        }
    } finally {
        if (-not $Keep) {
            try {
                Remove-ScenarioDistribution $restoreName
            } catch {
                Write-Host "Cleanup warning: $($_.Exception.Message)" -ForegroundColor Yellow
            }
            if (Test-Path -LiteralPath $restoreEntryFile) {
                Remove-Item -LiteralPath $restoreEntryFile -Force
            }
            Remove-SafeDirectory $restoreInstallDir $liveRoot
            Remove-SafeDirectory $restoreBackupDir $liveBackupRoot
        }
    }
}

function Test-LiveDistribution {
    param(
        [string]$Source,
        [pscustomobject]$SshKey
    )

    $token = Get-SafeToken $Source
    $name = "$NamePrefix-$token"
    $port = Get-FreeTcpPort
    $entryFile = New-ScenarioEntryFile $name $Source $SshKey.PublicKey
    $installDir = Join-Path $liveRoot $name
    $backupDir = Join-Path $liveBackupRoot $name

    try {
        Write-Host ""
        Write-Host "===== LIVE $Source -> $name =====" -ForegroundColor Magenta
        Remove-ScenarioDistribution $name
        Remove-SafeDirectory $installDir $liveRoot
        Remove-SafeDirectory $backupDir $liveBackupRoot

        Invoke-LiveCommand $entryFile @("ctl", "install", "--fallback") 0 "install fallback $Source" | Out-Null
        Invoke-LiveCommand $entryFile @("ctl", "user", "default") 0 "set default user $Source" | Out-Null
        Invoke-LiveCommand $entryFile @("ctl", "systemd", "enable") 0 "systemd enable $Source" | Out-Null
        Invoke-LiveCommand $entryFile @("vm", "shutdown") 0 "vm shutdown after systemd $Source" | Out-Null

        $packageFamily = Get-PackageFamily $name
        Write-Host "Package manager: $packageFamily" -ForegroundColor Green

        Invoke-LiveCommand $entryFile @("ctl", "ssh", "enable", ([string]$port)) 0 "ssh enable $Source" | Out-Null
        $status = Invoke-LiveCommand $entryFile @("ctl", "ssh", "status") 0 "ssh status $Source"
        $statusText = $status.Output -join "`n"
        Assert-True ($statusText -match "service manager:\s+systemd") "Expected systemd service manager for $Source."
        Assert-True ($statusText -match "service active:\s+active") "Expected active SSH service for $Source."
        Assert-True ($statusText -match "service enabled:\s+enabled") "Expected enabled SSH service for $Source."
        Assert-True ($statusText -match "effective port:\s+$port") "Expected SSH port $port for $Source."
        Assert-True ($statusText -match "configured key:\s+present") "Expected configured key for $Source."

        $verifyScript = @'
set -eu
echo systemd=$(ps -p 1 -o comm= | tr -d ' ')
if command -v rpm >/dev/null 2>&1; then rpm -q openssh-server; fi
if command -v dpkg-query >/dev/null 2>&1; then dpkg-query -W openssh-server; fi
sshd -T 2>/dev/null | grep ^port
systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null
systemctl is-enabled ssh 2>/dev/null || systemctl is-enabled sshd 2>/dev/null
'@
        Invoke-WslRootScript $name $verifyScript 0 "verify inside $Source" | Out-Null

        if ($SshKey.CanConnect) {
            Test-SshConnection `
                -Name $name `
                -UserName $User `
                -PrivateKey $SshKey.PrivateKey `
                -Port $port `
                -StatusOutput $status.Output `
                -SkipSshConnect:$SkipSshConnect
        } else {
            Write-Host "SSH connection skipped: generated key pair is unavailable." -ForegroundColor Yellow
        }

        Invoke-LiveCommand $entryFile @("status") 0 "entry status $Source" | Out-Null
        Test-ExportRoundTrip $name $Source $entryFile $backupDir $SshKey

        if ($Keep) {
            Write-Host "Keeping live distribution and entry: $name" -ForegroundColor Yellow
        } else {
            Invoke-LiveRemoveAndAssertGone $entryFile $name "remove live distribution $Source"
        }

        Write-Host "LIVE OK: $Source" -ForegroundColor Green
    } finally {
        if (-not $Keep) {
            try {
                Remove-ScenarioDistribution $name
            } catch {
                Write-Host "Cleanup warning: $($_.Exception.Message)" -ForegroundColor Yellow
            }
            if (Test-Path -LiteralPath $entryFile) {
                Remove-Item -LiteralPath $entryFile -Force
            }
            Remove-SafeDirectory $installDir $liveRoot
            Remove-SafeDirectory $backupDir $liveBackupRoot
        }
    }
}

if (-not $Yes) {
    Write-Host "This live test installs, configures SSH, exports, restores, shuts down, and removes WSL distributions." -ForegroundColor Yellow
    Write-Host "Run explicitly with:"
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\_lib\wsl_instance_kit\test\live.ps1 -Yes"
    Write-Host "Optional Oracle/RHEL-family Appx test:"
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\_lib\wsl_instance_kit\test\live.ps1 -Yes -Sources OracleLinux_8_10"
    Write-Host "Legacy yum-only diagnostic; expected to reject if systemd/dbus is unusable:"
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\_lib\wsl_instance_kit\test\live.ps1 -Yes -Sources OracleLinux_7_9"
    exit 2
}

Assert-True (Test-Path -LiteralPath $entryTemplate -PathType Leaf) "Entry template not found: $entryTemplate"
Assert-True ($NamePrefix -match '^[a-z0-9][a-z0-9.-]*$') "NamePrefix must be simple lowercase DNS-like text."

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wslkit-live-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

Push-Location $repoRoot
try {
    $sshKey = New-LiveSshKey $tempRoot
    foreach ($source in @($Sources)) {
        Test-LiveDistribution $source $sshKey
    }
    Write-Host ""
    Write-Host "live ok" -ForegroundColor Green
} finally {
    Pop-Location
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
