[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '_core\engine.ps1')

function Assert-ProjCommandRoutingTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Write-ProjCommandRoutingFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [int]$ExitCode = 0
    )

    $Body = @'
[IO.File]::AppendAllText(
    $env:SWAWKIT_PROJ_TEST_ROUTING_CAPTURE,
    "__LABEL__|$($args.Count)|$env:SWAWKIT_PROJ_COMMAND_PHASE|" +
    "$env:SWAWKIT_PROJ_GUARD_SCOPE|$env:SWAWKIT_PROJ_COMMAND_ADDRESS|" +
    "$env:SWAWKIT_PROJ_COMMAND_DIR|$env:SWAWKIT_PROJ_HELP_TARGET_ADDRESS|" +
    "$($args -join ',')`n"
)
exit __EXIT_CODE__
'@.Replace('__LABEL__', $Label).Replace(
        '__EXIT_CODE__',
        $ExitCode.ToString([Globalization.CultureInfo]::InvariantCulture)
    )
    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    [IO.File]::WriteAllText(
        $Path,
        $Body,
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-ProjCommandRoutingFixture {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][object]$ProjectContext,
        [Parameter(Mandatory = $true)][string]$KernelRoot,
        [Parameter(Mandatory = $true)][string]$CapturePath
    )

    if ([IO.File]::Exists($CapturePath)) {
        [IO.File]::Delete($CapturePath)
    }
    $Invocation = Resolve-ProjInvocation `
        -KernelRoot $KernelRoot `
        -ActionRoot ([string]$ProjectContext.ActionRoot) `
        -Arguments $Arguments
    $ExitCode = Invoke-ProjCommandPipeline `
        -Command $Invocation.Command `
        -ProjectContext $ProjectContext `
        -KernelRoot $KernelRoot `
        -InvocationDirectory ([string]$ProjectContext.ProjectRoot) `
        -Arguments $Invocation.Arguments `
        -UseProjHelp ([bool]$Invocation.UseProjHelp) `
        -HelpTargetAddress ([string]$Invocation.HelpTargetAddress)
    return [pscustomobject][ordered]@{
        ExitCode = $ExitCode
        Lines = [IO.File]::ReadAllLines($CapturePath)
    }
}

$TestBase = [IO.Path]::GetFullPath(
    (Join-Path $ProjRoot '..\..\data\_test')
)
[void][IO.Directory]::CreateDirectory($TestBase)
$TemporaryRoot = Join-Path $TestBase (
    "swawkit-proj-routing-$([Guid]::NewGuid().ToString('N'))"
)
$KernelRoot = Join-Path $TemporaryRoot 'kernel'
$ProjectRoot = Join-Path $TemporaryRoot 'project'
$ActionRoot = Join-Path $ProjectRoot '.swaw'
$GlobalRoot = Join-Path $KernelRoot '_global'
$HelpRoot = Join-Path $KernelRoot '.help'
$ProbeRoot = Join-Path $ActionRoot 'probe'
$SelfHelpRoot = Join-Path $ActionRoot 'self-help'
$KernelProbeRoot = Join-Path $KernelRoot '.probe'
$BunRoot = Join-Path $KernelRoot '.bun'
$TypeScriptRoot = Join-Path $ActionRoot 'typescript'
$CapturePath = Join-Path $TemporaryRoot 'capture.txt'
$EntryFile = Join-Path $TemporaryRoot 'routing-entry.cmd'
$SavedCapture = [Environment]::GetEnvironmentVariable(
    'SWAWKIT_PROJ_TEST_ROUTING_CAPTURE',
    'Process'
)

