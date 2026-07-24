. (Join-Path $PSScriptRoot 'helpers.ps1')
. (Join-Path $PSScriptRoot 'help-contract.ps1')

$UnicodeSegment = [string]([char]0x4E2D) + [string]([char]0x6587)
$TempRoot = Join-Path (
    [IO.Path]::GetTempPath()
) ("xvenv modules ! & ('$UnicodeSegment') " + [Guid]::NewGuid().ToString('N'))

try {
    Write-Host '[TEST] Built-in module catalog'
    [void][IO.Directory]::CreateDirectory($TempRoot)
    $CopiedModuleRoot = Join-Path $TempRoot 'module root'
    [void][IO.Directory]::CreateDirectory($CopiedModuleRoot)
    foreach ($ModuleDirectory in Get-ChildItem `
        -LiteralPath (Join-Path $KitRoot.FullName 'modules') `
        -Directory) {
        Copy-Item `
            -LiteralPath $ModuleDirectory.FullName `
            -Destination $CopiedModuleRoot `
            -Recurse
    }

    $ModuleTreeBefore = Get-TreeSnapshot $CopiedModuleRoot
    $Catalog = Import-XvenvModuleCatalog $CopiedModuleRoot
    $ReloadedCatalog = Import-XvenvModuleCatalog $CopiedModuleRoot
    Assert-Equal `
        ([string]::Join(',', [string[]]$Catalog.PublicOrder)) `
        'bun,pwsh,python,go' `
        'module order must be deterministic'
    Assert-Equal `
        ([string]::Join(',', [string[]]$Catalog.ComponentOrder)) `
        'uv' `
        'internal module order must be deterministic'
    Assert-Equal $Catalog.Tools.Count 4 'exactly four public modules must load'
    Assert-Equal `
        $ReloadedCatalog.Tools.Count `
        4 `
        'reloading modules must not accumulate registrations'
    Assert-True `
        ($Catalog.Tools.bun._Handlers.Install -is [scriptblock]) `
        'module handlers must be attached'
    Assert-Equal `
        (Get-TreeSnapshot $CopiedModuleRoot) `
        $ModuleTreeBefore `
        'module loading must be read-only'

    $DuplicateModule = Join-Path $CopiedModuleRoot 'duplicate'
    Copy-Item `
        -LiteralPath (Join-Path $CopiedModuleRoot 'bun') `
        -Destination $DuplicateModule `
        -Recurse
    Assert-Throws {
        Import-XvenvModuleCatalog $CopiedModuleRoot
    } 'duplicate module names must fail'
    Remove-Item -LiteralPath $DuplicateModule -Recurse -Force

    $MissingScriptModule = Join-Path $CopiedModuleRoot 'missing-script'
    Copy-Item `
        -LiteralPath (Join-Path $CopiedModuleRoot 'go') `
        -Destination $MissingScriptModule `
        -Recurse
    Remove-Item -LiteralPath (Join-Path $MissingScriptModule 'module.ps1') -Force
    Assert-Throws {
        Import-XvenvModuleCatalog $CopiedModuleRoot
    } 'a module without its behavior script must fail'
    Remove-Item -LiteralPath $MissingScriptModule -Recurse -Force

    $MismatchedModule = Join-Path $CopiedModuleRoot 'mismatched'
    Copy-Item `
        -LiteralPath (Join-Path $CopiedModuleRoot 'go') `
        -Destination $MismatchedModule `
        -Recurse
    $MismatchedManifestPath = Join-Path $MismatchedModule 'module.psd1'
    $MismatchedManifest = [IO.File]::ReadAllText($MismatchedManifestPath).
        Replace("Name = 'go'", "Name = 'other'").
        Replace("XVENV_GO_HOME", "XVENV_OTHER_HOME")
    Write-TestFile -Path $MismatchedManifestPath -Content $MismatchedManifest
    Assert-Throws {
        Import-XvenvModuleCatalog $CopiedModuleRoot
    } 'a module script must identify the same module as its manifest'
    $MismatchedScriptPath = Join-Path $MismatchedModule 'module.ps1'
    Write-TestFile -Path $MismatchedScriptPath -Content @'
Set-StrictMode -Version 2.0

@{
    Name = 'other'
    Install = {
        param($Context, $Definition, $Project, $Dependencies)
    }
}
'@
    Assert-Throws {
        Import-XvenvModuleCatalog $CopiedModuleRoot
    } 'a public module must explicitly provide ContributeEnvironment'

    Write-Host '[TEST] Entry point from a special-character path'
    $CopiedToolbox = Join-Path $TempRoot 'toolbox copy'
    $CopiedLib = Join-Path $CopiedToolbox '_lib'
    [void][IO.Directory]::CreateDirectory($CopiedLib)
    Copy-Item `
        -LiteralPath $KitRoot.FullName `
        -Destination $CopiedLib `
        -Recurse
    $SourceEntry = Get-XvenvFullPath (Join-Path $KitRoot.FullName '..\..\xvenv.cmd')
    $CopiedEntry = Join-Path $CopiedToolbox 'xvenv.cmd'
    Copy-Item -LiteralPath $SourceEntry -Destination $CopiedEntry
    $SourcePowerShellEntry = Get-XvenvFullPath (
        Join-Path $KitRoot.FullName '..\..\xvenv.ps1'
    )
    $CopiedPowerShellEntry = Join-Path $CopiedToolbox 'xvenv.ps1'
    Copy-Item `
        -LiteralPath $SourcePowerShellEntry `
        -Destination $CopiedPowerShellEntry
    $EntryProject = Join-Path $TempRoot 'entry project'
    [void][IO.Directory]::CreateDirectory((Join-Path $EntryProject '.git'))
    Push-Location $EntryProject
    try {
        & $CopiedEntry status
        $EntryExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    Assert-Equal $EntryExitCode 0 'the copied xvenv.cmd entry point must run'
    Assert-True `
        (-not [IO.Directory]::Exists((Join-Path $CopiedToolbox 'data'))) `
        'status through the real entry point must stay read-only'

    $StatusJson = (& $CopiedEntry status --json | Out-String).Trim()
    $StatusExitCode = $LASTEXITCODE
    $StatusReport = $StatusJson | ConvertFrom-Json
    Assert-Equal $StatusExitCode 0 'status --json through the real entry point must run'
    Assert-Equal $StatusReport.schema 'xvenv.status.v1' 'status JSON must publish its schema'
    Assert-True (-not $StatusReport.configured) 'an untouched project must be unconfigured'
    Assert-Equal @($StatusReport.tools).Count 0 'unconfigured status JSON must have no tools'

    $ToolsJson = (& $CopiedEntry tools --json | Out-String).Trim()
    $ToolsExitCode = $LASTEXITCODE
    $ToolsReport = $ToolsJson | ConvertFrom-Json
    Assert-Equal $ToolsExitCode 0 'tools --json through the real entry point must run'
    Assert-Equal $ToolsReport.schema 'xvenv.tools.v1' 'tools JSON must publish its schema'
    Assert-Equal `
        ([string]::Join(',', [string[]]@($ToolsReport.tools | ForEach-Object { $_.name }))) `
        'bun,pwsh,python,go' `
        'tools JSON must preserve public catalog order'
    Assert-True `
        (-not [IO.Directory]::Exists((Join-Path $CopiedToolbox 'data'))) `
        'JSON query commands must stay read-only'

    $RoundTripArguments = @(
        'exec',
        'program with spaces.exe',
        '',
        "value ! & (`"$UnicodeSegment`")"
    )
    $RoundTripPayload = ConvertTo-XvenvArgumentPayload $RoundTripArguments
    $DecodedArguments = @(
        ConvertFrom-XvenvArgumentPayload $RoundTripPayload
    )
    Assert-Equal `
        $DecodedArguments.Count `
        $RoundTripArguments.Count `
        'the PowerShell entry payload must preserve argument count'
    for ($Index = 0; $Index -lt $RoundTripArguments.Count; $Index++) {
        Assert-Equal `
            $DecodedArguments[$Index] `
            $RoundTripArguments[$Index] `
            "the PowerShell entry payload must preserve argument $Index"
    }

    $PowerShellStatusJson = (
        & $CopiedPowerShellEntry status --json | Out-String
    ).Trim()
    $PowerShellStatusExitCode = $LASTEXITCODE
    $PowerShellStatus = $PowerShellStatusJson | ConvertFrom-Json
    Assert-Equal `
        $PowerShellStatusExitCode `
        0 `
        'the PowerShell xvenv entry point must run'
    Assert-Equal `
        $PowerShellStatus.schema `
        'xvenv.status.v1' `
        'the PowerShell entry must preserve JSON output'

    $OriginalPath = $env:Path
    try {
        $env:Path = "$CopiedToolbox$([IO.Path]::PathSeparator)$OriginalPath"
        $ResolvedEntry = Get-Command xvenv -ErrorAction Stop
        Assert-Equal `
            $ResolvedEntry.Source `
            $CopiedPowerShellEntry `
            'PowerShell must prefer the argument-safe xvenv.ps1 entry'
    } finally {
        $env:Path = $OriginalPath
    }

    Test-XvenvHelpContract `
        -CopiedCmdEntry $CopiedEntry `
        -CopiedPowerShellEntry $CopiedPowerShellEntry `
        -CopiedToolbox $CopiedToolbox

    Write-Host 'xvenv module tests: PASS' -ForegroundColor Green
} finally {
    if ([IO.Directory]::Exists($TempRoot)) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}
