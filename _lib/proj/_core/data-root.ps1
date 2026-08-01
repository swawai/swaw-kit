Set-StrictMode -Version 2.0

function Get-ProjDataRootDirectories {
    param([Parameter(Mandatory = $true)][string]$DataDirectory)

    if (-not [IO.Directory]::Exists($DataDirectory)) {
        return @()
    }
    $Directories = @(Get-ChildItem `
        -LiteralPath $DataDirectory `
        -Directory `
        -Force |
        Where-Object { $_.Name.StartsWith(
            'proj.',
            [StringComparison]::OrdinalIgnoreCase
        ) })
    foreach ($Directory in $Directories) {
        if (($Directory.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Project DataRoot cannot be a reparse point: $($Directory.FullName)"
        }
    }
    return $Directories
}

function Get-ProjDataRootPlan {
    param(
        [Parameter(Mandatory = $true)][string]$DataDirectory,
        [Parameter(Mandatory = $true)][string]$EntryFile,
        [AllowEmptyString()][string]$InheritedDataRoot = '',
        [AllowEmptyString()][string]$LegacyDataDirectory = ''
    )

    $CanonicalDataDirectory = [IO.Path]::GetFullPath($DataDirectory)
    $CanonicalEntryFile = [IO.Path]::GetFullPath($EntryFile)
    $EntryName = [IO.Path]::GetFileNameWithoutExtension($CanonicalEntryFile)
    if ([string]::IsNullOrWhiteSpace($EntryName)) {
        throw "Project entry has no usable file name: $CanonicalEntryFile"
    }
    $Candidate = [IO.Path]::GetFullPath(
        (Join-Path $CanonicalDataDirectory "proj.$EntryName")
    )
    $Identity = Get-ProjEntryFileIdentity -EntryFile $CanonicalEntryFile
    $Directories = @(Get-ProjDataRootDirectories `
        -DataDirectory $CanonicalDataDirectory)

    $CandidateDirectory = $Directories |
        Where-Object { $_.FullName.Equals(
            $Candidate,
            [StringComparison]::OrdinalIgnoreCase
        ) } |
        Select-Object -First 1
    $CandidateRecord = if ($null -eq $CandidateDirectory) {
        $null
    } else {
        Read-ProjEntryIdentityRecord -DataRoot $Candidate
    }

    $IdentityMatches = @()
    foreach ($Directory in $Directories) {
        $Record = Read-ProjEntryIdentityRecord `
            -DataRoot $Directory.FullName
        if ($Record.Valid -and
            (Test-ProjEntryIdentityEqual `
                -Record $Record.Value `
                -Identity $Identity)) {
            $IdentityMatches += [pscustomobject]@{
                DataRoot = $Directory.FullName
                Record = $Record
            }
        }
    }
    if ($IdentityMatches.Count -gt 1) {
        throw (
            'Multiple project DataRoots contain the current entry File ID: ' +
            [string]::Join(', ', [string[]]@(
                $IdentityMatches | ForEach-Object { $_.DataRoot }
            )) +
            '. Manual repair is required.'
        )
    }

    $LegacyMatches = @()
    if (-not [string]::IsNullOrWhiteSpace($LegacyDataDirectory)) {
        $CanonicalLegacyDirectory = [IO.Path]::GetFullPath(
            $LegacyDataDirectory
        )
        if (-not $CanonicalLegacyDirectory.Equals(
            $CanonicalDataDirectory,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            foreach ($Directory in @(Get-ProjDataRootDirectories `
                -DataDirectory $CanonicalLegacyDirectory)) {
                $Record = Read-ProjEntryIdentityRecord `
                    -DataRoot $Directory.FullName
                if ($Record.Valid -and
                    (Test-ProjEntryIdentityEqual `
                        -Record $Record.Value `
                        -Identity $Identity)) {
                    $LegacyMatches += [pscustomobject]@{
                        DataRoot = $Directory.FullName
                        Record = $Record
                    }
                }
            }
        }
    }
    if ($LegacyMatches.Count -gt 1) {
        throw (
            'Multiple legacy project DataRoots contain the current entry ' +
            'File ID: ' + [string]::Join(', ', [string[]]@(
                $LegacyMatches | ForEach-Object { $_.DataRoot }
            )) + '. Manual repair is required.'
        )
    }
    $LegacyMatch = $LegacyMatches | Select-Object -First 1
    if ($null -ne $LegacyMatch -and $IdentityMatches.Count -gt 0) {
        throw (
            'Both the Swaw Kit Home and legacy project directory contain ' +
            "DataRoots for the current entry File ID: '$($IdentityMatches[0].DataRoot)', " +
            "'$($LegacyMatch.DataRoot)'. Manual repair is required."
        )
    }

    $CanonicalInherited = ''
    if (-not [string]::IsNullOrWhiteSpace($InheritedDataRoot)) {
        if (-not [IO.Path]::IsPathRooted($InheritedDataRoot)) {
            throw "Inherited SWAWKIT_PROJ_DATA_ROOT must be absolute."
        }
        $CanonicalInherited = [IO.Path]::GetFullPath(
            $InheritedDataRoot
        ).TrimEnd('\', '/')
        if (-not $CanonicalInherited.Equals(
            $Candidate,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $InheritedMatch = $IdentityMatches |
                Where-Object { $_.DataRoot.Equals(
                    $CanonicalInherited,
                    [StringComparison]::OrdinalIgnoreCase
                ) } |
                Select-Object -First 1
            $InheritedMatchesLegacy = $null -ne $LegacyMatch -and
                $CanonicalInherited.Equals(
                    [string]$LegacyMatch.DataRoot,
                    [StringComparison]::OrdinalIgnoreCase
                )
            if ($null -eq $InheritedMatch -and
                -not $InheritedMatchesLegacy) {
                throw (
                    "Another project's DataRoot is already active: " +
                    "$CanonicalInherited. Exit that project shell before " +
                    'invoking this entry.'
                )
            }
        }
    }

    $CandidateIdentityMatches = $false
    $CandidateNameMatches = $false
    if ($null -ne $CandidateRecord -and $CandidateRecord.Valid) {
        $CandidateIdentityMatches = Test-ProjEntryIdentityEqual `
            -Record $CandidateRecord.Value `
            -Identity $Identity
        $CandidateNameMatches = (
            [string]$CandidateRecord.Value.entryName
        ).Equals(
            $EntryName,
            [StringComparison]::OrdinalIgnoreCase
        )
    }

    if ($null -ne $CandidateDirectory) {
        if ($CandidateIdentityMatches -and $CandidateNameMatches) {
            return [pscustomobject][ordered]@{
                Kind = 'Direct'
                EntryName = $EntryName
                EntryFile = $CanonicalEntryFile
                Identity = $Identity
                DataRoot = $Candidate
                SourceDataRoot = ''
                Reason = ''
            }
        }
        if ($IdentityMatches.Count -eq 1 -and
            -not $IdentityMatches[0].DataRoot.Equals(
                $Candidate,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw (
                "The desired DataRoot '$Candidate' belongs to another File " +
                "ID while '$($IdentityMatches[0].DataRoot)' contains the " +
                'current File ID. Manual repair is required.'
            )
        }
        $Reason = if ($null -eq $CandidateRecord) {
            'candidate identity record is unavailable'
        } elseif (-not $CandidateRecord.Valid) {
            $CandidateRecord.Error
        } elseif (-not $CandidateNameMatches) {
            'entry name does not match the identity record'
        } else {
            'File ID does not match the identity record'
        }
        return [pscustomobject][ordered]@{
            Kind = 'ClaimCurrent'
            EntryName = $EntryName
            EntryFile = $CanonicalEntryFile
            Identity = $Identity
            DataRoot = $Candidate
            SourceDataRoot = ''
            Reason = $Reason
        }
    }

    if ($IdentityMatches.Count -eq 1) {
        return [pscustomobject][ordered]@{
            Kind = 'ClaimRename'
            EntryName = $EntryName
            EntryFile = $CanonicalEntryFile
            Identity = $Identity
            DataRoot = $Candidate
            SourceDataRoot = $IdentityMatches[0].DataRoot
            Reason = 'the entry File ID is bound under another entry name'
        }
    }

    if ($null -ne $LegacyMatch) {
        $LegacyNameMatches = (
            [string]$LegacyMatch.Record.Value.entryName
        ).Equals(
            $EntryName,
            [StringComparison]::OrdinalIgnoreCase
        ) -and [IO.Path]::GetFileName(
            [string]$LegacyMatch.DataRoot
        ).Equals(
            "proj.$EntryName",
            [StringComparison]::OrdinalIgnoreCase
        )
        return [pscustomobject][ordered]@{
            Kind = if ($LegacyNameMatches) {
                'MigrateLegacy'
            } else {
                'ClaimMigrateLegacy'
            }
            EntryName = $EntryName
            EntryFile = $CanonicalEntryFile
            Identity = $Identity
            DataRoot = $Candidate
            SourceDataRoot = [string]$LegacyMatch.DataRoot
            Reason = if ($LegacyNameMatches) {
                'legacy DataRoot is stored under SWAWKIT_PROJ_DIR'
            } else {
                'the entry File ID is stored under a renamed legacy DataRoot'
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($CanonicalInherited)) {
        throw (
            "Inherited DataRoot '$CanonicalInherited' has no valid binding " +
            'for the current entry. Manual repair is required.'
        )
    }
    return [pscustomobject][ordered]@{
        Kind = 'Create'
        EntryName = $EntryName
        EntryFile = $CanonicalEntryFile
        Identity = $Identity
        DataRoot = $Candidate
        SourceDataRoot = ''
        Reason = ''
    }
}

function Resolve-ProjProjectDataRoot {
    param(
        [Parameter(Mandatory = $true)][string]$ProjHome,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$ActionRoot,
        [Parameter(Mandatory = $true)][string]$EntryFile,
        [AllowNull()][scriptblock]$ClaimApprover = $null
    )

    $DataDirectory = [IO.Path]::GetFullPath(
        (Join-Path $ProjHome 'data')
    )
    $EntryName = [IO.Path]::GetFileNameWithoutExtension(
        [IO.Path]::GetFullPath($EntryFile)
    )
    $LegacyDataDirectory = [IO.Path]::GetFullPath(
        (Join-Path $ProjectRoot 'data')
    )
    $LegacyDataRootCandidate = [IO.Path]::GetFullPath(
        (Join-Path $LegacyDataDirectory "proj.$EntryName")
    )
    $InheritedDataRoot = [string][Environment]::GetEnvironmentVariable(
        'SWAWKIT_PROJ_DATA_ROOT',
        [EnvironmentVariableTarget]::Process
    )

    $Lock = Enter-ProjDataRootLock -DataDirectory $DataDirectory
    try {
        $Plan = Get-ProjDataRootPlan `
            -DataDirectory $DataDirectory `
            -EntryFile $EntryFile `
            -InheritedDataRoot $InheritedDataRoot `
            -LegacyDataDirectory $LegacyDataDirectory
        if ($Plan.Kind -in @('Direct', 'Create', 'MigrateLegacy')) {
            $Resolved = Complete-ProjDataRootPlan -Plan $Plan
            $LegacyDataRoot = if ($Plan.Kind -ceq 'MigrateLegacy') {
                [string]$Plan.SourceDataRoot
            } else {
                $LegacyDataRootCandidate
            }
            $Resolved = Set-ProjResolvedDataRoot `
                -DataRoot $Resolved `
                -LegacyDataRoot $LegacyDataRoot `
                -EntryName $EntryName
            return $Resolved
        }
    } finally {
        $Lock.Dispose()
    }

    $Claim = New-ProjDataRootClaim `
        -Plan $Plan `
        -ProjectRoot $ProjectRoot `
        -ActionRoot $ActionRoot
    $Approved = if ($null -eq $ClaimApprover) {
        Confirm-ProjDataRootClaim -Claim $Claim
    } else {
        [bool](& $ClaimApprover $Claim)
    }
    if (-not $Approved) {
        throw 'Project DataRoot claim was not approved.'
    }

    $Lock = Enter-ProjDataRootLock -DataDirectory $DataDirectory
    try {
        $CurrentPlan = Get-ProjDataRootPlan `
            -DataDirectory $DataDirectory `
            -EntryFile $EntryFile `
            -InheritedDataRoot $InheritedDataRoot `
            -LegacyDataDirectory $LegacyDataDirectory
        if (-not (Test-ProjDataRootClaimStateStable `
            -InitialPlan $Plan `
            -CurrentPlan $CurrentPlan)) {
            throw (
                'Project DataRoot state changed during claim. Review it and ' +
                'retry the entry.'
            )
        }
        if ($CurrentPlan.Kind -ceq 'Direct') {
            $Resolved = Complete-ProjDataRootPlan -Plan $CurrentPlan
            $LegacyDataRoot = if ($Plan.Kind -ceq 'ClaimMigrateLegacy') {
                [string]$Plan.SourceDataRoot
            } else {
                $LegacyDataRootCandidate
            }
            $Resolved = Set-ProjResolvedDataRoot `
                -DataRoot $Resolved `
                -LegacyDataRoot $LegacyDataRoot `
                -EntryName $EntryName
            return $Resolved
        }
        $Resolved = Complete-ProjDataRootPlan -Plan $CurrentPlan
        $LegacyDataRoot = if ($CurrentPlan.Kind -ceq
            'ClaimMigrateLegacy') {
            [string]$CurrentPlan.SourceDataRoot
        } else {
            $LegacyDataRootCandidate
        }
        $Resolved = Set-ProjResolvedDataRoot `
            -DataRoot $Resolved `
            -LegacyDataRoot $LegacyDataRoot `
            -EntryName $EntryName
        return $Resolved
    } finally {
        $Lock.Dispose()
    }
}
