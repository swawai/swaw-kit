<#
.SYNOPSIS
  Upload a local shell script to the remote host and run it with arguments.

.DESCRIPTION
  OpenSSH is used when key login already works. PuTTY is kept only as the
  password-based fallback. The uploaded script is placed in a private remote
  temp directory and removed after execution.
#>

param(
    [Parameter(Mandatory=$true)] [int]$Port,
    [Parameter(Mandatory=$true)] [string]$RemoteHost,
    [Parameter(Mandatory=$true)] [string]$RemoteUser,
    [Parameter(Mandatory=$true)] [string]$SshKeyPath,
    [Parameter(Mandatory=$true)] [string]$ScriptPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ps_common.ps1")

$remoteKit = Initialize-RemoteKitContext `
    -Port $Port `
    -RemoteHost $RemoteHost `
    -RemoteUser $RemoteUser `
    -SshKeyPath $SshKeyPath `
    -ModuleRoot $PSScriptRoot `
    -UploadSubdir "script_runner" `
    -QuietInfrastructureOutput

function Get-ForwardedScriptArgs {
    $countText = $env:REMOTE_KIT_SCRIPT_ARG_COUNT
    if ([string]::IsNullOrWhiteSpace($countText)) {
        return @()
    }

    $count = 0
    if (-not [int]::TryParse($countText, [ref]$count) -or $count -lt 0) {
        throw "Invalid REMOTE_KIT_SCRIPT_ARG_COUNT: $countText"
    }

    $values = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -le $count; $i++) {
        $name = "REMOTE_KIT_SCRIPT_ARG_$i"
        $value = [Environment]::GetEnvironmentVariable($name, "Process")
        if ($null -eq $value) {
            $value = ""
        }

        $values.Add($value)
    }

    return $values.ToArray()
}

function Assert-LocalInputs {
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        Write-Host "[ERROR] Local script not found: $ScriptPath"
        exit 1
    }
}

function Show-Overview {
    Write-RemoteKitInfrastructureLog "`n=================== Parameter Overview ======="
    Write-RemoteKitInfrastructureLog "Port        = $Port"
    Write-RemoteKitInfrastructureLog "RemoteHost  = $RemoteHost"
    Write-RemoteKitInfrastructureLog "RemoteUser  = $RemoteUser"
    Write-RemoteKitInfrastructureLog "SshKeyPath  = $SshKeyPath"
    Write-RemoteKitInfrastructureLog "ScriptPath  = $ScriptPath"
    Write-RemoteKitInfrastructureLog "ScriptArgs  = $($scriptArgs.Count)"
    Write-RemoteKitInfrastructureLog "OpenSshOpts = $($remoteKit.SshCommonOpts -join ' ')"
    Write-RemoteKitInfrastructureLog "CommandOpts = $($remoteKit.SshCommandOpts -join ' ')"
    Write-RemoteKitInfrastructureLog "PuttyHostKey= $(if ($remoteKit.AutoAcceptPuttyHostKey) { 'auto-accept' } else { 'manual-confirm' })"
    Write-RemoteKitInfrastructureLog "==============================================="
}

$scriptArgs = Get-ForwardedScriptArgs

Show-Overview
Assert-LocalInputs

$scriptContent = [System.IO.File]::ReadAllText($ScriptPath)
$remoteTemp = New-RemoteKitRemoteTempSpec
$remoteScriptName = "$($remoteTemp.Dir)/script.sh"
$remoteArgText = ($scriptArgs | ForEach-Object { Quote-RemoteKitPosixArg $_ }) -join " "
$remoteRunScript = if ([string]::IsNullOrWhiteSpace($remoteArgText)) {
    "bash $remoteScriptName"
} else {
    "bash $remoteScriptName $remoteArgText"
}
$remoteRunCommand = "code=0; chmod +x $remoteScriptName && $remoteRunScript || code=`$?; rm -rf $($remoteTemp.Dir); exit `$code"

Write-RemoteKitInfrastructureLog "[STEP] Trying to use OpenSSH client (ssh.exe / scp.exe) with key: $SshKeyPath"
$sshExitCode = Test-RemoteKitOpenSshKeyLogin -OutputOnlyOnError
Write-RemoteKitInfrastructureLog "[INFO] ssh test exit code = $sshExitCode"

if ($sshExitCode -eq 0) {
    Write-RemoteKitInfrastructureLog "[INFO] => OpenSSH-based key login successful, will use ssh/scp."

    $code = Invoke-RemoteKitOpenSshRemote $remoteTemp.InitCommand -UseCommandOptions -OutputOnlyOnError
    if ($code -ne 0) {
        Write-Host "[ERROR] ssh remote temp directory creation failed, exit code = $code"
        exit $code
    }

    $code = Copy-RemoteKitPreparedFile "openssh" "script_" ".sh" $scriptContent "local script" $remoteScriptName $null -OutputOnlyOnError
    if ($code -ne 0) {
        [void](Invoke-RemoteKitOpenSshRemote $remoteTemp.CleanupCommand -UseCommandOptions -OutputOnlyOnError)
        Write-Host "[ERROR] scp local script upload failed, exit code = $code"
        exit $code
    }

    $code = Invoke-RemoteKitOpenSshRemote $remoteRunCommand "<remote script command>" -UseCommandOptions
    if ($code -ne 0) {
        [void](Invoke-RemoteKitOpenSshRemote $remoteTemp.CleanupCommand -UseCommandOptions -OutputOnlyOnError)
        Write-Host "[ERROR] remote script failed, exit code = $code"
        exit $code
    }

    Write-RemoteKitInfrastructureLog "[INFO] Done via OpenSSH. exit 0"
    exit 0
}

Write-RemoteKitInfrastructureLog "[WARN] => OpenSSH failed to use private key, will use PuTTY (plink/pscp)."
Assert-RemoteKitPuttyTools
Initialize-RemoteKitPuttyHostKeyCache

$password = Read-RemoteKitSshPassword
$passwordFile = $null
try {
    $passwordFile = New-RemoteKitPasswordFile $password

    $code = Invoke-RemoteKitPuttyRemote $remoteTemp.InitCommand $passwordFile -OutputOnlyOnError
    if ($code -ne 0) {
        Write-Host "[ERROR] plink remote temp directory creation failed, exit code=$code"
        exit $code
    }

    $code = Copy-RemoteKitPreparedFile "putty" "script_" ".sh" $scriptContent "local script" $remoteScriptName $passwordFile -OutputOnlyOnError
    if ($code -ne 0) {
        [void](Invoke-RemoteKitPuttyRemote $remoteTemp.CleanupCommand $passwordFile -OutputOnlyOnError)
        Write-Host "[ERROR] pscp local script upload failed, exit code=$code"
        exit $code
    }

    $code = Invoke-RemoteKitPuttyRemote $remoteRunCommand $passwordFile "<remote script command>"
    if ($code -ne 0) {
        [void](Invoke-RemoteKitPuttyRemote $remoteTemp.CleanupCommand $passwordFile -OutputOnlyOnError)
    }
} finally {
    Remove-RemoteKitTempPath $passwordFile
    $password = $null
}

if ($code -ne 0) {
    Write-Host "[ERROR] remote script failed, exit code=$code"
    exit $code
}

Write-RemoteKitInfrastructureLog "`n[INFO] Done via PuTTY. exit 0"
exit 0
