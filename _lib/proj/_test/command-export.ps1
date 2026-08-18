[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-ProjCommandExportTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Command export test failed: $Message"
    }
}

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '_toolchain\_lib\runtime.ps1')
$TemporaryBase = [IO.Path]::GetFullPath(
    (Join-Path $ProjRoot '..\..\data\_test')
)
[void][IO.Directory]::CreateDirectory($TemporaryBase)
$TemporaryRoot = Join-Path $TemporaryBase (
    "swawkit-command-export-$([Guid]::NewGuid().ToString('N'))"
)
$ModulesJunction = ''

try {
    $ProjectRoot = Join-Path $TemporaryRoot 'project'
    $DataRoot = Join-Path $TemporaryRoot 'data'
    $CacheRoot = Join-Path $TemporaryRoot 'cache'
    [void][IO.Directory]::CreateDirectory($ProjectRoot)
    [void][IO.Directory]::CreateDirectory($DataRoot)
    $Context = New-ProjDevContext `
        -ProjectRoot $ProjectRoot `
        -DataRoot $DataRoot `
        -CacheDataRoot $CacheRoot `
        -EntryCommand 'fixture'
    $ExpectedCommandRoot = Join-Path $DataRoot 'modules\system\dev\setup'
    $ExpectedExport = Join-Path $ExpectedCommandRoot 'export'
    Assert-ProjCommandExportTest `
        -Condition (
            (Get-ProjDevCanonicalPath -Path $Context.SetupCommandRoot) -ceq
            (Get-ProjDevCanonicalPath -Path $ExpectedCommandRoot) -and
            (Get-ProjDevCanonicalPath -Path $Context.EnvironmentRoot) -ceq
            (Get-ProjDevCanonicalPath -Path $ExpectedExport) -and
            (Get-ProjDevCanonicalPath -Path $Context.ProviderStatePath) -ceq
            (Get-ProjDevCanonicalPath -Path (
                Join-Path $ExpectedCommandRoot '_state.json'
            )) -and
            (Get-ProjDevCanonicalPath -Path $Context.ProviderStateLockPath) -ceq
            (Get-ProjDevCanonicalPath -Path (
                Join-Path $ExpectedCommandRoot 'locks\state.lock'
            ))
        ) `
        -Message 'provider paths do not follow the command-data layout'
    Assert-ProjCommandExportTest `
        -Condition (-not [IO.Directory]::Exists($ExpectedCommandRoot)) `
        -Message 'resolving provider paths created directories'

    $ExpectedModuleRoot = Join-Path $DataRoot 'modules\project\build\app'
    $ModuleRoot = Get-ProjModuleCommandDataRoot `
        -DataRoot $DataRoot `
        -Address 'project/build/app'
    $ModuleExport = Resolve-ProjCommandExportPath `
        -DataRoot $DataRoot `
        -ProviderAddress 'project/build/app' `
        -ProviderSpace module
    Assert-ProjCommandExportTest `
        -Condition (
            (Get-ProjDevCanonicalPath -Path $ModuleRoot) -ceq
            (Get-ProjDevCanonicalPath -Path $ExpectedModuleRoot) -and
            (Get-ProjDevCanonicalPath -Path $ModuleExport) -ceq
            (Get-ProjDevCanonicalPath -Path (
                Join-Path $ExpectedModuleRoot 'export'
            ))
        ) `
        -Message 'Module provider paths do not follow the command-data layout'

    Assert-ProjCommandExportTest `
        -Condition ((Get-ProjModuleCommandDataRoot `
            -DataRoot $DataRoot `
            -Address 'vendor') -ceq (Join-Path $DataRoot 'modules\vendor')) `
        -Message 'an executable namespace-root module cannot own command data'

    foreach ($Address in @(
        '', '.Dev/setup', '.dev..setup', '.dev.setup', '.dev\setup',
        '..entry', 'build'
    )) {
        $Rejected = $false
        try {
            [void](Resolve-ProjCommandExportPath `
                -DataRoot $DataRoot `
                -ProviderAddress $Address)
        } catch {
            $Rejected = $true
        }
        Assert-ProjCommandExportTest `
            -Condition $Rejected `
            -Message "unsafe provider address was accepted: '$Address'"
    }

    foreach ($Address in @(
        '', 'Project/build', 'project..build', '.dev/setup',
        'project\build', '..entry', 'system/help', 'module/tool'
    )) {
        $Rejected = $false
        try {
            [void](Resolve-ProjCommandExportPath `
                -DataRoot $DataRoot `
                -ProviderAddress $Address `
                -ProviderSpace module)
        } catch {
            $Rejected = $true
        }
        Assert-ProjCommandExportTest `
            -Condition $Rejected `
            -Message "unsafe Module provider address was accepted: '$Address'"
    }

    $ExternalRoot = Join-Path $TemporaryRoot 'external'
    $ReparseDataRoot = Join-Path $TemporaryRoot 'reparse-data'
    [void][IO.Directory]::CreateDirectory($ExternalRoot)
    [void][IO.Directory]::CreateDirectory($ReparseDataRoot)
    $ExternalSentinel = Join-Path $ExternalRoot 'sentinel.txt'
    [IO.File]::WriteAllText($ExternalSentinel, 'outside')
    $ModulesJunction = Join-Path $ReparseDataRoot 'modules'
    [void](New-Item `
        -ItemType Junction `
        -Path $ModulesJunction `
        -Target $ExternalRoot)
    try {
        $ReparseRejected = $false
        try {
            [void](Resolve-ProjCommandExportPath `
                -DataRoot $ReparseDataRoot `
                -ProviderAddress '.dev/setup')
        } catch {
            $ReparseRejected = $_.Exception.Message -like '*reparse point*'
        }
        Assert-ProjCommandExportTest `
            -Condition $ReparseRejected `
            -Message 'an intermediate command-data junction was accepted'
        Assert-ProjCommandExportTest `
            -Condition (
                [IO.File]::ReadAllText($ExternalSentinel) -ceq 'outside'
            ) `
            -Message 'an external junction target was modified'
    } finally {
        if ([IO.Directory]::Exists($ModulesJunction)) {
            [IO.Directory]::Delete($ModulesJunction)
        }
        $ModulesJunction = ''
    }

    Write-Host '[PASS] Proj command export layout test' `
        -ForegroundColor Green
} finally {
    if (-not [string]::IsNullOrWhiteSpace($ModulesJunction) -and
        [IO.Directory]::Exists($ModulesJunction)) {
        [IO.Directory]::Delete($ModulesJunction)
    }
    if ([IO.Directory]::Exists($TemporaryRoot)) {
        Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force
    }
}

$global:LASTEXITCODE = 0
