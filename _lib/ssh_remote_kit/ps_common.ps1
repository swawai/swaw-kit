<#
.SYNOPSIS
  Shared local PowerShell runtime helpers for ssh_remote_kit.
#>

$script:RemoteKitContext = $null

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

function Test-RemoteKitOpenSshOption {
    param(
        [Parameter(Mandatory=$true)] [object[]]$Options,
        [Parameter(Mandatory=$true)] [string]$Name,
        [Parameter(Mandatory=$true)] [string]$Value
    )

    $text = $Options -join " "
    $namePattern = [regex]::Escape($Name)
    $valuePattern = [regex]::Escape($Value)
    return $text -imatch "(^|\s)(-o\s*)?$namePattern\s*=\s*$valuePattern(\s|$)"
}

function Initialize-RemoteKitContext {
    param(
        [Parameter(Mandatory=$true)] [int]$Port,
        [Parameter(Mandatory=$true)] [string]$RemoteHost,
        [Parameter(Mandatory=$true)] [string]$RemoteUser,
        [Parameter(Mandatory=$true)] [string]$SshKeyPath,
        [Parameter(Mandatory=$true)] [string]$ModuleRoot,
        [Parameter(Mandatory=$true)] [string]$UploadSubdir,
        [switch]$QuietInfrastructureOutput
    )

    $libRoot = Split-Path -Parent $ModuleRoot
    $repoRoot = Split-Path -Parent $libRoot
    $tempWorkspaceRoot = Join-Path $repoRoot "temp_workspace"
    $uploadTempRoot = Join-Path $tempWorkspaceRoot $UploadSubdir

    $sshIdOpts = @(Split-RemoteKitOptionString $env:REMOTE_KIT_SSH_ID_OPTS)
    if ($sshIdOpts.Count -eq 0) {
        $sshIdOpts = @("-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes")
    }

    $sshHostKeyOpts = @(Split-RemoteKitOptionString $env:REMOTE_KIT_SSH_HOSTKEY_OPTS)
    if ($sshHostKeyOpts.Count -eq 0) {
        $sshHostKeyOpts = @("-o", "StrictHostKeyChecking=accept-new")
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
        RemoteTarget            = "$RemoteUser@$RemoteHost"
        SshKeyPath              = $SshKeyPath
        ModuleRoot              = $ModuleRoot
        RepoRoot                = $repoRoot
        TempWorkspaceRoot       = $tempWorkspaceRoot
        UploadTempRoot          = $uploadTempRoot
        PlinkPath               = Join-Path $ModuleRoot "plink.exe"
        PscpPath                = Join-Path $ModuleRoot "pscp.exe"
        SshExe                  = "ssh.exe"
        ScpExe                  = "scp.exe"
        SshCommonOpts           = $sshCommonOpts
        SshCommandOpts          = $sshCommandOpts
        AutoAcceptPuttyHostKey  = Test-RemoteKitOpenSshOption $sshHostKeyOpts "StrictHostKeyChecking" "no"
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

        if (($arg -eq "-pw" -or $arg -eq "-pwfile") -and ($i + 1) -lt $Arguments.Count) {
            $displayArgs.Add($arg)
            $displayArgs.Add("<hidden>")
            $i++
            continue
        }

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
        [AllowNull()] [string]$InputText = $null,
        [switch]$OutputOnlyOnError
    )

    $displayArguments = if ($null -eq $LogArguments) { $Arguments } else { $LogArguments }
    Write-RemoteKitInfrastructureLog "[DEBUG] ${Label}: $(Format-RemoteKitCommandForLog $ExePath $displayArguments)"

    if (-not $OutputOnlyOnError.IsPresent -and -not $PSBoundParameters.ContainsKey("InputText")) {
        & $ExePath @Arguments | ForEach-Object { Write-Host $_ }
        return $LASTEXITCODE
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $ExePath
    $process.StartInfo.Arguments = Join-RemoteKitProcessArguments $Arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardInput = $PSBoundParameters.ContainsKey("InputText")
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true

    $process.Start() | Out-Null
    if ($PSBoundParameters.ContainsKey("InputText")) {
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
    }

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

function New-RemoteKitPasswordFile {
    param([Parameter(Mandatory=$true)] [string]$Password)

    $ctx = Get-RemoteKitContext

    if ($Password.Contains("`r") -or $Password.Contains("`n")) {
        throw "SSH password must not contain CR/LF characters when using PuTTY -pwfile."
    }

    New-Item -ItemType Directory -Force -Path $ctx.UploadTempRoot | Out-Null

    $path = Join-Path $ctx.UploadTempRoot ("password_$([guid]::NewGuid().ToString("N")).txt")
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, "", $utf8NoBom)

    $currentUserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $path /inheritance:r /grant:r "${currentUserName}:F" "SYSTEM:F" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Remove-RemoteKitTempPath $path
        throw "Failed to protect SSH password temp file ACL: $path"
    }

    [System.IO.File]::WriteAllText($path, $Password, $utf8NoBom)
    return $path
}

