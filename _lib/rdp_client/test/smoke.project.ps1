[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = New-Object Text.UTF8Encoding($false)

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$TemplateEntry = Join-Path $RepoRoot 'Favorites\template.rdp1.cmd'
$EntryName = '.rdp-project-test-' + [Guid]::NewGuid().ToString('N') + '.cmd'
$Entry = Join-Path $RepoRoot $EntryName
$CommandName = [IO.Path]::GetFileNameWithoutExtension($Entry)
$ManagedName = 'managed-' + [Guid]::NewGuid().ToString('N').Substring(0, 10)
$ExternalPath = Join-Path (
    (Join-Path $RepoRoot 'data\rdp-client\project-test-external')
) ([Guid]::NewGuid().ToString('N'))
$ArchiveScratch = Join-Path (
    (Join-Path $RepoRoot 'data\rdp-client\project-test-archive')
) ([Guid]::NewGuid().ToString('N'))

function Invoke-ProjectTestEntry {
    param([string[]]$Arguments, [int]$ExpectedExitCode)

    $OldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Output = (& $Entry @Arguments 2>&1 | Out-String)
        $ExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $OldPreference }
    if ($ExitCode -ne $ExpectedExitCode) {
        throw "Unexpected exit for '$($Arguments -join ' ')': $ExitCode`n$Output"
    }
    return $Output
}

