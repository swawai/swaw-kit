[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-ProjDevelopmentCommandLayout {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Development command layout test failed: $Message"
    }
}

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $ProjRoot '..\..'))
$SystemRoot = Join-Path $ProjRoot 'system'
$OfficialModuleRoot = Join-Path $ProjRoot 'modules'
$ProjectModuleRoot = Join-Path $RepoRoot '.swaw'
Assert-ProjDevelopmentCommandLayout `
    -Condition (-not [IO.Directory]::Exists((Join-Path $ProjRoot '_global'))) `
    -Message 'the removed no-op global guard directory still exists'

$ModuleManifests = @(
    Get-ChildItem -LiteralPath $ProjRoot -Recurse -File -Filter 'swawkit.module.json'
    Get-ChildItem -LiteralPath $ProjectModuleRoot `
        -Recurse -File -Filter 'swawkit.module.json'
)
foreach ($ModuleManifest in $ModuleManifests) {
    $ModuleDocument = Get-Content -LiteralPath $ModuleManifest.FullName -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-ProjDevelopmentCommandLayout `
        -Condition ($ModuleDocument.schema -ceq 'swawkit.command-module/v11') `
        -Message "legacy module contract remains: $($ModuleManifest.FullName)"
}
$LegacyModuleManifests = @(
    Get-ChildItem -LiteralPath $ProjRoot -Recurse -File -Filter '_module.json'
    Get-ChildItem -LiteralPath $ProjectModuleRoot `
        -Recurse -File -Filter '_module.json'
)
Assert-ProjDevelopmentCommandLayout `
    -Condition ($LegacyModuleManifests.Count -eq 0) `
    -Message 'the removed generic _module.json marker remains in a command root'

