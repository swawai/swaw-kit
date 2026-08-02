Set-StrictMode -Version 2.0

function Get-RdpClientSigningDisplayIdentity {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State
    )

    if ($null -ne $State.Certificate) {
        return [pscustomobject]@{
            Thumbprint  = $State.Certificate.Thumbprint
            Fingerprint = Get-RdpClientCertificateFingerprintSha256 `
                -Certificate $State.Certificate
        }
    }

    $Certificates = @(
        @($State.OwnedCertificates) + @($State.TrustCertificates) |
            Sort-Object Thumbprint -Unique
    )
    if ($Certificates.Count -eq 1) {
        return [pscustomobject]@{
            Thumbprint  = $Certificates[0].Thumbprint
            Fingerprint = Get-RdpClientCertificateFingerprintSha256 `
                -Certificate $Certificates[0]
        }
    }
    return $null
}

function Write-RdpClientSigningLocation {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Location
    )

    Write-Output ('  {0,-7} {1}' -f $Status, $Location)
}

function Get-RdpClientSigningFriendlyNameChanges {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [Parameter(Mandatory = $true)][pscustomobject]$Configuration
    )

    $Changes = @()
    foreach ($Certificate in @($State.OwnedCertificates)) {
        if ($Certificate.FriendlyName -ne $Configuration.PrivateKeyFriendlyName) {
            $Changes += [pscustomobject]@{
                Path = Join-Path $Configuration.CertificateStore $Certificate.Thumbprint
                FriendlyName = $Configuration.PrivateKeyFriendlyName
            }
        }
    }
    foreach ($Certificate in @($State.TrustCertificates)) {
        if ($Certificate.FriendlyName -ne $Configuration.RootTrustFriendlyName) {
            $Changes += [pscustomobject]@{
                Path = Join-Path $Configuration.TrustCertificateStore $Certificate.Thumbprint
                FriendlyName = $Configuration.RootTrustFriendlyName
            }
        }
    }
    return $Changes
}

function Write-RdpClientSigningStatus {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [Parameter(Mandatory = $true)][pscustomobject]$Configuration
    )

    if ($State.Name -eq 'Missing') {
        Write-Host '[RDP] Signing publisher: Not installed'
        Write-RdpClientSigningLocation `
            -Status 'ABSENT' `
            -Location "$($Configuration.CertificateStore)\<swaw-kit-publisher>"
        Write-RdpClientSigningLocation `
            -Status 'ABSENT' `
            -Location "$($Configuration.TrustCertificateStore)\<swaw-kit-publisher>"
        $PolicyTokens = @(Get-RdpClientTrustedPublisherTokens `
            -Configuration $Configuration)
        if ($PolicyTokens.Count -eq 0) {
            Write-RdpClientSigningLocation `
                -Status 'ABSENT' `
                -Location "$($Configuration.PolicyKeyPath)\$($Configuration.PolicyValueName) [swaw-kit-publisher]"
        } else {
            Write-RdpClientSigningLocation `
                -Status 'SHARED' `
                -Location "$($Configuration.PolicyKeyPath)\$($Configuration.PolicyValueName) = $($PolicyTokens.Count) opaque fingerprint(s); no swaw-kit certificate remains to match"
        }
        return
    }

    Write-Host "[RDP] Signing publisher: $($State.Name)"
    $Identity = Get-RdpClientSigningDisplayIdentity -State $State
    if ($null -eq $Identity) {
        $PrivateStatus = if (@($State.OwnedCertificates).Count -gt 0) {
            'PRESENT'
        } else {
            'ABSENT'
        }
        Write-RdpClientSigningLocation `
            -Status $PrivateStatus `
            -Location "$($Configuration.CertificateStore)\<swaw-kit-publisher>"
        Write-RdpClientSigningLocation `
            -Status $(if (@($State.TrustCertificates).Count -gt 0) { 'PRESENT' } else { 'ABSENT' }) `
            -Location "$($Configuration.TrustCertificateStore)\<swaw-kit-publisher>"
        Write-RdpClientSigningLocation `
            -Status 'UNKNOWN' `
            -Location "$($Configuration.PolicyKeyPath)\$($Configuration.PolicyValueName)"
    } else {
        $PrivatePath = Join-Path `
            $Configuration.CertificateStore `
            $Identity.Thumbprint
        $RootPath = Join-Path `
            $Configuration.TrustCertificateStore `
            $Identity.Thumbprint
        $PolicyToken = 'sha256:' + $Identity.Fingerprint
        $PolicyTokens = @(Get-RdpClientTrustedPublisherTokens `
            -Configuration $Configuration)
        $PolicyPresent = @($PolicyTokens | Where-Object {
            [string]::Equals(
                $_,
                $PolicyToken,
                [StringComparison]::OrdinalIgnoreCase
            )
        }).Count -gt 0

        Write-RdpClientSigningLocation `
            -Status $(if (Test-Path -LiteralPath $PrivatePath) { 'PRESENT' } else { 'ABSENT' }) `
            -Location $PrivatePath
        Write-RdpClientSigningLocation `
            -Status $(if (Test-Path -LiteralPath $RootPath) { 'PRESENT' } else { 'ABSENT' }) `
            -Location $RootPath
        Write-RdpClientSigningLocation `
            -Status $(if ($PolicyPresent) { 'PRESENT' } else { 'ABSENT' }) `
            -Location "$($Configuration.PolicyKeyPath)\$($Configuration.PolicyValueName) = $PolicyToken"

        $PrivateCertificate = Get-Item -LiteralPath $PrivatePath -ErrorAction SilentlyContinue
        if ($null -ne $PrivateCertificate) {
            Write-Host "  MY-NAME $($PrivateCertificate.FriendlyName)"
        }
        $RootCertificate = Get-Item -LiteralPath $RootPath -ErrorAction SilentlyContinue
        if ($null -ne $RootCertificate) {
            Write-Host "  ROOT-NAME $($RootCertificate.FriendlyName)"
        }
    }

    if ($null -ne $State.Certificate) {
        Write-Host '  PRIVATE-KEY PRESENT'
        Write-Host "  EXPIRES $($State.Certificate.NotAfter.ToString('yyyy-MM-dd HH:mm:ss'))"
    }
    if ($State.Reason.Length -gt 0) {
        Write-Host "  DETAIL  $($State.Reason)"
    }
    if ($State.Name -eq 'Ready' -and $State.ExpiresSoon) {
        Write-Warning 'The publisher certificate expires within 30 days.'
    }
}

