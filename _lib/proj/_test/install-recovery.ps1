[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '.dev\setup\_lib\bootstrap.ps1')

function Assert-ProjRecoveryTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Proj install recovery test failed: $Message"
    }
}

function Write-ProjRecoveryCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Identity
    )

    [void][IO.Directory]::CreateDirectory($Path)
    [IO.File]::WriteAllText(
        (Join-Path $Path 'identity.txt'),
        $Identity,
        [Text.UTF8Encoding]::new($false)
    )
}

$TestBase = [IO.Path]::GetFullPath(
    (Join-Path $ProjRoot '..\..\data\_test')
)
[void][IO.Directory]::CreateDirectory($TestBase)
$TemporaryRoot = Join-Path $TestBase (
    "swawkit-proj-recovery-$([Guid]::NewGuid().ToString('N'))"
)
$LockHolder = [pscustomobject]@{ Stream = $null }

try {
    $ProjectRoot = Join-Path $TemporaryRoot 'project'
    $DataRoot = Join-Path $TemporaryRoot 'data'
    [void][IO.Directory]::CreateDirectory($ProjectRoot)
    [void][IO.Directory]::CreateDirectory($DataRoot)
    $Context = New-ProjDevContext `
        -ProjectRoot $ProjectRoot `
        -DataRoot $DataRoot
    $Definition = [pscustomobject]@{ Name = 'fixture' }
    $Target = Join-Path $Context.EnvironmentRoot 'fixture\installs\v1'
    $Parent = Split-Path -Path $Target -Parent
    [void][IO.Directory]::CreateDirectory($Parent)
    $Validate = {
        param($ValidationContext, $ValidationDefinition, $InstallRoot)

        $IdentityPath = Join-Path $InstallRoot 'identity.txt'
        return [IO.File]::Exists($IdentityPath) -and
            [IO.File]::ReadAllText($IdentityPath) -ceq 'valid'
    }

    Write-ProjRecoveryCandidate -Path $Target -Identity 'valid'
    $StaleBackup = "$Target.backup-stale"
    $StalePartial = Join-Path $Parent '.partial-stale'
    Write-ProjRecoveryCandidate -Path $StaleBackup -Identity 'invalid'
    Write-ProjRecoveryCandidate -Path $StalePartial -Identity 'partial'
    $Healthy = Repair-ProjDevInstallState `
        -Context $Context `
        -Definition $Definition `
        -TargetPath $Target `
        -ValidateCandidate $Validate
    Assert-ProjRecoveryTest `
        -Condition (
            $Healthy.Ready -and
            -not (Test-ProjDevPathExists -Path $StaleBackup) -and
            -not (Test-ProjDevPathExists -Path $StalePartial)
        ) `
        -Message 'a healthy target did not clean interrupted residues'

    Remove-ProjDevControlledPathWithRetry `
        -Path $Target `
        -DataRoot $Context.DataRoot `
        -Activity 'preparing the missing-target recovery test'
    $MissingBackup = "$Target.backup-valid"
    Write-ProjRecoveryCandidate -Path $MissingBackup -Identity 'valid'
    $RestoredMissing = Repair-ProjDevInstallState `
        -Context $Context `
        -Definition $Definition `
        -TargetPath $Target `
        -ValidateCandidate $Validate
    Assert-ProjRecoveryTest `
        -Condition (
            $RestoredMissing.Ready -and
            $RestoredMissing.Restored -and
            (& $Validate $Context $Definition $Target)
        ) `
        -Message 'a valid backup was not restored for a missing target'

    [IO.File]::WriteAllText((Join-Path $Target 'identity.txt'), 'invalid')
    $InvalidBackup = "$Target.backup-valid"
    Write-ProjRecoveryCandidate -Path $InvalidBackup -Identity 'valid'
    $RestoredInvalid = Repair-ProjDevInstallState `
        -Context $Context `
        -Definition $Definition `
        -TargetPath $Target `
        -ValidateCandidate $Validate
    Assert-ProjRecoveryTest `
        -Condition (
            $RestoredInvalid.Ready -and
            $RestoredInvalid.Restored -and
            (& $Validate $Context $Definition $Target)
        ) `
        -Message 'a valid backup did not replace an invalid target'

    [IO.File]::WriteAllText((Join-Path $Target 'identity.txt'), 'invalid')
    $InterruptedWork = Join-Path $Parent '.work-interrupted'
    Write-ProjRecoveryCandidate -Path $InterruptedWork -Identity 'partial'
    $CleanState = Repair-ProjDevInstallState `
        -Context $Context `
        -Definition $Definition `
        -TargetPath $Target `
        -ValidateCandidate $Validate
    Assert-ProjRecoveryTest `
        -Condition (
            -not $CleanState.Ready -and
            -not (Test-ProjDevPathExists -Path $Target) -and
            -not (Test-ProjDevPathExists -Path $InterruptedWork)
        ) `
        -Message 'invalid state was not reset for a clean reinstall'

    Write-ProjRecoveryCandidate -Path $Target -Identity 'invalid'
    $LockedFile = Join-Path $Target 'locked.bin'
    [IO.File]::WriteAllText($LockedFile, 'locked')
    $LockedBackup = "$Target.backup-valid"
    Write-ProjRecoveryCandidate -Path $LockedBackup -Identity 'valid'
    $LockHolder.Stream = [IO.File]::Open(
        $LockedFile,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::None
    )
    $LockRejected = $false
    try {
        [void](Repair-ProjDevInstallState `
            -Context $Context `
            -Definition $Definition `
            -TargetPath $Target `
            -ValidateCandidate $Validate)
    } catch {
        $LockRejected = $_.Exception.Message -like '*Release processes*'
    } finally {
        $LockHolder.Stream.Dispose()
        $LockHolder.Stream = $null
    }
    Assert-ProjRecoveryTest `
        -Condition (
            $LockRejected -and
            (Test-ProjDevPathExists -Path $LockedBackup)
        ) `
        -Message 'a file lock did not preserve the valid backup'
    $AfterUnlock = Repair-ProjDevInstallState `
        -Context $Context `
        -Definition $Definition `
        -TargetPath $Target `
        -ValidateCandidate $Validate
    Assert-ProjRecoveryTest `
        -Condition ($AfterUnlock.Ready -and $AfterUnlock.Restored) `
        -Message 'recovery did not succeed after the file lock was released'

    $Staged = New-ProjDevInstallWorkPath `
        -TargetPath $Target `
        -Kind 'partial'
    Write-ProjRecoveryCandidate -Path $Staged -Identity 'new'
    $LockingValidator = {
        param($ValidationContext, $ValidationDefinition, $InstallRoot)

        $IdentityPath = Join-Path $InstallRoot 'identity.txt'
        $Identity = [IO.File]::ReadAllText($IdentityPath)
        if ($Identity -ceq 'new') {
            $LockHolder.Stream = [IO.File]::Open(
                $IdentityPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::None
            )
            return $false
        }
        return $Identity -ceq 'valid'
    }.GetNewClosure()
    $RollbackPending = $false
    try {
        Publish-ProjDevInstallDirectory `
            -Context $Context `
            -Definition $Definition `
            -StagedPath $Staged `
            -TargetPath $Target `
            -ValidatePublished $LockingValidator
    } catch {
        $RollbackPending = $_.Exception.Message -like '*rollback is pending*'
    } finally {
        if ($null -ne $LockHolder.Stream) {
            $LockHolder.Stream.Dispose()
            $LockHolder.Stream = $null
        }
    }
    $PendingPaths = Get-ProjDevInstallRecoveryPaths -TargetPath $Target
    Assert-ProjRecoveryTest `
        -Condition (
            $RollbackPending -and
            @($PendingPaths.Backups).Count -eq 1
        ) `
        -Message 'failed publish did not preserve a recoverable backup'
    $RecoveredPublish = Repair-ProjDevInstallState `
        -Context $Context `
        -Definition $Definition `
        -TargetPath $Target `
        -ValidateCandidate $Validate
    Assert-ProjRecoveryTest `
        -Condition ($RecoveredPublish.Ready -and $RecoveredPublish.Restored) `
        -Message 'a rollback-pending publish was not recovered'

    $MoveDestination = Join-Path $Parent 'move-destination'
    Write-ProjRecoveryCandidate -Path $MoveDestination -Identity 'existing'
    $MissingMoveSourceRejected = $false
    try {
        Move-ProjDevControlledPathWithRetry `
            -Source (Join-Path $Parent 'missing-move-source') `
            -Destination $MoveDestination `
            -DataRoot $Context.DataRoot `
            -Activity 'testing a missing move source'
    } catch {
        $MissingMoveSourceRejected =
            $_.Exception.Message -like '*source is missing*'
    }
    Assert-ProjRecoveryTest `
        -Condition $MissingMoveSourceRejected `
        -Message 'a missing move source was mistaken for an existing target'
    Remove-ProjDevControlledPathWithRetry `
        -Path $MoveDestination `
        -DataRoot $Context.DataRoot `
        -Activity 'cleaning the move contract test'

    Remove-ProjDevControlledPathWithRetry `
        -Path $Target `
        -DataRoot $Context.DataRoot `
        -Activity 'preparing the first-install rollback test'
    $FirstInstallStaged = New-ProjDevInstallWorkPath `
        -TargetPath $Target `
        -Kind 'partial'
    Write-ProjRecoveryCandidate -Path $FirstInstallStaged -Identity 'new'
    $FirstInstallMessageCorrect = $false
    try {
        Publish-ProjDevInstallDirectory `
            -Context $Context `
            -Definition $Definition `
            -StagedPath $FirstInstallStaged `
            -TargetPath $Target `
            -ValidatePublished $LockingValidator
    } catch {
        $FirstInstallMessageCorrect =
            $_.Exception.Message -like (
                '*No previous installation backup was available*'
            ) -and
            $_.Exception.Message -notlike '*valid backup*'
    } finally {
        if ($null -ne $LockHolder.Stream) {
            $LockHolder.Stream.Dispose()
            $LockHolder.Stream = $null
        }
    }
    $FirstInstallPaths = Get-ProjDevInstallRecoveryPaths -TargetPath $Target
    Assert-ProjRecoveryTest `
        -Condition (
            $FirstInstallMessageCorrect -and
            (Test-ProjDevPathExists -Path $Target) -and
            @($FirstInstallPaths.Backups).Count -eq 0
        ) `
        -Message 'first-install rollback reported a nonexistent backup'
    $RecoveredFirstInstall = Repair-ProjDevInstallState `
        -Context $Context `
        -Definition $Definition `
        -TargetPath $Target `
        -ValidateCandidate $Validate
    Assert-ProjRecoveryTest `
        -Condition (
            -not $RecoveredFirstInstall.Ready -and
            -not $RecoveredFirstInstall.Restored -and
            -not (Test-ProjDevPathExists -Path $Target)
        ) `
        -Message 'first-install failure was not reset after its lock released'

    Write-Host '[PASS] Proj install recovery test' -ForegroundColor Green
} finally {
    if ($null -ne $LockHolder.Stream) {
        $LockHolder.Stream.Dispose()
    }
    $ResolvedTemporaryRoot = [IO.Path]::GetFullPath($TemporaryRoot)
    $TestPrefix = $TestBase.TrimEnd('\') + '\'
    if ($ResolvedTemporaryRoot.StartsWith(
        $TestPrefix,
        [StringComparison]::OrdinalIgnoreCase
    ) -and
        [IO.Path]::GetFileName($ResolvedTemporaryRoot).StartsWith(
            'swawkit-proj-recovery-',
            [StringComparison]::Ordinal
        ) -and
        [IO.Directory]::Exists($ResolvedTemporaryRoot)) {
        Remove-Item -LiteralPath $ResolvedTemporaryRoot -Recurse -Force
    }
}
