<#
.SYNOPSIS
  Add/remove the current public key, or repair remote sshd public-key login.

.DESCRIPTION
  OpenSSH is used for both key login and password-based bootstrap. The
  password bootstrap path uses one interactive ssh connection and streams the
  helper script through stdin.
#>

param(
    [Parameter(Mandatory=$true)] [int]$Port,
    [Parameter(Mandatory=$true)] [string]$RemoteHost,
    [Parameter(Mandatory=$true)] [string]$RemoteUser,
    [AllowEmptyString()] [Parameter(Mandatory=$true)] [string]$SshKeyPath,
    [ValidateSet("add","remove","fix")] [string]$Action = "add",
    [switch]$FixSshdConfig
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ps_common.ps1")
. (Join-Path $PSScriptRoot "key_manager.openssh.ps1")

$remoteKit = Initialize-RemoteKitContext `
    -Port $Port `
    -RemoteHost $RemoteHost `
    -RemoteUser $RemoteUser `
    -SshKeyPath $SshKeyPath `
    -ModuleRoot $PSScriptRoot `
    -UploadSubdir "key_manager"

$helperScriptPath = Join-Path $PSScriptRoot "authorized_keys.sh"

if ($remoteKit.UseSshConfigHost -and ([string]::IsNullOrWhiteSpace($SshKeyPath) -or $SshKeyPath -eq "__REMOTE_KIT_SSH_CONFIG_IDENTITY__")) {
    $SshKeyPath = Resolve-RemoteKitOpenSshIdentityFile
    $remoteKit.SshKeyPath = $SshKeyPath
}

$pubKeyPath = "$SshKeyPath.pub"

if ($FixSshdConfig.IsPresent -and $Action -ne "add") {
    Write-Host "[ERROR] -FixSshdConfig is only supported with -Action add."
    exit 1
}

$needsPublicKey = ($Action -eq "add" -or $Action -eq "remove")
$willFixSshd = ($Action -eq "fix" -or $FixSshdConfig.IsPresent)
$shouldAutoCreateKeyPair = ($Action -eq "add" -or $Action -eq "fix")

function Get-PublicKeyLine {
    if (-not (Test-Path -LiteralPath $pubKeyPath -PathType Leaf)) {
        Write-Host "[ERROR] Public key file not found: $pubKeyPath"
        exit 1
    }

    $line = Get-Content -LiteralPath $pubKeyPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if (-not $line) {
        Write-Host "[ERROR] Public key file is empty: $pubKeyPath"
        exit 1
    }

    return ([string]$line -replace "^\uFEFF", "")
}

function Ensure-ConfiguredSshKeyPair {
    if (-not $shouldAutoCreateKeyPair) {
        return
    }

    $privateExists = Test-Path -LiteralPath $SshKeyPath -PathType Leaf
    $publicExists = Test-Path -LiteralPath $pubKeyPath -PathType Leaf
    if ($privateExists -or $publicExists) {
        return
    }

    $sshKeygen = Get-Command "ssh-keygen.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sshKeygen) {
        $sshKeygen = Get-Command "ssh-keygen" -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if (-not $sshKeygen) {
        Write-Host "[ERROR] ssh-keygen not found; cannot generate missing SSH key pair."
        exit 1
    }

    $keyDir = Split-Path -Parent $SshKeyPath
    if (-not [string]::IsNullOrWhiteSpace($keyDir) -and -not (Test-Path -LiteralPath $keyDir -PathType Container)) {
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
    }

    Write-Host "[INFO] SSH key pair not found; generating with ssh-keygen defaults: $SshKeyPath"
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $sshKeygen.Source
    $processInfo.Arguments = Join-RemoteKitProcessArguments @("-f", $SshKeyPath, "-N", "")
    $processInfo.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($processInfo)
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $process.Dispose()
    if ($exitCode -ne 0) {
        Write-Host "[ERROR] ssh-keygen failed, exit code = $exitCode"
        exit $exitCode
    }

    if (-not (Test-Path -LiteralPath $SshKeyPath -PathType Leaf) -or -not (Test-Path -LiteralPath $pubKeyPath -PathType Leaf)) {
        Write-Host "[ERROR] ssh-keygen did not create the expected key pair: $SshKeyPath"
        exit 1
    }
}

function Assert-LocalInputs {
    if ($needsPublicKey -and -not (Test-Path -LiteralPath $SshKeyPath -PathType Leaf)) {
        Write-Host "[ERROR] Private key file not found: $SshKeyPath"
        exit 1
    }

    if (-not (Test-Path -LiteralPath $helperScriptPath -PathType Leaf)) {
        Write-Host "[ERROR] Helper script not found: $helperScriptPath"
        exit 1
    }
}

function Show-Overview {
    Write-Host "`n=================== Parameter Overview ======="
    Write-Host "Port        = $Port"
    Write-Host "RemoteHost  = $RemoteHost"
    Write-Host "RemoteUser  = $RemoteUser"
    Write-Host "SshKeyPath  = $SshKeyPath"
    Write-Host "PubKeyPath  = $pubKeyPath"
    Write-Host "Action      = $Action"
    Write-Host "FixSshd     = $willFixSshd"
    Write-Host "OpenSshOpts = $($remoteKit.SshCommonOpts -join ' ')"
    Write-Host "PasswordBoot= OpenSSH interactive stdin payload"
    Write-Host "==============================================="
}

Ensure-ConfiguredSshKeyPair
Show-Overview
Assert-LocalInputs
$pubKeyLine = if ($needsPublicKey) { Get-PublicKeyLine } else { $null }

Write-Host "[STEP] Trying to use OpenSSH client (ssh.exe) with key: $SshKeyPath"
$sshExitCode = Test-RemoteKitOpenSshKeyLogin
Write-Host "[INFO] ssh test exit code = $sshExitCode"

$remoteSshdMode = if ($willFixSshd) { "fix-sshd" } elseif ($Action -eq "add") { "check-sshd" } else { "skip-sshd" }
$helperContent = [System.IO.File]::ReadAllText($helperScriptPath)
$payload = New-RemoteKitKeyManagerOpenSshPayload `
    -Action $Action `
    -SshdMode $remoteSshdMode `
    -HelperContent $helperContent `
    -PublicKeyLine $pubKeyLine

if ($sshExitCode -eq 0) {
    Write-Host "[INFO] => OpenSSH-based key login successful, will use one ssh stdin payload."
    $code = Invoke-RemoteKitKeyManagerOpenSshPayload $payload
    if ($code -ne 0) {
        Write-Host "[ERROR] OpenSSH key manager payload failed, exit code = $code"
        exit $code
    }

    Write-Host "[INFO] Done via OpenSSH. exit 0"
    exit 0
}

Write-Host "[WARN] => OpenSSH failed to use private key."
Write-Host "[STEP] Trying OpenSSH password bootstrap with one ssh connection."
Write-Host "[INFO] You may be prompted once per SSH hop; ProxyJump hosts with password auth can add prompts."
$code = Invoke-RemoteKitKeyManagerOpenSshPayload $payload -PasswordBootstrap

if ($code -ne 0) {
    Write-Host "[ERROR] OpenSSH password bootstrap failed, exit code=$code"
    exit $code
}

Write-Host "`n[INFO] Done via OpenSSH password bootstrap. exit 0"
exit 0
