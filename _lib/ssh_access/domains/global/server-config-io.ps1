Set-StrictMode -Version 2.0

function Get-SshAccessSshdConfigPath {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    return Join-Path (Join-Path $Context.ProgramData 'ssh') 'sshd_config'
}

function ConvertFrom-SshAccessTextDocument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $NewLineMatch = [regex]::Match($Text, "\r\n|\n|\r")
    $NewLine = if ($NewLineMatch.Success) {
        $NewLineMatch.Value
    } else {
        [Environment]::NewLine
    }
    $HasFinalNewLine = [regex]::IsMatch($Text, "(?:\r\n|\n|\r)$")
    $Lines = if ($Text.Length -eq 0) {
        @()
    } else {
        @([regex]::Split($Text, "\r\n|\n|\r"))
    }
    if ($HasFinalNewLine) {
        $Lines = @($Lines | Select-Object -First ($Lines.Count - 1))
    }

    return [pscustomobject]@{
        Lines           = [string[]]@($Lines)
        NewLine         = $NewLine
        HasFinalNewLine = $HasFinalNewLine
    }
}

function ConvertTo-SshAccessTextDocument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$NewLine,
        [Parameter(Mandatory = $true)][bool]$HasFinalNewLine
    )

    if ($Lines.Count -eq 0) {
        return ''
    }
    $Text = [string]::Join($NewLine, $Lines)
    if ($HasFinalNewLine) {
        $Text += $NewLine
    }
    return $Text
}

function Read-SshAccessSshdConfigDocument {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-SshAccessPathIsNotReparsePoint -Path $Path -Description 'sshd_config'
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "sshd_config is missing: $Path"
    }

    [byte[]]$Bytes = [IO.File]::ReadAllBytes($Path)
    $HasBom = $Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xef -and
        $Bytes[1] -eq 0xbb -and
        $Bytes[2] -eq 0xbf
    if ($Bytes.Length -ge 2 -and
        (($Bytes[0] -eq 0xff -and $Bytes[1] -eq 0xfe) -or
        ($Bytes[0] -eq 0xfe -and $Bytes[1] -eq 0xff))) {
        throw "sshd_config must be UTF-8, not UTF-16: $Path"
    }

    $Offset = if ($HasBom) { 3 } else { 0 }
    $Utf8 = New-Object Text.UTF8Encoding($false, $true)
    try {
        $Text = $Utf8.GetString($Bytes, $Offset, $Bytes.Length - $Offset)
    } catch {
        throw "sshd_config is not valid UTF-8: $Path"
    }

    $Document = ConvertFrom-SshAccessTextDocument -Text $Text
    $Document | Add-Member -NotePropertyName Path -NotePropertyValue $Path
    $Document | Add-Member -NotePropertyName Text -NotePropertyValue $Text
    $Document | Add-Member -NotePropertyName Bytes -NotePropertyValue $Bytes
    $Document | Add-Member -NotePropertyName HasBom -NotePropertyValue $HasBom
    return $Document
}

function ConvertTo-SshAccessSshdConfigBytes {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Document,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $Text = ConvertTo-SshAccessTextDocument `
        -Lines $Lines `
        -NewLine $Document.NewLine `
        -HasFinalNewLine $Document.HasFinalNewLine
    $Utf8 = New-Object Text.UTF8Encoding($false)
    [byte[]]$Body = $Utf8.GetBytes($Text)
    if (-not $Document.HasBom) {
        return $Body
    }

    [byte[]]$Bytes = New-Object byte[] ($Body.Length + 3)
    $Bytes[0] = 0xef
    $Bytes[1] = 0xbb
    $Bytes[2] = 0xbf
    [Array]::Copy($Body, 0, $Bytes, 3, $Body.Length)
    return $Bytes
}

function Test-SshAccessByteArrayEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Left,
        [Parameter(Mandatory = $true)][byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($Index = 0; $Index -lt $Left.Length; $Index++) {
        if ($Left[$Index] -ne $Right[$Index]) {
            return $false
        }
    }
    return $true
}

function Enter-SshAccessSshdConfigLock {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [int]$TimeoutMilliseconds = 5000
    )

    $Directory = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "The OpenSSH configuration directory is missing: $Directory"
    }
    Assert-SshAccessPathIsNotReparsePoint `
        -Path $Directory `
        -Description 'the OpenSSH configuration directory'
    $LockPath = $ConfigPath + '.sshaccess.lock'
    $Deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        Assert-SshAccessPathIsNotReparsePoint `
            -Path $LockPath `
            -Description 'the sshd_config lock'
        try {
            return New-Object IO.FileStream(
                $LockPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None,
                1,
                [IO.FileOptions]::DeleteOnClose
            )
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $Deadline) {
                throw "Timed out waiting for the sshd_config lock: $LockPath"
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Write-SshAccessSshdConfigAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][byte[]]$ExpectedBytes
    )

    $Directory = Split-Path -Parent $Path
    $TemporaryPath = Join-Path $Directory (
        '.sshd_config.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    $BackupPath = Join-Path $Directory (
        '.sshd_config.' + [Guid]::NewGuid().ToString('N') + '.backup'
    )
    $ReplacementComplete = $false
    try {
        Assert-SshAccessPathIsNotReparsePoint `
            -Path $Directory `
            -Description 'the OpenSSH configuration directory'
        Assert-SshAccessPathIsNotReparsePoint -Path $Path -Description 'sshd_config'
        [byte[]]$CurrentBytes = [IO.File]::ReadAllBytes($Path)
        if (-not (Test-SshAccessByteArrayEqual -Left $CurrentBytes -Right $ExpectedBytes)) {
            throw 'sshd_config changed while the port operation was preparing; retry the command.'
        }

        $Stream = New-Object IO.FileStream(
            $TemporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $Stream.Write($Bytes, 0, $Bytes.Length)
            $Stream.Flush($true)
        } finally {
            $Stream.Dispose()
        }

        $Sections = [Security.AccessControl.AccessControlSections]::Access -bor
            [Security.AccessControl.AccessControlSections]::Owner -bor
            [Security.AccessControl.AccessControlSections]::Group
        $SourceInfo = New-Object IO.FileInfo($Path)
        $TargetInfo = New-Object IO.FileInfo($TemporaryPath)
        $TargetInfo.SetAccessControl($SourceInfo.GetAccessControl($Sections))

        [byte[]]$LatestBytes = [IO.File]::ReadAllBytes($Path)
        if (-not (Test-SshAccessByteArrayEqual -Left $LatestBytes -Right $ExpectedBytes)) {
            throw 'sshd_config changed before its atomic replacement; retry the command.'
        }
        [IO.File]::Replace($TemporaryPath, $Path, $BackupPath, $true)
        $ReplacementComplete = $true
    } catch {
        if (Test-Path -LiteralPath $BackupPath -PathType Leaf) {
            throw (
                "The sshd_config update did not complete. " +
                "A recovery copy was preserved at '$BackupPath'. " +
                $_.Exception.Message
            )
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction Stop
            } catch {
                Write-SshAccessWarning -Message (
                    "A temporary sshd_config file could not be removed: " +
                    "'$TemporaryPath'."
                )
            }
        }
        if ($ReplacementComplete -and
            (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
            try {
                Remove-Item -LiteralPath $BackupPath -Force -ErrorAction Stop
            } catch {
                Write-SshAccessWarning -Message (
                    "The sshd_config update succeeded, but its temporary " +
                    "recovery copy could not be removed: '$BackupPath'."
                )
            }
        }
    }
}