try {
    [IO.File]::Copy($TemplateEntry, $Entry)
    . (Join-Path $PSScriptRoot '..\project-core.ps1')
    . (Join-Path $PSScriptRoot '..\project-archive.ps1')

    $Help = Invoke-ProjectTestEntry `
        -Arguments @('.project', '--help') `
        -ExpectedExitCode 0
    foreach ($Text in @('.project create', '.project info', '.project prompt',
        '.<session-id> exec', 'run.ps1', 'absolute')) {
        if (-not $Help.Contains($Text)) { throw "Project help is missing '$Text'." }
    }

    $EmptyInfo = Invoke-ProjectTestEntry `
        -Arguments @('.project', 'info') `
        -ExpectedExitCode 0
    if (-not $EmptyInfo.Contains('Managed projects:') -or
        -not $EmptyInfo.Contains('Collected runs:') -or
        -not $EmptyInfo.Contains('data\ is local and ignored')) {
        throw "Project info does not explain its local roots.`n$EmptyInfo"
    }

    $Created = Invoke-ProjectTestEntry `
        -Arguments @('.project', 'create', $ManagedName) `
        -ExpectedExitCode 0
    $Managed = Resolve-RdpClientProject -EntryFile $Entry -Value $ManagedName
    if (-not [IO.File]::Exists($Managed.EntryPoint) -or
        -not $Created.Contains($Managed.Path)) {
        throw 'Managed project creation did not create or report run.ps1.'
    }
    $Scaffold = [IO.File]::ReadAllText($Managed.EntryPoint)
    foreach ($Text in @('RDP_EXEC_OUTPUT_DIR', 'RDP_EXEC_SESSION_ID',
        'RDP_EXEC_WORK_DIR')) {
        if (-not $Scaffold.Contains($Text)) {
            throw "Project scaffold is missing '$Text'."
        }
    }
    $Duplicate = Invoke-ProjectTestEntry `
        -Arguments @('.project', 'create', $ManagedName) `
        -ExpectedExitCode 1
    if (-not $Duplicate.Contains('already exists')) {
        throw 'Project create must refuse overwrite without a force mode.'
    }
    $Info = Invoke-ProjectTestEntry `
        -Arguments @('.project', 'info', $ManagedName) `
        -ExpectedExitCode 0
    if (-not $Info.Contains('Kind:        managed') -or
        -not $Info.Contains('State:       READY')) {
        throw "Managed project info is incomplete.`n$Info"
    }
    $Prompt = Invoke-ProjectTestEntry `
        -Arguments @('.project', 'prompt', $ManagedName) `
        -ExpectedExitCode 0
    if (-not $Prompt.Contains($Managed.Path) -or
        -not $Prompt.Contains('Write all returned files')) {
        throw "Project prompt is not agent-ready.`n$Prompt"
    }

    $External = Invoke-ProjectTestEntry `
        -Arguments @('.project', 'create', $ExternalPath) `
        -ExpectedExitCode 0
    if (-not [IO.File]::Exists((Join-Path $ExternalPath 'run.ps1')) -or
        -not $External.Contains($ExternalPath)) {
        throw 'Absolute external project creation failed.'
    }

    foreach ($Invalid in @('.\relative', '..\relative', 'a\b', 'CON', 'name/child')) {
        $Rejected = Invoke-ProjectTestEntry `
            -Arguments @('.project', 'create', $Invalid) `
            -ExpectedExitCode 1
        if (-not $Rejected.Contains('absolute path or a safe name')) {
            throw "Unsafe project target was not rejected: $Invalid"
        }
    }
    foreach ($NotAbsolute in @('C:relative', '\root-relative')) {
        $Rejected = Invoke-ProjectTestEntry `
            -Arguments @('.project', 'create', $NotAbsolute) `
            -ExpectedExitCode 1
        if (-not $Rejected.Contains('fully absolute')) {
            throw "Drive-relative project path was not rejected: $NotAbsolute"
        }
    }
    $RemovedScript = Invoke-ProjectTestEntry `
        -Arguments @('.2', 'script', 'workflow.ps1') `
        -ExpectedExitCode 1
    if (-not $RemovedScript.Contains('.<session-id> exec')) {
        throw 'The removed session script command should show exec usage.'
    }
    $RelativeExec = Invoke-ProjectTestEntry `
        -Arguments @('.2', 'exec', '.\relative') `
        -ExpectedExitCode 1
    if (-not $RelativeExec.Contains('absolute path or a safe name')) {
        throw 'Session exec must reject a relative project before remote access.'
    }

    $ArchiveSource = Join-Path $ArchiveScratch 'source'
    $ArchivePath = Join-Path $ArchiveScratch 'project.zip'
    $ExpandedPath = Join-Path $ArchiveScratch 'expanded'
    [IO.Directory]::CreateDirectory((Join-Path $ArchiveSource 'nested')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $ArchiveSource 'run.ps1'), 'exit 0')
    [IO.File]::WriteAllText((Join-Path $ArchiveSource 'nested\value.txt'), 'value')
    New-RdpClientProjectArchive `
        -ProjectPath $ArchiveSource `
        -ArchivePath $ArchivePath
    Expand-RdpClientArtifactArchive `
        -ArchivePath $ArchivePath `
        -DestinationPath $ExpandedPath
    if ([IO.File]::ReadAllText((Join-Path $ExpandedPath 'nested\value.txt')) -ne
        'value') {
        throw 'Project archive round-trip did not preserve a nested artifact.'
    }

    Write-Host 'rdp client project tests: PASS' -ForegroundColor Green
} finally {
    if ([IO.File]::Exists($Entry)) { [IO.File]::Delete($Entry) }
    foreach ($Path in @(
        $ExternalPath,
        $ArchiveScratch,
        (Join-Path (Get-RdpClientEntryDataDirectory -EntryFile $Entry) 'projects'),
        (Join-Path (Get-RdpClientEntryDataDirectory -EntryFile $Entry) 'runs')
    )) {
        if ([IO.Directory]::Exists($Path)) {
            [IO.Directory]::Delete($Path, $true)
        }
    }
    $EntryData = Get-RdpClientEntryDataDirectory -EntryFile $Entry
    if ([IO.Directory]::Exists($EntryData) -and
        @(Get-ChildItem -LiteralPath $EntryData -Force).Count -eq 0) {
        [IO.Directory]::Delete($EntryData)
    }
}
