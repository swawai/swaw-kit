$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'engine.ps1')

function Assert-ProjSmoke {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$KernelRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ActionRoot = Join-Path ([IO.Path]::GetTempPath()) 'proj-smoke-actions-not-created'
$SmokeProjectContext = [pscustomobject]@{
    Protocol = '1'
    ProjectRoot = $KernelRoot
    ActionRoot = $ActionRoot
    DataRoot = Join-Path ([IO.Path]::GetTempPath()) 'proj-smoke-data-not-created'
    EntryName = 'proj-smoke'
    EntryFile = Join-Path $KernelRoot 'proj.ps1'
}

$RootCommand = Resolve-ProjCommand `
    -KernelRoot $KernelRoot `
    -ActionRoot $ActionRoot `
    -Address ''
Assert-ProjSmoke `
    ($RootCommand.Entry.Name -ceq 'run.ps1') `
    'the empty address must resolve the Kernel Root run.ps1'

$Info = Resolve-ProjCommand `
    -KernelRoot $KernelRoot `
    -ActionRoot $ActionRoot `
    -Address '.info'
Assert-ProjSmoke ($Info.Entry.Name -ceq 'run.ps1') '.info must select run.ps1'
Assert-ProjSmoke $Info.HasView '.info must expose index.html as its GUI view'
Assert-ProjSmoke `
    ($Info.Directory.EndsWith('.info')) `
    '.info must use the real root .info directory without name translation'

foreach ($Alias in @('.h', '--help', '-h')) {
    $ResolvedAlias = Resolve-ProjCommand `
        -KernelRoot $KernelRoot `
        -ActionRoot $ActionRoot `
        -Address $Alias
    Assert-ProjSmoke `
        ($ResolvedAlias.Entry.Name -ceq 'run.ps1') `
        "$Alias must be a real run.ps1 module"
}

$RejectedNestedMarker = $false
try {
    [void](Resolve-ProjCommand `
        -KernelRoot $KernelRoot `
        -ActionRoot $ActionRoot `
        -Address '.help.--verbose')
} catch {
    $RejectedNestedMarker = $_.Exception.Message.Contains(
        'Invalid kernel command segment'
    )
}
Assert-ProjSmoke `
    $RejectedNestedMarker `
    'only the Kernel Root may use a public command marker'

$Discoveries = @(Get-ProjCommandDiscoveries `
    -KernelRoot $KernelRoot `
    -ActionRoot $ActionRoot)
$Addresses = @($Discoveries | ForEach-Object Address)
foreach ($Expected in @('', '.h', '.help', '.info', '--help', '-h')) {
    Assert-ProjSmoke `
        ($Addresses -ccontains $Expected) `
        "dynamic discovery must include '$Expected'"
}
Assert-ProjSmoke `
    ($Addresses -cnotcontains '.core') `
    'the single-underscore _core tree must remain private'
$DiscoveryDirectories = @($Discoveries | ForEach-Object Directory)
foreach ($PrivateRootName in @(
    '_core',
    '_bin',
    '_help',
    '_shell',
    '_test'
)) {
    Assert-ProjSmoke `
        ($DiscoveryDirectories -cnotcontains (Join-Path $KernelRoot $PrivateRootName)) `
        "discovery must prune the private $PrivateRootName directory itself"
}

