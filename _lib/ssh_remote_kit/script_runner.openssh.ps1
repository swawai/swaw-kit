<#
.SYNOPSIS
  OpenSSH single-connection helpers for script_runner.ps1.
#>

function ConvertTo-RemoteKitScriptRunnerLfText {
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

function New-RemoteKitScriptRunnerOpenSshPayload {
    param(
        [Parameter(Mandatory=$true)] [string]$ScriptContent,
        [AllowNull()] [object[]]$ScriptArgs = @(),
        [AllowNull()] [string]$Token = $null
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        $Token = [guid]::NewGuid().ToString("N")
    }

    $scriptDelimiter = "REMOTE_KIT_${Token}_SCRIPT"
    $scriptText = ConvertTo-RemoteKitScriptRunnerLfText $ScriptContent
    if ($scriptText.Contains($scriptDelimiter)) {
        throw "Generated heredoc delimiter unexpectedly appears in script_runner payload content."
    }

    $remoteArgText = ($ScriptArgs | ForEach-Object { Quote-RemoteKitPosixArg $_ }) -join " "
    $remoteRunScript = if ([string]::IsNullOrWhiteSpace($remoteArgText)) {
        "bash `"`$script_path`""
    } else {
        "bash `"`$script_path`" $remoteArgText"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("set -euo pipefail")
    $lines.Add("remote_dir=`"`$(mktemp -d `"`${TMPDIR:-/tmp}/remote_kit.XXXXXXXXXX`")`"")
    $lines.Add("umask 077")
    $lines.Add("cleanup() { rm -rf `"`$remote_dir`"; }")
    $lines.Add("trap cleanup EXIT")
    $lines.Add("script_path=`"`$remote_dir/script.sh`"")
    $lines.Add("cat > `"`$script_path`" <<'$scriptDelimiter'")
    $lines.Add($scriptText.TrimEnd("`n"))
    $lines.Add($scriptDelimiter)
    $lines.Add("chmod +x `"`$script_path`"")
    $lines.Add($remoteRunScript)

    return (($lines.ToArray() -join "`n") + "`n")
}

function Get-RemoteKitScriptRunnerOpenSshOptions {
    return @(
        "-o", "BatchMode=no",
        "-o", "PreferredAuthentications=publickey,password,keyboard-interactive",
        "-o", "NumberOfPasswordPrompts=3",
        "-o", "ServerAliveInterval=60",
        "-o", "ServerAliveCountMax=3"
    )
}

function New-RemoteKitScriptRunnerOpenSshArgs {
    return @(Get-RemoteKitOpenSshBaseArgs) `
        + @("-T") `
        + @(Get-RemoteKitScriptRunnerOpenSshOptions) `
        + @(Get-RemoteKitOpenSshTargetArgs) `
        + @("bash -s")
}

function Invoke-RemoteKitScriptRunnerOpenSshPayload {
    param([Parameter(Mandatory=$true)] [string]$Payload)

    return Invoke-RemoteKitOpenSshStdinPayload `
        -Payload $Payload `
        -ExtraSshOptions @(Get-RemoteKitScriptRunnerOpenSshOptions) `
        -DisplayName "script_runner stdin payload"
}