function Copy-RemoteKitPreparedFile {
    param(
        [Parameter(Mandatory=$true)] [ValidateSet("openssh","putty")] [string]$Client,
        [Parameter(Mandatory=$true)] [string]$Prefix,
        [Parameter(Mandatory=$true)] [string]$Extension,
        [Parameter(Mandatory=$true)] [string]$Content,
        [Parameter(Mandatory=$true)] [string]$DisplayName,
        [Parameter(Mandatory=$true)] [string]$RemoteName,
        [AllowNull()] [string]$PasswordFile,
        [switch]$OutputOnlyOnError
    )

    $ctx = Get-RemoteKitContext
    $localPath = $null
    try {
        $localPath = New-RemoteKitUploadTextFile $Prefix $Extension $Content $DisplayName

        if ($Client -eq "openssh") {
            $args = @("-i", $ctx.SshKeyPath, "-o", "BatchMode=yes") + $ctx.SshCommonOpts + @("-P", $ctx.Port, $localPath, "$($ctx.RemoteTarget):$RemoteName")
            return Invoke-RemoteKitLoggedCommand "scp command" $ctx.ScpExe $args -OutputOnlyOnError:$OutputOnlyOnError.IsPresent
        }

        $args = @("-batch", "-P", $ctx.Port, "-pwfile", $PasswordFile, $localPath, "$($ctx.RemoteTarget):$RemoteName")
        return Invoke-RemoteKitLoggedCommand "pscp command" $ctx.PscpPath $args -OutputOnlyOnError:$OutputOnlyOnError.IsPresent
    } finally {
        Remove-RemoteKitTempPath $localPath
    }
}

function Invoke-RemoteKitOpenSshRemote {
    param(
        [Parameter(Mandatory=$true)] [string]$Command,
        [AllowNull()] [string]$CommandForLog = $null,
        [switch]$UseCommandOptions,
        [switch]$OutputOnlyOnError
    )

    $ctx = Get-RemoteKitContext
    $args = @("-i", $ctx.SshKeyPath) + $ctx.SshCommonOpts
    if ($UseCommandOptions.IsPresent) {
        $args += $ctx.SshCommandOpts
    }
    $args += @("-p", $ctx.Port, $ctx.RemoteTarget, $Command)

    $logArgs = $null
    if (-not [string]::IsNullOrWhiteSpace($CommandForLog)) {
        $logArgs = @("-i", $ctx.SshKeyPath) + $ctx.SshCommonOpts
        if ($UseCommandOptions.IsPresent) {
            $logArgs += $ctx.SshCommandOpts
        }
        $logArgs += @("-p", $ctx.Port, $ctx.RemoteTarget, $CommandForLog)
    }

    return Invoke-RemoteKitLoggedCommand "ssh command" $ctx.SshExe $args $logArgs -OutputOnlyOnError:$OutputOnlyOnError.IsPresent
}

function Invoke-RemoteKitPuttyRemote {
    param(
        [Parameter(Mandatory=$true)] [string]$Command,
        [Parameter(Mandatory=$true)] [string]$PasswordFile,
        [AllowNull()] [string]$CommandForLog = $null,
        [switch]$OutputOnlyOnError
    )

    $ctx = Get-RemoteKitContext
    $args = @("-batch", "-ssh", "-P", $ctx.Port, "-pwfile", $PasswordFile, $ctx.RemoteTarget, $Command)

    $logArgs = $null
    if (-not [string]::IsNullOrWhiteSpace($CommandForLog)) {
        $logArgs = @("-batch", "-ssh", "-P", $ctx.Port, "-pwfile", $PasswordFile, $ctx.RemoteTarget, $CommandForLog)
    }

    return Invoke-RemoteKitLoggedCommand "plink command" $ctx.PlinkPath $args $logArgs -OutputOnlyOnError:$OutputOnlyOnError.IsPresent
}

