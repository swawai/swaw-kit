Set-StrictMode -Version 2.0

function Get-SshAccessBoundPublicKey {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    $Parsed = Read-SshAccessPublicKeyFile -Path $Context.PublicKeyPath
    return [pscustomobject]@{
        Type = $Parsed.Type
        Blob = $Parsed.Blob
        Line = $Parsed.Line
    }
}

function ConvertFrom-SshAccessAuthorizedKeysText {
    param([AllowEmptyString()][string]$Text)

    $NewLineMatch = [regex]::Match($Text, "\r\n|\n|\r")
    $NewLine = if ($NewLineMatch.Success) { $NewLineMatch.Value } else { [Environment]::NewLine }
    $HasFinalNewLine = [regex]::IsMatch($Text, "(?:\r\n|\n|\r)$")
    if ($Text.Length -eq 0) {
        $Lines = @()
    } else {
        $Lines = @([regex]::Split($Text, "\r\n|\n|\r"))
        if ($HasFinalNewLine) {
            $Lines = @($Lines | Select-Object -First ($Lines.Count - 1))
        }
    }
    return [pscustomobject]@{
        Lines           = $Lines
        NewLine         = $NewLine
        HasFinalNewLine = $HasFinalNewLine
    }
}

function ConvertTo-SshAccessAuthorizedKeysText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$NewLine,
        [Parameter(Mandatory = $true)][bool]$FinalNewLine
    )

    if ($Lines.Count -eq 0) {
        return ''
    }
    $Text = [string]::Join($NewLine, $Lines)
    if ($FinalNewLine) {
        $Text += $NewLine
    }
    return $Text
}

function Read-SshAccessUtf8TextFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    [byte[]]$Bytes = [IO.File]::ReadAllBytes($Path)
    $Offset = 0
    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xef -and
        $Bytes[1] -eq 0xbb -and
        $Bytes[2] -eq 0xbf) {
        $Offset = 3
    } elseif ($Bytes.Length -ge 2 -and
        (($Bytes[0] -eq 0xff -and $Bytes[1] -eq 0xfe) -or
        ($Bytes[0] -eq 0xfe -and $Bytes[1] -eq 0xff))) {
        throw "The authorized_keys file must be UTF-8, not UTF-16: $Path"
    }

    $Utf8 = New-Object Text.UTF8Encoding($false, $true)
    try {
        return $Utf8.GetString($Bytes, $Offset, $Bytes.Length - $Offset)
    } catch {
        throw "The authorized_keys file is not valid UTF-8: $Path"
    }
}

function Read-SshAccessAuthorizedKeysDocument {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-SshAccessPathIsNotReparsePoint -Path $Path -Description 'authorized_keys'
    if (Test-Path -LiteralPath $Path -PathType Container) {
        throw "The authorized_keys path is a directory: $Path"
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $Document = ConvertFrom-SshAccessAuthorizedKeysText -Text ''
        $Document | Add-Member -NotePropertyName Exists -NotePropertyValue $false
        $Document | Add-Member -NotePropertyName Text -NotePropertyValue ''
        return $Document
    }
    $Text = Read-SshAccessUtf8TextFile -Path $Path
    $Document = ConvertFrom-SshAccessAuthorizedKeysText -Text $Text
    $Document | Add-Member -NotePropertyName Exists -NotePropertyValue $true
    $Document | Add-Member -NotePropertyName Text -NotePropertyValue $Text
    return $Document
}

function Enter-SshAccessAuthorizedKeysLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutMilliseconds = 5000
    )

    $LockPath = $Path + '.sshaccess.lock'
    $Deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        Assert-SshAccessPathIsNotReparsePoint -Path $LockPath -Description 'the authorized_keys lock'
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
            Assert-SshAccessPathIsNotReparsePoint -Path $LockPath -Description 'the authorized_keys lock'
            if ([DateTime]::UtcNow -ge $Deadline) {
                throw "Timed out waiting for the authorized_keys lock: $LockPath"
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Assert-SshAccessAuthorizedKeysSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedText,
        [Parameter(Mandatory = $true)][bool]$ExpectedExists
    )

    Assert-SshAccessPathIsNotReparsePoint -Path $Path -Description 'authorized_keys'
    $CurrentExists = Test-Path -LiteralPath $Path -PathType Leaf
    if ($CurrentExists -ne $ExpectedExists) {
        throw 'authorized_keys changed while this operation was preparing its update; retry the command.'
    }
    if ($CurrentExists) {
        $CurrentText = Read-SshAccessUtf8TextFile -Path $Path
        if (-not [string]::Equals($CurrentText, $ExpectedText, [StringComparison]::Ordinal)) {
            throw 'authorized_keys changed while this operation was preparing its update; retry the command.'
        }
    }
}

function Write-SshAccessAuthorizedKeysAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedText,
        [Parameter(Mandatory = $true)][bool]$ExpectedExists,
        [Parameter(Mandatory = $true)][pscustomobject]$Account
    )

    $Directory = Split-Path -Parent $Path
    $TemporaryPath = Join-Path $Directory ('.authorized_keys.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $BackupPath = Join-Path $Directory ('.authorized_keys.' + [Guid]::NewGuid().ToString('N') + '.backup')
    $Encoding = New-Object Text.UTF8Encoding($false)
    $ReplacementComplete = $false
    try {
        Assert-SshAccessPathIsNotReparsePoint -Path $Directory -Description 'the authorized_keys directory'
        Assert-SshAccessAuthorizedKeysSnapshot `
            -Path $Path `
            -ExpectedText $ExpectedText `
            -ExpectedExists $ExpectedExists
        if ($ExpectedExists) {
            Set-SshAccessAuthorizedKeysAcl -Path $Path -Account $Account
        }
        $Bytes = $Encoding.GetBytes($Text)
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

        Assert-SshAccessPathIsNotReparsePoint -Path $TemporaryPath -Description 'the authorized_keys temporary file'
        Set-SshAccessAuthorizedKeysAcl -Path $TemporaryPath -Account $Account
        Assert-SshAccessAuthorizedKeysSnapshot `
            -Path $Path `
            -ExpectedText $ExpectedText `
            -ExpectedExists $ExpectedExists
        if ($ExpectedExists) {
            [IO.File]::Replace($TemporaryPath, $Path, $BackupPath, $true)
        } else {
            [IO.File]::Move($TemporaryPath, $Path)
        }
        # Both the old destination and the replacement have the exact target
        # ACL before the atomic swap, so the content commit is the final step.
        $ReplacementComplete = $true
    } catch {
        if (Test-Path -LiteralPath $BackupPath -PathType Leaf) {
            throw "The authorized_keys update did not complete. A recovery copy was preserved at '$BackupPath'. $($_.Exception.Message)"
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $TemporaryPath -Force -ErrorAction Stop
            } catch {
                Write-SshAccessWarning -Message (
                    "A temporary authorized_keys file could not be removed: " +
                    "'$TemporaryPath'."
                )
            }
        }
        if ($ReplacementComplete -and (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
            try {
                Remove-Item -LiteralPath $BackupPath -Force -ErrorAction Stop
            } catch {
                Write-SshAccessWarning -Message (
                    "The authorized_keys update succeeded, but its temporary " +
                    "recovery copy could not be removed: '$BackupPath'."
                )
            }
        }
    }
}

function Get-SshAccessAuthorizedKeyReferenceState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][pscustomobject]$Key
    )

    $Document = Read-SshAccessAuthorizedKeysDocument -Path $Path
    return Measure-SshAccessAuthorizedKeyReferences `
        -Lines @($Document.Lines) `
        -Key $Key
}

