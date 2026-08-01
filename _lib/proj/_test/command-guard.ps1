[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '_core\engine.ps1')

function Assert-ProjCommandGuardTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Write-ProjCommandGuardFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Body
    )
    [void][IO.Directory]::CreateDirectory((Split-Path -Path $Path -Parent))
    [IO.File]::WriteAllText(
        $Path,
        $Body,
        [Text.UTF8Encoding]::new($false)
    )
}

$TestBase = [IO.Path]::GetFullPath(
    (Join-Path $ProjRoot '..\..\data\_test')
)
[void][IO.Directory]::CreateDirectory($TestBase)
$TemporaryRoot = Join-Path $TestBase (
    "swawkit-proj-command-guard-$([Guid]::NewGuid().ToString('N'))"
)
$KernelRoot = Join-Path $TemporaryRoot 'kernel'
$ProjectRoot = Join-Path $TemporaryRoot 'project'
$ActionRoot = Join-Path $ProjectRoot '.swaw'
$CommandRoot = Join-Path $ActionRoot 'probe'
$GlobalRoot = Join-Path $KernelRoot '_global'
$LocalGuardRoot = Join-Path $CommandRoot '_guard'
$EntryFile = Join-Path $TemporaryRoot 'guard-entry.cmd'
$CapturePath = Join-Path $TemporaryRoot 'capture.txt'
$SavedCapture = [Environment]::GetEnvironmentVariable(
    'SWAWKIT_TEST_GUARD_CAPTURE',
    'Process'
)

$GlobalBody = @'
[IO.File]::AppendAllText(
    $env:SWAWKIT_TEST_GUARD_CAPTURE,
    "global|$($args.Count)|$env:SWAWKIT_COMMAND_PHASE|" +
    "$env:SWAWKIT_GUARD_SCOPE|$env:SWAWKIT_COMMAND_ADDRESS|" +
    "$env:SWAWKIT_COMMAND_DIR`n"
)
exit 0
'@
$LocalBody = @'
[IO.File]::AppendAllText(
    $env:SWAWKIT_TEST_GUARD_CAPTURE,
    "command|$($args.Count)|$env:SWAWKIT_COMMAND_PHASE|" +
    "$env:SWAWKIT_GUARD_SCOPE|$env:SWAWKIT_COMMAND_ADDRESS|" +
    "$env:SWAWKIT_COMMAND_DIR`n"
)
exit 0
'@
$TargetBody = @'
[IO.File]::AppendAllText(
    $env:SWAWKIT_TEST_GUARD_CAPTURE,
    "target|$($args.Count)|$env:SWAWKIT_COMMAND_PHASE|" +
    "$env:SWAWKIT_GUARD_SCOPE|$env:SWAWKIT_COMMAND_ADDRESS|" +
    "$env:SWAWKIT_COMMAND_DIR|$($args -join ',')`n"
)
exit 23
'@

