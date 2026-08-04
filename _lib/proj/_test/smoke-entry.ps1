[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$EntryPath = Join-Path $RepoRoot 'swawkit.cmd'
$DeclaredDataRoot = Join-Path $RepoRoot 'data\proj.swawkit'
$DevelopmentEnvironment = Join-Path $DeclaredDataRoot 'dev_env'
$DevelopmentEnvironmentExistedBefore =
    [IO.Directory]::Exists($DevelopmentEnvironment)
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
    'entryName            swawkit',
    "entryFile            $EntryPath",
    "swawkitHome          $RepoRoot",
    "targetProjectRoot    $RepoRoot",
    "cacheRoot            $(Join-Path $RepoRoot 'data\proj_cache')",
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

$DemoEntryName = "test-smoke-entry-$([Guid]::NewGuid().ToString('N'))"
$DemoEntryPath = Join-Path $RepoRoot "$DemoEntryName.cmd"
$DemoDataRoot = Join-Path $RepoRoot "data\proj.$DemoEntryName"
$DemoEntryContent = [IO.File]::ReadAllText($EntryPath)
$DemoEntryContent = [regex]::Replace(
    $DemoEntryContent,
    '(?im)^set "(SWAWKIT_PROJ_[A-Z0-9_]+_MODE)=[^"]*"\s*$',
    'set "$1=disabled"'
)
try {
    [IO.File]::WriteAllText(
        $DemoEntryPath,
        $DemoEntryContent,
        [Text.UTF8Encoding]::new($false)
    )
    $DemoAction = Invoke-ProjCmdLineTest `
        -CommandLine (
            '"{0}" demo.echo "" "A&B" "A B"' -f $DemoEntryPath
        ) `
        -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($DemoAction.ExitCode -eq 0) `
    "the real .swaw demo Action failed: $($DemoAction.Text)"
foreach ($Expected in @(
    'SWAW Action demo.echo',
    'commandAddress=demo.echo',
    "entryName=$DemoEntryName",
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
        -CommandPath $DemoEntryPath `
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
    -CommandPath $DemoEntryPath `
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
    -CommandPath $DemoEntryPath `
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
} finally {
    if ([IO.File]::Exists($DemoEntryPath)) {
        [IO.File]::Delete($DemoEntryPath)
    }
    if ([IO.Directory]::Exists($DemoDataRoot)) {
        [IO.Directory]::Delete($DemoDataRoot, $true)
    }
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

$WebHelp = Invoke-ProjEntryTest `
    -Arguments @('.web', '.help') `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($WebHelp.ExitCode -eq 0) `
    ".web .help failed: $($WebHelp.Text)"
Assert-ProjEntryTest `
    $WebHelp.Text.Contains('swawkit .web') `
    '.web should be discoverable through module-local help'
Assert-ProjEntryTest `
    $WebHelp.Text.Contains('swawkit proj.build.app') `
    '.web help should point to the application build Action'

$AppBuildHelp = Invoke-ProjEntryTest `
    -Arguments @('proj.build.app', '.help') `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($AppBuildHelp.ExitCode -eq 0) `
    "proj.build.app .help failed: $($AppBuildHelp.Text)"
Assert-ProjEntryTest `
    $AppBuildHelp.Text.Contains('swawkit proj.build.app') `
    'the application build Action should be discoverable through local help'

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
Assert-ProjEntryTest `
    $Root.Text.Contains('swawkit .web') `
    'the root command should point to the explicit local web entry'

$SlashHelp = Invoke-ProjEntryTest `
    -Arguments @('/?') `
    -WorkingDirectory $InvocationDirectory
Assert-ProjEntryTest `
    ($SlashHelp.ExitCode -eq 1) `
    '/? must remain outside the promoted command protocol'

$RequiredProjectDeclarations = @(
    'SWAWKIT_PROJ_PROTOCOL',
    'SWAWKIT_PROJ_TARGET_PROJECT_ROOT',
    'SWAWKIT_PROJ_ACTION_ROOT',
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
    ([IO.File]::Exists((Join-Path $DeclaredDataRoot '_entry.json'))) `
    'entry commands must publish the entry identity binding'
Assert-ProjEntryTest `
    ([IO.Directory]::Exists($DevelopmentEnvironment) -eq
        $DevelopmentEnvironmentExistedBefore) `
    'read-only entry commands must not create the development environment'

Write-Host '[PASS] Proj promoted entry smoke test' -ForegroundColor Green
$global:LASTEXITCODE = 0
