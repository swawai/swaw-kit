[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EntryFile,

    [string]$CommandName = 'rdp',

    [switch]$Launch,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'entry.ps1')
. (Join-Path $PSScriptRoot 'signing-core.ps1')
. (Join-Path $PSScriptRoot 'connect-cache.ps1')

function Resolve-RdpClientOutputPath {
    param(
        [AllowNull()][AllowEmptyString()][string]$ConfiguredPath,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        $DesktopDirectory = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::DesktopDirectory
        )
        if ([string]::IsNullOrWhiteSpace($DesktopDirectory)) {
            throw 'Windows did not provide a Desktop directory for the current user.'
        }
        return Join-Path $DesktopDirectory ($EntryName + '.rdp')
    }

    $ExpandedPath = [Environment]::ExpandEnvironmentVariables(
        $ConfiguredPath.Trim()
    )
    if (-not [IO.Path]::IsPathRooted($ExpandedPath)) {
        throw 'RDP_OUTPUT_PATH must be an absolute path.'
    }
    if (-not [string]::Equals(
        [IO.Path]::GetExtension($ExpandedPath),
        '.rdp',
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'RDP_OUTPUT_PATH must name an .rdp file.'
    }
    return [IO.Path]::GetFullPath($ExpandedPath)
}

try {
    $Utf8NoBom = New-Object Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $Utf8NoBom
    $OutputEncoding = $Utf8NoBom

    $ResolvedEntry = [IO.Path]::GetFullPath($EntryFile)
    $HostAlias = Resolve-RdpClientHostAlias -Value $env:RDP_HOST_ALIAS
    $Document = Read-RdpClientEntryDocument -Path $ResolvedEntry
    $RdpLines = ConvertTo-RdpClientOutputLines `
        -Document $Document `
        -HostAlias $HostAlias

    $EntryName = [IO.Path]::GetFileNameWithoutExtension($ResolvedEntry)
    if ([string]::IsNullOrWhiteSpace($EntryName)) {
        throw 'Could not derive an RDP output name from the entry file.'
    }
    $OutputPath = Resolve-RdpClientOutputPath `
        -ConfiguredPath $env:RDP_OUTPUT_PATH `
        -EntryName $EntryName
    $OutputDirectory = [IO.Path]::GetDirectoryName($OutputPath)
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        throw "Could not derive the RDP output directory from: $OutputPath"
    }
    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

    if ([IO.File]::Exists($OutputPath) -and -not $Launch -and -not $Force) {
        throw "RDP file already exists: $OutputPath Run `"$CommandName .rdp create --force`" to overwrite it."
    }

    $SigningConfiguration = Get-RdpClientSigningConfiguration
    $SigningState = Get-RdpClientSigningState `
        -Configuration $SigningConfiguration
    $SigningIdentity = Get-RdpClientSigningIdentity `
        -State $SigningState `
        -CommandName $CommandName
    $SourceHash = Get-RdpClientSourceHash -Lines $RdpLines
    $ManifestPath = Get-RdpClientManifestPath `
        -RuntimeDirectory $PSScriptRoot `
        -EntryName $EntryName
    $ReuseArtifact = $Launch -and (Test-RdpClientArtifactIsCurrent `
        -ManifestPath $ManifestPath `
        -EntryPath $ResolvedEntry `
        -OutputPath $OutputPath `
        -SourceHash $SourceHash `
        -SigningIdentity $SigningIdentity)

    if ($ReuseArtifact) {
        Write-Host "[RDP] Reused:    $OutputPath"
        if ($SigningState.Name -eq 'Ready') {
            Write-Host "[RDP] Signed:     $($SigningConfiguration.FriendlyName) (unchanged)"
        } else {
            Write-Host '[RDP] Signing:   not installed; cached file remains unsigned.'
        }
    } else {
        # mstsc and rdpsign use the native Windows RDP text representation.
        [IO.File]::WriteAllLines($OutputPath, $RdpLines, [Text.Encoding]::Unicode)
        Write-Host "[RDP] Generated: $OutputPath"
        $null = Invoke-RdpClientFileSigning `
            -Path $OutputPath `
            -CommandName $CommandName `
            -Configuration $SigningConfiguration
        Write-RdpClientArtifactManifest `
            -ManifestPath $ManifestPath `
            -EntryPath $ResolvedEntry `
            -OutputPath $OutputPath `
            -SourceHash $SourceHash `
            -SigningIdentity $SigningIdentity
    }

    Write-Host "[RDP] Target:    $($RdpLines | Where-Object { $_ -like 'full address:*' } | Select-Object -First 1)"

    if ($Launch) {
        Assert-RdpClientHostAliasResolves -HostAlias $HostAlias

        $Mstsc = Get-Command 'mstsc.exe' -ErrorAction Stop
        Start-Process -FilePath $Mstsc.Source -ArgumentList ('"{0}"' -f $OutputPath) | Out-Null
        Write-Host '[RDP] Started mstsc.exe.'
    }

    exit 0
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    exit 1
}
