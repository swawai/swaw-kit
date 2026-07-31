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
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$EntryFile,
        [AllowEmptyString()][string]$InheritedDataRoot = ''
    )

    $CanonicalProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
    $CanonicalEntryFile = [IO.Path]::GetFullPath($EntryFile)
    $EntryName = [IO.Path]::GetFileNameWithoutExtension($CanonicalEntryFile)
    if ([string]::IsNullOrWhiteSpace($EntryName)) {
        throw "Project entry has no usable file name: $CanonicalEntryFile"
    }
    $DataDirectory = [IO.Path]::GetFullPath(
        (Join-Path $CanonicalProjectRoot 'data')
    )
    $Candidate = [IO.Path]::GetFullPath(
        (Join-Path $DataDirectory "proj.$EntryName")
    )
    $Identity = Get-ProjEntryFileIdentity -EntryFile $CanonicalEntryFile
    $Directories = @(Get-ProjDataRootDirectories `
        -DataDirectory $DataDirectory)

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
            if ($null -eq $InheritedMatch) {
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

function Enter-ProjDataRootLock {
    param([Parameter(Mandatory = $true)][string]$DataDirectory)

    [void][IO.Directory]::CreateDirectory($DataDirectory)
    $DataDirectoryItem = Get-Item -LiteralPath $DataDirectory -Force
    if (($DataDirectoryItem.Attributes -band
        [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (
            'Project data directory cannot be a reparse point: ' +
            $DataDirectory
        )
    }
    $LockPath = Join-Path $DataDirectory '_proj-entry.lock'
    foreach ($Attempt in 1..100) {
        try {
            return [IO.FileStream]::new(
                $LockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        } catch [IO.IOException] {
            if ($Attempt -eq 100) {
                throw "Timed out waiting for the project DataRoot lock: $LockPath"
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Complete-ProjDataRootPlan {
    param([Parameter(Mandatory = $true)][object]$Plan)

    switch ([string]$Plan.Kind) {
        'Direct' {
            return [string]$Plan.DataRoot
        }
        'Create' {
            [void][IO.Directory]::CreateDirectory($Plan.DataRoot)
        }
        'ClaimCurrent' {
            if (-not [IO.Directory]::Exists($Plan.DataRoot)) {
                throw "Claim target disappeared: $($Plan.DataRoot)"
            }
        }
        'ClaimRename' {
            if ([IO.Directory]::Exists($Plan.DataRoot)) {
                throw "Claim rename target already exists: $($Plan.DataRoot)"
            }
            if (-not [IO.Directory]::Exists($Plan.SourceDataRoot)) {
                throw "Claim rename source disappeared: $($Plan.SourceDataRoot)"
            }
            [IO.Directory]::Move(
                [string]$Plan.SourceDataRoot,
                [string]$Plan.DataRoot
            )
        }
        default {
            throw "Unsupported DataRoot plan kind '$($Plan.Kind)'."
        }
    }
    Write-ProjEntryIdentityRecord `
        -DataRoot $Plan.DataRoot `
        -EntryName $Plan.EntryName `
        -EntryFile $Plan.EntryFile `
        -Identity $Plan.Identity
    return [string]$Plan.DataRoot
}

function Test-ProjDataRootClaimStateStable {
    param(
        [Parameter(Mandatory = $true)][object]$InitialPlan,
        [Parameter(Mandatory = $true)][object]$CurrentPlan
    )

    foreach ($Property in @('EntryFile', 'DataRoot')) {
        if (-not ([string]$InitialPlan.$Property).Equals(
            [string]$CurrentPlan.$Property,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            return $false
        }
    }
    if (-not ([string]$InitialPlan.EntryName).Equals(
        [string]$CurrentPlan.EntryName,
        [StringComparison]::OrdinalIgnoreCase
    ) -or
        [string]$InitialPlan.Identity.Key -cne
            [string]$CurrentPlan.Identity.Key) {
        return $false
    }
    if ([string]$CurrentPlan.Kind -ceq 'Direct') {
        return $true
    }
    return (
        [string]$CurrentPlan.Kind -ceq [string]$InitialPlan.Kind -and
        ([string]$CurrentPlan.SourceDataRoot).Equals(
            [string]$InitialPlan.SourceDataRoot,
            [StringComparison]::OrdinalIgnoreCase
        )
    )
}

function Resolve-ProjProjectDataRoot {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$ActionRoot,
        [Parameter(Mandatory = $true)][string]$EntryFile,
        [AllowNull()][scriptblock]$ClaimApprover = $null
    )

    $DataDirectory = [IO.Path]::GetFullPath(
        (Join-Path $ProjectRoot 'data')
    )
    $InheritedDataRoot = [string][Environment]::GetEnvironmentVariable(
        'SWAWKIT_PROJ_DATA_ROOT',
        [EnvironmentVariableTarget]::Process
    )

    $Lock = Enter-ProjDataRootLock -DataDirectory $DataDirectory
    try {
        $Plan = Get-ProjDataRootPlan `
            -ProjectRoot $ProjectRoot `
            -EntryFile $EntryFile `
            -InheritedDataRoot $InheritedDataRoot
        if ($Plan.Kind -in @('Direct', 'Create')) {
            $Resolved = Complete-ProjDataRootPlan -Plan $Plan
            $env:SWAWKIT_PROJ_DATA_ROOT = $Resolved
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
            -ProjectRoot $ProjectRoot `
            -EntryFile $EntryFile `
            -InheritedDataRoot $InheritedDataRoot
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
            $env:SWAWKIT_PROJ_DATA_ROOT = $Resolved
            return $Resolved
        }
        $Resolved = Complete-ProjDataRootPlan -Plan $CurrentPlan
        $env:SWAWKIT_PROJ_DATA_ROOT = $Resolved
        return $Resolved
    } finally {
        $Lock.Dispose()
    }
}
