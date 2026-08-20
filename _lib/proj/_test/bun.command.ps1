[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DevPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot '_lib\bun-fixture.ps1')

if (-not [IO.File]::Exists([IO.Path]::GetFullPath($DevPath))) {
    throw "Proj Dev test candidate is missing: $DevPath"
}

$TestBase = [IO.Path]::GetFullPath((Join-Path $ProjRoot '..\..\data\_test'))
[void][IO.Directory]::CreateDirectory($TestBase)
$TemporaryRoot = Join-Path $TestBase (
    "swawkit-proj-bun-command-$([Guid]::NewGuid().ToString('N'))"
)
$BinRoot = Join-Path $TemporaryRoot 'bin'
$InvocationRoot = Join-Path $TemporaryRoot 'invocation'
$DataRoot = Join-Path $TemporaryRoot 'data-root'
$BunExecutable = Join-Path $BinRoot 'bun.exe'
$CapturePath = Join-Path $TemporaryRoot 'capture.txt'
$EntryPath = Join-Path $ProjRoot 'system\dev\bun\run.ps1'
$EnvironmentExportPath = Join-Path $ProjRoot (
    '..\..\data\proj.swawkit\modules\system\dev\setup\export\environment.json'
)
$EnvironmentExport = Get-Content `
    -LiteralPath $EnvironmentExportPath `
    -Raw `
    -Encoding utf8 |
    ConvertFrom-Json
$PowerShell = [IO.Path]::GetFullPath(
    [string]$EnvironmentExport.pwshExecutable
)
if (-not [IO.File]::Exists($PowerShell)) {
    throw "Managed PowerShell test executable is missing: $PowerShell"
}
$PreviousPath = [string]$env:PATH
$PreviousEntryCommand = [string]$env:SWAWKIT_PROJ_ENTRY_COMMAND
$PreviousAddress = [string]$env:SWAWKIT_PROJ_CORE_COMMAND_ADDRESS
$PreviousDirectory = [string]$env:SWAWKIT_PROJ_CORE_COMMAND_DIR
$PreviousCapture = [string]$env:SWAWKIT_PROJ_TEST_BUN_CAPTURE
$PreviousDataRoot = [string]$env:SWAWKIT_PROJ_DATA_ROOT

try {
    [void][IO.Directory]::CreateDirectory($BinRoot)
    [void][IO.Directory]::CreateDirectory($InvocationRoot)
    New-ProjBunFixtureExecutable -Path $BunExecutable -Version '1.2.15'

    $InputRevision = 'sha256-' + ('1' * 64)
    $PublicationToken = '2' * 32
    $SetupRoot = Join-Path $DataRoot 'modules\system\dev\setup'
    $ExportRoot = Join-Path $SetupRoot 'export'
    [void][IO.Directory]::CreateDirectory($ExportRoot)
    [IO.File]::WriteAllText(
        (Join-Path $SetupRoot '_state.json'),
        ([ordered]@{
            schema = 'swawkit.command-provider-state/v2'
            status = 'ready'
            inputRevision = $InputRevision
            token = $PublicationToken
            exports = @(
                [ordered]@{
                    id = 'environment'
                    contract = 'swawkit.proj.dev-setup/v4'
                }
            )
        } | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $ExportRoot 'environment.json'),
        ([ordered]@{
            schema = 'swawkit.proj-dev-environment/v1'
            inputRevision = $InputRevision
            publicationToken = $PublicationToken
            variables = @()
            paths = @($BinRoot)
            bunExecutable = $BunExecutable
            pwshExecutable = $PowerShell
        } | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $ExportRoot 'env.ps1'),
        (
            "`$env:SWAWKIT_PROJ_MODULE_SYSTEM_DEV_SETUP_PUBLICATION_TOKEN = " +
            "'$PublicationToken'`r`n" +
            "`$env:PATH = '$($BinRoot.Replace("'", "''"))' + " +
            "[IO.Path]::PathSeparator + `$env:PATH`r`n"
        ),
        [Text.UTF8Encoding]::new($false)
    )

    $env:PATH = $PreviousPath
    $env:SWAWKIT_PROJ_ENTRY_COMMAND = 'swawkit'
    $env:SWAWKIT_PROJ_CORE_COMMAND_ADDRESS = '.dev/bun'
    $env:SWAWKIT_PROJ_CORE_COMMAND_DIR = Split-Path $EntryPath -Parent
    $env:SWAWKIT_PROJ_TEST_BUN_CAPTURE = $CapturePath
    $env:SWAWKIT_PROJ_DATA_ROOT = $DataRoot

    [string[]]$Arguments = @(
        'hello world',
        'quote"value',
        'a&b',
        'a|b',
        '%PATH%'
    )
    Push-Location $InvocationRoot
    try {
        $Result = Invoke-ProjBunEntryFixture `
            -PowerShell $PowerShell `
            -EntryPath $EntryPath `
            -Arguments $Arguments
    } finally {
        Pop-Location
    }
    $Capture = [IO.File]::ReadAllLines($CapturePath)
    Assert-ProjBunTest `
        -Condition (
            $Result.ExitCode -eq 0 -and
            $Capture.Count -eq ($Arguments.Count + 4) -and
            [string]::Join("`n", $Capture[4..($Capture.Count - 1)]) -ceq
                [string]::Join("`n", $Arguments)
        ) `
        -Message (
            'the thin Bun wrapper changed argv: expected=' +
            [string]::Join('|', $Arguments) + '; actual=' +
            [string]::Join('|', $Capture) + '; output=' +
            $Result.Output
        )

    $ExitResult = Invoke-ProjBunEntryFixture `
        -PowerShell $PowerShell `
        -EntryPath $EntryPath `
        -Arguments @('exit:37')
    Assert-ProjBunTest `
        -Condition ($ExitResult.ExitCode -eq 37) `
        -Message 'the thin Bun wrapper changed the executable exit code'

    [IO.File]::Delete($BunExecutable)
    $Missing = Invoke-ProjBunEntryFixture `
        -PowerShell $PowerShell `
        -EntryPath $EntryPath `
        -Arguments @('--version')
    Assert-ProjBunTest `
        -Condition (
            $Missing.ExitCode -ne 0 -and
            $Missing.Output.Contains("Run 'swawkit .dev/setup'")
        ) `
        -Message 'the thin Bun wrapper accepted a missing published executable'

    New-ProjBunFixtureExecutable -Path $BunExecutable -Version '1.2.15'
    $ReplacementStatePath = Join-Path $SetupRoot '.race-state.json'
    [IO.File]::WriteAllText(
        $ReplacementStatePath,
        ([ordered]@{
            schema = 'swawkit.command-provider-state/v2'
            status = 'unavailable'
            inputRevision = ('sha256-' + ('4' * 64))
            token = ('5' * 32)
        } | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $ExportRoot 'env.ps1'),
        (
            "`$env:SWAWKIT_PROJ_MODULE_SYSTEM_DEV_SETUP_PUBLICATION_TOKEN = " +
            "'$PublicationToken'`r`n" +
            "[IO.File]::Move(" +
            "'$($ReplacementStatePath.Replace("'", "''"))', " +
            "'$((Join-Path $SetupRoot '_state.json').Replace("'", "''"))', " +
            "`$true)`r`n"
        ),
        [Text.UTF8Encoding]::new($false)
    )
    $ChangedWhileLoading = Invoke-ProjBunEntryFixture `
        -PowerShell $PowerShell `
        -EntryPath $EntryPath `
        -Arguments @('--version')
    Assert-ProjBunTest `
        -Condition (
            $ChangedWhileLoading.ExitCode -ne 0 -and
            $ChangedWhileLoading.Output.Contains(
                'development environment changed while it was loading'
            )
        ) `
        -Message (
            'the thin Bun wrapper accepted a provider invalidation while ' +
            "loading its Export: $($ChangedWhileLoading.Output)"
        )

    Write-Host '[PASS] Proj thin Bun command wrapper' -ForegroundColor Green
} finally {
    $env:PATH = $PreviousPath
    $env:SWAWKIT_PROJ_ENTRY_COMMAND = $PreviousEntryCommand
    $env:SWAWKIT_PROJ_CORE_COMMAND_ADDRESS = $PreviousAddress
    $env:SWAWKIT_PROJ_CORE_COMMAND_DIR = $PreviousDirectory
    $env:SWAWKIT_PROJ_TEST_BUN_CAPTURE = $PreviousCapture
    $env:SWAWKIT_PROJ_DATA_ROOT = $PreviousDataRoot
    if ([IO.Directory]::Exists($TemporaryRoot)) {
        Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force
    }
}

$global:LASTEXITCODE = 0