function Test-RemoteKitOpenSshKeyLogin {
    param([switch]$OutputOnlyOnError)

    $ctx = Get-RemoteKitContext
    $testArgs = @("-i", $ctx.SshKeyPath, "-o", "BatchMode=yes") + $ctx.SshCommonOpts + @("-p", $ctx.Port, $ctx.RemoteTarget, "echo OK")
    return Invoke-RemoteKitLoggedCommand "ssh command" $ctx.SshExe $testArgs -OutputOnlyOnError:$OutputOnlyOnError.IsPresent
}

function Assert-RemoteKitPuttyTools {
    $ctx = Get-RemoteKitContext

    if (-not (Test-Path -LiteralPath $ctx.PlinkPath -PathType Leaf)) {
        Write-Host "[ERROR] plink.exe not found: $($ctx.PlinkPath)"
        exit 1
    }

    if (-not (Test-Path -LiteralPath $ctx.PscpPath -PathType Leaf)) {
        Write-Host "[ERROR] pscp.exe not found: $($ctx.PscpPath)"
        exit 1
    }
}

function Read-RemoteKitSshPassword {
    $ctx = Get-RemoteKitContext

    do {
        $password = $env:REMOTE_KIT_SSH_PASSWORD
        if (-not [string]::IsNullOrWhiteSpace($password)) {
            Write-RemoteKitInfrastructureLog "[INFO] Using SSH password from REMOTE_KIT_SSH_PASSWORD."
        } else {
            $secure = Read-Host -Prompt "Please input the SSH password for $($ctx.RemoteUser)@$($ctx.RemoteHost) (input hidden)" -AsSecureString
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            $password = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        if ([string]::IsNullOrWhiteSpace($password)) {
            Write-Host "Password cannot be empty. Please try again."
        }
    } while ([string]::IsNullOrWhiteSpace($password))

    return $password
}

function Initialize-RemoteKitPuttyHostKeyCache {
    $ctx = Get-RemoteKitContext
    $fakeUser = "remote_kit_probe_fe750f81_9419_4787_a836_01b4e0719736"
    $fakePass = "0f71e8a8_0d43_4fd6_8fd7_7cae82b8c3b1"
    $fakePassPath = $null

    Write-Host "`n[STEP] Using virtual user '$fakeUser' + fakePassword for an interactive plink connection, to cache hostkey."

    try {
        $fakePassPath = New-RemoteKitPasswordFile $fakePass
        $args = @("-ssh", "-P", $ctx.Port, "-pwfile", $fakePassPath, "$fakeUser@$($ctx.RemoteHost)")

        if ($ctx.AutoAcceptPuttyHostKey) {
            Write-Host "[INFO] StrictHostKeyChecking=no detected; auto-confirming PuTTY host key cache step."
            [void](Invoke-RemoteKitLoggedCommand "plink command" $ctx.PlinkPath $args $null "y`n")
        } else {
            $answer = Read-Host "Continue? [Y/N]"
            if ($answer -notmatch '^[Yy]$') {
                Write-Host "User cancelled, script exiting."
                exit 0
            }

            [void](Invoke-RemoteKitLoggedCommand "plink command" $ctx.PlinkPath $args)
        }
    } finally {
        Remove-RemoteKitTempPath $fakePassPath
    }

    Write-Host "`n[INFO] Virtual user connection ended (will report Access denied). If you have already input 'yes', host key has been cached.`n"
}

function New-RemoteKitRemoteTempSpec {
    $remoteId = [guid]::NewGuid().ToString("N")
    $remoteDir = "/tmp/remote_kit_$remoteId"

    return [pscustomobject]@{
        Id             = $remoteId
        Dir            = $remoteDir
        InitCommand    = "umask 077; mkdir $remoteDir && chmod 700 $remoteDir"
        CleanupCommand = "rm -rf $remoteDir"
    }
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
