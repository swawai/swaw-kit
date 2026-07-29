<#
.SYNOPSIS
  Shared local PowerShell runtime helpers for ssh_remote_kit.
#>

$script:RemoteKitContext = $null

function Get-RemoteKitOpenSshTempDirectoryTemplate {
    return '${TMPDIR:-/tmp}/swaw-kit-ssh-remote.XXXXXXXXXX'
}

function Test-RemoteKitVerbose {
    $value = $env:REMOTE_KIT_VERBOSE
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }

    return $value -match '^(1|true|yes|on|debug)$'
}

function Test-RemoteKitInfrastructureLogEnabled {
    if (Test-RemoteKitVerbose) {
        return $true
    }

    if ($null -eq $script:RemoteKitContext) {
        return $true
    }

    return -not [bool]$script:RemoteKitContext.QuietInfrastructureOutput
}

function Write-RemoteKitInfrastructureLog {
    param([Parameter(Mandatory=$true)] [string]$Message)

    if (Test-RemoteKitInfrastructureLogEnabled) {
        Write-Host $Message
    }
}

function Split-RemoteKitOptionString {
    param([AllowNull()] [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    $tokens = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Text.StringBuilder
    $inQuotes = $false

    for ($i = 0; $i -lt $Value.Length; $i++) {
        $ch = $Value[$i]

        if ($ch -eq '\' -and $inQuotes -and ($i + 1) -lt $Value.Length -and $Value[$i + 1] -eq '"') {
            [void]$current.Append('"')
            $i++
            continue
        }

        if ($ch -eq '"') {
            $inQuotes = -not $inQuotes
            continue
        }

        if ([char]::IsWhiteSpace($ch) -and -not $inQuotes) {
            if ($current.Length -gt 0) {
                $tokens.Add($current.ToString())
                [void]$current.Clear()
            }
            continue
        }

        [void]$current.Append($ch)
    }

    if ($inQuotes) {
        throw "Unclosed quote in REMOTE_KIT SSH option string: $Value"
    }

    if ($current.Length -gt 0) {
        $tokens.Add($current.ToString())
    }

    return $tokens.ToArray()
}

function Initialize-RemoteKitContext {
    param(
        [Parameter(Mandatory=$true)] [int]$Port,
        [Parameter(Mandatory=$true)] [string]$RemoteHost,
        [Parameter(Mandatory=$true)] [string]$RemoteUser,
        [AllowEmptyString()] [Parameter(Mandatory=$true)] [string]$SshKeyPath,
        [Parameter(Mandatory=$true)] [string]$ModuleRoot,
        [Parameter(Mandatory=$true)] [string]$UploadSubdir,
        [AllowNull()] [string]$SshConfigPath = $env:REMOTE_KIT_SSH_CONFIG_PATH,
        [AllowNull()] [string]$SshHostAlias = $env:REMOTE_KIT_SSH_HOST,
        [switch]$QuietInfrastructureOutput
    )

    $libRoot = Split-Path -Parent $ModuleRoot
    $repoRoot = Split-Path -Parent $libRoot
    $tempWorkspaceRoot = Join-Path $repoRoot "temp_workspace"
    $uploadTempRoot = Join-Path $tempWorkspaceRoot $UploadSubdir

    $useSshConfigHost = -not [string]::IsNullOrWhiteSpace($SshConfigPath) -and -not [string]::IsNullOrWhiteSpace($SshHostAlias)

    $sshIdOpts = @(Split-RemoteKitOptionString $env:REMOTE_KIT_SSH_ID_OPTS)
    if ($sshIdOpts.Count -eq 0) {
        $sshIdOpts = if ($useSshConfigHost) { @() } else { @("-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes") }
    }

    $sshHostKeyOpts = @(Split-RemoteKitOptionString $env:REMOTE_KIT_SSH_HOSTKEY_OPTS)
    if ($sshHostKeyOpts.Count -eq 0) {
        $sshHostKeyOpts = if ($useSshConfigHost) { @() } else { @("-o", "StrictHostKeyChecking=accept-new") }
    }

    $sshLogOpts = @(Split-RemoteKitOptionString $env:REMOTE_KIT_SSH_LOG_OPTS)
    $sshCommandOpts = @(Split-RemoteKitOptionString $env:REMOTE_KIT_SSH_COMMAND_OPTS)
    if ($sshCommandOpts.Count -eq 0) {
        $sshCommandOpts = @("-n", "-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=60", "-o", "ServerAliveCountMax=3")
    }

    $sshCommonOpts = @($sshIdOpts + $sshHostKeyOpts + $sshLogOpts)

    $script:RemoteKitContext = [pscustomobject]@{
        Port                    = $Port
        RemoteHost              = $RemoteHost
        RemoteUser              = $RemoteUser
        RemoteTarget            = if ($useSshConfigHost) { $SshHostAlias } else { "$RemoteUser@$RemoteHost" }
        SshKeyPath              = $SshKeyPath
        SshConfigPath           = $SshConfigPath
        SshHostAlias            = $SshHostAlias
        UseSshConfigHost        = $useSshConfigHost
        ModuleRoot              = $ModuleRoot
        RepoRoot                = $repoRoot
        TempWorkspaceRoot       = $tempWorkspaceRoot
        UploadTempRoot          = $uploadTempRoot
        SshExe                  = "ssh.exe"
        SshCommonOpts           = $sshCommonOpts
        SshCommandOpts          = $sshCommandOpts
        QuietInfrastructureOutput = $QuietInfrastructureOutput.IsPresent
    }

    return $script:RemoteKitContext
}

function Get-RemoteKitContext {
    if ($null -eq $script:RemoteKitContext) {
        throw "Remote kit context has not been initialized."
    }

    return $script:RemoteKitContext
}

function Get-RemoteKitOpenSshBaseArgs {
    $ctx = Get-RemoteKitContext
    $args = @()

    if ($ctx.UseSshConfigHost) {
        $args += @("-F", $ctx.SshConfigPath)
    } else {
        $args += @("-i", $ctx.SshKeyPath)
    }

    $args += $ctx.SshCommonOpts
    return $args
}

function Get-RemoteKitOpenSshTargetArgs {
    $ctx = Get-RemoteKitContext
    if ($ctx.UseSshConfigHost) {
        return @($ctx.RemoteTarget)
    }

    return @("-p", $ctx.Port, $ctx.RemoteTarget)
}

function Format-RemoteKitArgForLog {
    param([AllowNull()] [object]$Argument)

    $value = [string]$Argument
    if ($value -match '[\s"]') {
        return '"' + ($value -replace '"', '\"') + '"'
    }

    return $value
}

function Format-RemoteKitCommandForLog {
    param(
        [Parameter(Mandatory=$true)] [string]$ExePath,
        [Parameter(Mandatory=$true)] [object[]]$Arguments
    )

    $displayArgs = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = [string]$Arguments[$i]

        $displayArgs.Add((Format-RemoteKitArgForLog $arg))
    }

    return "$ExePath $($displayArgs -join ' ')"
}

function Join-RemoteKitProcessArguments {
    param([Parameter(Mandatory=$true)] [object[]]$Arguments)

    $quoted = foreach ($arg in $Arguments) {
        $value = [string]$arg
        if ($value -eq "") {
            '""'
        } elseif ($value -notmatch '[\s"]') {
            $value
        } else {
            '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
        }
    }

    return $quoted -join " "
}

function Invoke-RemoteKitLoggedCommand {
    param(
        [Parameter(Mandatory=$true)] [string]$Label,
        [Parameter(Mandatory=$true)] [string]$ExePath,
        [Parameter(Mandatory=$true)] [object[]]$Arguments,
        [AllowNull()] [object[]]$LogArguments = $null,
        [switch]$OutputOnlyOnError
    )

    $displayArguments = if ($null -eq $LogArguments) { $Arguments } else { $LogArguments }
    Write-RemoteKitInfrastructureLog "[DEBUG] ${Label}: $(Format-RemoteKitCommandForLog $ExePath $displayArguments)"

    if (-not $OutputOnlyOnError.IsPresent) {
        & $ExePath @Arguments | ForEach-Object { Write-Host $_ }
        return $LASTEXITCODE
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $ExePath
    $process.StartInfo.Arguments = Join-RemoteKitProcessArguments $Arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardInput = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true

    $process.Start() | Out-Null
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if (-not $OutputOnlyOnError.IsPresent -or $process.ExitCode -ne 0) {
        foreach ($line in ($stdout -split '\r?\n')) {
            if ($line) { Write-Host $line }
        }
        foreach ($line in ($stderr -split '\r?\n')) {
            if ($line) { Write-Host $line }
        }
    }

    return $process.ExitCode
}

function Remove-RemoteKitTempPath {
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $ctx = Get-RemoteKitContext
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue

    $dir = Split-Path -Parent $Path
    foreach ($candidate in @($dir, $ctx.TempWorkspaceRoot)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $remaining = @(Get-ChildItem -LiteralPath $candidate -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function New-RemoteKitUploadTextFile {
    param(
        [Parameter(Mandatory=$true)] [string]$Prefix,
        [Parameter(Mandatory=$true)] [string]$Extension,
        [Parameter(Mandatory=$true)] [string]$Content,
        [Parameter(Mandatory=$true)] [string]$DisplayName
    )

    $ctx = Get-RemoteKitContext
    New-Item -ItemType Directory -Force -Path $ctx.UploadTempRoot | Out-Null

    if (-not $Extension.StartsWith(".")) {
        $Extension = ".$Extension"
    }

    $path = Join-Path $ctx.UploadTempRoot ("$Prefix$([guid]::NewGuid().ToString("N"))$Extension")
    $sourceHasBom = $Content.Length -gt 0 -and [int][char]$Content[0] -eq 0xFEFF
    if ($sourceHasBom) {
        $Content = $Content.Substring(1)
    }

    $sourceHasCr = $Content.Contains("`r")
    $contentLf = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $contentLf.EndsWith("`n")) {
        $contentLf += "`n"
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $contentLf, $utf8NoBom)

    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes -contains [byte]13) {
        throw "Upload temp file still contains CR bytes: $path"
    }

    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    if ($hasBom) {
        throw "Upload temp file still contains UTF-8 BOM: $path"
    }

    Write-RemoteKitInfrastructureLog "[INFO] Prepared $DisplayName for upload: sourceCR=$sourceHasCr sourceBOM=$sourceHasBom => uploadLF=True uploadBOM=False"
    return $path
}

function Invoke-RemoteKitOpenSshStdinPayload {
    param(
        [Parameter(Mandatory=$true)] [string]$Payload,
        [AllowNull()] [object[]]$ExtraSshOptions = @(),
        [string]$RemoteCommand = "bash -s",
        [string]$DisplayName = "stdin payload"
    )

    $ctx = Get-RemoteKitContext
    $payloadPath = $null

    try {
        $payloadPath = New-RemoteKitUploadTextFile "swaw-kit-ssh-remote-payload-" ".sh" $Payload $DisplayName
        $args = @(Get-RemoteKitOpenSshBaseArgs) + @("-T") + @($ExtraSshOptions) + @(Get-RemoteKitOpenSshTargetArgs) + @($RemoteCommand)
        Write-RemoteKitInfrastructureLog "[DEBUG] ssh command: $(Format-RemoteKitCommandForLog $ctx.SshExe ($args + @("<", $payloadPath)))"

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo.FileName = $ctx.SshExe
        $process.StartInfo.Arguments = Join-RemoteKitProcessArguments $args
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $false
        $process.StartInfo.RedirectStandardInput = $true
        $process.StartInfo.RedirectStandardOutput = $false
        $process.StartInfo.RedirectStandardError = $false

        $process.Start() | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($payloadPath)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
        $process.WaitForExit()
        return $process.ExitCode
    } finally {
        Remove-RemoteKitTempPath $payloadPath
    }
}

function Test-RemoteKitOpenSshKeyLogin {
    param([switch]$OutputOnlyOnError)

    $ctx = Get-RemoteKitContext
    $testArgs = @(Get-RemoteKitOpenSshBaseArgs) + @("-o", "BatchMode=yes") + @(Get-RemoteKitOpenSshTargetArgs) + @("echo OK")
    return Invoke-RemoteKitLoggedCommand "ssh command" $ctx.SshExe $testArgs -OutputOnlyOnError:$OutputOnlyOnError.IsPresent
}

function Quote-RemoteKitPosixArg {
    param([AllowNull()] [string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }

    $singleQuote = [string][char]39
    $doubleQuote = [string][char]34
    $escapedSingleQuote = $singleQuote + $doubleQuote + $singleQuote + $doubleQuote + $singleQuote
    return $singleQuote + ([string]$Value).Replace($singleQuote, $escapedSingleQuote) + $singleQuote
}
