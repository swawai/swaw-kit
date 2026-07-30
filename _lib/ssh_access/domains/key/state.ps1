Set-StrictMode -Version 2.0

function Assert-SshAccessPrivateKeyContainer {
    param([Parameter(Mandatory = $true)][string]$Path)

    $Stream = New-Object IO.FileStream(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $Reader = New-Object IO.StreamReader(
            $Stream,
            [Text.Encoding]::UTF8,
            $true,
            1024,
            $true
        )
        try {
            $Header = $Reader.ReadLine()
        } finally {
            $Reader.Dispose()
        }
    } finally {
        $Stream.Dispose()
    }

    $SupportedHeaders = @(
        '-----BEGIN OPENSSH PRIVATE KEY-----',
        '-----BEGIN PRIVATE KEY-----',
        '-----BEGIN ENCRYPTED PRIVATE KEY-----',
        '-----BEGIN RSA PRIVATE KEY-----',
        '-----BEGIN EC PRIVATE KEY-----'
    )
    if ([string]::IsNullOrWhiteSpace($Header) -or
        $SupportedHeaders -notcontains $Header.Trim()) {
        throw "The bound private-key path does not contain a supported private-key container: $Path"
    }
}

function Get-SshAccessPrivateKeyFingerprint {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    Assert-SshAccessPrivateKeyContainer -Path $Context.PrivateKeyPath
    $SshKeygen = Resolve-SshAccessOpenSshExecutable -Context $Context -Name 'ssh-keygen.exe'
    $Result = Invoke-SshAccessCapturedProcess `
        -Executable $SshKeygen `
        -Arguments @('-E', 'sha256', '-lf', $Context.PrivateKeyPath)
    if ($Result.ExitCode -ne 0) {
        $Detail = ($Result.StdOut + [Environment]::NewLine + $Result.StdErr).Trim()
        throw "ssh-keygen could not inspect the private key (exit $($Result.ExitCode)): $Detail"
    }

    $Match = [regex]::Match($Result.StdOut, '(?<!\S)(SHA256:[A-Za-z0-9+/]+={0,2})(?=\s|$)')
    if (-not $Match.Success) {
        throw 'ssh-keygen returned no SHA256 fingerprint for the private key.'
    }
    return $Match.Groups[1].Value.TrimEnd('=')
}

function Get-SshAccessKeyState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Context)

    if (Test-Path -LiteralPath $Context.PublicKeyPath -PathType Container) {
        throw "SSH_ACCESS_PUBLIC_KEY_PATH points to a directory: $($Context.PublicKeyPath)"
    }
    if (Test-Path -LiteralPath $Context.PrivateKeyPath -PathType Container) {
        throw "The derived private key path points to a directory: $($Context.PrivateKeyPath)"
    }

    $PrivateExists = Test-Path -LiteralPath $Context.PrivateKeyPath -PathType Leaf
    $PublicExists = Test-Path -LiteralPath $Context.PublicKeyPath -PathType Leaf
    $PublicKey = $null
    $PublicKeyState = if ($PublicExists) { 'invalid' } else { 'missing' }
    $PublicKeyError = ''
    $PrivateFingerprint = ''
    $PairConsistency = if ($PrivateExists -and $PublicExists) {
        'unknown'
    } else {
        ''
    }

    if ($PublicExists) {
        try {
            $PublicKey = Read-SshAccessPublicKeyFile -Path $Context.PublicKeyPath
            $PublicKeyState = 'valid'
        } catch {
            $PublicKeyError = $_.Exception.Message
        }
    }
    if ($PrivateExists -and $null -ne $PublicKey) {
        try {
            $PrivateFingerprint = Get-SshAccessPrivateKeyFingerprint -Context $Context
            $PairConsistency = if ([string]::Equals(
                    $PrivateFingerprint,
                    $PublicKey.Fingerprint,
                    [StringComparison]::Ordinal
                )) {
                'matching'
            } else {
                'mismatched'
            }
        } catch {
            $PublicKeyError = $_.Exception.Message
            $PairConsistency = 'unknown'
        }
    } elseif ($PrivateExists -and $PublicExists) {
        $PairConsistency = 'unknown'
    }

    return [pscustomobject]@{
        PrivateKeyPath = $Context.PrivateKeyPath
        PublicKeyPath  = $Context.PublicKeyPath
        PrivateExists  = $PrivateExists
        PublicExists   = $PublicExists
        KeyMaterial    = if ($PrivateExists -and $PublicExists) {
            'complete'
        } elseif ($PublicExists) {
            'public-only'
        } elseif ($PrivateExists) {
            'private-only'
        } else {
            'missing'
        }
        ConfiguredType = $Context.KeyType
        PublicKeyState = $PublicKeyState
        PublicKey      = $PublicKey
        PrivateFingerprint = $PrivateFingerprint
        PairConsistency    = $PairConsistency
        Error          = $PublicKeyError
    }
}

function Show-SshAccessKeyState {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Context,
        [pscustomobject]$State = (Get-SshAccessKeyState -Context $Context)
    )

    Write-SshAccessHeading 'Bound key'
    Write-SshAccessField 'Key material' $State.KeyMaterial
    Write-SshAccessField 'Public key' $State.PublicKeyPath
    Write-SshAccessField 'Public exists' $State.PublicExists
    Write-SshAccessField 'Private key' $State.PrivateKeyPath
    Write-SshAccessField 'Private exists' $State.PrivateExists
    Write-SshAccessField 'Configured type' $State.ConfiguredType
    Write-SshAccessField 'Public key state' $State.PublicKeyState
    if ($State.KeyMaterial -eq 'complete') {
        Write-SshAccessField 'Pair consistency' $State.PairConsistency
    }
    if ($null -ne $State.PublicKey) {
        Write-SshAccessField 'Actual type' $State.PublicKey.Type
        Write-SshAccessField 'Fingerprint' $State.PublicKey.Fingerprint
        if (-not [string]::IsNullOrWhiteSpace($State.PrivateFingerprint)) {
            Write-SshAccessField 'Private fingerprint' $State.PrivateFingerprint
        }
        Write-SshAccessField 'Public content' $State.PublicKey.Line
    }
    if (-not [string]::IsNullOrWhiteSpace($State.Error)) {
        Write-SshAccessField 'Problem' $State.Error
    }
}
