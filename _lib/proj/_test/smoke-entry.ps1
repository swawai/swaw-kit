[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$EntryPath = Join-Path $RepoRoot 'swawkit.cmd'
$DeclaredDataRoot = Join-Path $RepoRoot 'data\swaw-kit'
$DataRootExistedBefore = [IO.Directory]::Exists($DeclaredDataRoot)
function Assert-ProjEntryTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}
function Invoke-ProjEntryTest {
    param(
        [string]$CommandPath = $EntryPath,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )
    Push-Location -LiteralPath $WorkingDirectory
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Output = @(& $CommandPath @Arguments 2>&1)
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
        Pop-Location
    }
    return [pscustomobject]@{
        ExitCode = [int]$ExitCode
        Text = [string]::Join(
            [Environment]::NewLine,
            [string[]]@($Output | ForEach-Object { [string]$_ })
        )
    }
}
function Invoke-ProjCmdLineTest {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $CmdPath = Join-Path $env:SystemRoot 'System32\cmd.exe'
    Push-Location -LiteralPath $WorkingDirectory
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Output = @(& $CmdPath /d /s /c $CommandLine 2>&1)
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
        Pop-Location
    }

    return [pscustomobject]@{
        ExitCode = [int]$ExitCode
        Text = [string]::Join(
            [Environment]::NewLine,
            [string[]]@($Output | ForEach-Object { [string]$_ })
        )
    }
}

if (-not [IO.File]::Exists($EntryPath)) {
    throw "Swaw Kit entry is missing: $EntryPath"
}

$UserPathBefore = [Environment]::GetEnvironmentVariable(
    'Path',
    [EnvironmentVariableTarget]::User
)
$MachinePathBefore = [Environment]::GetEnvironmentVariable(
    'Path',
    [EnvironmentVariableTarget]::Machine
)

