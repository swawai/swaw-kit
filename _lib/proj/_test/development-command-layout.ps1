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

function Read-ProjLayoutJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
        ConvertFrom-Json
}

function Assert-ProjExecution {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Type,
        [string]$Value = ''
    )

    $Path = Join-Path $SystemRoot $RelativePath
    Assert-ProjDevelopmentCommandLayout `
        -Condition ([IO.File]::Exists($Path)) `
        -Message "execution declaration is missing: $RelativePath"
    $Document = Read-ProjLayoutJson -Path $Path
    $ActualValue = switch ($Type) {
        'core' { [string]$Document.implementation.handler }
        'runtime' { [string]$Document.implementation.product }
        'native-delegate' { [string]$Document.implementation.owner }
        default { '' }
    }
    Assert-ProjDevelopmentCommandLayout `
        -Condition ($Document.schema -ceq 'swawkit.facet-execution/v2' -and
            $Document.implementation.type -ceq $Type -and
            $ActualValue -ceq $Value) `
        -Message "execution declaration is invalid: $RelativePath"
}

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $ProjRoot '..\..'))
$SystemRoot = Join-Path $ProjRoot 'system'
$OfficialModuleRoot = Join-Path $ProjRoot 'modules'
$ProjectModuleRoot = Join-Path $RepoRoot '.swaw'

$RemovedStage0Paths = @(
    '_toolchain\_lib\provider-state.ps1',
    '_toolchain\_lib\command-export.ps1',
    '_toolchain\_lib\context.ps1',
    '_toolchain\_lib\activation.ps1',
    '_toolchain\_lib\declaration.ps1',
    '_toolchain\_lib\console-process.ps1',
    '_toolchain\_modules\rust\command.ps1',
    '_toolchain\_modules\rust\runtime.ps1',
    '_toolchain\_modules\msvc\command.ps1',
    '_toolchain\_modules\msvc\runtime.ps1',
    '_toolchain\_modules\go\module.psd1',
    '_toolchain\_modules\python\module.psd1',
    '_toolchain\_modules\uv\module.psd1'
)
Assert-ProjDevelopmentCommandLayout `
    -Condition (@($RemovedStage0Paths | Where-Object {
        Test-Path -LiteralPath (Join-Path $ProjRoot $_)
    }).Count -eq 0) `
    -Message 'the removed Profile/provider Stage-0 island still exists'

$RetiredFiles = @(
    Get-ChildItem -LiteralPath $ProjRoot -Recurse -File |
        Where-Object { $_.Name -in @(
            'swawkit.module.json',
            '_module.json',
            'run.core.json',
            'run.toolchain.json',
            'run.native',
            'run.delegate'
        ) }
)
Assert-ProjDevelopmentCommandLayout `
    -Condition ($RetiredFiles.Count -eq 0) `
    -Message "retired command protocol files remain: $($RetiredFiles.Count)"

$Resources = @(Get-ChildItem -LiteralPath $SystemRoot `
    -Recurse -File -Filter 'swawkit.resource.json')
Assert-ProjDevelopmentCommandLayout `
    -Condition ($Resources.Count -eq 57) `
    -Message "the authored System Resource inventory changed: $($Resources.Count)"
foreach ($Resource in $Resources) {
    $Document = Read-ProjLayoutJson -Path $Resource.FullName
    Assert-ProjDevelopmentCommandLayout `
        -Condition ($Document.schema -ceq 'swawkit.resource/v1' -and
            $Document.kind -ceq 'command') `
        -Message "invalid Command Resource: $($Resource.FullName)"

    $Name = $Resource.Directory.Name
    Assert-ProjDevelopmentCommandLayout `
        -Condition ($Name.Length -le 64 -and
            $Name -cmatch '^[a-z][a-z0-9-]*$') `
        -Message "invalid Resource selector: $Name"
    if ($Resource.Directory.Parent.FullName -cne $SystemRoot) {
        $Collection = $Resource.Directory.Parent
        $Owner = $Collection.Parent
        $CollectionDeclaration = Join-Path $Collection.FullName 'swawkit.facet.json'
        Assert-ProjDevelopmentCommandLayout `
            -Condition ($Collection.Name -ceq 'subcommands' -and
                [IO.File]::Exists($CollectionDeclaration) -and
                [IO.File]::Exists((Join-Path $Owner.FullName 'swawkit.resource.json'))) `
            -Message "nested Resource is not owned by a subcommands Facet: $($Resource.FullName)"
    }
}

$Facets = @(Get-ChildItem -LiteralPath $SystemRoot `
    -Recurse -File -Filter 'swawkit.facet.json')
