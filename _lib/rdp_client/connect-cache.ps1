Set-StrictMode -Version 2.0

function Get-RdpClientSha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $Algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $Algorithm.ComputeHash($Bytes)
        )).Replace('-', '')
    } finally {
        $Algorithm.Dispose()
    }
}

function Get-RdpClientSourceHash {
    param([Parameter(Mandatory = $true)][string[]]$Lines)

    $CanonicalText = [string]::Join("`n", $Lines)
    return Get-RdpClientSha256Hex -Bytes (
        [Text.Encoding]::UTF8.GetBytes($CanonicalText)
    )
}

function Get-RdpClientFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    return Get-RdpClientSha256Hex -Bytes ([IO.File]::ReadAllBytes($Path))
}

function Get-RdpClientSigningIdentity {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [string]$CommandName = 'rdp'
    )

    if ($State.Name -eq 'Missing') {
        return 'unsigned'
    }
    if ($State.Name -ne 'Ready') {
        throw "RDP signing state is $($State.Name): $($State.Reason) Run `"$CommandName .sign status`" for details."
    }
    return 'signed:' + $State.PolicyToken
}

function Get-RdpClientManifestPath {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    $DataDirectory = [IO.Path]::GetFullPath(
        (Join-Path $RuntimeDirectory '..\..\data\rdp-client')
    )
    return Join-Path (Join-Path $DataDirectory $EntryName) 'manifest.json'
}

function Test-RdpClientManifestProperty {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Manifest,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $null -ne $Manifest.PSObject.Properties[$Name]
}

function Test-RdpClientArtifactIsCurrent {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$EntryPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$SourceHash,
        [Parameter(Mandatory = $true)][string]$SigningIdentity
    )

    if (-not [IO.File]::Exists($ManifestPath) -or
        -not [IO.File]::Exists($OutputPath)) {
        return $false
    }

    try {
        $Json = [IO.File]::ReadAllText($ManifestPath, [Text.Encoding]::UTF8)
        $Manifest = $Json | ConvertFrom-Json
        if ($null -eq $Manifest -or $Manifest -is [Array]) {
            return $false
        }

        $RequiredProperties = @(
            'version',
            'entryPath',
            'outputPath',
            'sourceHash',
            'outputHash',
            'signingIdentity'
        )
        foreach ($PropertyName in $RequiredProperties) {
            if (-not (Test-RdpClientManifestProperty `
                -Manifest $Manifest `
                -Name $PropertyName)) {
                return $false
            }
        }

        if ([int]$Manifest.version -ne 1 -or
            -not [string]::Equals(
                [string]$Manifest.entryPath,
                $EntryPath,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            -not [string]::Equals(
                [string]$Manifest.outputPath,
                $OutputPath,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            -not [string]::Equals(
                [string]$Manifest.sourceHash,
                $SourceHash,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            -not [string]::Equals(
                [string]$Manifest.signingIdentity,
                $SigningIdentity,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            return $false
        }

        $ActualOutputHash = Get-RdpClientFileHash -Path $OutputPath
        return [string]::Equals(
            [string]$Manifest.outputHash,
            $ActualOutputHash,
            [StringComparison]::OrdinalIgnoreCase
        )
    } catch {
        return $false
    }
}

function Write-RdpClientArtifactManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$EntryPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$SourceHash,
        [Parameter(Mandatory = $true)][string]$SigningIdentity
    )

    $ManifestDirectory = [IO.Path]::GetDirectoryName($ManifestPath)
    [IO.Directory]::CreateDirectory($ManifestDirectory) | Out-Null

    $Manifest = [ordered]@{
        version         = 1
        entryPath       = $EntryPath
        outputPath      = $OutputPath
        sourceHash      = $SourceHash
        outputHash      = Get-RdpClientFileHash -Path $OutputPath
        signingIdentity = $SigningIdentity
    }
    $Json = $Manifest | ConvertTo-Json
    $TemporaryPath = Join-Path (
        $ManifestDirectory
    ) ('.manifest.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $BackupPath = Join-Path (
        $ManifestDirectory
    ) ('.manifest.' + [Guid]::NewGuid().ToString('N') + '.bak')

    try {
        [IO.File]::WriteAllText(
            $TemporaryPath,
            $Json + [Environment]::NewLine,
            (New-Object Text.UTF8Encoding($false))
        )
        if ([IO.File]::Exists($ManifestPath)) {
            [IO.File]::Replace($TemporaryPath, $ManifestPath, $BackupPath)
        } else {
            [IO.File]::Move($TemporaryPath, $ManifestPath)
        }
    } finally {
        if ([IO.File]::Exists($TemporaryPath)) {
            [IO.File]::Delete($TemporaryPath)
        }
        if ([IO.File]::Exists($BackupPath)) {
            [IO.File]::Delete($BackupPath)
        }
    }
}
