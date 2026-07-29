<#
.SYNOPSIS
  OpenSSH single-connection helpers for key_manager.ps1.
#>

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

function New-RemoteKitKeyManagerOpenSshPayload {
    param(
        [Parameter(Mandatory=$true)] [ValidateSet("add","remove","fix")] [string]$Action,
        [Parameter(Mandatory=$true)] [ValidateSet("check-sshd","fix-sshd","skip-sshd")] [string]$SshdMode,
        [Parameter(Mandatory=$true)] [string]$HelperContent,
        [AllowNull()] [string]$PublicKeyLine,
        [AllowNull()] [string]$Token = $null
    )

    if (($Action -eq "add" -or $Action -eq "remove") -and [string]::IsNullOrWhiteSpace($PublicKeyLine)) {
        throw "PublicKeyLine is required for key_manager action '$Action'."
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        $Token = [guid]::NewGuid().ToString("N")
    }

    $scriptDelimiter = "REMOTE_KIT_${Token}_SCRIPT"
    $pubkeyDelimiter = "REMOTE_KIT_${Token}_PUBKEY"
    $helperText = ConvertTo-RemoteKitLfText $HelperContent
    $publicKeyText = if ($null -eq $PublicKeyLine) { "" } else { ConvertTo-RemoteKitLfText $PublicKeyLine }

    if ($helperText.Contains($scriptDelimiter) -or $publicKeyText.Contains($pubkeyDelimiter)) {
        throw "Generated heredoc delimiter unexpectedly appears in key_manager payload content."
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("set -euo pipefail")
    $lines.Add("remote_dir=`"`$(mktemp -d `"$(Get-RemoteKitOpenSshTempDirectoryTemplate)`")`"")
    $lines.Add("umask 077")
    $lines.Add("cleanup() { rm -rf `"`$remote_dir`"; }")
    $lines.Add("trap cleanup EXIT")
    $lines.Add("script_path=`"`$remote_dir/authorized_keys.sh`"")
    $lines.Add("pubkey_path=`"`$remote_dir/key.pub`"")
    $lines.Add("cat > `"`$script_path`" <<'$scriptDelimiter'")
    $lines.Add(($helperText.TrimEnd("`n")))
    $lines.Add($scriptDelimiter)
    $lines.Add("chmod +x `"`$script_path`"")

    if ($Action -ne "fix") {
        $lines.Add("cat > `"`$pubkey_path`" <<'$pubkeyDelimiter'")
        $lines.Add(($publicKeyText.TrimEnd("`n")))
        $lines.Add($pubkeyDelimiter)
    }

    $actionArg = Quote-RemoteKitPosixArg $Action
    $modeArg = Quote-RemoteKitPosixArg $SshdMode
    $lines.Add("bash `"`$script_path`" $actionArg `"`$pubkey_path`" $modeArg")

    return (($lines.ToArray() -join "`n") + "`n")
}

function Get-RemoteKitKeyManagerOpenSshOptions {
    param([switch]$PasswordBootstrap)

    if ($PasswordBootstrap.IsPresent) {
        return @(
            "-o", "BatchMode=no",
            "-o", "PubkeyAuthentication=no",
            "-o", "PasswordAuthentication=yes",
            "-o", "KbdInteractiveAuthentication=yes",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=3"
        )
    }

    return @("-o", "BatchMode=yes")
}

function New-RemoteKitKeyManagerOpenSshArgs {
    param([switch]$PasswordBootstrap)

    return @(Get-RemoteKitOpenSshBaseArgs) `
        + @("-T") `
        + @(Get-RemoteKitKeyManagerOpenSshOptions -PasswordBootstrap:$PasswordBootstrap.IsPresent) `
        + @(Get-RemoteKitOpenSshTargetArgs) `
        + @("bash -s")
}

function Convert-RemoteKitOpenSshIdentityPath {
    param(
        [Parameter(Mandatory=$true)] [string]$Value,
        [Parameter(Mandatory=$true)] [string]$UserProfile
    )

    $path = $Value.Trim().Trim('"')
    if ($path -ieq "none" -or [string]::IsNullOrWhiteSpace($path)) {
        return $null
    }

    if ($path -eq "~") {
        return $UserProfile
    }

    if ($path.StartsWith("~/") -or $path.StartsWith("~\")) {
        $tail = $path.Substring(2).Replace("/", "\")
        return (Join-Path $UserProfile $tail)
    }

    if ($path -match '^[A-Za-z]:/') {
        return $path.Replace("/", "\")
    }

    return $path
}

function Select-RemoteKitOpenSshIdentityFile {
    param(
        [Parameter(Mandatory=$true)] [string]$EffectiveConfigText,
        [string]$UserProfile = $env:USERPROFILE
    )

    foreach ($line in ($EffectiveConfigText -split '\r?\n')) {
        if ($line -notmatch '^\s*identityfile\s+(.+?)\s*$') {
            continue
        }

        $candidate = Convert-RemoteKitOpenSshIdentityPath $Matches[1] $UserProfile
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return $null
}

function Resolve-RemoteKitOpenSshIdentityFile {
    $ctx = Get-RemoteKitContext
    if (-not $ctx.UseSshConfigHost) {
        return $ctx.SshKeyPath
    }

    $args = @("-G") + @(Get-RemoteKitOpenSshBaseArgs) + @(Get-RemoteKitOpenSshTargetArgs)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $ctx.SshExe
    $process.StartInfo.Arguments = Join-RemoteKitProcessArguments $args
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true

    $process.Start() | Out-Null
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        foreach ($line in ($stderr -split '\r?\n')) {
            if ($line) { Write-Host $line }
        }
        throw "ssh -G failed while resolving IdentityFile for $($ctx.RemoteTarget)."
    }

    $identityFile = Select-RemoteKitOpenSshIdentityFile $stdout
    if ([string]::IsNullOrWhiteSpace($identityFile)) {
        throw "No usable IdentityFile found from ssh -G for $($ctx.RemoteTarget). Add IdentityFile to the embedded ssh_config block."
    }

    return $identityFile
}

function Invoke-RemoteKitKeyManagerOpenSshPayload {
    param(
        [Parameter(Mandatory=$true)] [string]$Payload,
        [switch]$PasswordBootstrap
    )

    return Invoke-RemoteKitOpenSshStdinPayload `
        -Payload $Payload `
        -ExtraSshOptions @(Get-RemoteKitKeyManagerOpenSshOptions -PasswordBootstrap:$PasswordBootstrap.IsPresent) `
        -DisplayName "key_manager stdin payload"
}
