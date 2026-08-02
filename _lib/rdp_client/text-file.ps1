Set-StrictMode -Version 2.0

function Read-RdpClientTextFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $Utf8NoBom = New-Object Text.UTF8Encoding($false, $true)
    if (-not [IO.File]::Exists($Path)) {
        return [pscustomobject]@{
            Exists   = $false
            Text     = ''
            Lines    = [string[]]@('')
            Encoding = $Utf8NoBom
            NewLine  = "`r`n"
        }
    }

    $Bytes = [IO.File]::ReadAllBytes($Path)
    $Offset = 0
    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $Encoding = New-Object Text.UTF8Encoding($true, $true)
        $Offset = 3
    } elseif ($Bytes.Length -ge 2 -and
        $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $Encoding = New-Object Text.UnicodeEncoding($false, $true, $true)
        $Offset = 2
    } elseif ($Bytes.Length -ge 2 -and
        $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        $Encoding = New-Object Text.UnicodeEncoding($true, $true, $true)
        $Offset = 2
    } else {
        try {
            $null = $Utf8NoBom.GetString($Bytes)
            $Encoding = $Utf8NoBom
        } catch {
            $Encoding = [Text.Encoding]::Default
        }
    }

    $Text = $Encoding.GetString($Bytes, $Offset, $Bytes.Length - $Offset)
    $NewLine = if ($Text.Contains("`r`n")) {
        "`r`n"
    } elseif ($Text.Contains("`n")) {
        "`n"
    } elseif ($Text.Contains("`r")) {
        "`r"
    } else {
        "`r`n"
    }
    return [pscustomobject]@{
        Exists   = $true
        Text     = $Text
        Lines    = [string[]]@([regex]::Split($Text, "`r`n|`n|`r"))
        Encoding = $Encoding
        NewLine  = $NewLine
    }
}

function Write-RdpClientTextFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][Text.Encoding]$Encoding
    )

    $Directory = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($Directory)) {
        [IO.Directory]::CreateDirectory($Directory) | Out-Null
    }
    $TemporaryPath = Join-Path `
        $Directory `
        ('.hosts.swaw-kit.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $BackupPath = Join-Path `
        $Directory `
        ('.hosts.swaw-kit.' + [Guid]::NewGuid().ToString('N') + '.bak')

    try {
        $Preamble = $Encoding.GetPreamble()
        $Body = $Encoding.GetBytes($Text)
        $Bytes = New-Object byte[] ($Preamble.Length + $Body.Length)
        [Buffer]::BlockCopy($Preamble, 0, $Bytes, 0, $Preamble.Length)
        [Buffer]::BlockCopy($Body, 0, $Bytes, $Preamble.Length, $Body.Length)
        [IO.File]::WriteAllBytes($TemporaryPath, $Bytes)

        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($TemporaryPath, $Path, $BackupPath, $true)
            if ([IO.File]::Exists($BackupPath)) {
                [IO.File]::Delete($BackupPath)
            }
        } else {
            [IO.File]::Move($TemporaryPath, $Path)
        }
    } finally {
        if ([IO.File]::Exists($TemporaryPath)) {
            [IO.File]::Delete($TemporaryPath)
        }
    }
}