Assert-ProjDevelopmentCommandLayout `
    -Condition ($Facets.Count -eq 109) `
    -Message "the authored Facet inventory changed: $($Facets.Count)"
foreach ($Facet in $Facets) {
    $Document = Read-ProjLayoutJson -Path $Facet.FullName
    Assert-ProjDevelopmentCommandLayout `
        -Condition ($Document.schema -ceq 'swawkit.facet/v1' -and
            $Document.kind -cin @('collection', 'operation', 'projection')) `
        -Message "invalid Facet declaration: $($Facet.FullName)"
    if ($Facet.Directory.Name -ceq 'subcommands') {
        Assert-ProjDevelopmentCommandLayout `
            -Condition ($Document.kind -ceq 'collection') `
            -Message "subcommands is not a Collection Facet: $($Facet.FullName)"
    }
    if ($Facet.Directory.Name -ceq 'execute') {
        Assert-ProjDevelopmentCommandLayout `
            -Condition ($Document.kind -ceq 'operation') `
            -Message "execute is not an Operation Facet: $($Facet.FullName)"
        $LocalEntries = @(Get-ChildItem -LiteralPath $Facet.Directory.FullName -File |
            Where-Object { $_.Name -match '^run\.(ps1|cmd|exe|ts|js)$' })
        $Declarations = @(
            Get-ChildItem -LiteralPath $Facet.Directory.FullName `
                -File -Filter 'swawkit.execution.json'
        )
        Assert-ProjDevelopmentCommandLayout `
            -Condition (($LocalEntries.Count + $Declarations.Count) -eq 1) `
            -Message "execute Facet must own exactly one implementation: $($Facet.Directory.FullName)"
    }
}

$ExecutionDeclarations = @(Get-ChildItem -LiteralPath $SystemRoot `
    -Recurse -File -Filter 'swawkit.execution.json')
Assert-ProjDevelopmentCommandLayout `
    -Condition ($ExecutionDeclarations.Count -eq 86) `
    -Message "the Facet execution inventory changed: $($ExecutionDeclarations.Count)"
foreach ($Execution in $ExecutionDeclarations) {
    $Document = Read-ProjLayoutJson -Path $Execution.FullName
    Assert-ProjDevelopmentCommandLayout `
        -Condition ($Document.schema -ceq 'swawkit.facet-execution/v2' -and
            $Document.implementation.type -cin @(
                'core', 'invoke', 'native-delegate', 'native', 'runtime'
            ) -and
            [IO.File]::Exists((Join-Path $Execution.Directory.FullName 'swawkit.facet.json'))) `
        -Message "execution is not local to a declared Facet: $($Execution.FullName)"
}

$LocalCommands = @(
    'dev\subcommands\bun\execute\run.ps1',
    'dev\subcommands\cmd\execute\run.ps1',
    'dev\subcommands\exec\execute\run.ps1',
    'dev\subcommands\msvc\subcommands\cl\execute\run.ps1',
    'dev\subcommands\pwsh\execute\run.ps1',
    'dev\subcommands\rust\subcommands\cargo\execute\run.ps1',
    'dev\subcommands\rust\subcommands\rustc\execute\run.ps1'
)
foreach ($RelativePath in $LocalCommands) {
    $Path = Join-Path $SystemRoot $RelativePath
    Assert-ProjDevelopmentCommandLayout `
        -Condition ([IO.File]::Exists($Path)) `
        -Message "local execute implementation is missing: $RelativePath"
    $Source = [IO.File]::ReadAllText($Path)
    $Match = [regex]::Match(
        $Source,
        "Join-Path [`$]PSScriptRoot '([^']*_lib\\process[.]ps1)'"
    )
    Assert-ProjDevelopmentCommandLayout `
        -Condition ($Match.Success -and
            [IO.File]::Exists([IO.Path]::GetFullPath((Join-Path `
                (Split-Path -Parent $Path) `
                $Match.Groups[1].Value
            )))) `
        -Message "local execute implementation has a broken process library path: $RelativePath"
}

Assert-ProjExecution `
    -RelativePath 'dev\subcommands\setup\execute\swawkit.execution.json' `
    -Type 'runtime' -Value 'dev'
Assert-ProjExecution `
    -RelativePath 'module\subcommands\instantiate\execute\swawkit.execution.json' `
    -Type 'runtime' -Value 'module'
Assert-ProjExecution `
    -RelativePath 'module\subcommands\status\execute\swawkit.execution.json' `
    -Type 'runtime' -Value 'module'
Assert-ProjExecution `
    -RelativePath 'view\subcommands\source\execute\swawkit.execution.json' `
    -Type 'core' -Value 'meta.view.source'
foreach ($Runtime in @(
    @{ Path = 'runtime\execute\swawkit.execution.json'; Handler = 'runtime.status' },
    @{ Path = 'runtime\subcommands\cleanup\execute\swawkit.execution.json'; Handler = 'runtime.cleanup' },
    @{ Path = 'runtime\subcommands\host\subcommands\exit\execute\swawkit.execution.json'; Handler = 'host.exit' },
    @{ Path = 'runtime\subcommands\host\subcommands\restart\execute\swawkit.execution.json'; Handler = 'host.restart' }
)) {
    Assert-ProjExecution -RelativePath $Runtime.Path `
        -Type 'core' -Value $Runtime.Handler
}

Assert-ProjExecution `
    -RelativePath 'context\execute\swawkit.execution.json' `
    -Type 'native'
$ContextPorts = @('new', 'add', 'remove', 'note', 'prompt', 'render', 'show', 'list', 'delete')
foreach ($Port in $ContextPorts) {
    Assert-ProjExecution `
        -RelativePath "context\subcommands\$Port\execute\swawkit.execution.json" `
        -Type 'native-delegate' -Value '$/system::context/execute'
}
Assert-ProjDevelopmentCommandLayout `
    -Condition ([IO.File]::Exists((Join-Path $SystemRoot 'context\Cargo.toml')) -and
        [IO.File]::Exists((Join-Path $SystemRoot 'context\Cargo.lock')) -and
        [IO.File]::Exists((Join-Path $SystemRoot 'context\src\main.rs')) -and
        [IO.File]::Exists((Join-Path $SystemRoot 'context\src\lib.rs'))) `
    -Message '.context is not one locked Native Facet owner'

$Views = @(Get-ChildItem -LiteralPath $SystemRoot -Recurse -File -Filter 'web.json')
Assert-ProjDevelopmentCommandLayout `
    -Condition ($Views.Count -eq 2) `
    -Message "the authored Web View inventory changed: $($Views.Count)"
foreach ($View in $Views) {
    $Document = Read-ProjLayoutJson -Path $View.FullName
    Assert-ProjDevelopmentCommandLayout `
        -Condition ($View.Directory.Name -ceq 'view' -and
            [IO.File]::Exists((Join-Path $View.Directory.Parent.FullName 'swawkit.facet.json')) -and
            $Document.schema -ceq 'swawkit.view-source/web/v1' -and
            $Document.column.width -ceq 'wide' -and
            $Document.column.body.component -ceq 'resource-list' -and
            $Document.column.body.source -ceq 'facet-result') `
        -Message "invalid Facet-local Web View: $($View.FullName)"
}

$ResourceKinds = @(Get-ChildItem -LiteralPath $SystemRoot `
    -Recurse -File -Filter 'swawkit.resource-kind.json')
$KindDefinitions = @($ResourceKinds | Where-Object {
    $Document = Read-ProjLayoutJson -Path $_.FullName
    $null -ne $Document.PSObject.Properties['kind']
})
$KindReferences = @($ResourceKinds | Where-Object {
    $Document = Read-ProjLayoutJson -Path $_.FullName
    $null -ne $Document.PSObject.Properties['ref']
})
Assert-ProjDevelopmentCommandLayout `
    -Condition ($KindDefinitions.Count -eq 2 -and $KindReferences.Count -eq 33) `
    -Message 'Resource Kind definitions and exact references drifted'
foreach ($Reference in $KindReferences) {
    $Document = Read-ProjLayoutJson -Path $Reference.FullName
    Assert-ProjDevelopmentCommandLayout `
        -Condition ($Reference.Directory.Name -ceq 'runs' -and
            $Document.schema -ceq 'swawkit.resource-kind/v1' -and
            $Document.ref -ceq '$/system::runs/all') `
        -Message "invalid explicit Run Resource Kind ref: $($Reference.FullName)"

    $FacetPath = Join-Path $Reference.Directory.FullName 'swawkit.facet.json'
    $ExecutionPath = Join-Path $Reference.Directory.FullName 'swawkit.execution.json'
    Assert-ProjDevelopmentCommandLayout `
        -Condition ([IO.File]::Exists($FacetPath) -and [IO.File]::Exists($ExecutionPath)) `
        -Message "incomplete explicit Runs Facet: $($Reference.Directory.FullName)"

    $Facet = Read-ProjLayoutJson -Path $FacetPath
    $Execution = Read-ProjLayoutJson -Path $ExecutionPath
    $Arguments = @($Execution.implementation.arguments)
    Assert-ProjDevelopmentCommandLayout `
        -Condition ($Facet.schema -ceq 'swawkit.facet/v1' -and
            $Facet.kind -ceq 'collection' -and
            $Facet.presentation.icon -ceq '=' -and
            $Facet.presentation.label.'zh-CN' -ceq '运行记录' -and
            $Facet.presentation.label.en -ceq 'Runs' -and
            $Facet.presentation.summary.'zh-CN' -ceq '浏览该命令的持久运行' -and
            $Facet.presentation.summary.en -ceq 'Browse persisted runs for this command' -and
            $Execution.schema -ceq 'swawkit.facet-execution/v2' -and
            $Execution.implementation.type -ceq 'invoke' -and
            $Execution.implementation.target -ceq '$/system::runs/execute' -and
            $Execution.implementation.returns -ceq 'swawkit.resource-list/v2' -and
            $Arguments.Count -eq 2 -and
            $Arguments[0] -ceq '--json' -and
            $Arguments[1].bind -ceq 'resource.route') `
        -Message "explicit Runs Facet contract drifted: $($Reference.Directory.FullName)"
}
Assert-ProjDevelopmentCommandLayout `
    -Condition (@(Get-ChildItem -LiteralPath $SystemRoot `
        -Recurse -File -Filter 'swawkit.exports.json').Count -eq 1 -and
        @(Get-ChildItem -LiteralPath $SystemRoot `
            -Recurse -File -Filter 'swawkit.requirements.json').Count -eq 7) `
    -Message 'Resource Export or execute-Facet Requirement ownership drifted'

Write-Host '[PASS] Proj Resource-Facet development layout test' `
    -ForegroundColor Green
$global:LASTEXITCODE = 0
