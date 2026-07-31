[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '_core\engine.ps1')

function Assert-ProjDataRootTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$TestBase = [IO.Path]::GetFullPath(
    (Join-Path $ProjRoot '..\..\data\_test')
)
[void][IO.Directory]::CreateDirectory($TestBase)
$TemporaryRoot = Join-Path $TestBase (
    "swawkit-proj-data-root-$([Guid]::NewGuid().ToString('N'))"
)
$ProjectRoot = Join-Path $TemporaryRoot 'project'
$ActionRoot = Join-Path $ProjectRoot '.swaw'
$PreviousDataRoot = [Environment]::GetEnvironmentVariable(
    'SWAWKIT_PROJ_DATA_ROOT',
    [EnvironmentVariableTarget]::Process
)

try {
    [void][IO.Directory]::CreateDirectory($ProjectRoot)
    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_PROJ_DATA_ROOT',
        $null,
        [EnvironmentVariableTarget]::Process
    )

    $AlphaEntry = Join-Path $ProjectRoot 'alpha.cmd'
    [IO.File]::WriteAllText($AlphaEntry, '@echo off')
    $AlphaRoot = Resolve-ProjProjectDataRoot `
        -ProjectRoot $ProjectRoot `
        -ActionRoot $ActionRoot `
        -EntryFile $AlphaEntry
    Assert-ProjDataRootTest `
        -Condition ($AlphaRoot -ceq (
            Join-Path $ProjectRoot 'data\proj.alpha'
        ) -and
            [IO.File]::Exists((Join-Path $AlphaRoot '_entry.json'))) `
        -Message 'a fresh entry did not create data/proj.<entry-name>'

    $DirectPlan = Get-ProjDataRootPlan `
        -ProjectRoot $ProjectRoot `
        -EntryFile $AlphaEntry `
        -InheritedDataRoot $AlphaRoot
    Assert-ProjDataRootTest `
        -Condition ($DirectPlan.Kind -ceq 'Direct') `
        -Message 'matching entry name and File ID did not resolve directly'

    $BetaEntry = Join-Path $ProjectRoot 'beta.cmd'
    [IO.File]::Move($AlphaEntry, $BetaEntry)
    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_PROJ_DATA_ROOT',
        $null,
        [EnvironmentVariableTarget]::Process
    )
    $Claims = [pscustomobject]@{
        Rename = $false
        Context = $false
        Current = $false
        MissingRecord = $false
    }
    $BetaRoot = Resolve-ProjProjectDataRoot `
        -ProjectRoot $ProjectRoot `
        -ActionRoot $ActionRoot `
        -EntryFile $BetaEntry `
        -ClaimApprover {
            param($Claim)
            $Claims.Rename =
                $Claim.Kind -ceq 'ClaimRename' -and
                $Claim.SourceDataRoot -ceq $AlphaRoot
            $Claims.Context =
                $Claim.ProjectRoot -ceq $ProjectRoot -and
                $Claim.ActionRoot -ceq $ActionRoot -and
                -not [string]::IsNullOrWhiteSpace($Claim.VolumeId) -and
                -not [string]::IsNullOrWhiteSpace($Claim.FileId)
            return $Claims.Rename -and $Claims.Context
        }
    Assert-ProjDataRootTest `
        -Condition ($Claims.Rename -and $Claims.Context -and
            $BetaRoot -ceq (Join-Path $ProjectRoot 'data\proj.beta') -and
            -not [IO.Directory]::Exists($AlphaRoot)) `
        -Message 'rename claim omitted context or did not complete'

    $GammaEntry = Join-Path $ProjectRoot 'gamma.cmd'
    [IO.File]::Copy($BetaEntry, $GammaEntry)
    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_PROJ_DATA_ROOT',
        $null,
        [EnvironmentVariableTarget]::Process
    )
    $GammaRoot = Resolve-ProjProjectDataRoot `
        -ProjectRoot $ProjectRoot `
        -ActionRoot $ActionRoot `
        -EntryFile $GammaEntry
    Assert-ProjDataRootTest `
        -Condition ($GammaRoot -ceq (
            Join-Path $ProjectRoot 'data\proj.gamma'
        )) `
        -Message 'a copied entry did not receive a new DataRoot'

    $Replacement = Join-Path $ProjectRoot 'replacement.cmd'
    $Backup = Join-Path $ProjectRoot 'gamma.backup.cmd'
    [IO.File]::WriteAllText($Replacement, '@echo replaced')
    [IO.File]::Replace($Replacement, $GammaEntry, $Backup, $true)
    [IO.File]::Delete($Backup)
    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_PROJ_DATA_ROOT',
        $null,
        [EnvironmentVariableTarget]::Process
    )
    [void](Resolve-ProjProjectDataRoot `
        -ProjectRoot $ProjectRoot `
        -ActionRoot $ActionRoot `
        -EntryFile $GammaEntry `
        -ClaimApprover {
            param($Plan)
            $Claims.Current = $Plan.Kind -ceq 'ClaimCurrent'
            return $Claims.Current
        })
    Assert-ProjDataRootTest `
        -Condition $Claims.Current `
        -Message 'same-name entry with another File ID bypassed claim'

    $EpsilonEntry = Join-Path $ProjectRoot 'epsilon.cmd'
    [IO.File]::WriteAllText($EpsilonEntry, '@echo original')
    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_PROJ_DATA_ROOT',
        $null,
        [EnvironmentVariableTarget]::Process
    )
    $EpsilonRoot = Resolve-ProjProjectDataRoot `
        -ProjectRoot $ProjectRoot `
        -ActionRoot $ActionRoot `
        -EntryFile $EpsilonEntry
    $EpsilonOriginalRecord = (
        Read-ProjEntryIdentityRecord -DataRoot $EpsilonRoot
    ).Value

    $FirstReplacement = Join-Path $ProjectRoot 'epsilon.first.cmd'
    $FirstBackup = Join-Path $ProjectRoot 'epsilon.first.backup.cmd'
    [IO.File]::WriteAllText($FirstReplacement, '@echo first replacement')
    [IO.File]::Replace(
        $FirstReplacement,
        $EpsilonEntry,
        $FirstBackup,
        $true
    )
    [IO.File]::Delete($FirstBackup)
    $RejectedChangedEntry = $false
    try {
        [void](Resolve-ProjProjectDataRoot `
            -ProjectRoot $ProjectRoot `
            -ActionRoot $ActionRoot `
            -EntryFile $EpsilonEntry `
            -ClaimApprover {
                param($Claim)
                $SecondReplacement = Join-Path `
                    $ProjectRoot `
                    'epsilon.second.cmd'
                $SecondBackup = Join-Path `
                    $ProjectRoot `
                    'epsilon.second.backup.cmd'
                [IO.File]::WriteAllText(
                    $SecondReplacement,
                    '@echo second replacement'
                )
                [IO.File]::Replace(
                    $SecondReplacement,
                    $EpsilonEntry,
                    $SecondBackup,
                    $true
                )
                [IO.File]::Delete($SecondBackup)
                return $Claim.Kind -ceq 'ClaimCurrent'
            })
    } catch {
        $RejectedChangedEntry = $_.Exception.Message -like (
            '*state changed during claim*'
        )
    }
    $EpsilonCurrentIdentity = Get-ProjEntryFileIdentity `
        -EntryFile $EpsilonEntry
    $EpsilonPublishedRecord = (
        Read-ProjEntryIdentityRecord -DataRoot $EpsilonRoot
    ).Value
    Assert-ProjDataRootTest `
        -Condition ($RejectedChangedEntry -and
            (Test-ProjEntryIdentityEqual `
                -Record $EpsilonPublishedRecord `
                -Identity $EpsilonCurrentIdentity) -eq $false -and
            [string]$EpsilonPublishedRecord.fileId -ceq
                [string]$EpsilonOriginalRecord.fileId) `
        -Message 'claim approval was applied after the entry File ID changed'

    $DeltaEntry = Join-Path $ProjectRoot 'delta.cmd'
    [IO.File]::WriteAllText($DeltaEntry, '@echo off')
    $DeltaRoot = Join-Path $ProjectRoot 'data\proj.delta'
    [void][IO.Directory]::CreateDirectory($DeltaRoot)
    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_PROJ_DATA_ROOT',
        $null,
        [EnvironmentVariableTarget]::Process
    )
    [void](Resolve-ProjProjectDataRoot `
        -ProjectRoot $ProjectRoot `
        -ActionRoot $ActionRoot `
        -EntryFile $DeltaEntry `
        -ClaimApprover {
            param($Plan)
            $Claims.MissingRecord =
                $Plan.Kind -ceq 'ClaimCurrent'
            return $Claims.MissingRecord
        })
    Assert-ProjDataRootTest `
        -Condition $Claims.MissingRecord `
        -Message 'an unrecorded same-name DataRoot bypassed claim'

    $env:SWAWKIT_PROJ_DATA_ROOT = $BetaRoot
    $RejectedForeignRoot = $false
    try {
        [void](Get-ProjDataRootPlan `
            -ProjectRoot $ProjectRoot `
            -EntryFile $GammaEntry `
            -InheritedDataRoot $BetaRoot)
    } catch {
        $RejectedForeignRoot =
            $_.Exception.Message -like "*Another project's DataRoot*"
    }
    Assert-ProjDataRootTest `
        -Condition $RejectedForeignRoot `
        -Message 'another entry DataRoot was accepted as inherited context'

    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_PROJ_DATA_ROOT',
        $null,
        [EnvironmentVariableTarget]::Process
    )
    $DuplicateRoot = Join-Path $ProjectRoot 'data\proj.duplicate'
    [void][IO.Directory]::CreateDirectory($DuplicateRoot)
    [IO.File]::Copy(
        (Join-Path $GammaRoot '_entry.json'),
        (Join-Path $DuplicateRoot '_entry.json'),
        $true
    )
    $RejectedDuplicateIdentity = $false
    try {
        [void](Get-ProjDataRootPlan `
            -ProjectRoot $ProjectRoot `
            -EntryFile $GammaEntry)
    } catch {
        $RejectedDuplicateIdentity =
            $_.Exception.Message -like '*Multiple project DataRoots*'
    }
    Assert-ProjDataRootTest `
        -Condition $RejectedDuplicateIdentity `
        -Message 'multiple DataRoots with one File ID were not rejected'
} finally {
    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_PROJ_DATA_ROOT',
        $PreviousDataRoot,
        [EnvironmentVariableTarget]::Process
    )
    if ([IO.Directory]::Exists($TemporaryRoot)) {
        [IO.Directory]::Delete($TemporaryRoot, $true)
    }
}

Write-Host '[PASS] Proj entry identity and DataRoot claims' `
    -ForegroundColor Green
$global:LASTEXITCODE = 0
