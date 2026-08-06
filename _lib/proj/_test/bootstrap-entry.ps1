[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-ProjBootstrapEntryTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Get-ProjBootstrapEntryTestEnvironment {
    $Result = [Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::Ordinal
    )
    $Environment = [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process
    )
    foreach ($Name in [string[]]@($Environment.Keys)) {
        $Result[$Name] = [string]$Environment[$Name]
    }
    return $Result
}

function Test-ProjBootstrapEntryEnvironmentEqual {
    param(
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Actual
    )

    if ($Expected.Count -ne $Actual.Count) {
        return $false
    }
    foreach ($Pair in $Expected.GetEnumerator()) {
        if (-not $Actual.ContainsKey([string]$Pair.Key) -or
            [string]$Actual[[string]$Pair.Key] -cne [string]$Pair.Value) {
            return $false
        }
    }
    return $true
}

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$BootstrapRoot = Join-Path $RepoRoot '_lib\proj\_bootstrap'
. (Join-Path $BootstrapRoot '_lib\entry.ps1')
. (Join-Path $RepoRoot '_lib\proj\_core\entry-identity.ps1')

$CmdPath = Join-Path $RepoRoot 'swawkit.cmd'
$CmdText = [IO.File]::ReadAllText($CmdPath, [Text.Encoding]::UTF8)
$LauncherBootstrapPath = Join-Path $BootstrapRoot 'launcher.ps1'
$LauncherBootstrapText = [IO.File]::ReadAllText(
    $LauncherBootstrapPath,
    [Text.Encoding]::UTF8
)
$CoreBootstrapText = [IO.File]::ReadAllText(
    (Join-Path $BootstrapRoot 'run.ps1'),
    [Text.Encoding]::UTF8
)
Assert-ProjBootstrapEntryTest `
    -Condition (
        $CmdText.Contains('swawkit.exe') -and
        $CmdText.Contains(' %*') -and
        -not $CmdText.Contains('_bin\swawkit-proj.exe') -and
        -not $CmdText.Contains(':CaptureArguments') -and
        $CmdText -cnotmatch 'set\s+"SWAWKIT_PROJ_ENTRY_FILE='
    ) `
    -Message 'swawkit.cmd still behaves as a project Entry or argument relay'
Assert-ProjBootstrapEntryTest `
    -Condition (
        $LauncherBootstrapText.Contains(
            'Invoke-ProjBootstrapEnvironmentIsolated -Action'
        ) -and
        $LauncherBootstrapText.Contains('Initialize-ProjBootstrapCore') -and
        $CoreBootstrapText -cnotmatch '(?m)^\s*exit\s+0\s*$'
    ) `
    -Message 'the Launcher build path can pollute or exit its caller'

$EnvironmentBefore = Get-ProjBootstrapEntryTestEnvironment
Invoke-ProjBootstrapEnvironmentIsolated -Action {
    . (Join-Path $BootstrapRoot 'toolchains\runtime.ps1')
    [void](Initialize-ProjBootstrapToolchain)
    $env:PATH = 'C:\bootstrap-build-path-poison'
    $env:SWAWKIT_HOME = 'C:\bootstrap-build-path-poison'
    $env:SWAWKIT_PROJ_DEV_ISOLATION_PROBE = 'created'
}
$EnvironmentAfter = Get-ProjBootstrapEntryTestEnvironment
Assert-ProjBootstrapEntryTest `
    -Condition (Test-ProjBootstrapEntryEnvironmentEqual `
        -Expected $EnvironmentBefore `
        -Actual $EnvironmentAfter) `
    -Message 'Bootstrap toolchain initialization polluted its caller environment'

$ExpectedIsolationFailure = $false
try {
    Invoke-ProjBootstrapEnvironmentIsolated -Action {
        $env:SWAWKIT_PROJ_DEV_ISOLATION_PROBE = 'created-before-failure'
        throw 'expected Bootstrap isolation failure'
    }
} catch {
    $ExpectedIsolationFailure =
        $_.Exception.Message -ceq 'expected Bootstrap isolation failure'
}
Assert-ProjBootstrapEntryTest `
    -Condition ($ExpectedIsolationFailure -and
        (Test-ProjBootstrapEntryEnvironmentEqual `
            -Expected $EnvironmentBefore `
            -Actual (Get-ProjBootstrapEntryTestEnvironment))) `
    -Message 'Bootstrap failure leaked environment changes or was swallowed'

$TestBase = Join-Path $RepoRoot 'data\_test'
[void][IO.Directory]::CreateDirectory($TestBase)
$TemporaryRoot = Join-Path $TestBase (
    "swawkit-proj-bootstrap-entry-$([Guid]::NewGuid().ToString('N'))"
)
$TemplatePath = Join-Path $TemporaryRoot 'template.proj1.exe'
$EntryPath = Join-Path $TemporaryRoot 'published\swawkit.exe'
$WrapperPath = Join-Path $TemporaryRoot 'handoff\swawkit.cmd'
$HandoffExe = Join-Path $TemporaryRoot 'handoff\swawkit.exe'
$ProbePath = Join-Path $TemporaryRoot 'handoff\probe.cmd'
$RunnerPath = Join-Path $TemporaryRoot 'handoff\run-test.cmd'
$MatrixRoot = Join-Path $TemporaryRoot 'core-matrix'

try {
    foreach ($Directory in @(
        (Split-Path -Path $EntryPath -Parent),
        (Split-Path -Path $WrapperPath -Parent),
        $MatrixRoot
    )) {
        [void][IO.Directory]::CreateDirectory($Directory)
    }

    $ExistingRuntime = Join-Path $MatrixRoot 'existing-core.exe'
    $ExistingBootstrap = Join-Path $MatrixRoot 'existing-bootstrap.ps1'
    $UnexpectedMarker = Join-Path $MatrixRoot 'unexpected-bootstrap.txt'
    [IO.File]::WriteAllBytes($ExistingRuntime, [byte[]]@(1))
    [IO.File]::WriteAllText(
        $ExistingBootstrap,
        "[IO.File]::WriteAllText('$($UnexpectedMarker.Replace("'", "''"))', 'called')",
        [Text.UTF8Encoding]::new($false)
    )
    Initialize-ProjBootstrapCore `
        -RuntimePath $ExistingRuntime `
        -BootstrapPath $ExistingBootstrap
    Assert-ProjBootstrapEntryTest `
        -Condition (-not [IO.File]::Exists($UnexpectedMarker)) `
        -Message 'an existing Core aborted or reran Launcher recovery'

    $MissingRuntime = Join-Path $MatrixRoot 'built-core.exe'
    $MissingBootstrap = Join-Path $MatrixRoot 'missing-bootstrap.ps1'
    $MissingRuntimeLiteral = $MissingRuntime.Replace("'", "''")
    [IO.File]::WriteAllText(
        $MissingBootstrap,
        "[IO.File]::WriteAllBytes('$MissingRuntimeLiteral', [byte[]]@(1))",
        [Text.UTF8Encoding]::new($false)
    )
    Initialize-ProjBootstrapCore `
        -RuntimePath $MissingRuntime `
        -BootstrapPath $MissingBootstrap
    Assert-ProjBootstrapEntryTest `
        -Condition ([IO.File]::Exists($MissingRuntime)) `
        -Message 'a missing Core did not run its Bootstrap before Launcher build'

    $SystemPowerShell = Join-Path $env:SystemRoot (
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    )
    $EntryBootstrapPath = Join-Path $BootstrapRoot 'entry.ps1'
    & $SystemPowerShell `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File $EntryBootstrapPath
    Assert-ProjBootstrapEntryTest `
        -Condition ($LASTEXITCODE -eq 0) `
        -Message "root Entry preparation failed with exit code $LASTEXITCODE"

    $ContinuationMarker = Join-Path $MatrixRoot 'continued.txt'
    $ContinuationScript = Join-Path $MatrixRoot 'continuation.ps1'
    $LauncherLiteral = $LauncherBootstrapPath.Replace("'", "''")
    $EntryLiteral = $EntryBootstrapPath.Replace("'", "''")
    $MarkerLiteral = $ContinuationMarker.Replace("'", "''")
    [IO.File]::WriteAllText(
        $ContinuationScript,
        (@"
`$ErrorActionPreference = 'Stop'
& '$LauncherLiteral'
& '$EntryLiteral'
[IO.File]::WriteAllText('$MarkerLiteral', 'continued')
"@).TrimStart(),
        [Text.UTF8Encoding]::new($false)
    )
    & $SystemPowerShell `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File $ContinuationScript
    Assert-ProjBootstrapEntryTest `
        -Condition ($LASTEXITCODE -eq 0 -and
            [IO.File]::Exists($ContinuationMarker)) `
        -Message 'an existing Launcher template or root Entry exited its caller'

    [IO.File]::WriteAllBytes(
        $TemplatePath,
        [byte[]]@(0x4d, 0x5a, 0x01, 0x02, 0x03, 0x04)
    )
    [void](Publish-ProjBootstrapRootEntry `
        -TemplatePath $TemplatePath `
        -EntryPath $EntryPath)
    $FirstIdentity = Get-ProjEntryFileIdentity -EntryFile $EntryPath
    $FirstContent = [IO.File]::ReadAllBytes($EntryPath)

    [IO.File]::WriteAllBytes(
        $TemplatePath,
        [byte[]]@(0x4d, 0x5a, 0x09, 0x08, 0x07, 0x06)
    )
    [void](Publish-ProjBootstrapRootEntry `
        -TemplatePath $TemplatePath `
        -EntryPath $EntryPath)
    $SecondIdentity = Get-ProjEntryFileIdentity -EntryFile $EntryPath
    Assert-ProjBootstrapEntryTest `
        -Condition (
            $FirstIdentity.Key -ceq $SecondIdentity.Key -and
            [Linq.Enumerable]::SequenceEqual(
                [byte[]]$FirstContent,
                [byte[]][IO.File]::ReadAllBytes($EntryPath)
            ) -and
            @(Get-ChildItem `
                -LiteralPath (Split-Path -Path $EntryPath -Parent) `
                -Filter '.swawkit.exe.*.tmp').Count -eq 0
        ) `
        -Message 'idempotent Entry publication replaced the File ID or left residue'

    [IO.File]::Copy($CmdPath, $WrapperPath, $false)
    [IO.File]::Copy($env:ComSpec, $HandoffExe, $false)
    [IO.File]::WriteAllText(
        $ProbePath,
        (@'
@echo off
if defined SWAWKIT_PROJ_ENTRY_FILE exit /b 91
if not "%~1"=="alpha beta" exit /b 92
if not "%~2"=="" exit /b 93
exit /b 37
'@).TrimStart(),
        [Text.Encoding]::ASCII
    )
    [IO.File]::WriteAllText(
        $RunnerPath,
        (@'
@echo off
set "SWAWKIT_PROJ_ENTRY_FILE=C:\poison.cmd"
call "%~dp0swawkit.cmd" /d /c call "%~dp0probe.cmd" "alpha beta" ""
exit /b %ERRORLEVEL%
'@).TrimStart(),
        [Text.Encoding]::ASCII
    )
    & $RunnerPath
    Assert-ProjBootstrapEntryTest `
        -Condition ($LASTEXITCODE -eq 37) `
        -Message (
            'swawkit.cmd did not clear Entry identity, preserve arguments, ' +
            "or return the native child exit code: $LASTEXITCODE"
        )

    Write-Host '[PASS] Proj Bootstrap root Entry handoff' `
        -ForegroundColor Green
} finally {
    $ResolvedTemporaryRoot = [IO.Path]::GetFullPath($TemporaryRoot)
    if ($ResolvedTemporaryRoot.StartsWith(
        ([IO.Path]::GetFullPath($TestBase).TrimEnd('\') + '\'),
        [StringComparison]::OrdinalIgnoreCase
    ) -and
        [IO.Path]::GetFileName($ResolvedTemporaryRoot).StartsWith(
            'swawkit-proj-bootstrap-entry-',
            [StringComparison]::Ordinal
        ) -and
        [IO.Directory]::Exists($ResolvedTemporaryRoot)) {
        [IO.Directory]::Delete($ResolvedTemporaryRoot, $true)
    }
}

$global:LASTEXITCODE = 0