try {
    foreach ($Directory in @(
        $KernelRoot,
        $ProjectRoot,
        $ActionRoot,
        $CommandRoot,
        $GlobalRoot,
        $LocalGuardRoot
    )) {
        [void][IO.Directory]::CreateDirectory($Directory)
    }
    [IO.File]::WriteAllText($EntryFile, '@exit /b 0')
    Write-ProjCommandGuardFixture `
        -Path (Join-Path $GlobalRoot 'run.ps1') `
        -Body $GlobalBody
    Write-ProjCommandGuardFixture `
        -Path (Join-Path $LocalGuardRoot 'run.ps1') `
        -Body $LocalBody
    Write-ProjCommandGuardFixture `
        -Path (Join-Path $CommandRoot 'run.ps1') `
        -Body $TargetBody
    $env:SWAWKIT_TEST_GUARD_CAPTURE = $CapturePath

    $Command = Resolve-ProjCommand `
        -KernelRoot $KernelRoot `
        -ActionRoot $ActionRoot `
        -Address 'probe'
    $ProjectContext = [pscustomobject][ordered]@{
        Protocol = '1'
        ProjHome = $TemporaryRoot
        ProjectRoot = $ProjectRoot
        ActionRoot = $ActionRoot
        DataRoot = Join-Path $TemporaryRoot 'data'
        EntryName = 'guard-entry'
        EntryFile = $EntryFile
    }

    $TargetExitCode = Invoke-ProjCommandPipeline `
        -Command $Command `
        -ProjectContext $ProjectContext `
        -KernelRoot $KernelRoot `
        -InvocationDirectory $TemporaryRoot `
        -Arguments @('alpha', '--help', 'value')
    $Lines = [IO.File]::ReadAllLines($CapturePath)
    Assert-ProjCommandGuardTest `
        -Condition ($TargetExitCode -eq 23 -and $Lines.Count -eq 3) `
        -Message 'the guard pipeline lost order or the target exit code'
    Assert-ProjCommandGuardTest `
        -Condition (
            $Lines[0] -ceq "global|0|guard|global|probe|$CommandRoot" -and
            $Lines[1] -ceq "command|0|guard|command|probe|$CommandRoot" -and
            $Lines[2] -ceq (
                "target|3|run||probe|$CommandRoot|alpha,--help,value"
            )
        ) `
        -Message "guard protocol context is incorrect: $($Lines -join '; ')"

    [IO.File]::Delete($CapturePath)
    Write-ProjCommandGuardFixture `
        -Path (Join-Path $GlobalRoot 'run.ps1') `
        -Body ($GlobalBody.Replace('exit 0', 'exit 31'))
    $GlobalFailure = Invoke-ProjCommandPipeline `
        -Command $Command `
        -ProjectContext $ProjectContext `
        -KernelRoot $KernelRoot `
        -InvocationDirectory $TemporaryRoot `
        -Arguments @('must', 'not', 'run')
    $Lines = [IO.File]::ReadAllLines($CapturePath)
    Assert-ProjCommandGuardTest `
        -Condition ($GlobalFailure -eq 31 -and $Lines.Count -eq 1 -and
            $Lines[0].StartsWith('global|')) `
        -Message 'a failing global guard did not short-circuit the pipeline'

    [IO.File]::Delete($CapturePath)
    Write-ProjCommandGuardFixture `
        -Path (Join-Path $GlobalRoot 'run.ps1') `
        -Body $GlobalBody
    Write-ProjCommandGuardFixture `
        -Path (Join-Path $LocalGuardRoot 'run.ps1') `
        -Body ($LocalBody.Replace('exit 0', 'exit 32'))
    $LocalFailure = Invoke-ProjCommandPipeline `
        -Command $Command `
        -ProjectContext $ProjectContext `
        -KernelRoot $KernelRoot `
        -InvocationDirectory $TemporaryRoot `
        -Arguments @('must', 'not', 'run')
    $Lines = [IO.File]::ReadAllLines($CapturePath)
    Assert-ProjCommandGuardTest `
        -Condition ($LocalFailure -eq 32 -and $Lines.Count -eq 2 -and
            $Lines[0].StartsWith('global|') -and
            $Lines[1].StartsWith('command|')) `
        -Message 'a failing command guard did not short-circuit the target'

    [IO.File]::Delete((Join-Path $LocalGuardRoot 'run.ps1'))
    [IO.File]::WriteAllText(
        (Join-Path $LocalGuardRoot 'run.ts'),
        'throw new Error("must not run");'
    )
    $RejectedRuntimeGuard = $false
    try {
        [void](Get-ProjCommandGuards `
            -KernelRoot $KernelRoot `
            -Command $Command)
    } catch {
        $RejectedRuntimeGuard =
            $_.Exception.Message -like '*not bootstrap-safe*'
    }
    Assert-ProjCommandGuardTest `
        -Condition $RejectedRuntimeGuard `
        -Message 'a run.ts guard was accepted into the bootstrap phase'

    $Discoveries = @(Get-ProjCommandDiscoveries `
        -KernelRoot $KernelRoot `
        -ActionRoot $ActionRoot)
    Assert-ProjCommandGuardTest `
        -Condition (@($Discoveries | Where-Object {
            [string]$_.Directory -in @($GlobalRoot, $LocalGuardRoot)
        }).Count -eq 0) `
        -Message 'a hidden execution guard leaked into command discovery'
} finally {
    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_TEST_GUARD_CAPTURE',
        $SavedCapture,
        'Process'
    )
    if ([IO.Directory]::Exists($TemporaryRoot)) {
        [IO.Directory]::Delete($TemporaryRoot, $true)
    }
}

Write-Host '[PASS] Proj command execution guard protocol' `
    -ForegroundColor Green
$global:LASTEXITCODE = 0
