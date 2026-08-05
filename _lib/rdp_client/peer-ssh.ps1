Set-StrictMode -Version 2.0

function Resolve-RdpClientPeerSshEntryPath {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw (
            'RDP_PEER_SSH_ENTRY is empty. Set it to a template.vps1.cmd ' +
            'entry that can connect to this Windows target.'
        )
    }

    $ExpandedPath = [Environment]::ExpandEnvironmentVariables($Value.Trim())
    if (-not [IO.Path]::IsPathRooted($ExpandedPath)) {
        throw 'RDP_PEER_SSH_ENTRY must be an absolute path.'
    }

    $ResolvedPath = [IO.Path]::GetFullPath($ExpandedPath)
    if (-not [IO.File]::Exists($ResolvedPath)) {
        throw "RDP_PEER_SSH_ENTRY was not found: $ResolvedPath"
    }
    if (@('.cmd', '.bat') -notcontains [IO.Path]::GetExtension($ResolvedPath).ToLowerInvariant()) {
        throw 'RDP_PEER_SSH_ENTRY must name a .cmd or .bat entry file.'
    }
    return $ResolvedPath
}

function Assert-RdpClientPeerSshEntryIsSeparate {
    param(
        [Parameter(Mandatory = $true)][string]$SshEntryPath,
        [Parameter(Mandatory = $true)][string]$RdpEntryPath
    )

    if ([string]::Equals(
        $SshEntryPath,
        $RdpEntryPath,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'RDP_PEER_SSH_ENTRY cannot point to this RDP entry itself.'
    }
}

function Invoke-RdpClientPeerSshPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$SshEntryPath,
        [Parameter(Mandatory = $true)][string]$RemoteSource
    )

    $SourceBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($RemoteSource)
    )
    # Windows PowerShell 5's redirected StandardInput may prepend a UTF-8 BOM.
    # Keep disposable ASCII framing before the marker so remote legacy code
    # pages cannot consume any marker byte while decoding that preamble.
    $InputPayload = '___RDP_CLIENT_PAYLOAD_V1:' + $SourceBase64
    $Bootstrap = (
        '$ProgressPreference=''SilentlyContinue'';' +
        '$u=New-Object Text.UTF8Encoding($false);' +
        '[Console]::OutputEncoding=$u;$OutputEncoding=$u;' +
        '$i=[Console]::In.ReadToEnd();' +
        'if($i -notmatch ''RDP_CLIENT_PAYLOAD_V1:(?<p>[A-Za-z0-9+/=]+)'')' +
        '{throw ''RDP peer stdin payload was not found.''};' +
        '$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches.p));' +
        '&([ScriptBlock]::Create($s))'
    )
    $BootstrapBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($Bootstrap)
    )
    while ($BootstrapBase64.EndsWith('=')) {
        $Bootstrap += ' '
        $BootstrapBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($Bootstrap)
        )
    }

    $Utf8 = New-Object Text.UTF8Encoding($false)
    $InputBytes = $Utf8.GetBytes($InputPayload)
    $Process = New-Object Diagnostics.Process
    $StartInfo = New-Object Diagnostics.ProcessStartInfo
    $Started = $false
    try {
        $StartInfo.FileName = $env:ComSpec
        $StartInfo.Arguments = (
            '/d /s /c ""%RDP_CLIENT_PEER_SSH_ENTRY%" stdin -- ' +
            'powershell.exe -NoLogo -NoProfile -NonInteractive ' +
            '-OutputFormat Text -EncodedCommand ' + $BootstrapBase64 + '"'
        )
        $StartInfo.UseShellExecute = $false
        $StartInfo.CreateNoWindow = $true
        $StartInfo.RedirectStandardInput = $true
        $StartInfo.RedirectStandardOutput = $true
        $StartInfo.RedirectStandardError = $true
        $StartInfo.StandardOutputEncoding = $Utf8
        $StartInfo.StandardErrorEncoding = $Utf8
        # Windows PowerShell 5 enumerates the first lazy, empty dictionary read
        # as $null. Prime it before adding the one transport-only variable.
        [void]$StartInfo.EnvironmentVariables
        $ChildEnvironment = $StartInfo.EnvironmentVariables
        foreach ($Item in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
            $ChildEnvironment[[string]$Item.Key] = [string]$Item.Value
        }
        $ChildEnvironment['RDP_CLIENT_PEER_SSH_ENTRY'] = $SshEntryPath
        $Process.StartInfo = $StartInfo

        $Process.Start() | Out-Null
        $Started = $true
        $StdOutTask = $Process.StandardOutput.ReadToEndAsync()
        $StdErrTask = $Process.StandardError.ReadToEndAsync()
        try {
            $Process.StandardInput.BaseStream.Write(
                $InputBytes,
                0,
                $InputBytes.Length
            )
        } catch {
            try { $Process.StandardInput.Close() } catch { }
            $Process.WaitForExit()
            $EarlyStdOut = $StdOutTask.Result.Trim()
            $EarlyStdErr = $StdErrTask.Result.Trim()
            throw (
                'SSH entry closed standard input before receiving the payload. ' +
                "stdout=[$EarlyStdOut] stderr=[$EarlyStdErr]"
            )
        }
        $Process.StandardInput.Close()
        $Process.WaitForExit()
        $StdOut = $StdOutTask.Result
        $StdErr = $StdErrTask.Result
        $ExitCode = $Process.ExitCode
    } finally {
        if ($Started -and -not $Process.HasExited) {
            try { $Process.StandardInput.Close() } catch { }
            try { $Process.Kill() } catch { }
        }
        $Process.Dispose()
    }

    $Output = @(
        foreach ($Text in @($StdOut, $StdErr)) {
            @($Text -split '\r?\n' | Where-Object { $_.Length -gt 0 })
        }
    )
    return [pscustomobject]@{
        ExitCode = $ExitCode
        Output   = $Output
    }
}

