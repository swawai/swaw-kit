<#
.SYNOPSIS
  Run a local shell script on the remote host through one OpenSSH connection.

.DESCRIPTION
  The local script is streamed to remote bash through stdin. The remote side
  writes it into a private temp directory, runs it with forwarded arguments,
  and removes the temp directory on exit.
#>

param(
    [Parameter(Mandatory=$true)] [int]$Port,
    [Parameter(Mandatory=$true)] [string]$RemoteHost,
    [Parameter(Mandatory=$true)] [string]$RemoteUser,
    [AllowEmptyString()] [Parameter(Mandatory=$true)] [string]$SshKeyPath,
    [Parameter(Mandatory=$true)] [string]$ScriptPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "ps_common.ps1")
. (Join-Path $PSScriptRoot "script_runner.openssh.ps1")

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
    Write-RemoteKitInfrastructureLog "==============================================="
}

$scriptArgs = Get-ForwardedScriptArgs

Show-Overview
Assert-LocalInputs

$scriptContent = [System.IO.File]::ReadAllText($ScriptPath)
$payload = New-RemoteKitScriptRunnerOpenSshPayload `
    -ScriptContent $scriptContent `
    -ScriptArgs $scriptArgs

$code = Invoke-RemoteKitScriptRunnerOpenSshPayload $payload
if ($code -ne 0) {
    Write-Host "[ERROR] remote script failed, exit code=$code"
    exit $code
}

Write-RemoteKitInfrastructureLog "[INFO] Done via OpenSSH stdin payload. exit 0"
exit 0
