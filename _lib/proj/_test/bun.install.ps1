[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '.dev\setup\_lib\bootstrap.ps1')
. (Join-Path $ProjRoot '_core\engine.ps1')
. (Join-Path $PSScriptRoot '_lib\bun-fixture.ps1')

$EnvironmentNames = @(
    'SWAWKIT_PROJ_PROTOCOL',
    'SWAWKIT_PROJ_ID',
    'SWAWKIT_PROJ_DIR',
    'SWAWKIT_PROJ_ACTION_ROOT',
    'SWAWKIT_PROJ_DATA_ROOT',
    'SWAWKIT_PROJ_ENTRY_COMMAND',
    'SWAWKIT_PROJ_ENTRY_FILE',
    'SWAWKIT_INVOCATION_DIR',
    'SWAWKIT_PROJ_BUN_MODE',
    'SWAWKIT_PROJ_BUN_VERSION',
    'SWAWKIT_PROJ_BUN_SHA256',
    'SWAWKIT_TEST_BUN_CAPTURE'
)
$EnvironmentSnapshot = Enter-ProjBunIsolatedEnvironment `
    -ProjectVariableNames $EnvironmentNames
$UserPathBefore = [Environment]::GetEnvironmentVariable('PATH', 'User')
$MachinePathBefore = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
$TestTemporaryBase = [IO.Path]::GetFullPath(
    (Join-Path $ProjRoot '..\..\data\_test')
)
[void][IO.Directory]::CreateDirectory($TestTemporaryBase)
$TemporaryRoot = Join-Path $TestTemporaryBase (
    "swawkit-proj-bun-$([Guid]::NewGuid().ToString('N'))"
)
$SystemPowerShell = Join-Path $env:SystemRoot (
    'System32\WindowsPowerShell\v1.0\powershell.exe'
)

try {
    $ProjectRoot = Join-Path $TemporaryRoot 'project'
    $DataRoot = Join-Path $TemporaryRoot 'data root'
    $FixtureRoot = Join-Path $TemporaryRoot 'fixture'
    $ArchiveRoot = Join-Path $FixtureRoot 'archive'
    $BunArchiveRoot = Join-Path $ArchiveRoot 'bun-windows-x64'
    $InvocationRoot = Join-Path $ProjectRoot 'work area'
    foreach ($Directory in @(
        $ProjectRoot,
        $DataRoot,
        $BunArchiveRoot,
        $InvocationRoot
    )) {
        [void][IO.Directory]::CreateDirectory($Directory)
    }

    $FixtureExecutable = Join-Path $BunArchiveRoot 'bun.exe'
    New-ProjBunFixtureExecutable `
        -Path $FixtureExecutable `
        -Version '1.2.15'
    $ArchivePath = Join-Path $FixtureRoot 'bun-windows-x64.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($ArchiveRoot, $ArchivePath)
    $Definition = New-ProjBunTestDefinition `
        -ArchivePath $ArchivePath `
        -Sha256 (Get-ProjDevFileSha256 -Path $ArchivePath)
    $Context = New-ProjDevContext `
        -ProjectId 'bun-test' `
        -ProjectRoot $ProjectRoot `
        -DataRoot $DataRoot `
        -EntryCommand 'swawkit' `
        -InvocationDirectory $InvocationRoot

    $Changed = Install-ProjDevBun `
        -Context $Context `
        -Definition $Definition
    Assert-ProjBunTest -Condition $Changed -Message 'first install was skipped'
    Assert-ProjBunTest `
        -Condition (Test-ProjDevInstalled `
            -Context $Context `
            -Definition $Definition) `
        -Message 'trusted fixture installation was not recognized'
    $InstallRoot = Get-ProjDevInstallRoot `
        -Context $Context `
        -Definition $Definition
    $ExpectedBunx = "@echo off`r`n`"%~dp0bun.exe`" x %*`r`n"
    Assert-ProjBunTest `
        -Condition ([IO.File]::ReadAllText(
            (Join-Path $InstallRoot 'bunx.cmd')
        ) -ceq $ExpectedBunx) `
        -Message 'bunx.cmd shim is not byte-compatible with the baseline'

    $Plan = New-ProjDevEnvironmentPlan -Context $Context
    Add-ProjDevBunEnvironment `
        -Context $Context `
        -Definition $Definition `
        -Plan $Plan
    $Scripts = ConvertTo-ProjDevEnvironmentScripts -Plan $Plan
    Assert-ProjBunTest `
        -Condition (Publish-ProjDevEnvironmentScripts `
            -Context $Context `
            -Scripts $Scripts) `
        -Message 'first environment publication was skipped'
    Assert-ProjBunEnvironmentScriptsUsable `
        -Context $Context `
        -ExpectedExecutable (Join-Path $InstallRoot 'bun.exe') `
        -PowerShell $SystemPowerShell
    $EnvCmdHash = Get-ProjDevFileSha256 -Path $Context.EnvCmdPath
    $EnvPs1Hash = Get-ProjDevFileSha256 -Path $Context.EnvPs1Path

    Assert-ProjBunTest `
        -Condition (-not (Install-ProjDevBun `
            -Context $Context `
            -Definition $Definition)) `
        -Message 'valid installation was needlessly replaced'
    Assert-ProjBunTest `
        -Condition (-not (Publish-ProjDevEnvironmentScripts `
            -Context $Context `
            -Scripts (ConvertTo-ProjDevEnvironmentScripts -Plan $Plan))) `
        -Message 'byte-stable environment was needlessly rewritten'
    Assert-ProjBunTest `
        -Condition (
            (Get-ProjDevFileSha256 -Path $Context.EnvCmdPath) -ceq $EnvCmdHash -and
            (Get-ProjDevFileSha256 -Path $Context.EnvPs1Path) -ceq $EnvPs1Hash
        ) `
        -Message 'repeated setup changed generated environment bytes'

    $UnpinnedDefinition = New-ProjBunTestDefinition `
        -ArchivePath $ArchivePath `
        -Sha256 (Get-ProjDevFileSha256 -Path $ArchivePath)
    $UnpinnedDefinition.ProjectSha256 = ''
    $UnpinnedDefinition.Sha256 = ''
    $UnpinnedDefinition.Verification = 'unverified'
    $UnpinnedContext = New-ProjDevContext `
        -ProjectId 'bun-unpinned' `
        -ProjectRoot $ProjectRoot `
        -DataRoot (Join-Path $TemporaryRoot 'unpinned-data')
    Assert-ProjBunTest `
        -Condition (Install-ProjDevBun `
            -Context $UnpinnedContext `
            -Definition $UnpinnedDefinition) `
        -Message 'Bun without an upstream or project hash was blocked'
    $UnpinnedMetadata = Get-ProjDevValidInstallMetadata `
        -Context $UnpinnedContext `
        -Definition $UnpinnedDefinition
    Assert-ProjBunTest `
        -Condition (
            $null -ne $UnpinnedMetadata -and
            [string]$UnpinnedMetadata.sourceSha256 -ceq (
                Get-ProjDevFileSha256 -Path $ArchivePath
            ) -and
            [string]$UnpinnedMetadata.sourceVerification -ceq 'unverified'
        ) `
        -Message 'unpinned installation did not record its downloaded SHA-256'

    $BadDataRoot = Join-Path $TemporaryRoot 'bad-data'
    $BadContext = New-ProjDevContext `
        -ProjectId 'bun-bad' `
        -ProjectRoot $ProjectRoot `
        -DataRoot $BadDataRoot
    $BadDefinition = New-ProjBunTestDefinition `
        -ArchivePath $ArchivePath `
        -Sha256 ('0' * 64)
    Assert-ProjBunThrows `
        -Action {
            Install-ProjDevBun `
                -Context $BadContext `
                -Definition $BadDefinition
        } `
        -Pattern '*SHA-256 verification failed*'
    Assert-ProjBunTest `
        -Condition (-not [IO.Directory]::Exists(
            (Get-ProjDevInstallRoot `
                -Context $BadContext `
                -Definition $BadDefinition)
        )) `
        -Message 'wrong-checksum artifact created an installation'

    [IO.File]::AppendAllText((Join-Path $InstallRoot 'bun.exe'), 'damage')
    Assert-ProjBunTest `
        -Condition (-not (Test-ProjDevInstalled `
            -Context $Context `
            -Definition $Definition)) `
        -Message 'installed-file corruption was not detected'
    [IO.File]::Delete($ArchivePath)
    Assert-ProjBunTest `
        -Condition (Install-ProjDevBun `
            -Context $Context `
            -Definition $Definition) `
        -Message 'damaged install was not repaired from verified cache'
    Assert-ProjBunTest `
        -Condition (Test-ProjDevInstalled `
            -Context $Context `
            -Definition $Definition) `
        -Message 'cache repair did not restore a trusted installation'

    Assert-ProjBunZipTraversalRejected `
        -TemporaryRoot $TemporaryRoot `
        -FixtureRoot $FixtureRoot

    $ActionRoot = Join-Path $ProjectRoot '.swaw'
    [void][IO.Directory]::CreateDirectory($ActionRoot)
    $EntryFile = Join-Path $ProjectRoot 'entry.cmd'
    [IO.File]::WriteAllText($EntryFile, '@echo off')
    $HelpDataRoot = Join-Path $TemporaryRoot 'help data'
    Set-ProjBunProcessEnvironment -Values @{
        SWAWKIT_PROJ_PROTOCOL = '1'
        SWAWKIT_PROJ_ID = 'bun-help'
        SWAWKIT_PROJ_DIR = $ProjectRoot
        SWAWKIT_PROJ_ACTION_ROOT = $ActionRoot
        SWAWKIT_PROJ_DATA_ROOT = $HelpDataRoot
        SWAWKIT_PROJ_ENTRY_COMMAND = 'swawkit'
        SWAWKIT_PROJ_ENTRY_FILE = $EntryFile
        SWAWKIT_INVOCATION_DIR = $InvocationRoot
        SWAWKIT_PROJ_BUN_MODE = 'disabled'
        SWAWKIT_PROJ_BUN_VERSION = '1.2.15'
    }
    $HelpExitCode = Invoke-ProjMain `
        -KernelRoot $ProjRoot `
        -Arguments @('.dev.setup', '--help')
    Assert-ProjBunTest `
        -Condition ($HelpExitCode -eq 0 -and
            -not [IO.Directory]::Exists($HelpDataRoot)) `
        -Message '.dev.setup --help was not handled read-only by Proj'

    $SetupDataRoot = Join-Path $TemporaryRoot 'setup entry data'
    $env:SWAWKIT_PROJ_ID = 'bun-setup'
    $env:SWAWKIT_PROJ_DATA_ROOT = $SetupDataRoot
    $SetupEntry = Join-Path $ProjRoot '.dev\setup\run.ps1'
    $SetupResult = Invoke-ProjBunEntryFixture `
        -PowerShell $SystemPowerShell `
        -EntryPath $SetupEntry `
        -Arguments @()
    Assert-ProjBunTest `
        -Condition ($SetupResult.ExitCode -eq 0 -and
            [IO.File]::Exists((Join-Path $SetupDataRoot 'dev_env\env.cmd')) -and
            [IO.File]::Exists((Join-Path $SetupDataRoot 'dev_env\env.ps1')) -and
            -not [IO.Directory]::Exists(
                (Join-Path $SetupDataRoot 'dev_env\bun')
            )) `
        -Message "real disabled .dev.setup entry failed: $($SetupResult.Output)"
    $SetupEnvHash = Get-ProjDevFileSha256 `
        -Path (Join-Path $SetupDataRoot 'dev_env\env.ps1')
    $RejectedSetup = Invoke-ProjBunEntryFixture `
        -PowerShell $SystemPowerShell `
        -EntryPath $SetupEntry `
        -Arguments @('unexpected')
    Assert-ProjBunTest `
        -Condition ($RejectedSetup.ExitCode -eq 1 -and
            (Get-ProjDevFileSha256 `
                -Path (Join-Path $SetupDataRoot 'dev_env\env.ps1')
            ) -ceq $SetupEnvHash) `
        -Message '.dev.setup accepted arguments or changed state after rejection'

    Assert-ProjBunTest `
        -Condition (
            [Environment]::GetEnvironmentVariable('PATH', 'User') -ceq
                $UserPathBefore -and
            [Environment]::GetEnvironmentVariable('PATH', 'Machine') -ceq
                $MachinePathBefore
        ) `
        -Message 'setup changed persistent User or Machine PATH'

    Write-Host '[PASS] Proj Bun installation test' -ForegroundColor Green
} finally {
    Exit-ProjBunIsolatedEnvironment -Snapshot $EnvironmentSnapshot
    $ResolvedTemporaryRoot = [IO.Path]::GetFullPath($TemporaryRoot)
    $SystemTemporaryRoot = [IO.Path]::GetFullPath(
        $TestTemporaryBase
    ).TrimEnd('\') + '\'
    if ($ResolvedTemporaryRoot.StartsWith(
        $SystemTemporaryRoot,
        [StringComparison]::OrdinalIgnoreCase
    ) -and
        [IO.Path]::GetFileName($ResolvedTemporaryRoot).StartsWith(
            'swawkit-proj-bun-',
            [StringComparison]::Ordinal
        ) -and
        [IO.Directory]::Exists($ResolvedTemporaryRoot)) {
        Remove-Item -LiteralPath $ResolvedTemporaryRoot -Recurse -Force
    }
}