$TempActionRoot = Join-Path ([IO.Path]::GetTempPath()) "proj-action-root-$([Guid]::NewGuid().ToString('N'))"
$ResolvedActionRoot = [IO.Path]::GetFullPath($TempActionRoot)
$SystemTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $ResolvedActionRoot.StartsWith(
    $SystemTempRoot,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Refusing to create an Action smoke-test root outside system temp: $ResolvedActionRoot"
}
try {
    $CheckDirectory = Join-Path $ResolvedActionRoot 'check'
    [void][IO.Directory]::CreateDirectory($CheckDirectory)
    [IO.File]::WriteAllText((Join-Path $CheckDirectory 'run.ts'), '')
    $PrivateActionDirectory = Join-Path $ResolvedActionRoot '_private'
    [void][IO.Directory]::CreateDirectory($PrivateActionDirectory)
    [IO.File]::WriteAllText((Join-Path $PrivateActionDirectory 'run.ps1'), '')
    $DotActionDirectory = Join-Path $ResolvedActionRoot '.kernel-looking'
    [void][IO.Directory]::CreateDirectory($DotActionDirectory)
    [IO.File]::WriteAllText((Join-Path $DotActionDirectory 'run.ps1'), '')
    $ViewOnlyDirectory = Join-Path $ResolvedActionRoot 'about'
    [void][IO.Directory]::CreateDirectory($ViewOnlyDirectory)
    [IO.File]::WriteAllText((Join-Path $ViewOnlyDirectory 'index.html'), '')

    $AboutHelpDirectory = Join-Path $ViewOnlyDirectory '_help'
    [void][IO.Directory]::CreateDirectory($AboutHelpDirectory)
    Assert-ProjSmoke `
        (-not (Test-ProjUsesLocalHelp `
            -KernelRoot $KernelRoot `
            -ActionRoot $ResolvedActionRoot `
            -TargetAddress 'about')) `
        '_help without zh-CN.txt must not enable Proj help'
    $AboutHelpPath = Join-Path $AboutHelpDirectory 'zh-CN.txt'
    [IO.File]::WriteAllText($AboutHelpPath, 'About help')
    Assert-ProjSmoke `
        (Test-ProjUsesLocalHelp `
            -KernelRoot $KernelRoot `
            -ActionRoot $ResolvedActionRoot `
            -TargetAddress 'about') `
        '_help/zh-CN.txt must enable Proj help for a command group'
    [IO.File]::WriteAllText($AboutHelpPath, '')
    $RejectedEmptyHelp = $false
    try {
        [void](Test-ProjUsesLocalHelp `
            -KernelRoot $KernelRoot `
            -ActionRoot $ResolvedActionRoot `
            -TargetAddress 'about')
    } catch {
        $RejectedEmptyHelp = $_.Exception.Message.Contains('Help file is empty')
    }
    Assert-ProjSmoke `
        $RejectedEmptyHelp `
        'an empty opted-in help document must fail the help protocol'

    $Check = Resolve-ProjCommand `
        -KernelRoot $KernelRoot `
        -ActionRoot $ResolvedActionRoot `
        -Address 'check'
    Assert-ProjSmoke ($Check.Source -ceq 'Action') 'check must resolve from the Action Root'
    Assert-ProjSmoke ($Check.Entry.Name -ceq 'run.ts') 'check must select run.ts'

    $AllDiscoveries = @(Get-ProjCommandDiscoveries `
        -KernelRoot $KernelRoot `
        -ActionRoot $ResolvedActionRoot)
    $DiscoveredCheck = @($AllDiscoveries | Where-Object {
        $_.Source -ceq 'Action' -and $_.Address -ceq 'check'
    })
    Assert-ProjSmoke `
        ($DiscoveredCheck.Count -eq 1) `
        'dynamic discovery must merge the Action Root'
    $DiscoveredViewOnly = @($AllDiscoveries | Where-Object {
        $_.Source -ceq 'Action' -and $_.Address -ceq 'about'
    })
    Assert-ProjSmoke `
        ($DiscoveredViewOnly.Count -eq 1 -and
            -not $DiscoveredViewOnly[0].Executable -and
            $DiscoveredViewOnly[0].HasView) `
        'index.html alone must describe a GUI-only node'
    $RejectedViewOnlyExecution = $false
    try {
        [void](Resolve-ProjCommand `
            -KernelRoot $KernelRoot `
            -ActionRoot $ResolvedActionRoot `
            -Address 'about')
    } catch {
        $RejectedViewOnlyExecution = $_.Exception.Message.Contains(
            'GUI-only node'
        )
    }
    Assert-ProjSmoke `
        $RejectedViewOnlyExecution `
        'a GUI-only node must not become CLI-executable'
    $ActionDirectories = @($AllDiscoveries | Where-Object {
        $_.Source -ceq 'Action'
    } | ForEach-Object Directory)
    Assert-ProjSmoke `
        ($ActionDirectories -cnotcontains $PrivateActionDirectory) `
        'Action discovery must prune single-underscore private directories'
    Assert-ProjSmoke `
        ($ActionDirectories -cnotcontains $DotActionDirectory) `
        'Action discovery must not expose dot directories as Actions'
} finally {
    if ([IO.Directory]::Exists($ResolvedActionRoot)) {
        Remove-Item -LiteralPath $ResolvedActionRoot -Recurse -Force
    }
}

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) "proj-entry-contract-$([Guid]::NewGuid().ToString('N'))"
$ResolvedTempRoot = [IO.Path]::GetFullPath($TempRoot)
if (-not $ResolvedTempRoot.StartsWith($SystemTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to create a smoke-test directory outside the system temp root: $ResolvedTempRoot"
}

try {
    [void][IO.Directory]::CreateDirectory($ResolvedTempRoot)
    $RunEntryNames = @('run.exe', 'run.ts', 'run.py', 'run.ps1', 'run.cmd')
    foreach ($Name in $RunEntryNames) {
        [IO.File]::WriteAllText((Join-Path $ResolvedTempRoot $Name), '')
    }
    $RejectedMultipleEntries = $false
    try {
        [void](Get-ProjEntryResolution -Directory $ResolvedTempRoot)
    } catch {
        $RejectedMultipleEntries = $_.Exception.Message.Contains(
            'Exactly one run.* is allowed'
        )
    }
    Assert-ProjSmoke `
        $RejectedMultipleEntries `
        'a module must reject multiple canonical run.* entries'
    foreach ($Name in $RunEntryNames) {
        [IO.File]::Delete((Join-Path $ResolvedTempRoot $Name))
    }

    [IO.File]::WriteAllText((Join-Path $ResolvedTempRoot 'index.ps1'), '')
    $LegacyEntry = Get-ProjEntryResolution -Directory $ResolvedTempRoot
    Assert-ProjSmoke `
        ($null -eq $LegacyEntry.Selected -and $LegacyEntry.Existing.Count -eq 0) `
        'legacy index.ps1 must not remain an executable-entry fallback'
    [IO.File]::Delete((Join-Path $ResolvedTempRoot 'index.ps1'))

    Assert-ProjSmoke `
        ((ConvertTo-ProjWindowsArgument -Value '') -ceq '""') `
        'the Windows argv encoder must preserve an empty argument'
    Assert-ProjSmoke `
        ((ConvertTo-ProjWindowsArgument -Value 'a b') -ceq '"a b"') `
        'the Windows argv encoder must quote whitespace'
    Assert-ProjSmoke `
        ((ConvertTo-ProjWindowsArgument -Value 'q"z') -ceq '"q\"z"') `
        'the Windows argv encoder must escape embedded quotes'
    Assert-ProjSmoke `
        ((ConvertTo-ProjWindowsArgument -Value 'a b\') -ceq '"a b\\"') `
        'the Windows argv encoder must double trailing slashes before a closing quote'

    $CmdProbeOutput = Join-Path $ResolvedTempRoot 'cmd.txt'
    $PreviousCmdProbeOutput = $env:PROJ_SMOKE_CMD_PATH
    try {
        $env:PROJ_SMOKE_CMD_PATH = $CmdProbeOutput
        $CmdProbeScript = @'
@echo off
> "%PROJ_SMOKE_CMD_PATH%" echo %SWAWKIT_COMMAND_ADDRESS%
if not "%~1"=="" >> "%PROJ_SMOKE_CMD_PATH%" echo %~1
exit /b 37
'@
        [IO.File]::WriteAllText(
            (Join-Path $ResolvedTempRoot 'run.cmd'),
            $CmdProbeScript
        )
        $CmdEntry = Get-ProjEntryResolution -Directory $ResolvedTempRoot
        $CmdCommand = [pscustomobject]@{
            Address = '.cmd-probe'
            Directory = $ResolvedTempRoot
            Entry = $CmdEntry.Selected
        }
        $CmdExitCode = Invoke-ProjResolvedCommand `
            -Command $CmdCommand `
            -ProjectContext $SmokeProjectContext `
            -KernelRoot $KernelRoot `
            -InvocationDirectory $KernelRoot `
            -Arguments @()
        Assert-ProjSmoke `
            ($CmdExitCode -eq 37) `
            "the CMD adapter must preserve exit code 37; got $CmdExitCode"
        Assert-ProjSmoke `
            (([IO.File]::ReadAllText($CmdProbeOutput)).Trim() -ceq '.cmd-probe') `
            'the CMD adapter must provide the resolved command environment'

        foreach ($HelpMarker in @('.help', '.h', '-h', '--help')) {
            $CmdHelpExitCode = Invoke-ProjResolvedCommand `
                -Command $CmdCommand `
                -ProjectContext $SmokeProjectContext `
                -KernelRoot $KernelRoot `
                -InvocationDirectory $KernelRoot `
                -Arguments @($HelpMarker)
            Assert-ProjSmoke `
                ($CmdHelpExitCode -eq 37) `
                "the CMD adapter must preserve $HelpMarker exit code"
            [string[]]$CmdProbeLines = [IO.File]::ReadAllLines(
                $CmdProbeOutput
            )
            Assert-ProjSmoke `
                ($CmdProbeLines.Count -eq 2 -and
                    $CmdProbeLines[1].Trim() -ceq $HelpMarker) `
                "the CMD adapter must pass safe help selector $HelpMarker as %1"
        }

        $RejectedCmdArguments = $false
        try {
            [void](Invoke-ProjResolvedCommand `
                -Command $CmdCommand `
                -ProjectContext $SmokeProjectContext `
                -KernelRoot $KernelRoot `
                -InvocationDirectory $KernelRoot `
                -Arguments @('dynamic'))
        } catch {
            $RejectedCmdArguments = $_.Exception.Message.Contains(
                'does not accept dynamic tail arguments'
            )
        }
        Assert-ProjSmoke `
            $RejectedCmdArguments `
            'the V0 CMD adapter must reject dynamic tail arguments explicitly'
    } finally {
        [IO.File]::Delete((Join-Path $ResolvedTempRoot 'run.cmd'))
        if ($null -eq $PreviousCmdProbeOutput) {
            Remove-Item -LiteralPath 'Env:PROJ_SMOKE_CMD_PATH' -ErrorAction SilentlyContinue
        } else {
            $env:PROJ_SMOKE_CMD_PATH = $PreviousCmdProbeOutput
        }
    }

    $ProbeScript = @'
$Encoded = foreach ($Value in @($args)) {
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Value))
}
[IO.File]::WriteAllLines($env:PROJ_SMOKE_ARGV_PATH, [string[]]@($Encoded))
exit 23
'@
    [IO.File]::WriteAllText((Join-Path $ResolvedTempRoot 'run.ps1'), $ProbeScript)
    $ProbeOutput = Join-Path $ResolvedTempRoot 'argv.txt'
    $PreviousProbeOutput = $env:PROJ_SMOKE_ARGV_PATH
    try {
        $env:PROJ_SMOKE_ARGV_PATH = $ProbeOutput
        $ProbeEntry = Get-ProjEntryResolution -Directory $ResolvedTempRoot
        $ProbeCommand = [pscustomobject]@{
            Address = '.probe'
            Directory = $ResolvedTempRoot
            Entry = $ProbeEntry.Selected
        }
        [string[]]$RoundTripArguments = @('', 'a b', 'q"z', 'trail\')
        $ProbeExitCode = Invoke-ProjResolvedCommand `
            -Command $ProbeCommand `
            -ProjectContext $SmokeProjectContext `
            -KernelRoot $KernelRoot `
            -InvocationDirectory $KernelRoot `
            -Arguments $RoundTripArguments
        Assert-ProjSmoke `
            ($ProbeExitCode -eq 23) `
            "the PowerShell child runner must preserve exit code 23; got $ProbeExitCode"
        [string[]]$EncodedRows = [IO.File]::ReadAllLines($ProbeOutput)
        [string[]]$DecodedRows = @($EncodedRows | ForEach-Object {
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_))
        })
        Assert-ProjSmoke `
            ($DecodedRows.Count -eq $RoundTripArguments.Count) `
            'the PowerShell child runner must preserve the argument count'
        for ($Index = 0; $Index -lt $RoundTripArguments.Count; $Index++) {
            Assert-ProjSmoke `
                ($DecodedRows[$Index] -ceq $RoundTripArguments[$Index]) `
                "the PowerShell child runner must preserve argument $Index"
        }
    } finally {
        if ($null -eq $PreviousProbeOutput) {
            Remove-Item -LiteralPath 'Env:PROJ_SMOKE_ARGV_PATH' -ErrorAction SilentlyContinue
        } else {
            $env:PROJ_SMOKE_ARGV_PATH = $PreviousProbeOutput
        }
    }

    $WrongCaseDirectory = Join-Path $ResolvedTempRoot '.Info'
    [void][IO.Directory]::CreateDirectory($WrongCaseDirectory)
    [IO.File]::WriteAllText((Join-Path $WrongCaseDirectory 'run.ps1'), '')
    $RejectedWrongCase = $false
    try {
        [void](Resolve-ProjCommand `
            -KernelRoot $ResolvedTempRoot `
            -ActionRoot $ActionRoot `
            -Address '.info')
    } catch {
        $RejectedWrongCase = $_.Exception.Message.Contains(
            'Non-canonical command directory'
        )
    }
    Assert-ProjSmoke `
        $RejectedWrongCase `
        'direct resolution must reject non-canonical directory casing'
} finally {
    if ([IO.Directory]::Exists($ResolvedTempRoot)) {
        Remove-Item -LiteralPath $ResolvedTempRoot -Recurse -Force
    }
}

Write-Host '[PASS] Proj filesystem command protocol smoke test'
