Set-StrictMode -Version 2.0

function New-ProjDataRootClaimException {
    param(
        [Parameter(Mandatory = $true)][string]$Message
    )

    $Exception = [InvalidOperationException]::new($Message)
    $Exception.Data['SwawKit.Proj.SuppressErrorPrefix'] = $true
    return $Exception
}

function New-ProjDataRootClaim {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$ActionRoot
    )

    return [pscustomobject][ordered]@{
        Kind = [string]$Plan.Kind
        ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
        ActionRoot = [IO.Path]::GetFullPath($ActionRoot)
        EntryName = [string]$Plan.EntryName
        EntryFile = [string]$Plan.EntryFile
        VolumeId = [string]$Plan.Identity.VolumeId
        FileId = [string]$Plan.Identity.FileId
        DataRoot = [string]$Plan.DataRoot
        SourceDataRoot = [string]$Plan.SourceDataRoot
        Reason = [string]$Plan.Reason
    }
}

function Confirm-ProjDataRootClaim {
    param(
        [Parameter(Mandatory = $true)][object]$Claim
    )

    $Lines = @(
        'Project DataRoot ownership claim is required.'
        "Kind: $($Claim.Kind)"
        "Entry: $($Claim.EntryName)"
        "Entry File: $($Claim.EntryFile)"
        "Volume ID: $($Claim.VolumeId)"
        "File ID: $($Claim.FileId)"
        "Target: $($Claim.DataRoot)"
    )
    if (-not [string]::IsNullOrWhiteSpace($Claim.SourceDataRoot)) {
        $Lines += "Source: $($Claim.SourceDataRoot)"
    }
    $Lines += "Reason: $($Claim.Reason)"
    $Lines += "Review: $($Claim.EntryName) ..entry.claim"
    $Lines += "Apply: $($Claim.EntryName) ..entry.claim --yes"
    throw (New-ProjDataRootClaimException -Message (
        [string]::Join([Environment]::NewLine, $Lines)
    ))
}