function Write-RdpClientSigningInstallChanges {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$State,
        [Parameter(Mandatory = $true)][pscustomobject]$Configuration,
        [switch]$DryRun
    )

    $Heading = if ($DryRun) {
        '[RDP] Signing install --dry-run'
    } else {
        '[RDP] Signing install'
    }
    Write-Host $Heading

    $FriendlyNameChanges = @(
        Get-RdpClientSigningFriendlyNameChanges `
            -State $State `
            -Configuration $Configuration
    )
    if ($State.Name -eq 'Ready' -and $FriendlyNameChanges.Count -eq 0) {
        Write-Host '  No changes.'
        return
    }

    $Identity = Get-RdpClientSigningDisplayIdentity -State $State
    if ($State.Name -eq 'Missing') {
        Write-RdpClientSigningLocation `
            -Status 'ADD' `
            -Location "$($Configuration.CertificateStore)\<generated-thumbprint> FriendlyName = `"$($Configuration.PrivateKeyFriendlyName)`""
        Write-RdpClientSigningLocation `
            -Status 'ADD' `
            -Location "$($Configuration.TrustCertificateStore)\<same-generated-thumbprint> FriendlyName = `"$($Configuration.RootTrustFriendlyName)`""
        Write-RdpClientSigningLocation `
            -Status 'ADD' `
            -Location "$($Configuration.PolicyKeyPath)\$($Configuration.PolicyValueName) += sha256:<generated-fingerprint>"
        return
    }

    if ($null -eq $Identity) {
        throw 'The publisher identity is ambiguous; exact install changes cannot be determined.'
    }

    foreach ($Change in $FriendlyNameChanges) {
        Write-RdpClientSigningLocation `
            -Status 'UPDATE' `
            -Location "$($Change.Path) FriendlyName = `"$($Change.FriendlyName)`""
    }

    $RootPath = Join-Path `
        $Configuration.TrustCertificateStore `
        $Identity.Thumbprint
    if (-not (Test-Path -LiteralPath $RootPath)) {
        Write-RdpClientSigningLocation `
            -Status 'ADD' `
            -Location "$RootPath FriendlyName = `"$($Configuration.RootTrustFriendlyName)`""
    }

    $PolicyToken = 'sha256:' + $Identity.Fingerprint
    $PolicyTokens = @(Get-RdpClientTrustedPublisherTokens `
        -Configuration $Configuration)
    $PolicyPresent = @($PolicyTokens | Where-Object {
        [string]::Equals(
            $_,
            $PolicyToken,
            [StringComparison]::OrdinalIgnoreCase
        )
    }).Count -gt 0
    if (-not $PolicyPresent) {
        Write-RdpClientSigningLocation `
            -Status 'ADD' `
            -Location "$($Configuration.PolicyKeyPath)\$($Configuration.PolicyValueName) += $PolicyToken"
    }
}