function Invoke-RdpClientPeerSshCopy {
    param(
        [Parameter(Mandatory = $true)][string]$SshEntryPath,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$RemoteName
    )

    if (-not [IO.File]::Exists($SourcePath)) {
        throw "SSH copy source was not found: $SourcePath"
    }
    if ($RemoteName -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'SSH copy remote name contains unsupported characters.'
    }

    $Utf8 = New-Object Text.UTF8Encoding($false)
    $Process = New-Object Diagnostics.Process
    $StartInfo = New-Object Diagnostics.ProcessStartInfo
    $Started = $false
    try {
        $StartInfo.FileName = $env:ComSpec
        $StartInfo.Arguments = (
            '/d /s /c ""%RDP_CLIENT_PEER_SSH_ENTRY%" copy ' +
            '"%RDP_CLIENT_PEER_COPY_SOURCE%" ' +
            '":%RDP_CLIENT_PEER_COPY_NAME%""'
        )
        $StartInfo.UseShellExecute = $false
        $StartInfo.CreateNoWindow = $true
        $StartInfo.RedirectStandardInput = $false
        $StartInfo.RedirectStandardOutput = $true
        $StartInfo.RedirectStandardError = $true
        $StartInfo.StandardOutputEncoding = $Utf8
        $StartInfo.StandardErrorEncoding = $Utf8
        [void]$StartInfo.EnvironmentVariables
        $ChildEnvironment = $StartInfo.EnvironmentVariables
        foreach ($Item in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
            $ChildEnvironment[[string]$Item.Key] = [string]$Item.Value
        }
        $ChildEnvironment['RDP_CLIENT_PEER_SSH_ENTRY'] = $SshEntryPath
        $ChildEnvironment['RDP_CLIENT_PEER_COPY_SOURCE'] = $SourcePath
        $ChildEnvironment['RDP_CLIENT_PEER_COPY_NAME'] = $RemoteName
        $Process.StartInfo = $StartInfo

        $Process.Start() | Out-Null
        $Started = $true
        $StdOutTask = $Process.StandardOutput.ReadToEndAsync()
        $StdErrTask = $Process.StandardError.ReadToEndAsync()
        $Process.WaitForExit()
        $StdOut = $StdOutTask.Result
        $StdErr = $StdErrTask.Result
        $ExitCode = $Process.ExitCode
    } finally {
        if ($Started -and -not $Process.HasExited) {
            try { $Process.Kill() } catch { }
        }
        $Process.Dispose()
    }

    return [pscustomobject]@{
        ExitCode = $ExitCode
        Output   = @(
            foreach ($Text in @($StdOut, $StdErr)) {
                @($Text -split '\r?\n' | Where-Object { $_.Length -gt 0 })
            }
        )
    }
}
