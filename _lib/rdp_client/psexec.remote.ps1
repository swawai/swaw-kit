$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0

$Utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8
[Console]::OutputEncoding = $Utf8
$OutputEncoding = $Utf8
$HelperUploadPath = ''

function Get-RdpClientNativeArchitecture {
    $Architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($Architecture)) {
        $Architecture = $env:PROCESSOR_ARCHITECTURE
    }
    if ([string]::IsNullOrWhiteSpace($Architecture)) {
        throw 'Windows architecture environment variables are unavailable.'
    }
    switch ($Architecture.ToUpperInvariant()) {
        'AMD64' { return 'AMD64' }
        'ARM64' { return 'ARM64' }
        'X86' { return 'x86' }
        default { throw "Unsupported Windows architecture: $Architecture" }
    }
}

function Get-RdpClientPsExecDownload {
    param([Parameter(Mandatory = $true)][string]$Architecture)

    switch ($Architecture) {
        'AMD64' {
            return [pscustomobject]@{
                FileName = 'PsExec64.exe'
                Uri      = 'https://live.sysinternals.com/PsExec64.exe'
            }
        }
        'ARM64' {
            return [pscustomobject]@{
                FileName = 'PsExec64a.exe'
                Uri      = 'https://live.sysinternals.com/ARM64/PsExec64a.exe'
            }
        }
        'x86' {
            return [pscustomobject]@{
                FileName = 'PsExec.exe'
                Uri      = 'https://live.sysinternals.com/PsExec.exe'
            }
        }
        default { throw "Unsupported Windows architecture: $Architecture" }
    }
}

function Get-RdpClientPsExecSignature {
    param([Parameter(Mandatory = $true)][string]$Path)

    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    $Subject = ''
    if ($null -ne $Signature.SignerCertificate) {
        $Subject = [string]$Signature.SignerCertificate.Subject
    }
    return [pscustomobject]@{
        Status    = [string]$Signature.Status
        Subject   = $Subject
        IsTrusted = (
            [string]$Signature.Status -eq 'Valid' -and
            $Subject -match '(?:^|,\s*)O=Microsoft Corporation(?:,|$)'
        )
    }
}

function Get-RdpClientSshServerAddress {
    $Parts = @([string]$env:SSH_CONNECTION -split '\s+' | Where-Object {
        $_.Length -gt 0
    })
    if ($Parts.Count -lt 4) {
        throw 'SSH_CONNECTION is unavailable; the peer identity cannot be verified.'
    }
    $Address = $null
    if (-not [Net.IPAddress]::TryParse($Parts[2], [ref]$Address)) {
        throw "SSH_CONNECTION contains an invalid peer address: $($Parts[2])"
    }
    if ($Address.IsIPv4MappedToIPv6) {
        return $Address.MapToIPv4().ToString()
    }
    return $Address.ToString()
}

function Assert-RdpClientExpectedPeer {
    param(
        [Parameter(Mandatory = $true)][string]$PeerAddress,
        [Parameter(Mandatory = $true)][object[]]$ExpectedAddresses
    )

    if (-not @($ExpectedAddresses | Where-Object {
        [string]::Equals(
            [string]$_,
            $PeerAddress,
            [StringComparison]::OrdinalIgnoreCase
        )
    }).Count) {
        throw (
            "SSH peer $PeerAddress does not match the RDP full address " +
            "($($ExpectedAddresses -join ', '))."
        )
    }
}

function Write-RdpClientPsExecHeader {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$PeerAddress,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Write-Output "[RDP] Peer PsExec $Title"
    Write-Output "  Peer:         $env:COMPUTERNAME ($PeerAddress via SSH)"
    Write-Output "  SSH account:  $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Output "  Architecture: $Architecture"
    Write-Output "  Path:         $Path"
}

function Join-RdpClientProcessArguments {
    param([AllowNull()][object[]]$Arguments = @())

    $Quoted = foreach ($Argument in @($Arguments)) {
        $Value = [string]$Argument
        if ($Value.Length -eq 0) {
            '""'
        } elseif ($Value -notmatch '[\s"]') {
            $Value
        } else {
            '"' +
                ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') +
                '"'
        }
    }
    return $Quoted -join ' '
}

