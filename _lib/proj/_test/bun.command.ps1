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
    'SWAWKIT_PROJ_HOME',
    'SWAWKIT_PROJ_DIR',
    'SWAWKIT_PROJ_ACTION_ROOT',
    'SWAWKIT_PROJ_DATA_ROOT',
    'SWAWKIT_PROJ_ENTRY_COMMAND',
    'SWAWKIT_PROJ_ENTRY_FILE',
    'SWAWKIT_INVOCATION_DIR',
    'SWAWKIT_PROJ_BUN_MODE',
    'SWAWKIT_PROJ_BUN_VERSION',
    'SWAWKIT_PROJ_BUN_SHA256',
    'SWAWKIT_PROJ_PWSH_MODE',
    'SWAWKIT_PROJ_PWSH_VERSION',
    'SWAWKIT_PROJ_PWSH_SHA256',
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
    "swawkit-proj-bun-command-$([Guid]::NewGuid().ToString('N'))"
)
$ControlHome = [IO.Path]::GetFullPath((Join-Path $ProjRoot '..\..'))
$EntryName = "test-bun-command-$([Guid]::NewGuid().ToString('N'))"
$ConsumerDataRoot = Join-Path $ControlHome "data\proj.$EntryName"
$SystemPowerShell = Join-Path $env:SystemRoot (
    'System32\WindowsPowerShell\v1.0\powershell.exe'
)

