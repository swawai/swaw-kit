Set-StrictMode -Version 2.0

function Resolve-RdpClientShadowSshEntryPath {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw (
            'RDP_SHADOW_SSH_ENTRY is empty. Set it to a template.vps1.cmd ' +
            'entry that can connect to this Windows target.'
        )
    }

    $ExpandedPath = [Environment]::ExpandEnvironmentVariables($Value.Trim())
    if (-not [IO.Path]::IsPathRooted($ExpandedPath)) {
        throw 'RDP_SHADOW_SSH_ENTRY must be an absolute path.'
    }

    $ResolvedPath = [IO.Path]::GetFullPath($ExpandedPath)
    if (-not [IO.File]::Exists($ResolvedPath)) {
        throw "RDP_SHADOW_SSH_ENTRY was not found: $ResolvedPath"
    }
    if (@('.cmd', '.bat') -notcontains [IO.Path]::GetExtension($ResolvedPath).ToLowerInvariant()) {
        throw 'RDP_SHADOW_SSH_ENTRY must name a .cmd or .bat entry file.'
    }
    return $ResolvedPath
}

function Assert-RdpClientShadowSshEntryIsSeparate {
    param(
        [Parameter(Mandatory = $true)][string]$SshEntryPath,
        [Parameter(Mandatory = $true)][string]$RdpEntryPath
    )

    if ([string]::Equals(
        $SshEntryPath,
        $RdpEntryPath,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'RDP_SHADOW_SSH_ENTRY cannot point to this RDP entry itself.'
    }
}

function ConvertTo-RdpClientShadowEncodedCommand {
    param([Parameter(Mandatory = $true)][string]$RemoteSource)

    $EncodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($RemoteSource)
    )
    if ($EncodedCommand.Length -le 6000) {
        # The SSH entry is a .cmd chain; trailing '=' padding is not preserved
        # reliably while that chain rebuilds the remote command.
        while ($EncodedCommand.EndsWith('=')) {
            $RemoteSource += ' '
            $EncodedCommand = [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($RemoteSource)
            )
        }
        return $EncodedCommand
    }

    $SourceBytes = [Text.Encoding]::UTF8.GetBytes($RemoteSource)
    $CompressedStream = New-Object IO.MemoryStream
    try {
        $Gzip = New-Object IO.Compression.GZipStream(
            $CompressedStream,
            [IO.Compression.CompressionMode]::Compress,
            $true
        )
        try {
            $Gzip.Write($SourceBytes, 0, $SourceBytes.Length)
        } finally {
            $Gzip.Dispose()
        }
        $Payload = [Convert]::ToBase64String($CompressedStream.ToArray())
    } finally {
        $CompressedStream.Dispose()
    }

    $Bootstrap = (
        '$p=''' + $Payload + ''';' +
        '$m=New-Object IO.MemoryStream(,[Convert]::FromBase64String($p));' +
        '$g=New-Object IO.Compression.GZipStream($m,' +
        '[IO.Compression.CompressionMode]::Decompress);' +
        '$r=New-Object IO.StreamReader($g,[Text.Encoding]::UTF8);' +
        '&([ScriptBlock]::Create($r.ReadToEnd()))'
    )
    $EncodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($Bootstrap)
    )
    # Add harmless PowerShell whitespace instead of stripping required Base64 padding.
    while ($EncodedCommand.EndsWith('=')) {
        $Bootstrap += ' '
        $EncodedCommand = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($Bootstrap)
        )
    }
    if ($EncodedCommand.Length -gt 7000) {
        throw (
            'The compressed SSH PowerShell payload is still too long for cmd.exe: ' +
            "$($EncodedCommand.Length) characters."
        )
    }
    return $EncodedCommand
}

function Invoke-RdpClientShadowSshPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$SshEntryPath,
        [Parameter(Mandatory = $true)][string]$RemoteSource
    )

    $EncodedCommand = ConvertTo-RdpClientShadowEncodedCommand -RemoteSource $RemoteSource
    $Output = @(& $SshEntryPath `
        '--' `
        'powershell.exe' `
        '-NoLogo' `
        '-NoProfile' `
        '-NonInteractive' `
        '-OutputFormat' `
        'Text' `
        '-EncodedCommand' `
        $EncodedCommand 2>&1)
    $ExitCode = $LASTEXITCODE

    return [pscustomobject]@{
        ExitCode       = $ExitCode
        Output         = $Output
        EncodedCommand = $EncodedCommand
    }
}