function Invoke-RdpClientCapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowNull()][object[]]$Arguments = @()
    )

    $Process = New-Object Diagnostics.Process
    $Started = $false
    try {
        $Process.StartInfo.FileName = $FilePath
        $Process.StartInfo.Arguments = Join-RdpClientProcessArguments $Arguments
        $Process.StartInfo.UseShellExecute = $false
        $Process.StartInfo.CreateNoWindow = $true
        $Process.StartInfo.RedirectStandardInput = $false
        $Process.StartInfo.RedirectStandardOutput = $true
        $Process.StartInfo.RedirectStandardError = $true
        $Process.StartInfo.StandardOutputEncoding = $Utf8
        $Process.StartInfo.StandardErrorEncoding = $Utf8
        $Process.Start() | Out-Null
        $Started = $true
        $StdOutTask = $Process.StandardOutput.ReadToEndAsync()
        $StdErrTask = $Process.StandardError.ReadToEndAsync()
        $Process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $Process.ExitCode
            StdOut   = $StdOutTask.Result
            StdErr   = $StdErrTask.Result
        }
    } finally {
        if ($Started -and -not $Process.HasExited) {
            try { $Process.Kill() } catch { }
        }
        $Process.Dispose()
    }
}

try {
    $PayloadBase64 = '__RDP_CLIENT_PSEXEC_PAYLOAD__'
    $PayloadJson = $Utf8.GetString([Convert]::FromBase64String($PayloadBase64))
    $Request = $PayloadJson | ConvertFrom-Json
    $PeerAddress = Get-RdpClientSshServerAddress
    Assert-RdpClientExpectedPeer `
        -PeerAddress $PeerAddress `
        -ExpectedAddresses @($Request.ExpectedAddresses)

    $Architecture = Get-RdpClientNativeArchitecture
    $Download = Get-RdpClientPsExecDownload -Architecture $Architecture
    $LocalAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    if ([string]::IsNullOrWhiteSpace($LocalAppData)) {
        throw 'The peer SSH account has no LocalApplicationData directory.'
    }
    $ManagedDirectory = Join-Path $LocalAppData 'swaw-kit\rdp-client'
    $ManagedPath = Join-Path $ManagedDirectory 'psexec.exe'
    $HelperPath = Join-Path $ManagedDirectory 'psexec-session-launch.ps1'
    $ExpectedHelperHash = [string]$Request.HelperSha256
    if ($ExpectedHelperHash -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The expected PsExec session helper hash is invalid.'
    }
    $ExpectedHelperHash = $ExpectedHelperHash.ToUpperInvariant()
    if ($Request.Action -eq 'add' -and -not [bool]$Request.DryRun) {
        $HelperUploadName = [string]$Request.HelperUploadName
        if ($HelperUploadName -notmatch
            '^\.swaw-kit-psexec-session-[A-Fa-f0-9]{32}\.ps1$') {
            throw 'The PsExec session helper upload name is invalid.'
        }
        $HelperUploadPath = Join-Path $HOME $HelperUploadName
    }
    $Present = [IO.File]::Exists($ManagedPath)
    $Signature = $null
    if ($Present) {
        $Signature = Get-RdpClientPsExecSignature -Path $ManagedPath
    }
    $HelperPresent = [IO.File]::Exists($HelperPath)
    $HelperHash = ''
    if ($HelperPresent) {
        $HelperHash = (
            Get-FileHash -LiteralPath $HelperPath -Algorithm SHA256
        ).Hash.ToUpperInvariant()
    }
    $HelperReady = $HelperPresent -and $HelperHash -eq $ExpectedHelperHash

    if ($Request.Action -eq 'status') {
        Write-RdpClientPsExecHeader `
            -Title 'status' `
            -PeerAddress $PeerAddress `
            -Architecture $Architecture `
            -Path $ManagedPath
        $Ready = $Present -and $Signature.IsTrusted -and $HelperReady
        if ($Ready) {
            Write-Output '  State:        READY'
        } else {
            Write-Output '  State:        INCOMPLETE'
        }
        if ($Present) {
            $Version = [Diagnostics.FileVersionInfo]::GetVersionInfo(
                $ManagedPath
            ).FileVersion
            Write-Output (
                "  PsExec:       PRESENT version=$Version " +
                "signature=$($Signature.Status)"
            )
        } else {
            Write-Output '  PsExec:       ABSENT'
        }
        if ($HelperReady) {
            Write-Output "  Helper:       READY sha256=$HelperHash"
        } elseif ($HelperPresent) {
            Write-Output "  Helper:       OUTDATED sha256=$HelperHash"
        } else {
            Write-Output '  Helper:       ABSENT'
        }
        exit 0
    }

    if ($Request.Action -eq 'add') {
        if ([bool]$Request.DryRun) {
            Write-RdpClientPsExecHeader `
                -Title 'add plan' `
                -PeerAddress $PeerAddress `
                -Architecture $Architecture `
                -Path $ManagedPath
            if ($Present -and $Signature.IsTrusted) {
                Write-Output '  PRESENT valid Microsoft-signed PsExec'
            } elseif ($Present) {
                Write-Output "  REPLACE $ManagedPath"
            } else {
                Write-Output "  ADD     $ManagedPath"
            }
            if ($HelperReady) {
                Write-Output "  PRESENT $HelperPath"
            } elseif ($HelperPresent) {
                Write-Output "  REPLACE $HelperPath"
            } else {
                Write-Output "  ADD     $HelperPath"
            }
            Write-Output "  SOURCE  $($Download.Uri)"
            Write-Output '  VERIFY  Authenticode signer=Microsoft Corporation'
            Write-Output "  VERIFY  helper sha256=$ExpectedHelperHash"
            Write-Output '[RDP] Dry run: no peer changes were made.'
            exit 0
        }

        [IO.Directory]::CreateDirectory($ManagedDirectory) | Out-Null
        $PsExecChanged = $false
        $PsExecChangeAction = ''
        if (-not ($Present -and $Signature.IsTrusted)) {
            $PsExecChangeAction = if ($Present) { 'REPLACED' } else { 'ADDED' }
            $TemporaryPath = Join-Path $ManagedDirectory (
                '.psexec-' + [Guid]::NewGuid().ToString('N') + '.exe'
            )
            try {
                [Net.ServicePointManager]::SecurityProtocol =
                    [Net.ServicePointManager]::SecurityProtocol -bor
                    [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest `
                    -UseBasicParsing `
                    -Uri $Download.Uri `
                    -OutFile $TemporaryPath
                $DownloadedSignature = Get-RdpClientPsExecSignature `
                    -Path $TemporaryPath
                if (-not $DownloadedSignature.IsTrusted) {
                    throw (
                        'Downloaded PsExec failed Microsoft Authenticode ' +
                        "verification: $($DownloadedSignature.Status), " +
                        $DownloadedSignature.Subject
                    )
                }
                Move-Item `
                    -LiteralPath $TemporaryPath `
                    -Destination $ManagedPath `
                    -Force
                $PsExecChanged = $true
            } finally {
                if ([IO.File]::Exists($TemporaryPath)) {
                    Remove-Item -LiteralPath $TemporaryPath -Force
                }
            }
        }

        $HelperChanged = $false
        $HelperChangeAction = ''
        if (-not $HelperReady) {
            $HelperChangeAction = if ($HelperPresent) { 'REPLACED' } else { 'ADDED' }
            if (-not [IO.File]::Exists($HelperUploadPath)) {
                throw 'The uploaded PsExec session helper was not found.'
            }
            $HelperBytes = [IO.File]::ReadAllBytes($HelperUploadPath)
            $Hasher = [Security.Cryptography.SHA256]::Create()
            try {
                $SourceHash = [BitConverter]::ToString(
                    $Hasher.ComputeHash($HelperBytes)
                ).Replace('-', '')
            } finally {
                $Hasher.Dispose()
            }
            if ($SourceHash -ne $ExpectedHelperHash) {
                throw 'The PsExec session helper source failed SHA-256 verification.'
            }
            $TemporaryHelperPath = Join-Path $ManagedDirectory (
                '.psexec-session-' + [Guid]::NewGuid().ToString('N') + '.ps1'
            )
            try {
                [IO.File]::WriteAllBytes($TemporaryHelperPath, $HelperBytes)
                Move-Item `
                    -LiteralPath $TemporaryHelperPath `
                    -Destination $HelperPath `
                    -Force
                $HelperChanged = $true
            } finally {
                if ([IO.File]::Exists($TemporaryHelperPath)) {
                    Remove-Item -LiteralPath $TemporaryHelperPath -Force
                }
            }
        }
        if ([IO.File]::Exists($HelperUploadPath)) {
            Remove-Item -LiteralPath $HelperUploadPath -Force
        }
        $HelperUploadPath = ''
        Write-RdpClientPsExecHeader `
            -Title 'add' `
            -PeerAddress $PeerAddress `
            -Architecture $Architecture `
            -Path $ManagedPath
        if ($PsExecChanged) {
            Write-Output (
                '  {0,-9}{1} ({2} from Microsoft Sysinternals Live)' -f
                $PsExecChangeAction,
                $ManagedPath,
                $Download.FileName
            )
        } else {
            Write-Output '  PRESENT valid Microsoft-signed PsExec'
        }
        if ($HelperChanged) {
            Write-Output ('  {0,-9}{1}' -f $HelperChangeAction, $HelperPath)
        } else {
            Write-Output "  PRESENT $HelperPath"
        }
        Write-Output '[RDP] Peer PsExec is ready.'
        exit 0
    }

    if ($Request.Action -eq 'remove') {
        if ([bool]$Request.DryRun) {
            Write-RdpClientPsExecHeader `
                -Title 'remove plan' `
                -PeerAddress $PeerAddress `
                -Architecture $Architecture `
                -Path $ManagedPath
            if ($Present) {
                Write-Output "  REMOVE  $ManagedPath"
            } else {
                Write-Output '  ABSENT  no managed PsExec file'
            }
            if ($HelperPresent) {
                Write-Output "  REMOVE  $HelperPath"
            } else {
                Write-Output '  ABSENT  no managed session helper'
            }
            Write-Output '[RDP] Dry run: no peer changes were made.'
            exit 0
        }
        if ($Present) {
            Remove-Item -LiteralPath $ManagedPath -Force
        }
        if ($HelperPresent) {
            Remove-Item -LiteralPath $HelperPath -Force
        }
        if ([IO.Directory]::Exists($ManagedDirectory) -and
            @(Get-ChildItem -LiteralPath $ManagedDirectory -Force).Count -eq 0) {
            [IO.Directory]::Delete($ManagedDirectory)
        }
        Write-RdpClientPsExecHeader `
            -Title 'remove' `
            -PeerAddress $PeerAddress `
            -Architecture $Architecture `
            -Path $ManagedPath
        if ($Present -or $HelperPresent) {
            Write-Output '[RDP] Removed the managed PsExec files.'
        } else {
            Write-Output '[RDP] Managed PsExec files were already absent.'
        }
        exit 0
    }

    if (-not $Present) {
        throw 'Managed PsExec is absent. Run .peer psexec add first.'
    }
    if (-not $Signature.IsTrusted) {
        throw (
            'Managed PsExec does not have a valid Microsoft signature. ' +
            'Run .peer psexec add to replace it.'
        )
    }
    if ($Request.Action -eq 'launch') {
        if (-not $HelperReady) {
            throw (
                'Managed PsExec session helper is absent or outdated. ' +
                'Run .peer psexec add first.'
            )
        }
        $LaunchSessionId = [int]$Request.SessionId
        if ($LaunchSessionId -le 0) {
            throw 'PsExec session ID must be a positive integer.'
        }
        $LaunchPayloadJson = [ordered]@{
            Arguments = @($Request.Arguments)
        } | ConvertTo-Json -Compress -Depth 3
        $LaunchPayloadBase64 = [Convert]::ToBase64String(
            $Utf8.GetBytes($LaunchPayloadJson)
        )
        Write-RdpClientPsExecHeader `
            -Title 'session launch' `
            -PeerAddress $PeerAddress `
            -Architecture $Architecture `
            -Path $ManagedPath
        $Invocation = Invoke-RdpClientCapturedProcess `
            -FilePath $ManagedPath `
            -Arguments @(
                '-accepteula',
                '-nobanner',
                '-s',
                'powershell.exe',
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                $HelperPath,
                '-SessionId',
                [string]$LaunchSessionId,
                '-PayloadBase64',
                $LaunchPayloadBase64
            )
        foreach ($Text in @($Invocation.StdOut, $Invocation.StdErr)) {
            $Text -split '[\r\n]+' | Where-Object {
                $_.Length -gt 0
            } | ForEach-Object { Write-Output $_ }
        }
        exit $Invocation.ExitCode
    }

    Write-RdpClientPsExecHeader `
        -Title 'run' `
        -PeerAddress $PeerAddress `
        -Architecture $Architecture `
        -Path $ManagedPath
    $PsExecArguments = @($Request.Arguments)
    if (-not @($PsExecArguments | Where-Object {
        [string]::Equals(
            [string]$_,
            '-accepteula',
            [StringComparison]::OrdinalIgnoreCase
        )
    }).Count) {
        $PsExecArguments = @('-accepteula') + $PsExecArguments
    }
    $Invocation = Invoke-RdpClientCapturedProcess `
        -FilePath $ManagedPath `
        -Arguments $PsExecArguments
    $CombinedOutput = $Invocation.StdOut + "`n" + $Invocation.StdErr
    $Detached = @($PsExecArguments | Where-Object {
        [string]::Equals(
            [string]$_,
            '-d',
            [StringComparison]::OrdinalIgnoreCase
        )
    }).Count -gt 0
    $ExitCode = $Invocation.ExitCode
    if ($Detached -and $ExitCode -ne 0 -and $CombinedOutput -match
        '(?m)^.+ started on .+ with process ID [0-9]+\.\s*$') {
        # PsExec 2.43 returns 1 after a successful detached launch. Its stable
        # PID confirmation distinguishes that case from a start failure.
        $ExitCode = 0
    }
    foreach ($Text in @($Invocation.StdOut, $Invocation.StdErr)) {
        $Text -split '[\r\n]+' | Where-Object { $_.Length -gt 0 } | ForEach-Object {
            Write-Output $_
        }
    }
    exit $ExitCode
} catch {
    if (-not [string]::IsNullOrWhiteSpace($HelperUploadPath) -and
        [IO.File]::Exists($HelperUploadPath)) {
        try { Remove-Item -LiteralPath $HelperUploadPath -Force } catch { }
    }
    Write-Output "[ERROR] $($_.Exception.Message)"
    exit 1
}