try {
    foreach ($Directory in @($KernelRoot, $ProjectRoot, $ActionRoot)) {
        [void][IO.Directory]::CreateDirectory($Directory)
    }
    [IO.File]::WriteAllText($EntryFile, '@exit /b 0')
    $env:SWAWKIT_PROJ_TEST_ROUTING_CAPTURE = $CapturePath
    $ProjectContext = [pscustomobject][ordered]@{
        Protocol = '1'
        ProjHome = $TemporaryRoot
        ProjectRoot = $ProjectRoot
        ActionRoot = $ActionRoot
        DataRoot = Join-Path $TemporaryRoot 'data'
        EntryName = 'routing-entry'
        EntryFile = $EntryFile
    }

    Write-ProjCommandRoutingFixture `
        -Path (Join-Path $GlobalRoot 'run.ps1') `
        -Label global
    Write-ProjCommandRoutingFixture `
        -Path (Join-Path $HelpRoot '_guard\run.ps1') `
        -Label help-guard
    Write-ProjCommandRoutingFixture `
        -Path (Join-Path $HelpRoot 'run.ps1') `
        -Label help-target `
        -ExitCode 21
    Write-ProjCommandRoutingFixture `
        -Path (Join-Path $ProbeRoot '_guard\run.ps1') `
        -Label forbidden-probe-guard
    Write-ProjCommandRoutingFixture `
        -Path (Join-Path $ProbeRoot 'run.ps1') `
        -Label forbidden-probe-target
    [void][IO.Directory]::CreateDirectory((Join-Path $ProbeRoot '_help'))
    [IO.File]::WriteAllText(
        (Join-Path $ProbeRoot '_help\zh-CN.txt'),
        'probe help',
        [Text.UTF8Encoding]::new($false)
    )

    $LocalHelp = Invoke-ProjCommandRoutingFixture `
        -Arguments @('probe', '--help') `
        -ProjectContext $ProjectContext `
        -KernelRoot $KernelRoot `
        -CapturePath $CapturePath
    $ExpectedHelpLines = @(
        "global|0|guard|global|.help|$HelpRoot|probe|",
        "help-guard|0|guard|command|.help|$HelpRoot|probe|",
        "help-target|0|run||.help|$HelpRoot|probe|"
    )
    Assert-ProjCommandRoutingTest `
        -Condition ($LocalHelp.ExitCode -eq 21 -and
            [string]::Join("`n", $LocalHelp.Lines) -ceq
                [string]::Join("`n", $ExpectedHelpLines)) `
        -Message 'local help did not replace the target with complete guard context'

    Write-ProjCommandRoutingFixture `
        -Path (Join-Path $SelfHelpRoot '_guard\run.ps1') `
        -Label self-help-guard
    Write-ProjCommandRoutingFixture `
        -Path (Join-Path $SelfHelpRoot 'run.ps1') `
        -Label self-help-target `
        -ExitCode 22
    $OwnedHelp = Invoke-ProjCommandRoutingFixture `
        -Arguments @('self-help', '--help') `
        -ProjectContext $ProjectContext `
        -KernelRoot $KernelRoot `
        -CapturePath $CapturePath
    Assert-ProjCommandRoutingTest `
        -Condition ($OwnedHelp.ExitCode -eq 22 -and
            $OwnedHelp.Lines.Count -eq 3 -and
            $OwnedHelp.Lines[1] -ceq
                "self-help-guard|0|guard|command|self-help|$SelfHelpRoot||" -and
            $OwnedHelp.Lines[2] -ceq
                "self-help-target|1|run||self-help|$SelfHelpRoot||--help") `
        -Message 'module-owned help did not preserve its command guard and argument'

    Write-ProjCommandRoutingFixture `
        -Path (Join-Path $KernelProbeRoot '_guard\run.ps1') `
        -Label kernel-guard
    Write-ProjCommandRoutingFixture `
        -Path (Join-Path $KernelProbeRoot 'run.ps1') `
        -Label kernel-target `
        -ExitCode 23
    $KernelProbe = Invoke-ProjCommandRoutingFixture `
        -Arguments @('.probe', 'alpha', '--help', 'value') `
        -ProjectContext $ProjectContext `
        -KernelRoot $KernelRoot `
        -CapturePath $CapturePath
    Assert-ProjCommandRoutingTest `
        -Condition ($KernelProbe.ExitCode -eq 23 -and
            $KernelProbe.Lines[1] -ceq
                "kernel-guard|0|guard|command|.probe|$KernelProbeRoot||" -and
            $KernelProbe.Lines[2] -ceq (
                "kernel-target|3|run||.probe|$KernelProbeRoot||" +
                'alpha,--help,value'
            )) `
        -Message 'kernel guard parameter isolation is incorrect'

    Write-ProjCommandRoutingFixture `
        -Path (Join-Path $BunRoot '_guard\run.ps1') `
        -Label bun-guard
    Write-ProjCommandRoutingFixture `
        -Path (Join-Path $BunRoot 'run.ps1') `
        -Label bun-target `
        -ExitCode 47
    Write-ProjCommandRoutingFixture `
        -Path (Join-Path $TypeScriptRoot '_guard\run.ps1') `
        -Label typescript-guard
    [void][IO.Directory]::CreateDirectory($TypeScriptRoot)
    $TypeScriptEntry = Join-Path $TypeScriptRoot 'run.ts'
    [IO.File]::WriteAllText($TypeScriptEntry, 'void 0;')
    $Bridge = Invoke-ProjCommandRoutingFixture `
        -Arguments @('typescript', 'alpha', 'value') `
        -ProjectContext $ProjectContext `
        -KernelRoot $KernelRoot `
        -CapturePath $CapturePath
    $ExpectedBridgeLines = @(
        "global|0|guard|global|typescript|$TypeScriptRoot||",
        "typescript-guard|0|guard|command|typescript|$TypeScriptRoot||",
        "bun-guard|0|guard|command|typescript|$TypeScriptRoot||",
        "bun-target|3|run||typescript|$TypeScriptRoot||$TypeScriptEntry,alpha,value"
    )
    Assert-ProjCommandRoutingTest `
        -Condition ($Bridge.ExitCode -eq 47 -and
            [string]::Join("`n", $Bridge.Lines) -ceq
                [string]::Join("`n", $ExpectedBridgeLines)) `
        -Message 'run.ts bridge guard order or logical command context is incorrect'
} finally {
    [Environment]::SetEnvironmentVariable(
        'SWAWKIT_PROJ_TEST_ROUTING_CAPTURE',
        $SavedCapture,
        'Process'
    )
    if ([IO.Directory]::Exists($TemporaryRoot)) {
        [IO.Directory]::Delete($TemporaryRoot, $true)
    }
}

Write-Host '[PASS] Proj command routing and guard context' -ForegroundColor Green
$global:LASTEXITCODE = 0