foreach ($ManifestRoot in @($SystemRoot, $OfficialModuleRoot, $ProjectModuleRoot)) {
    if (-not [IO.Directory]::Exists($ManifestRoot)) {
        continue
    }
    $CanonicalRoot = [IO.Path]::GetFullPath($ManifestRoot).TrimEnd('\')
    $RootManifests = Get-ChildItem -LiteralPath $CanonicalRoot `
        -Recurse -File -Filter 'swawkit.module.json'
    foreach ($RootManifest in $RootManifests) {
        $RelativeDirectory = $RootManifest.Directory.FullName.Substring(
            $CanonicalRoot.Length
        ).TrimStart('\')
        foreach ($Segment in $RelativeDirectory.Split('\')) {
            Assert-ProjDevelopmentCommandLayout `
                -Condition ($Segment.Length -le 64 -and
                    $Segment -cmatch '^[a-z][a-z0-9-]*$' -and
                    $Segment -notin @(
                        'con', 'prn', 'aux', 'nul',
                        'com1', 'com2', 'com3', 'com4', 'com5',
                        'com6', 'com7', 'com8', 'com9',
                        'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5',
                        'lpt6', 'lpt7', 'lpt8', 'lpt9'
                    )) `
                -Message "invalid command directory segment: $Segment"
        }
        $Ancestor = $RootManifest.Directory.Parent
        while ($null -ne $Ancestor -and
            $Ancestor.FullName -cne $CanonicalRoot) {
            Assert-ProjDevelopmentCommandLayout `
                -Condition ([IO.File]::Exists((
                    Join-Path $Ancestor.FullName 'swawkit.module.json'
                ))) `
                -Message "module parent has no Manifest: $($Ancestor.FullName)"
            $Ancestor = $Ancestor.Parent
        }
    }
}
$ObsoleteExecutionEntries = Get-ChildItem -LiteralPath $ProjRoot -Recurse -File |
    Where-Object { $_.Name -in @(
        'run.core.json',
        'run.toolchain.json',
        'run.native',
        'run.delegate'
    ) }
Assert-ProjDevelopmentCommandLayout `
    -Condition (@($ObsoleteExecutionEntries).Count -eq 0) `
    -Message 'an obsolete framework-interpreted run entry remains'

$CommandEntries = [ordered]@{
    bun = 'dev\bun\run.ps1'
    cargo = 'dev\rust\cargo\run.ps1'
    cl = 'dev\msvc\cl\run.ps1'
    rustc = 'dev\rust\rustc\run.ps1'
    cmd = 'dev\cmd\run.ps1'
    exec = 'dev\exec\run.ps1'
    pwsh = 'dev\pwsh\run.ps1'
}
foreach ($Name in $CommandEntries.Keys) {
    $LegacyPath = Join-Path $ProjRoot ".$Name"
    $EntryPath = Join-Path $SystemRoot $CommandEntries[$Name]

    Assert-ProjDevelopmentCommandLayout `
        -Condition (-not (Test-Path -LiteralPath $LegacyPath)) `
        -Message "legacy command .$Name still exists"
    Assert-ProjDevelopmentCommandLayout `
        -Condition ([IO.File]::Exists($EntryPath)) `
        -Message "$Name does not have its declared PowerShell entry"
}
foreach ($OldAddress in @('cargo', 'cl', 'rustc')) {
    Assert-ProjDevelopmentCommandLayout `
        -Condition (-not (Test-Path -LiteralPath (Join-Path $SystemRoot "dev\$OldAddress"))) `
        -Message "old flat .dev.$OldAddress command still exists"
}

$SetupRoot = Join-Path $SystemRoot 'dev\setup'
$SetupManifest = Join-Path $SetupRoot 'swawkit.module.json'
Assert-ProjDevelopmentCommandLayout `
    -Condition ([IO.File]::Exists($SetupManifest) -and
        -not [IO.File]::Exists((Join-Path $SetupRoot 'run.ps1'))) `
    -Message '.dev/setup did not converge to one Dev Runtime Component entry'
$SetupContract = Get-Content -LiteralPath $SetupManifest -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-ProjDevelopmentCommandLayout `
    -Condition ($SetupContract.schema -ceq 'swawkit.command-module/v11' -and
        $SetupContract.execution.type -ceq 'runtime' -and
        $SetupContract.execution.product -ceq 'dev' -and
        $null -eq $SetupContract.execution.PSObject.Properties['handler']) `
    -Message '.dev/setup Dev Runtime Component manifest is invalid'

$InstantiateManifest = Join-Path $SystemRoot 'module\instantiate\swawkit.module.json'
Assert-ProjDevelopmentCommandLayout `
    -Condition ([IO.File]::Exists($InstantiateManifest)) `
    -Message '.module/instantiate Runtime Component manifest is missing'
$InstantiateContract = Get-Content -LiteralPath $InstantiateManifest -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-ProjDevelopmentCommandLayout `
    -Condition ($InstantiateContract.schema -ceq 'swawkit.command-module/v11' -and
        $InstantiateContract.execution.type -ceq 'runtime' -and
        $InstantiateContract.execution.product -ceq 'module' -and
        $null -eq $InstantiateContract.PSObject.Properties['requires']) `
    -Message '.module/instantiate Runtime Component manifest is invalid'

$StatusManifest = Join-Path $SystemRoot 'module\status\swawkit.module.json'
Assert-ProjDevelopmentCommandLayout `
    -Condition ([IO.File]::Exists($StatusManifest)) `
    -Message '.module/status Runtime Component manifest is missing'
$StatusContract = Get-Content -LiteralPath $StatusManifest -Raw -Encoding UTF8 |
    ConvertFrom-Json
$StatusRequires = @(if (
    $null -ne $StatusContract.PSObject.Properties['requires']
) {
    $StatusContract.requires
})
Assert-ProjDevelopmentCommandLayout `
    -Condition ($StatusContract.schema -ceq 'swawkit.command-module/v11' -and
        $StatusContract.execution.type -ceq 'runtime' -and
        $StatusContract.execution.product -ceq 'module' -and
        $StatusRequires.Count -eq 0) `
    -Message '.module/status Runtime Component manifest is invalid'

$ModuleProductRoot = Join-Path $SystemRoot 'module'
Assert-ProjDevelopmentCommandLayout `
    -Condition ([IO.File]::Exists((Join-Path $ModuleProductRoot 'Cargo.toml')) -and
        [IO.File]::Exists((Join-Path $ModuleProductRoot 'Cargo.lock')) -and
        [IO.File]::Exists((Join-Path $ModuleProductRoot 'src\main.rs')) -and
        -not [IO.Directory]::Exists((Join-Path $ModuleProductRoot '_app'))) `
    -Message '.module does not own an independent locked Rust Runtime Component'

Assert-ProjDevelopmentCommandLayout `
    -Condition (-not (Test-Path -LiteralPath (Join-Path $ProjRoot '.runtime'))) `
    -Message 'the removed legacy .runtime command directory still exists outside system/'

$RuntimeContracts = @(
    @{ Path = 'runtime\swawkit.module.json'; Handler = 'runtime.status' },
    @{ Path = 'runtime\host\exit\swawkit.module.json'; Handler = 'host.exit' },
    @{ Path = 'runtime\host\restart\swawkit.module.json'; Handler = 'host.restart' },
    @{ Path = 'runtime\cleanup\swawkit.module.json'; Handler = 'runtime.cleanup' }
)
foreach ($RuntimeContract in $RuntimeContracts) {
    $RuntimeManifest = Join-Path $SystemRoot $RuntimeContract.Path
    Assert-ProjDevelopmentCommandLayout `
        -Condition ([IO.File]::Exists($RuntimeManifest)) `
        -Message "Runtime System manifest is missing: $($RuntimeContract.Path)"
    $RuntimeDocument = Get-Content -LiteralPath $RuntimeManifest -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-ProjDevelopmentCommandLayout `
        -Condition ($RuntimeDocument.schema -ceq 'swawkit.command-module/v11' -and
            $RuntimeDocument.execution.type -ceq 'core' -and
            $RuntimeDocument.execution.handler -ceq $RuntimeContract.Handler) `
        -Message "Runtime System manifest is invalid: $($RuntimeContract.Path)"
}

$ContextCommands = @(
    'new',
    'add',
    'remove',
    'note',
    'prompt',
    'render',
    'show',
    'list',
    'delete'
)
$ContextRoot = Join-Path $SystemRoot 'context'
$ContextNativeManifest = Join-Path $ContextRoot 'swawkit.module.json'
$ContextNativeDocument = Get-Content -LiteralPath $ContextNativeManifest -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-ProjDevelopmentCommandLayout `
    -Condition ([IO.File]::Exists($ContextNativeManifest) -and
        $ContextNativeDocument.execution.type -ceq 'native' -and
        [IO.File]::Exists((Join-Path $ContextRoot 'Cargo.toml')) -and
        [IO.File]::Exists((Join-Path $ContextRoot 'Cargo.lock')) -and
        [IO.File]::Exists((Join-Path $ContextRoot 'src\main.rs')) -and
        [IO.File]::Exists((Join-Path $ContextRoot 'src\lib.rs')) -and
        -not [IO.File]::Exists((Join-Path $ContextRoot '_native-set')) -and
        -not [IO.Directory]::Exists((Join-Path $ContextRoot '_lib')) -and
        -not [IO.Directory]::Exists((Join-Path $ContextRoot '_src')) -and
        -not [IO.Directory]::Exists((Join-Path $OfficialModuleRoot 'context'))) `
    -Message '.context is not one locked native domain engine'
foreach ($ContextCommand in $ContextCommands) {
    $ContextCommandRoot = Join-Path $ContextRoot $ContextCommand
    $ContextManifestPath = Join-Path $ContextCommandRoot 'swawkit.module.json'
    $ContextManifest = Get-Content -LiteralPath $ContextManifestPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-ProjDevelopmentCommandLayout `
        -Condition ([IO.File]::Exists($ContextManifestPath) -and
            $ContextManifest.schema -ceq 'swawkit.command-module/v11' -and
            $ContextManifest.execution.type -ceq 'delegate' -and
            $ContextManifest.execution.owner.type -ceq 'command' -and
            $ContextManifest.execution.owner.space -ceq 'system' -and
            $null -eq $ContextManifest.execution.owner.PSObject.Properties['namespace'] -and
            $ContextManifest.execution.owner.address -ceq '.context' -and
            -not [IO.File]::Exists((Join-Path $ContextCommandRoot 'run.delegate'))) `
        -Message "Context delegated execution declaration is invalid: $ContextManifestPath"
    Assert-ProjDevelopmentCommandLayout `
        -Condition (-not [IO.File]::Exists((Join-Path $ContextCommandRoot 'Cargo.toml')) -and
            -not [IO.File]::Exists((Join-Path $ContextCommandRoot 'Cargo.lock')) -and
            -not [IO.File]::Exists((Join-Path $ContextCommandRoot 'run.native')) -and
            -not [IO.File]::Exists((Join-Path $ContextCommandRoot 'run.core.json')) -and
            -not [IO.File]::Exists((Join-Path $ContextCommandRoot 'run.toolchain.json'))) `
        -Message "Context port incorrectly owns an independent implementation: $ContextCommandRoot"
}

$ContextModuleManifest = Join-Path $ContextRoot 'swawkit.module.json'
Assert-ProjDevelopmentCommandLayout `
    -Condition ([IO.File]::Exists($ContextModuleManifest)) `
    -Message '.context does not declare its module facets'
$ContextModule = Get-Content -LiteralPath $ContextModuleManifest -Raw -Encoding UTF8 |
    ConvertFrom-Json
$ContextFacet = @($ContextModule.facets)[0]
$ContextSubjectKind = @($ContextModule.subjectKinds)[0]
$ContextOverviewFacet = @($ContextSubjectKind.facets) |
    Where-Object { $_.id -ceq 'overview' } |
    Select-Object -First 1
Assert-ProjDevelopmentCommandLayout `
    -Condition ($ContextModule.schema -ceq 'swawkit.command-module/v11' -and
        $ContextModule.execution.type -ceq 'native' -and
        @($ContextModule.facets).Count -eq 1 -and
        $ContextFacet.id -ceq 'contexts' -and
        $ContextFacet.kind -ceq 'collection' -and
        $ContextFacet.subjectKind.kind -ceq 'context' -and
        $ContextFacet.subjectKind.provider.type -ceq 'command' -and
        $ContextFacet.subjectKind.provider.space -ceq 'system' -and
        $null -eq $ContextFacet.subjectKind.provider.PSObject.Properties['namespace'] -and
        $ContextFacet.subjectKind.provider.address -ceq '.context' -and
        $ContextFacet.resolver.type -ceq 'command' -and
        $ContextFacet.resolver.address -ceq '.context/list' -and
        @($ContextFacet.resolver.arguments).Count -eq 1 -and
        $ContextFacet.resolver.arguments[0] -ceq '--json' -and
        $ContextFacet.resolver.returns -ceq 'swawkit.subject-collection/v3' -and
        $ContextSubjectKind.kind -ceq 'context' -and
        @($ContextSubjectKind.facets).Count -eq 7 -and
        $ContextOverviewFacet.resolver.address -ceq '.context/show' -and
        $ContextOverviewFacet.resolver.arguments[0].bind -ceq 'subject.id') `
    -Message '.context collection facet declaration is invalid'
Assert-ProjDevelopmentCommandLayout `
    -Condition (-not (Test-Path -LiteralPath (
        Join-Path $ContextRoot 'resource.core.json'
    ))) `
    -Message 'the removed Context resource provider manifest still exists'

$RunsModuleManifest = Join-Path $SystemRoot 'runs\swawkit.module.json'
Assert-ProjDevelopmentCommandLayout `
    -Condition ([IO.File]::Exists($RunsModuleManifest)) `
    -Message '.runs does not declare its Run Subject facets'
$RunsModule = Get-Content -LiteralPath $RunsModuleManifest -Raw -Encoding UTF8 |
    ConvertFrom-Json
$AllRunsFacet = @($RunsModule.facets)[0]
$RunSubjectKind = @($RunsModule.subjectKinds)[0]
$RunOverviewFacet = @($RunSubjectKind.facets) |
    Where-Object { $_.id -ceq 'overview' } |
    Select-Object -First 1
$RunOpenFacet = @($RunSubjectKind.facets) |
    Where-Object { $_.id -ceq 'open' } |
    Select-Object -First 1
$RunsContractChecks = @(
    ($RunsModule.schema -ceq 'swawkit.command-module/v11')
    (@($RunsModule.facets).Count -eq 1)
    ($AllRunsFacet.id -ceq 'all')
    ($AllRunsFacet.kind -ceq 'collection')
    (-not [string]::IsNullOrWhiteSpace($AllRunsFacet.label.'zh-CN'))
    ($AllRunsFacet.label.en -ceq 'All Runs')
    ($AllRunsFacet.subjectKind.kind -ceq 'run')
    ($AllRunsFacet.subjectKind.provider.type -ceq 'command')
    ($AllRunsFacet.subjectKind.provider.space -ceq 'system')
    ($AllRunsFacet.subjectKind.provider.address -ceq '.runs')
    ($AllRunsFacet.resolver.address -ceq '.runs')
    (@($AllRunsFacet.resolver.arguments).Count -eq 1)
    ($AllRunsFacet.resolver.arguments[0] -ceq '--json')
    ($AllRunsFacet.resolver.returns -ceq 'swawkit.subject-collection/v3')
    ($RunSubjectKind.kind -ceq 'run')
    (@($RunSubjectKind.facets).Count -eq 2)
    ($RunOverviewFacet.resolver.address -ceq '.runs')
    ($RunOverviewFacet.resolver.arguments[0] -ceq '--run')
    ($RunOverviewFacet.resolver.arguments[1].bind -ceq 'subject.id')
    ($RunOverviewFacet.resolver.returns -ceq 'swawkit.command-run-journal/v2')
    ($RunOpenFacet.resolver.address -ceq '.runs')
    ($RunOpenFacet.resolver.arguments[0] -ceq '--open')
    ($RunOpenFacet.resolver.arguments[1].bind -ceq 'subject.id')
)
Assert-ProjDevelopmentCommandLayout `
    -Condition ($RunsContractChecks -notcontains $false) `
    -Message '.runs Run collection facet declaration is invalid'

$ProcessContracts = @(
    @{ Name = '.dev/bun'; Script = 'dev\bun\run.ps1'; Relative = '..\_lib\process.ps1' },
    @{ Name = '.dev/cmd'; Script = 'dev\cmd\run.ps1'; Relative = '..\_lib\process.ps1' },
    @{ Name = '.dev/exec'; Script = 'dev\exec\run.ps1'; Relative = '..\_lib\process.ps1' },
    @{ Name = '.dev/msvc/cl'; Script = 'dev\msvc\cl\run.ps1'; Relative = '..\..\_lib\process.ps1' },
    @{ Name = '.dev/pwsh'; Script = 'dev\pwsh\run.ps1'; Relative = '..\_lib\process.ps1' },
    @{ Name = '.dev/rust/cargo'; Script = 'dev\rust\cargo\run.ps1'; Relative = '..\..\_lib\process.ps1' },
    @{ Name = '.dev/rust/rustc'; Script = 'dev\rust\rustc\run.ps1'; Relative = '..\..\_lib\process.ps1' }
)
foreach ($Contract in $ProcessContracts) {
    $ScriptPath = Join-Path $SystemRoot $Contract.Script
    $Source = [IO.File]::ReadAllText($ScriptPath)
    $TargetPath = [IO.Path]::GetFullPath((Join-Path `
        (Split-Path -Parent $ScriptPath) `
        $Contract.Relative
    ))

    Assert-ProjDevelopmentCommandLayout `
        -Condition ($Source.Contains([string]$Contract.Relative)) `
        -Message "$($Contract.Name) no longer declares its expected relative path"
    Assert-ProjDevelopmentCommandLayout `
        -Condition (Test-Path `
            -LiteralPath $TargetPath `
            -PathType Leaf) `
        -Message "$($Contract.Name) resolves to a missing target"
    Assert-ProjDevelopmentCommandLayout `
        -Condition ($Source.Contains('Import-ProjDevTargetEnvironment') -and
            -not $Source.Contains('_toolchain') -and
            -not $Source.Contains('_bootstrap')) `
        -Message "$($Contract.Name) does not explicitly consume the target Dev environment"
}

$PwshEntry = Join-Path $SystemRoot 'dev\pwsh\run.ps1'
$PwshSource = [IO.File]::ReadAllText($PwshEntry)
Assert-ProjDevelopmentCommandLayout `
    -Condition ($PwshSource.Contains('accepts only -File or -Command') -and
        $PwshSource.Contains("-Application 'pwsh.exe'") -and
        -not [IO.File]::Exists((Join-Path $SystemRoot 'dev\ps\run.ps1'))) `
    -Message '.dev/pwsh does not explicitly launch the target PowerShell environment'

$DevProcessLibrary = [IO.File]::ReadAllText((
    Join-Path $SystemRoot 'dev\_lib\process.ps1'
))
Assert-ProjDevelopmentCommandLayout `
    -Condition ($DevProcessLibrary.Contains('swawkit.command-provider-state/v2') -and
        $DevProcessLibrary.Contains('swawkit.proj.dev-setup/v3') -and
        $DevProcessLibrary.Contains('swawkit.proj-dev-environment/v1') -and
        $DevProcessLibrary.Contains('Import-ProjDevTargetEnvironment')) `
    -Message 'the explicit target Dev environment consumer contract is incomplete'

Write-Host '[PASS] Proj development command layout test' `
    -ForegroundColor Green
$global:LASTEXITCODE = 0
