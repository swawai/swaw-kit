Set-StrictMode -Version 2.0

function Get-SshAccessPublicKeyFingerprint {
    param([Parameter(Mandatory = $true)][byte[]]$BlobBytes)

    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $Hash = $Hasher.ComputeHash($BlobBytes)
    } finally {
        $Hasher.Dispose()
    }
    return 'SHA256:' + [Convert]::ToBase64String($Hash).TrimEnd('=')
}

function ConvertFrom-SshAccessWireFields {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $Fields = New-Object Collections.ArrayList
    $Offset = 0
    while ($Offset -lt $Bytes.Length) {
        if (($Bytes.Length - $Offset) -lt 4) {
            return $null
        }
        [uint32]$Length = `
            ([uint32]$Bytes[$Offset] -shl 24) -bor `
            ([uint32]$Bytes[$Offset + 1] -shl 16) -bor `
            ([uint32]$Bytes[$Offset + 2] -shl 8) -bor `
            [uint32]$Bytes[$Offset + 3]
        $Offset += 4
        if ($Length -gt ($Bytes.Length - $Offset)) {
            return $null
        }

        [byte[]]$Field = New-Object byte[] ([int]$Length)
        if ($Length -gt 0) {
            [Array]::Copy($Bytes, $Offset, $Field, 0, [int]$Length)
        }
        [void]$Fields.Add($Field)
        $Offset += [int]$Length
    }
    return [pscustomobject]@{
        Fields = [object[]]$Fields.ToArray()
    }
}

function Test-SshAccessSupportedPublicKeyBlob {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $Parsed = ConvertFrom-SshAccessWireFields -Bytes $Bytes
    if ($null -eq $Parsed) {
        return $false
    }
    [object[]]$Fields = $Parsed.Fields
    $Algorithm = [Text.Encoding]::ASCII.GetString([byte[]]$Fields[0])
    if (-not [string]::Equals($Algorithm, $Type, [StringComparison]::Ordinal)) {
        return $false
    }

    if ($Type -eq 'ssh-ed25519') {
        return $Fields.Count -eq 2 -and ([byte[]]$Fields[1]).Length -eq 32
    }
    if ($Type -eq 'ssh-rsa') {
        return $Fields.Count -eq 3 -and
            ([byte[]]$Fields[1]).Length -gt 0 -and
            ([byte[]]$Fields[2]).Length -gt 0
    }
    if ($Type -match '^ecdsa-sha2-(nistp256|nistp384|nistp521)$') {
        if ($Fields.Count -ne 3) {
            return $false
        }
        $Curve = [Text.Encoding]::ASCII.GetString([byte[]]$Fields[1])
        if (-not [string]::Equals($Curve, $Matches[1], [StringComparison]::Ordinal)) {
            return $false
        }
        $ExpectedPointLength = switch ($Matches[1]) {
            'nistp256' { 65 }
            'nistp384' { 97 }
            'nistp521' { 133 }
        }
        [byte[]]$Point = $Fields[2]
        return $Point.Length -eq $ExpectedPointLength -and $Point[0] -eq 4
    }
    return $false
}

function ConvertFrom-SshAccessPublicKeyLine {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line
    )

    $Trimmed = $Line.Trim()
    if ($Trimmed.Length -eq 0 -or $Trimmed.StartsWith('#')) {
        return $null
    }

    $Fields = @($Trimmed -split '\s+', 3)
    if ($Fields.Count -lt 2 -or
        $Fields[0] -notmatch '^[^\s,="]+$' -or
        $Fields[1] -notmatch '^[A-Za-z0-9+/]+={0,3}$') {
        return $null
    }

    $Type = $Fields[0]
    $Blob = $Fields[1]
    try {
        [byte[]]$Bytes = [Convert]::FromBase64String($Blob)
    } catch {
        return $null
    }
    if ($Bytes.Length -lt 8 -or
        -not (Test-SshAccessSupportedPublicKeyBlob -Type $Type -Bytes $Bytes)) {
        return $null
    }

    return [pscustomobject]@{
        Type        = $Type
        Blob        = $Blob
        Identity    = "$Type $Blob"
        Fingerprint = Get-SshAccessPublicKeyFingerprint -BlobBytes $Bytes
        Line        = $Trimmed
    }
}

function Read-SshAccessPublicKeyFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Public key file not found: $Path"
    }

    $Keys = New-Object Collections.ArrayList
    foreach ($Line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        $Key = ConvertFrom-SshAccessPublicKeyLine -Line $Line
        if ($null -eq $Key) {
            continue
        }

        $PlainFields = @($Line.Trim() -split '\s+', 3)
        if ($PlainFields.Count -lt 2 -or
            -not [string]::Equals($PlainFields[0], $Key.Type, [StringComparison]::Ordinal) -or
            -not [string]::Equals($PlainFields[1], $Key.Blob, [StringComparison]::Ordinal)) {
            continue
        }
        [void]$Keys.Add($Key)
    }

    if ($Keys.Count -eq 0) {
        throw "No valid OpenSSH public key was found in: $Path"
    }
    if ($Keys.Count -ne 1) {
        throw "The bound public key file must contain exactly one public key: $Path"
    }

    $Result = $Keys[0]
    return [pscustomobject]@{
        Type        = $Result.Type
        Blob        = $Result.Blob
        Identity    = $Result.Identity
        Fingerprint = $Result.Fingerprint
        Line        = $Result.Line
        Path        = $Path
    }
}
