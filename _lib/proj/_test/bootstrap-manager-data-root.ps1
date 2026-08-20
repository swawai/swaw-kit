[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-ProjManagerDataRootTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Invoke-ProjManagerDataRootExpectedFailure {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)

    $Failed = $false
    $Message = ''
    try {
        [void](& $Action)
    } catch {
        $Failed = $true
        $Message = $_.Exception.Message
    }
    if (-not $Failed) {
        throw 'Assertion failed: the manager DataRoot operation unexpectedly succeeded'
    }
    return $Message
}

$ProjRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $ProjRoot '_runtime\manager-data-root.ps1')
$TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "swawkit-proj-manager-root-$([Guid]::NewGuid().ToString('N'))"
)

try {
    $FreshRoot = Join-Path $TemporaryRoot 'fresh\data\proj.swawkit'
    $FreshId = Initialize-ProjManagerDataRoot -DataRoot $FreshRoot
    $EntryIdPath = Join-Path $FreshRoot 'entry.id'
    [byte[]]$EntryIdBytes = [IO.File]::ReadAllBytes($EntryIdPath)
    Assert-ProjManagerDataRootTest `
        -Condition (
            $FreshId -cmatch '^[a-f0-9]{64}$' -and
            $EntryIdBytes.Count -eq 65 -and
            $EntryIdBytes[64] -eq 10 -and
            @(
                Get-ChildItem -LiteralPath $FreshRoot -Force |
                    ForEach-Object Name
            ).Count -eq 1 -and
            [IO.File]::Exists($EntryIdPath)
        ) `
        -Message 'fresh manager initialization was not one atomic root with one valid entry.id'
    Assert-ProjManagerDataRootTest `
        -Condition (
            (Initialize-ProjManagerDataRoot -DataRoot $FreshRoot) -ceq
                $FreshId
        ) `
        -Message 'an existing valid manager root did not preserve its identity'
    Assert-ProjManagerDataRootTest `
        -Condition (@(
            Get-ChildItem `
                -LiteralPath (Split-Path $FreshRoot -Parent) `
                -Force |
                Where-Object Name -CLike '.proj.swawkit.*.tmp'
        ).Count -eq 0) `
        -Message 'fresh manager initialization leaked a staging directory'

    $LegacyRoot = Join-Path $TemporaryRoot 'legacy\data\proj.swawkit'
    [void][IO.Directory]::CreateDirectory($LegacyRoot)
    $LegacyDocumentPath = Join-Path $LegacyRoot '_entry.json'
    $LegacyDocument = '{"legacy":true}'
    [IO.File]::WriteAllText(
        $LegacyDocumentPath,
        $LegacyDocument,
        [Text.UTF8Encoding]::new($false)
    )
    $Failure = Invoke-ProjManagerDataRootExpectedFailure {
        Initialize-ProjManagerDataRoot -DataRoot $LegacyRoot
    }
    Assert-ProjManagerDataRootTest `
        -Condition (
            $Failure.Contains('-MigrateLegacyManagerDataRoot') -and
            -not [IO.File]::Exists((Join-Path $LegacyRoot 'entry.id')) -and
            [IO.File]::ReadAllText($LegacyDocumentPath) -ceq $LegacyDocument
        ) `
        -Message 'ordinary Bootstrap silently claimed an existing legacy manager root'
    $MigratedId = Initialize-ProjManagerDataRoot `
        -DataRoot $LegacyRoot `
        -MigrateLegacy
    Assert-ProjManagerDataRootTest `
        -Condition (
            $MigratedId -cmatch '^[a-f0-9]{64}$' -and
            [IO.File]::ReadAllText($LegacyDocumentPath) -ceq $LegacyDocument -and
            @(
                Get-ChildItem -LiteralPath $LegacyRoot -Force |
                    Where-Object Name -CLike '.entry.id.*.tmp'
            ).Count -eq 0
        ) `
        -Message 'explicit migration did not add only a stable entry.id'

    $InvalidRoot = Join-Path $TemporaryRoot 'invalid\data\proj.swawkit'
    [void][IO.Directory]::CreateDirectory($InvalidRoot)
    $InvalidEntryIdPath = Join-Path $InvalidRoot 'entry.id'
    [IO.File]::WriteAllText(
        $InvalidEntryIdPath,
        "invalid`n",
        [Text.ASCIIEncoding]::new()
    )
    [void](Invoke-ProjManagerDataRootExpectedFailure {
        Initialize-ProjManagerDataRoot -DataRoot $InvalidRoot
    })
    [void](Invoke-ProjManagerDataRootExpectedFailure {
        Initialize-ProjManagerDataRoot `
            -DataRoot $InvalidRoot `
            -MigrateLegacy
    })
    Assert-ProjManagerDataRootTest `
        -Condition ([IO.File]::ReadAllText($InvalidEntryIdPath) -ceq "invalid`n") `
        -Message 'migration overwrote an invalid existing entry.id'
} finally {
    if ([IO.Directory]::Exists($TemporaryRoot)) {
        [IO.Directory]::Delete($TemporaryRoot, $true)
    }
}

Write-Host '[PASS] Proj manager DataRoot initialization' -ForegroundColor Green
$global:LASTEXITCODE = 0