try {
    $ProjectRoot = Join-Path $TemporaryRoot 'project'
    $InvocationRoot = Join-Path $ProjectRoot 'work area'
    $ActionRoot = Join-Path $ProjectRoot '.swaw'
    foreach ($Directory in @($ProjectRoot, $InvocationRoot, $ActionRoot)) {
        [void][IO.Directory]::CreateDirectory($Directory)
    }
    $EntryFile = Join-Path $ProjectRoot "$EntryName.cmd"
    [IO.File]::WriteAllText($EntryFile, '@echo off')

    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_PROJ_DATA_ROOT',
        $null,
        [EnvironmentVariableTarget]::Process
    )
    [void](Resolve-ProjProjectDataRoot `
        -ProjHome $ControlHome `
        -ProjectRoot $ProjectRoot `
        -ActionRoot $ActionRoot `
        -EntryFile $EntryFile)
    $ConsumerContext = New-ProjDevContext `
        -ProjectRoot $ProjectRoot `
        -DataRoot $ConsumerDataRoot `
        -CacheDataRoot (Join-Path $TemporaryRoot 'shared cache') `
        -EntryCommand 'swawkit' `
        -InvocationDirectory $InvocationRoot
    Assert-ProjBunTest `
        -Condition (-not (Assert-ProjDevActiveEnvironmentCompatible `
            -Context $ConsumerContext)) `
        -Message 'an inactive shell was reported as a development environment'

    $env:SWAWKIT_DEV_GENERATION_ID = '0123456789abcdef'
    Assert-ProjBunThrows `
        -Action {
            Assert-ProjDevActiveEnvironmentCompatible `
                -Context $ConsumerContext
        } `
        -Pattern '*incomplete*'
    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_DEV_GENERATION_ID',
        $null,
        'Process'
    )

    $env:SWAWKIT_DEV_PROJECT_ROOT = $ConsumerContext.ProjectRoot
    $env:SWAWKIT_DEV_ENV_ROOT = $ConsumerContext.EnvironmentRoot
    Assert-ProjBunTest `
        -Condition (Assert-ProjDevActiveEnvironmentCompatible `
            -Context $ConsumerContext) `
        -Message 'the same project development environment was rejected'
    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_DEV_ENV_ROOT',
        $null,
        'Process'
    )
    Assert-ProjBunThrows `
        -Action {
            Assert-ProjDevActiveEnvironmentCompatible `
                -Context $ConsumerContext
        } `
        -Pattern '*incomplete*'
    $env:SWAWKIT_DEV_PROJECT_ROOT = $ProjRoot
    $env:SWAWKIT_DEV_ENV_ROOT = Join-Path $TemporaryRoot 'foreign env'
    Assert-ProjBunThrows `
        -Action {
            Assert-ProjDevActiveEnvironmentCompatible `
                -Context $ConsumerContext
        } `
        -Pattern "*Another project's*"

    $ForeignDataRoot = Join-Path $TemporaryRoot 'foreign setup data'
    Set-ProjBunProcessEnvironment -Values @{
        SWAWKIT_PROJ_PROTOCOL = '1'
        SWAWKIT_PROJ_HOME = $ControlHome
        SWAWKIT_PROJ_DIR = $ProjectRoot
        SWAWKIT_PROJ_ACTION_ROOT = $ActionRoot
        SWAWKIT_PROJ_DATA_ROOT = $ForeignDataRoot
        SWAWKIT_PROJ_ENTRY_COMMAND = 'swawkit'
        SWAWKIT_PROJ_ENTRY_FILE = $EntryFile
        SWAWKIT_INVOCATION_DIR = $InvocationRoot
        SWAWKIT_PROJ_BUN_MODE = 'disabled'
        SWAWKIT_PROJ_BUN_VERSION = '1.2.15'
    }
    $ForeignSetupResult = Invoke-ProjBunEntryFixture `
        -PowerShell $SystemPowerShell `
        -EntryPath (Join-Path $ProjRoot '.dev\setup\run.ps1') `
        -Arguments @()
    Assert-ProjBunTest `
        -Condition ($ForeignSetupResult.ExitCode -eq 1 -and
            -not [IO.Directory]::Exists($ForeignDataRoot)) `
        -Message 'foreign active environment was accepted or wrote setup state'
    foreach ($Name in @(
        'SWAWKIT_DEV_PROJECT_ROOT',
        'SWAWKIT_DEV_ENV_ROOT'
    )) {
        [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
    }

    Set-ProjBunProcessEnvironment -Values @{
        SWAWKIT_PROJ_PROTOCOL = '1'
        SWAWKIT_PROJ_DIR = $ConsumerContext.ProjectRoot
        SWAWKIT_PROJ_ACTION_ROOT = $ActionRoot
        SWAWKIT_PROJ_DATA_ROOT = $ConsumerContext.DataRoot
        SWAWKIT_PROJ_ENTRY_COMMAND = $ConsumerContext.EntryCommand
        SWAWKIT_PROJ_ENTRY_FILE = $EntryFile
        SWAWKIT_INVOCATION_DIR = $ConsumerContext.InvocationDirectory
        SWAWKIT_PROJ_BUN_MODE = 'managed'
        SWAWKIT_PROJ_BUN_VERSION = '1.2.15'
    }
    $MissingResult = Invoke-ProjBunMainFixture `
        -PowerShell $SystemPowerShell `
        -KernelRoot $ProjRoot `
        -WorkingDirectory $InvocationRoot `
        -Arguments @('.bun', '--version')
    Assert-ProjBunTest `
        -Condition ($MissingResult.ExitCode -eq 1 -and
            -not [IO.Directory]::Exists(
                (Join-Path $ConsumerDataRoot 'dev_env')
            )) `
        -Message '.bun implicitly created development state before setup'

    $env:SWAWKIT_PROJ_BUN_MODE = 'disabled'
    $DisabledResult = Invoke-ProjBunMainFixture `
        -PowerShell $SystemPowerShell `
        -KernelRoot $ProjRoot `
        -WorkingDirectory $InvocationRoot `
        -Arguments @('.bun', '--version')
    Assert-ProjBunTest `
        -Condition ($DisabledResult.ExitCode -eq 1 -and
            -not [IO.Directory]::Exists(
                (Join-Path $ConsumerDataRoot 'dev_env')
            )) `
        -Message 'disabled .bun wrote development state'
    $env:SWAWKIT_PROJ_BUN_MODE = 'managed'

    $Definition = Get-ProjDevBunDefinition
    $Definition.Sha256 = 'f' * 64
    $Definition.Verification = 'unverified'
    $InstallRoot = Get-ProjDevInstallRoot `
        -Context $ConsumerContext `
        -Definition $Definition
    [void][IO.Directory]::CreateDirectory($InstallRoot)
    New-ProjBunFixtureExecutable `
        -Path (Join-Path $InstallRoot 'bun.exe') `
        -Version '1.2.15'
    $ExpectedBunx = "@echo off`r`n`"%~dp0bun.exe`" x %*`r`n"
    [IO.File]::WriteAllText(
        (Join-Path $InstallRoot 'bunx.cmd'),
        $ExpectedBunx,
        [Text.UTF8Encoding]::new($false)
    )
    Write-ProjDevInstallMetadata `
        -Definition $Definition `
        -InstallRoot $InstallRoot

    $MissingEnvironmentResult = Invoke-ProjBunMainFixture `
        -PowerShell $SystemPowerShell `
        -KernelRoot $ProjRoot `
        -WorkingDirectory $InvocationRoot `
        -Arguments @('.bun', '--version')
    Assert-ProjBunTest `
        -Condition ($MissingEnvironmentResult.ExitCode -eq 1 -and
            -not [IO.File]::Exists($ConsumerContext.EnvCmdPath) -and
            -not [IO.File]::Exists($ConsumerContext.EnvPs1Path)) `
        -Message '.bun did not require the generated project environment'

    $Plan = New-ProjDevEnvironmentPlan -Context $ConsumerContext
    Add-ProjDevBunEnvironment `
        -Context $ConsumerContext `
        -Definition $Definition `
        -Plan $Plan
    $Scripts = ConvertTo-ProjDevEnvironmentScripts -Plan $Plan
    [void](Publish-ProjDevEnvironmentScripts `
        -Context $ConsumerContext `
        -Scripts $Scripts)
    [void](Publish-ProjDevEnvironmentState `
        -Context $ConsumerContext `
        -GenerationId ([string]$Scripts.GenerationId))

    $env:SWAWKIT_PROJ_PWSH_MODE = 'managed'
    $env:SWAWKIT_PROJ_PWSH_VERSION = '7.6.4'
    $env:SWAWKIT_PROJ_PWSH_SHA256 = ''
    $UnrelatedDeclarationExitCode = Invoke-ProjMain `
        -KernelRoot $ProjRoot `
        -Arguments @('.bun', 'unrelated-declaration-probe')
    Assert-ProjBunTest `
        -Condition ($UnrelatedDeclarationExitCode -eq 0) `
        -Message 'an unrelated PowerShell declaration change blocked Bun'

    $CapturePath = Join-Path $TemporaryRoot 'bun-capture.txt'
    $env:SWAWKIT_TEST_BUN_CAPTURE = $CapturePath
    Push-Location $InvocationRoot
    try {
        $BunHelpExitCode = Invoke-ProjMain `
            -KernelRoot $ProjRoot `
            -Arguments @('.bun', '--help')
        $BunHelpCapture = [IO.File]::ReadAllLines($CapturePath)
        Assert-ProjBunTest `
            -Condition ($BunHelpExitCode -eq 0 -and
                $BunHelpCapture.Count -eq 5 -and
                $BunHelpCapture[4] -ceq '--help' -and
                $BunHelpCapture[2] -ceq '.bun' -and
                (Get-ProjDevCanonicalPath -Path $BunHelpCapture[3]) -ceq
                (Get-ProjDevCanonicalPath -Path (
                    Join-Path $ProjRoot '.bun'
                ))) `
            -Message '.bun --help was intercepted instead of reaching Bun'

        [string[]]$ExpectedArguments = @(
            'hello world',
            '',
            'quote"value',
            'a&b',
            'a|b',
            '%PATH%',
            'exit:23'
        )
        $InvokeExitCode = Invoke-ProjMain `
            -KernelRoot $ProjRoot `
            -Arguments ([string[]]@('.bun') + $ExpectedArguments)
        $Captured = [IO.File]::ReadAllLines($CapturePath)
        Assert-ProjBunTest `
            -Condition ($InvokeExitCode -eq 23 -and
                [string]::Join(
                    "`n",
                    $Captured[4..($Captured.Count - 1)]
                ) -ceq [string]::Join("`n", $ExpectedArguments)) `
            -Message '.bun did not preserve public dynamic argv and exit code'
        Assert-ProjBunTest `
            -Condition (
                (Get-ProjDevCanonicalPath -Path $Captured[1]) -ceq
                (Get-ProjDevCanonicalPath -Path $InvocationRoot)
            ) `
            -Message '.bun lost the public invocation directory'

        $SeparatorExitCode = Invoke-ProjMain `
            -KernelRoot $ProjRoot `
            -Arguments @('.bun', '--', '--help')
        $SeparatorCapture = [IO.File]::ReadAllLines($CapturePath)
        Assert-ProjBunTest `
            -Condition ($SeparatorExitCode -eq 0 -and
                $SeparatorCapture[4] -ceq '--' -and
                $SeparatorCapture[5] -ceq '--help') `
            -Message '.bun changed the explicit option separator'

        $DemoDirectory = Join-Path $ActionRoot 'demo'
        [void][IO.Directory]::CreateDirectory($DemoDirectory)
        $DemoEntry = Join-Path $DemoDirectory 'run.ts'
        [IO.File]::WriteAllText($DemoEntry, '')
        $RunTsExitCode = Invoke-ProjMain `
            -KernelRoot $ProjRoot `
            -Arguments @('demo', 'alpha')
        $RunTsCapture = [IO.File]::ReadAllLines($CapturePath)
        Assert-ProjBunTest `
            -Condition ($RunTsExitCode -eq 0 -and
                (Get-ProjDevCanonicalPath -Path $RunTsCapture[0]) -ceq
                (Get-ProjDevCanonicalPath -Path $ProjectRoot) -and
                (Get-ProjDevCanonicalPath -Path $RunTsCapture[1]) -ceq
                (Get-ProjDevCanonicalPath -Path $InvocationRoot) -and
                (Get-ProjDevCanonicalPath -Path $RunTsCapture[4]) -ceq
                (Get-ProjDevCanonicalPath -Path $DemoEntry) -and
                $RunTsCapture[5] -ceq 'alpha' -and
                $RunTsCapture[2] -ceq 'demo' -and
                (Get-ProjDevCanonicalPath -Path $RunTsCapture[3]) -ceq
                (Get-ProjDevCanonicalPath -Path $DemoDirectory)) `
            -Message 'run.ts did not use the managed .bun runtime bridge'
    } finally {
        Pop-Location
    }

    [IO.File]::Copy(
        $env:ComSpec,
        (Join-Path $InstallRoot 'bun.exe'),
        $true
    )
    Write-ProjDevInstallMetadata `
        -Definition $Definition `
        -InstallRoot $InstallRoot
    $WorkingDirectoryResult = Invoke-ProjBunEntryFixture `
        -PowerShell $SystemPowerShell `
        -EntryPath (Join-Path $ProjRoot '.bun\run.ps1') `
        -Arguments @('/d', '/c', 'cd')
    Assert-ProjBunTest `
        -Condition ($WorkingDirectoryResult.ExitCode -eq 0 -and
            (Get-ProjDevCanonicalPath -Path (
                $WorkingDirectoryResult.Output.Trim()
            )) -ceq
            (Get-ProjDevCanonicalPath -Path $InvocationRoot)) `
        -Message '.bun native process did not use the caller directory'

    Assert-ProjBunTest `
        -Condition (
            [Environment]::GetEnvironmentVariable('PATH', 'User') -ceq
                $UserPathBefore -and
            [Environment]::GetEnvironmentVariable('PATH', 'Machine') -ceq
                $MachinePathBefore
        ) `
        -Message 'Bun commands changed persistent User or Machine PATH'

    Write-Host '[PASS] Proj Bun command protocol test' -ForegroundColor Green
} finally {
    Exit-ProjBunIsolatedEnvironment -Snapshot $EnvironmentSnapshot
    if ([IO.Directory]::Exists($ConsumerDataRoot) -and
        [IO.Path]::GetFileName($ConsumerDataRoot) -ceq "proj.$EntryName") {
        Remove-Item -LiteralPath $ConsumerDataRoot -Recurse -Force
    }
    $ResolvedTemporaryRoot = [IO.Path]::GetFullPath($TemporaryRoot)
    $SystemTemporaryRoot = [IO.Path]::GetFullPath(
        $TestTemporaryBase
    ).TrimEnd('\') + '\'
    if ($ResolvedTemporaryRoot.StartsWith(
        $SystemTemporaryRoot,
        [StringComparison]::OrdinalIgnoreCase
    ) -and
        [IO.Path]::GetFileName($ResolvedTemporaryRoot).StartsWith(
            'swawkit-proj-bun-command-',
            [StringComparison]::Ordinal
        ) -and
        [IO.Directory]::Exists($ResolvedTemporaryRoot)) {
        Remove-Item -LiteralPath $ResolvedTemporaryRoot -Recurse -Force
    }
}
