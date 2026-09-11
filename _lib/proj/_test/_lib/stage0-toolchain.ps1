Set-StrictMode -Version 2.0

$Stage0ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$Stage0ToolchainRoot = Join-Path $Stage0ProjRoot '_toolchain'
. (Join-Path $Stage0ToolchainRoot '_lib\runtime.ps1')

foreach ($File in @(
    'event.ps1',
    'artifact.ps1',
    'recovery.ps1',
    'install.ps1',
    'environment.ps1'
)) {
    . (Join-Path (Join-Path $Stage0ToolchainRoot '_lib') $File)
}

$Stage0ModuleRoot = Join-Path $Stage0ToolchainRoot '_modules'
foreach ($File in @(
    'bun\module.ps1',
    'bun\release.ps1',
    'bun\selection.ps1',
    'bun\install.ps1',
    'pwsh\module.ps1',
    'pwsh\release.ps1',
    'pwsh\selection.ps1',
    'pwsh\install.ps1',
    'msvc\module.ps1',
    'msvc\payload.ps1',
    'msvc\manifest.ps1',
    'msvc\release.ps1',
    'msvc\install.ps1',
    'msvc\environment.ps1',
    'rust\module.ps1',
    'rust\metadata.ps1',
    'rust\state.ps1',
    'rust\release.ps1',
    'rust\process.ps1',
    'rust\install.ps1',
    'rust\environment.ps1'
)) {
    . (Join-Path $Stage0ModuleRoot $File)
}

function New-ProjStage0TestContext {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$CacheDataRoot,
        [string]$EntryCommand = 'swawkit',
        [AllowNull()][string]$InvocationDirectory = $null,
        [AllowNull()][string]$EnvironmentRoot = $null,
        [AllowNull()][string]$ToolchainExecutable = $null
    )

    $ProjectRoot = Get-ProjDevFullPath -Path $ProjectRoot
    if (-not [IO.Directory]::Exists($ProjectRoot)) {
        throw "Stage-0 test project directory does not exist: $ProjectRoot"
    }
    $DataRoot = Assert-ProjDevControlledRoot `
        -Root $DataRoot `
        -Description 'Stage-0 test data root'
    $CacheDataRoot = Assert-ProjDevControlledRoot `
        -Root $CacheDataRoot `
        -Description 'Stage-0 test cache data root'
    $InvocationDirectory = if ([string]::IsNullOrWhiteSpace(
        $InvocationDirectory
    )) {
        $ProjectRoot
    } else {
        Get-ProjDevFullPath -Path $InvocationDirectory
    }
    if (-not [IO.Directory]::Exists($InvocationDirectory)) {
        throw (
            'Stage-0 test invocation directory does not exist: ' +
            $InvocationDirectory
        )
    }
    $EnvironmentRoot = if ([string]::IsNullOrWhiteSpace($EnvironmentRoot)) {
        Join-Path $DataRoot 'environment'
    } else {
        $EnvironmentRoot
    }
    $EnvironmentRoot = Assert-ProjDevPathInsideDataRoot `
        -Path $EnvironmentRoot `
        -DataRoot $DataRoot `
        -Activity 'resolving the Stage-0 test environment root'
    return [pscustomobject][ordered]@{
        ProjectRoot = $ProjectRoot
        DataRoot = $DataRoot
        CacheDataRoot = $CacheDataRoot
        EnvironmentRoot = $EnvironmentRoot
        EnvCmdPath = Join-Path $EnvironmentRoot 'env.cmd'
        EnvPs1Path = Join-Path $EnvironmentRoot 'env.ps1'
        CacheRoot = Join-Path $CacheDataRoot 'downloads'
        ArtifactLockRoot = Join-Path $CacheDataRoot '_locks'
        EntryCommand = $EntryCommand
        EnvironmentRepairInvocation = "$EntryCommand .dev/setup"
        InvocationDirectory = $InvocationDirectory
        ToolchainExecutable = $ToolchainExecutable
    }
}
