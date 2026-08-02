[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('status', 'install', 'remove', 'open')]
    [string]$Action,

    [string]$CommandName = 'rdp',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'signing-core.ps1')
. (Join-Path $PSScriptRoot 'signing-report.ps1')

function New-RdpClientPublisherCertificate {
    param([Parameter(Mandatory = $true)][pscustomobject]$Configuration)

    if ($null -eq (Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue)) {
        throw 'New-SelfSignedCertificate is unavailable on this Windows installation.'
    }

    return New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Provider 'Microsoft Enhanced RSA and AES Cryptographic Provider' `
        -Subject $Configuration.Subject `
        -FriendlyName $Configuration.PrivateKeyFriendlyName `
        -CertStoreLocation $Configuration.CertificateStore `
        -HashAlgorithm sha256 `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -KeyExportPolicy NonExportable `
        -KeySpec Signature `
        -NotBefore ([DateTime]::Now.AddMinutes(-5)) `
        -NotAfter ([DateTime]::Now.AddYears(5))
}

function Assert-RdpClientSigningInstallableState {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [Parameter(Mandatory = $true)][string]$EntryCommand
    )

    if (@('Ready', 'RootTrustMissing', 'TrustMissing', 'Missing') -contains $State.Name) {
        return
    }
    throw "Signing state is $($State.Name): $($State.Reason) Run `"$EntryCommand .sign remove`" and then install again."
}

function Add-RdpClientRootTrustCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)][pscustomobject]$Configuration
    )

    $CertificatePath = Join-Path `
        $Configuration.TrustCertificateStore `
        $Certificate.Thumbprint
    if (Test-Path -LiteralPath $CertificatePath) {
        return $false
    }

    Write-Host '[RDP] Windows will ask you to trust the self-signed publisher for the current user.'
    $PublicCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $Certificate.RawData
    )
    $PublicCertificate.FriendlyName = $Configuration.RootTrustFriendlyName
    $Store = [Security.Cryptography.X509Certificates.X509Store]::new(
        $Configuration.TrustStoreName,
        $Configuration.TrustStoreLocation
    )
    try {
        $Store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $Store.Add($PublicCertificate)
    } finally {
        $Store.Close()
        $PublicCertificate.Dispose()
    }
    return $true
}

function Set-RdpClientSigningFriendlyNames {
    param([Parameter(Mandatory = $true)][pscustomobject]$Configuration)

    foreach ($Certificate in @(
        Get-RdpClientOwnedPublisherCertificates -Configuration $Configuration
    )) {
        if ($Certificate.FriendlyName -ne $Configuration.PrivateKeyFriendlyName) {
            $Certificate.FriendlyName = $Configuration.PrivateKeyFriendlyName
        }
    }
    foreach ($Certificate in @(
        Get-RdpClientOwnedRootTrustCertificates -Configuration $Configuration
    )) {
        if ($Certificate.FriendlyName -ne $Configuration.RootTrustFriendlyName) {
            $Certificate.FriendlyName = $Configuration.RootTrustFriendlyName
        }
    }
}

function Remove-RdpClientRootTrustCertificates {
    param(
        [AllowEmptyCollection()][string[]]$Thumbprints,
        [Parameter(Mandatory = $true)][pscustomobject]$Configuration
    )

    $NormalizedThumbprints = @($Thumbprints |
        ForEach-Object { $_.Replace(' ', '').ToUpperInvariant() } |
        Select-Object -Unique)
    if ($NormalizedThumbprints.Count -eq 0) {
        return
    }

    $Certificates = @(Get-ChildItem -Path $Configuration.TrustCertificateStore |
        Where-Object { $NormalizedThumbprints -contains $_.Thumbprint })
    if ($Certificates.Count -eq 0) {
        return
    }

    Write-Host '[RDP] Windows may ask you to confirm removal of the current-user Root trust.'
    $Store = [Security.Cryptography.X509Certificates.X509Store]::new(
        $Configuration.TrustStoreName,
        $Configuration.TrustStoreLocation
    )
    try {
        $Store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        foreach ($Certificate in $Certificates) {
            $Store.Remove($Certificate)
        }
    } finally {
        $Store.Close()
    }
}

function Restore-RdpClientTrustPolicy {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Snapshot,
        [Parameter(Mandatory = $true)][pscustomobject]$Configuration
    )

    if ($Snapshot.Exists) {
        New-Item -Path $Configuration.PolicyKeyPath -Force | Out-Null
        New-ItemProperty `
            -LiteralPath $Configuration.PolicyKeyPath `
            -Name $Configuration.PolicyValueName `
            -Value ([string]$Snapshot.Value) `
            -PropertyType String `
            -Force | Out-Null
    } elseif (Test-Path -LiteralPath $Configuration.PolicyKeyPath) {
        Remove-ItemProperty `
            -LiteralPath $Configuration.PolicyKeyPath `
            -Name $Configuration.PolicyValueName `
            -ErrorAction SilentlyContinue
    }
}

function Install-RdpClientSigning {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Configuration,
        [Parameter(Mandatory = $true)][string]$EntryCommand
    )

    $RdpSignPath = Get-RdpClientRdpSignPath
    if (-not [IO.File]::Exists($RdpSignPath)) {
        throw "rdpsign.exe was not found: $RdpSignPath"
    }

    $State = Get-RdpClientSigningState -Configuration $Configuration
    Assert-RdpClientSigningInstallableState `
        -State $State `
        -EntryCommand $EntryCommand
    Write-RdpClientSigningInstallChanges `
        -State $State `
        -Configuration $Configuration
    if ($State.Name -eq 'Ready') {
        Set-RdpClientSigningFriendlyNames -Configuration $Configuration
        return
    }

    if (@('RootTrustMissing', 'TrustMissing') -contains $State.Name) {
        $PolicySnapshot = Get-RdpClientRegistryValueState `
            -Path $Configuration.PolicyKeyPath `
            -Name $Configuration.PolicyValueName
        $AddedRootTrust = $false
        try {
            $AddedRootTrust = Add-RdpClientRootTrustCertificate `
                -Certificate $State.Certificate `
                -Configuration $Configuration
            $Tokens = @(Get-RdpClientTrustedPublisherTokens -Configuration $Configuration)
            $Tokens = Add-RdpClientPublisherToken -Tokens $Tokens -Token $State.PolicyToken
            Set-RdpClientTrustedPublisherTokens -Tokens $Tokens -Configuration $Configuration
            Set-RdpClientSigningFriendlyNames -Configuration $Configuration
            $Repaired = Get-RdpClientSigningState -Configuration $Configuration
            if ($Repaired.Name -ne 'Ready') {
                throw "Trust repair did not reach Ready state: $($Repaired.Name)."
            }
        } catch {
            Restore-RdpClientTrustPolicy `
                -Snapshot $PolicySnapshot `
                -Configuration $Configuration
            if ($AddedRootTrust) {
                Remove-RdpClientRootTrustCertificates `
                    -Thumbprints @($State.Certificate.Thumbprint) `
                    -Configuration $Configuration
            }
            throw
        }
        Write-Host '[RDP] Signing publisher: Ready'
        return
    }

    $PolicySnapshot = Get-RdpClientRegistryValueState `
        -Path $Configuration.PolicyKeyPath `
        -Name $Configuration.PolicyValueName
    $CreatedCertificate = $null
    $AddedRootTrust = $false
    try {
        $Certificate = New-RdpClientPublisherCertificate -Configuration $Configuration
        $CreatedCertificate = $Certificate

        $Fingerprint = Get-RdpClientCertificateFingerprintSha256 -Certificate $Certificate
        $AddedRootTrust = Add-RdpClientRootTrustCertificate `
            -Certificate $Certificate `
            -Configuration $Configuration
        $PolicyToken = 'sha256:' + $Fingerprint
        $Tokens = @(Get-RdpClientTrustedPublisherTokens -Configuration $Configuration)
        $Tokens = Add-RdpClientPublisherToken -Tokens $Tokens -Token $PolicyToken
        Set-RdpClientTrustedPublisherTokens -Tokens $Tokens -Configuration $Configuration
        Set-RdpClientSigningFriendlyNames -Configuration $Configuration
        $Installed = Get-RdpClientSigningState -Configuration $Configuration
        if ($Installed.Name -ne 'Ready') {
            throw "Signing installation did not reach Ready state: $($Installed.Name)."
        }
        Write-Host '[RDP] Signing publisher: Ready'
    } catch {
        Restore-RdpClientTrustPolicy -Snapshot $PolicySnapshot -Configuration $Configuration
        if ($AddedRootTrust) {
            Remove-RdpClientRootTrustCertificates `
                -Thumbprints @($Certificate.Thumbprint) `
                -Configuration $Configuration
        }
        if ($null -ne $CreatedCertificate) {
            Remove-Item -LiteralPath `
                (Join-Path $Configuration.CertificateStore $CreatedCertificate.Thumbprint) `
                -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Remove-RdpClientSigning {
    param([Parameter(Mandatory = $true)][pscustomobject]$Configuration)

    $Certificates = @(Get-RdpClientOwnedPublisherCertificates -Configuration $Configuration)
    $TrustCertificates = @(Get-RdpClientOwnedRootTrustCertificates -Configuration $Configuration)
    $PolicyTokens = New-Object 'Collections.Generic.List[string]'
    $CertificateThumbprints = New-Object 'Collections.Generic.List[string]'
    foreach ($Certificate in @($Certificates) + @($TrustCertificates)) {
        $CertificateThumbprints.Add($Certificate.Thumbprint)
        $PolicyTokens.Add(
            'sha256:' + (Get-RdpClientCertificateFingerprintSha256 -Certificate $Certificate)
        )
    }

    if ($Certificates.Count -eq 0 -and $TrustCertificates.Count -eq 0) {
        Write-Host '[RDP] Signing publisher is already absent.'
        return
    }

    $Tokens = @(Get-RdpClientTrustedPublisherTokens -Configuration $Configuration)
    foreach ($PolicyToken in $PolicyTokens) {
        $Tokens = @(
            Remove-RdpClientPublisherToken -Tokens $Tokens -Token $PolicyToken
        )
    }
    Set-RdpClientTrustedPublisherTokens -Tokens $Tokens -Configuration $Configuration

    Remove-RdpClientRootTrustCertificates `
        -Thumbprints @($CertificateThumbprints) `
        -Configuration $Configuration

    foreach ($Certificate in $Certificates) {
        Remove-Item -LiteralPath `
            (Join-Path $Configuration.CertificateStore $Certificate.Thumbprint) `
            -Force
    }

    Write-Host '[RDP] Removed the swaw-kit publisher, private key, Root trust, and RDP trust entry.'
}

function Open-RdpClientCertificateManager {
    param([Parameter(Mandatory = $true)][pscustomobject]$Configuration)

    $SystemDirectory = Get-RdpClientSigningSystemDirectory
    $MmcPath = Join-Path $SystemDirectory 'mmc.exe'
    $CertificateManagerPath = Join-Path $SystemDirectory 'certmgr.msc'
    foreach ($Path in @($MmcPath, $CertificateManagerPath)) {
        if (-not [IO.File]::Exists($Path)) {
            throw "Windows certificate manager component not found: $Path"
        }
    }

    $State = Get-RdpClientSigningState -Configuration $Configuration
    Write-Host '[RDP] Opening Certificates - Current User.'
    Write-Host '  GUI location: Personal > Certificates'
    Write-Host '  Trust location: Trusted Root Certification Authorities > Certificates'
    Write-Host "  My label:      $($Configuration.PrivateKeyFriendlyName)"
    Write-Host "  Root label:    $($Configuration.RootTrustFriendlyName)"
    Write-Host "  Subject:       $($Configuration.Subject)"
    Write-Host "  Current state: $($State.Name)"
    Write-Host '  Use .sign remove for complete cleanup; do not delete only the certificate in the GUI.'
    Start-Process `
        -FilePath $MmcPath `
        -ArgumentList ('"{0}"' -f $CertificateManagerPath) | Out-Null
}

try {
    $Utf8NoBom = New-Object Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $Utf8NoBom
    $OutputEncoding = $Utf8NoBom
    $Configuration = Get-RdpClientSigningConfiguration

    if ($DryRun -and $Action -ne 'install') {
        throw '--dry-run is supported only by .sign install.'
    }

    switch ($Action) {
        'status' {
            $State = Get-RdpClientSigningState -Configuration $Configuration
            Write-RdpClientSigningStatus -State $State -Configuration $Configuration
        }
        'install' {
            if ($DryRun) {
                $State = Get-RdpClientSigningState -Configuration $Configuration
                Assert-RdpClientSigningInstallableState `
                    -State $State `
                    -EntryCommand $CommandName
                Write-RdpClientSigningInstallChanges `
                    -State $State `
                    -Configuration $Configuration `
                    -DryRun
            } else {
                Install-RdpClientSigning `
                    -Configuration $Configuration `
                    -EntryCommand $CommandName
            }
        }
        'remove' {
            Remove-RdpClientSigning -Configuration $Configuration
        }
        'open' {
            Open-RdpClientCertificateManager -Configuration $Configuration
        }
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    exit 1
}