$InvocationDirectory = [IO.Path]::GetTempPath().TrimEnd('\', '/')
Push-Location -LiteralPath $InvocationDirectory
try {
    $ExpectedInvocationDirectory = (Get-Location).ProviderPath
} finally {
    Pop-Location
}
$Info = Invoke-ProjEntryTest `
    -Arguments @('.info') `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest ($Info.ExitCode -eq 0) ".info failed: $($Info.Text)"
foreach ($Expected in @(
    'command              .info',
    'projectId            swaw-kit',
    $RepoRoot,
    $ExpectedInvocationDirectory
)) {
    Assert-ProjEntryTest `
        $Info.Text.Contains($Expected) `
        ".info should contain '$Expected'. Output: $($Info.Text)"
}

$InfoTail = Invoke-ProjEntryTest `
    -Arguments @('.info', 'unexpected') `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($InfoTail.ExitCode -eq 1) `
    '.info must reject dynamic tail arguments'

$EmptyTail = Invoke-ProjCmdLineTest `
    -CommandLine ('"{0}" .help ""' -f $EntryPath) `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($EmptyTail.ExitCode -eq 1) `
    'the CMD entry must preserve an explicit empty tail argument'

$MetaTail = Invoke-ProjCmdLineTest `
    -CommandLine ('"{0}" .help "a&b"' -f $EntryPath) `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($MetaTail.ExitCode -eq 1) `
    'the CMD entry must pass a quoted metacharacter argument as data'
Assert-ProjEntryTest `
    (-not $MetaTail.Text.Contains("'b' is not recognized")) `
    'the CMD entry must not execute a metacharacter tail as another command'

$EscapedMetaTail = Invoke-ProjEntryTest `
    -Arguments @('.help', 'a^&b') `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($EscapedMetaTail.ExitCode -eq 1) `
    'the PowerShell-to-CMD bridge must preserve a CMD-escaped metacharacter tail'
Assert-ProjEntryTest `
    (-not $EscapedMetaTail.Text.Contains("'b' is not recognized")) `
    'the PowerShell-to-CMD bridge must not reparse an escaped metacharacter tail'

$DemoAction = Invoke-ProjCmdLineTest `
    -CommandLine (
        '"{0}" demo.echo "" "A&B" "A B"' -f $EntryPath
    ) `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($DemoAction.ExitCode -eq 0) `
    "the real .swaw demo Action failed: $($DemoAction.Text)"
foreach ($Expected in @(
    'SWAW Action demo.echo',
    'commandAddress=demo.echo',
    'projectId=swaw-kit',
    "currentDirectory=$RepoRoot",
    'argumentCount=3',
    'arg[0]=""',
    'arg[1]="A&B"',
    'arg[2]="A B"'
)) {
    Assert-ProjEntryTest `
        $DemoAction.Text.Contains($Expected) `
        "the real .swaw demo Action should contain '$Expected'"
}

foreach ($Address in @('.help', '.h', '--help', '-h')) {
    $Help = Invoke-ProjEntryTest `
        -Arguments @($Address) `
        -WorkingDirectory $InvocationDirectory
    Assert-ProjEntryTest `
        ($Help.ExitCode -eq 0) `
        "$Address failed: $($Help.Text)"
    Assert-ProjEntryTest `
        $Help.Text.Contains('swawkit .info') `
        "$Address should discover the root Proj commands."
    Assert-ProjEntryTest `
        $Help.Text.Contains('swawkit demo') `
        "$Address should discover the top-level project Actions."
    Assert-ProjEntryTest `
        (-not $Help.Text.Contains('swawkit demo.echo')) `
        "$Address must only list top-level commands."
    Assert-ProjEntryTest `
        (-not $Help.Text.Contains('{{COMMAND}}')) `
        "$Address should replace the command placeholder."
}

foreach ($Marker in @('.help', '.h', '-h', '--help')) {
    $GroupHelp = Invoke-ProjEntryTest `
        -Arguments @('demo', $Marker) `
        -WorkingDirectory $InvocationDirectory
    Assert-ProjEntryTest `
        ($GroupHelp.ExitCode -eq 0) `
        "demo $Marker failed: $($GroupHelp.Text)"
    Assert-ProjEntryTest `
        $GroupHelp.Text.Contains('swawkit demo.echo') `
        "demo $Marker should discover its immediate child command."
    Assert-ProjEntryTest `
        $GroupHelp.Text.Contains('swawkit demo.native-help') `
        "demo $Marker should discover commands that manage their own help."

    $LeafHelp = Invoke-ProjEntryTest `
        -Arguments @('demo.echo', $Marker) `
        -WorkingDirectory $InvocationDirectory
    Assert-ProjEntryTest `
        ($LeafHelp.ExitCode -eq 0) `
        "demo.echo $Marker failed: $($LeafHelp.Text)"
    Assert-ProjEntryTest `
        $LeafHelp.Text.Contains('swawkit demo.echo [value ...]') `
        "demo.echo $Marker should render its local help text."
    Assert-ProjEntryTest `
        (-not $LeafHelp.Text.Contains('SWAW Action demo.echo')) `
        "demo.echo $Marker must not execute the target Action."

    $ModuleHelp = Invoke-ProjEntryTest `
        -Arguments @('demo.native-help', $Marker) `
        -WorkingDirectory $InvocationDirectory
    Assert-ProjEntryTest `
        ($ModuleHelp.ExitCode -eq 0) `
        "demo.native-help $Marker failed: $($ModuleHelp.Text)"
    Assert-ProjEntryTest `
        $ModuleHelp.Text.Contains('Module-owned help: demo.native-help') `
        "demo.native-help $Marker should execute the module."
    Assert-ProjEntryTest `
        $ModuleHelp.Text.Contains("selector=$Marker") `
        "demo.native-help $Marker should receive the selector unchanged."
}

$OrdinaryDoubleDash = Invoke-ProjEntryTest `
    -Arguments @('demo.echo', '--', '--help') `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($OrdinaryDoubleDash.ExitCode -eq 0) `
    "'--' must remain an ordinary module argument: $($OrdinaryDoubleDash.Text)"
foreach ($Expected in @('arg[0]="--"', 'arg[1]="--help"')) {
    Assert-ProjEntryTest `
        $OrdinaryDoubleDash.Text.Contains($Expected) `
        "'--' must not act as a Proj help barrier; expected '$Expected'"
}

$HelpAmongArguments = Invoke-ProjEntryTest `
    -Arguments @('demo.echo', '--help', 'value') `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($HelpAmongArguments.ExitCode -eq 0) `
    "help among dynamic arguments must reach the module: $($HelpAmongArguments.Text)"
foreach ($Expected in @('arg[0]="--help"', 'arg[1]="value"')) {
    Assert-ProjEntryTest `
        $HelpAmongArguments.Text.Contains($Expected) `
        "non-standalone help selector should remain a module argument: '$Expected'"
}

$InfoHelp = Invoke-ProjEntryTest `
    -Arguments @('.info', '.h') `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($InfoHelp.ExitCode -eq 0) `
    ".info .h failed: $($InfoHelp.Text)"
Assert-ProjEntryTest `
    $InfoHelp.Text.Contains('swawkit .info') `
    '.info .h should render the module-local help text'

$MissingHelp = Invoke-ProjEntryTest `
    -Arguments @('missing-command', '.help') `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($MissingHelp.ExitCode -eq 1) `
    'help for a missing command node must fail'
Assert-ProjEntryTest `
    $MissingHelp.Text.Contains('Command not found') `
    'a missing target should fail through normal command resolution'

foreach ($HiddenOrInvalidTarget in @('_core', 'demo._help', 'Demo')) {
    $RejectedHelp = Invoke-ProjEntryTest `
        -Arguments @($HiddenOrInvalidTarget, '.help') `
        -WorkingDirectory $InvocationDirectory
    Assert-ProjEntryTest `
        ($RejectedHelp.ExitCode -eq 1) `
        "help must reject hidden or non-canonical target '$HiddenOrInvalidTarget'"
}

$Root = Invoke-ProjEntryTest `
    -Arguments @() `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest ($Root.ExitCode -eq 0) "root command failed: $($Root.Text)"
Assert-ProjEntryTest `
    $Root.Text.Contains('Swaw Kit Proj command tree is ready.') `
    'the root command should execute the promoted Proj entry'

$SlashHelp = Invoke-ProjEntryTest `
    -Arguments @('/?') `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($SlashHelp.ExitCode -eq 1) `
    '/? must remain outside the promoted command protocol'

$RequiredProjectDeclarations = @(
    'SWAWKIT_PROJ_PROTOCOL',
    'SWAWKIT_PROJ_ID',
    'SWAWKIT_PROJ_DIR',
    'SWAWKIT_PROJ_ACTION_ROOT',
    'SWAWKIT_PROJ_DATA_ROOT',
    'SWAWKIT_PROJ_ENTRY_COMMAND',
    'SWAWKIT_PROJ_ENTRY_FILE'
)
$SavedDeclarations = @{}
try {
    foreach ($Name in $RequiredProjectDeclarations) {
        $SavedDeclarations[$Name] = [Environment]::GetEnvironmentVariable(
            $Name,
            [EnvironmentVariableTarget]::Process
        )
        [Environment]::SetEnvironmentVariable(
            $Name,
            $null,
            [EnvironmentVariableTarget]::Process
        )
    }
    $DirectProj = Invoke-ProjEntryTest `
        -CommandPath (Join-Path `
            $env:SystemRoot `
            'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -Arguments @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            (Join-Path $RepoRoot '_lib\proj\proj.ps1'),
            '.info'
        ) `
        -WorkingDirectory $InvocationDirectory
} finally {
    foreach ($Name in $RequiredProjectDeclarations) {
        [Environment]::SetEnvironmentVariable(
            $Name,
            $SavedDeclarations[$Name],
            [EnvironmentVariableTarget]::Process
        )
    }
}
Assert-ProjEntryTest `
    ($DirectProj.ExitCode -eq 1) `
    'the internal Proj runtime must reject a missing project declaration context'
Assert-ProjEntryTest `
    $DirectProj.Text.Contains('SWAWKIT_PROJ_PROTOCOL') `
    'the strict-context failure should identify the missing protocol'

Assert-ProjEntryTest `
    ([string]$UserPathBefore -ceq [string][Environment]::GetEnvironmentVariable(
        'Path',
        [EnvironmentVariableTarget]::User
    )) `
    'the entry must not change User PATH'
Assert-ProjEntryTest `
    ([string]$MachinePathBefore -ceq [string][Environment]::GetEnvironmentVariable(
        'Path',
        [EnvironmentVariableTarget]::Machine
    )) `
    'the entry must not change Machine PATH'
Assert-ProjEntryTest `
    ([IO.Directory]::Exists($DeclaredDataRoot) -eq $DataRootExistedBefore) `
    'read-only entry commands must not create the declared Data Root'

Write-Host '[PASS] Proj promoted entry smoke test' -ForegroundColor Green
$global:LASTEXITCODE = 0