function Add-SshAccessAuthorizedKey {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Account,
        [Parameter(Mandatory = $true)][pscustomobject]$Key
    )

    Initialize-SshAccessAuthorizedKeysDirectory -Account $Account
    $Lock = Enter-SshAccessAuthorizedKeysLock -Path $Account.AuthorizedKeysPath
    try {
        $Document = Read-SshAccessAuthorizedKeysDocument -Path $Account.AuthorizedKeysPath
        $References = Measure-SshAccessAuthorizedKeyReferences `
            -Lines @($Document.Lines) `
            -Key $Key
        if ($References.PlainAuthorizationCount -gt 0) {
            if (Test-Path -LiteralPath $Account.AuthorizedKeysPath -PathType Leaf) {
                Set-SshAccessAuthorizedKeysAcl -Path $Account.AuthorizedKeysPath -Account $Account
            }
            return [pscustomobject]@{
                Changed                 = $false
                MatchCount              = $References.IdentityReferenceCount
                PlainMatchCount         = $References.PlainAuthorizationCount
                OptionBoundMatchCount   = $References.OptionBoundReferenceCount
            }
        }
        if ($References.OptionBoundReferenceCount -gt 0) {
            throw (
                'The bound public-key identity already appears in ' +
                "$($References.OptionBoundReferenceCount) option-bound authorized_keys line(s). " +
                'Refusing to add a plain authorization because that could weaken the existing access constraints. ' +
                'Revoke the identity first or edit authorized_keys deliberately.'
            )
        }

        $Lines = @($Document.Lines) + $Key.Line
        $Text = ConvertTo-SshAccessAuthorizedKeysText `
            -Lines $Lines `
            -NewLine $Document.NewLine `
            -FinalNewLine $true
        Write-SshAccessAuthorizedKeysAtomic `
            -Path $Account.AuthorizedKeysPath `
            -Text $Text `
            -ExpectedText $Document.Text `
            -ExpectedExists $Document.Exists `
            -Account $Account
        return [pscustomobject]@{
            Changed                 = $true
            MatchCount              = 1
            PlainMatchCount         = 1
            OptionBoundMatchCount   = 0
        }
    } finally {
        if ($null -ne $Lock) {
            $Lock.Dispose()
        }
    }
}

function Remove-SshAccessAuthorizedKey {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Account,
        [Parameter(Mandatory = $true)][pscustomobject]$Key
    )

    $Directory = Split-Path -Parent $Account.AuthorizedKeysPath
    Assert-SshAccessPathIsNotReparsePoint -Path $Directory -Description 'the authorized_keys directory'
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return [pscustomobject]@{
            Changed                 = $false
            MatchCount              = 0
            PlainMatchCount         = 0
            OptionBoundMatchCount   = 0
        }
    }

    $Lock = Enter-SshAccessAuthorizedKeysLock -Path $Account.AuthorizedKeysPath
    try {
        $Document = Read-SshAccessAuthorizedKeysDocument -Path $Account.AuthorizedKeysPath
        $Remaining = New-Object Collections.Generic.List[string]
        $RemovedPlain = 0
        $RemovedOptionBound = 0
        foreach ($Line in @($Document.Lines)) {
            $Kind = Get-SshAccessAuthorizedKeyLineReferenceKind -Line $Line -Key $Key
            if ($Kind -eq 'plain') {
                $RemovedPlain++
            } elseif ($Kind -eq 'option-bound') {
                $RemovedOptionBound++
            } else {
                $Remaining.Add($Line)
            }
        }
        $Removed = $RemovedPlain + $RemovedOptionBound

        if ($Removed -eq 0) {
            if (Test-Path -LiteralPath $Account.AuthorizedKeysPath -PathType Leaf) {
                Set-SshAccessAuthorizedKeysAcl -Path $Account.AuthorizedKeysPath -Account $Account
            }
            return [pscustomobject]@{
                Changed                 = $false
                MatchCount              = 0
                PlainMatchCount         = 0
                OptionBoundMatchCount   = 0
            }
        }

        $Text = ConvertTo-SshAccessAuthorizedKeysText `
            -Lines @($Remaining) `
            -NewLine $Document.NewLine `
            -FinalNewLine $Document.HasFinalNewLine
        Write-SshAccessAuthorizedKeysAtomic `
            -Path $Account.AuthorizedKeysPath `
            -Text $Text `
            -ExpectedText $Document.Text `
            -ExpectedExists $Document.Exists `
            -Account $Account
        return [pscustomobject]@{
            Changed                 = $true
            MatchCount              = $Removed
            PlainMatchCount         = $RemovedPlain
            OptionBoundMatchCount   = $RemovedOptionBound
        }
    } finally {
        if ($null -ne $Lock) {
            $Lock.Dispose()
        }
    }
}
