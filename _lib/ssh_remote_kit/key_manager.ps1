<#
.SYNOPSIS
  Add/remove the current public key, or repair remote sshd public-key login.

.DESCRIPTION
  OpenSSH is used when key login already works. PuTTY is kept only as the
  password-based bootstrap fallback for installing the key.
#>

param(
    [Parameter(Mandatory=$true)] [int]$Port,
    [Parameter(Mandatory=$true)] [string]$RemoteHost,
    [Parameter(Mandatory=$true)] [string]$RemoteUser,
    [Parameter(Mandatory=$true)] [string]$SshKeyPath,
    [ValidateSet("add","remove","fix")] [string]$Action = "add",
    [switch]$FixSshdConfig
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ps_common.ps1")

$remoteKit = Initialize-RemoteKitContext `
    -Port $Port `
    -RemoteHost $RemoteHost `
    -RemoteUser $RemoteUser `
    -SshKeyPath $SshKeyPath `
    -ModuleRoot $PSScriptRoot `
    -UploadSubdir "key_manager"

$helperScriptPath = Join-Path $PSScriptRoot "authorized_keys.sh"
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
    Write-Host "PuttyHostKey= $(if ($remoteKit.AutoAcceptPuttyHostKey) { 'auto-accept' } else { 'manual-confirm' })"
    Write-Host "==============================================="
}

Ensure-ConfiguredSshKeyPair
Show-Overview
Assert-LocalInputs
$pubKeyLine = if ($needsPublicKey) { Get-PublicKeyLine } else { $null }

Write-Host "[STEP] Trying to use OpenSSH client (ssh.exe / scp.exe) with key: $SshKeyPath"
$sshExitCode = Test-RemoteKitOpenSshKeyLogin
Write-Host "[INFO] ssh test exit code = $sshExitCode"

$remoteTemp = New-RemoteKitRemoteTempSpec
$remoteScriptName = "$($remoteTemp.Dir)/authorized_keys.sh"
$remotePubKeyName = "$($remoteTemp.Dir)/key.pub"
$remoteSshdMode = if ($willFixSshd) { "fix-sshd" } elseif ($Action -eq "add") { "check-sshd" } else { "skip-sshd" }
$remoteRunCommand = "code=0; chmod +x $remoteScriptName && bash $remoteScriptName $Action $remotePubKeyName $remoteSshdMode || code=`$?; rm -rf $($remoteTemp.Dir); exit `$code"

if ($sshExitCode -eq 0) {
    Write-Host "[INFO] => OpenSSH-based key login successful, will use ssh/scp."

    $code = Invoke-RemoteKitOpenSshRemote $remoteTemp.InitCommand -UseCommandOptions
    if ($code -ne 0) {
        Write-Host "[ERROR] ssh remote temp directory creation failed, exit code = $code"
        exit $code
    }

    if ($needsPublicKey) {
        $code = Copy-RemoteKitPreparedFile "openssh" "key_" ".pub" $pubKeyLine "public key" $remotePubKeyName $null
        if ($code -ne 0) {
            [void](Invoke-RemoteKitOpenSshRemote $remoteTemp.CleanupCommand -UseCommandOptions)
            Write-Host "[ERROR] scp public key upload failed, exit code = $code"
            exit $code
        }
    }

    $helperContent = [System.IO.File]::ReadAllText($helperScriptPath)
    $code = Copy-RemoteKitPreparedFile "openssh" "authorized_keys_" ".sh" $helperContent "authorized_keys.sh" $remoteScriptName $null
    if ($code -ne 0) {
        [void](Invoke-RemoteKitOpenSshRemote $remoteTemp.CleanupCommand -UseCommandOptions)
        Write-Host "[ERROR] scp helper script upload failed, exit code = $code"
        exit $code
    }

    $code = Invoke-RemoteKitOpenSshRemote $remoteRunCommand -UseCommandOptions
    if ($code -ne 0) {
        [void](Invoke-RemoteKitOpenSshRemote $remoteTemp.CleanupCommand -UseCommandOptions)
        Write-Host "[ERROR] ssh failed, exit code = $code"
        exit $code
    }

    Write-Host "[INFO] Done via OpenSSH. exit 0"
    exit 0
}

Write-Host "[WARN] => OpenSSH failed to use private key, will use PuTTY (plink/pscp)."
Assert-RemoteKitPuttyTools
Initialize-RemoteKitPuttyHostKeyCache

$password = Read-RemoteKitSshPassword
$passwordFile = $null
try {
    $passwordFile = New-RemoteKitPasswordFile $password

    $code = Invoke-RemoteKitPuttyRemote $remoteTemp.InitCommand $passwordFile
    if ($code -ne 0) {
        Write-Host "[ERROR] plink remote temp directory creation failed, exit code=$code"
        exit $code
    }

    if ($needsPublicKey) {
        $code = Copy-RemoteKitPreparedFile "putty" "key_" ".pub" $pubKeyLine "public key" $remotePubKeyName $passwordFile
        if ($code -ne 0) {
            [void](Invoke-RemoteKitPuttyRemote $remoteTemp.CleanupCommand $passwordFile)
            Write-Host "[ERROR] pscp public key upload failed, exit code=$code"
            exit $code
        }
    }

    $helperContent = [System.IO.File]::ReadAllText($helperScriptPath)
    $code = Copy-RemoteKitPreparedFile "putty" "authorized_keys_" ".sh" $helperContent "authorized_keys.sh" $remoteScriptName $passwordFile
    if ($code -ne 0) {
        [void](Invoke-RemoteKitPuttyRemote $remoteTemp.CleanupCommand $passwordFile)
        Write-Host "[ERROR] pscp helper script upload failed, exit code=$code"
        exit $code
    }

    $code = Invoke-RemoteKitPuttyRemote $remoteRunCommand $passwordFile
    if ($code -ne 0) {
        [void](Invoke-RemoteKitPuttyRemote $remoteTemp.CleanupCommand $passwordFile)
    }
} finally {
    Remove-RemoteKitTempPath $passwordFile
    $password = $null
}

if ($code -ne 0) {
    Write-Host "[ERROR] plink failed, exit code=$code"
    exit $code
}

Write-Host "`n[INFO] Done via PuTTY. exit 0"
exit 0
