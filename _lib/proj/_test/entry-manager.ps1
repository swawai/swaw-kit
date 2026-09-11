[CmdletBinding()]
param(
    [string]$LauncherPath = '',
    [string]$CorePath = '',
    [string]$HostPath = '',
    [string]$ModulePath = '',
    [string]$DevPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-ProjEntryManager {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Invoke-ProjEntryManager {
    param(
        [Parameter(Mandatory = $true)][string]$EntryPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $PreviousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Output = @(& $EntryPath @Arguments 2>&1)
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousPreference
    }
    return [pscustomobject][ordered]@{
        ExitCode = [int]$ExitCode
        Text = [string]::Join(
            [Environment]::NewLine,
            [string[]]@($Output | ForEach-Object { [string]$_ })
        )
    }
}

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $PSScriptRoot '_lib\runtime-fixture.ps1')
$Artifacts = Resolve-ProjCandidateRuntimeArtifacts `
    -LauncherPath $LauncherPath `
    -CorePath $CorePath `
    -HostPath $HostPath `
    -ModulePath $ModulePath `
    -DevPath $DevPath
$TemporaryRoot = Join-Path $RepoRoot (
    "data\_test\swawkit-proj-entry-manager-$([Guid]::NewGuid().ToString('N'))"
)

try {
    $Runtime = New-ProjCandidateRuntimeFixture `
        -RuntimeHome (Join-Path $TemporaryRoot 'runtime-home') `
        -LauncherPath $Artifacts.LauncherPath `
        -CorePath $Artifacts.CorePath `
        -HostPath $Artifacts.HostPath `
        -ModulePath $Artifacts.ModulePath `
        -DevPath $Artifacts.DevPath
    $ManagerEntry = Add-ProjCandidateRuntimeEntry `
        -Runtime $Runtime `
        -RelativePath 'swawkit.exe'
    $FixtureHome = [string]$Runtime.Home
    $EntryPath = Join-Path $FixtureHome 'proj1.exe'
    $DataRoot = Join-Path $FixtureHome 'data\proj.proj1'
    $RuntimeRoot = Join-Path $DataRoot 'runtime'
    $CurrentPath = Join-Path $RuntimeRoot 'current'

    $Created = Invoke-ProjEntryManager `
        -EntryPath $ManagerEntry `
        -Arguments @('.entry/instances/create', 'proj1', '--json')
    Assert-ProjEntryManager `
        -Condition ($Created.ExitCode -eq 0) `
        -Message "manager create failed: $($Created.Text)"
    $CreatedDocument = $Created.Text | ConvertFrom-Json
    Assert-ProjEntryManager `
        -Condition (
            $CreatedDocument.protocol -ceq 'swawkit.entry-instance-mutation/v2' -and
            $CreatedDocument.operation -ceq 'create' -and
            $CreatedDocument.changed -eq $true -and
            $CreatedDocument.entry.entryName -ceq 'proj1' -and
            $CreatedDocument.entry.status -ceq 'ready' -and
            $CreatedDocument.entry.entryFile -ceq $EntryPath -and
            $CreatedDocument.entry.dataRoot -ceq $DataRoot -and
            @($CreatedDocument.entry.issues).Count -eq 0
        ) `
        -Message 'manager create returned an unexpected mutation document'

    Assert-ProjEntryManager `
        -Condition (
            [IO.File]::Exists($EntryPath) -and
            -not [IO.File]::Exists((Join-Path $DataRoot 'entry.id')) -and
            [IO.File]::Exists((Join-Path $DataRoot 'launcher.json')) -and
            [IO.File]::Exists($CurrentPath)
        ) `
        -Message 'manager create did not publish the complete Entry boundary'
    $LauncherReceipt = Get-Content `
        -LiteralPath (Join-Path $DataRoot 'launcher.json') `
        -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    $LauncherDigest = (Get-FileHash -LiteralPath $EntryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-ProjEntryManager `
        -Condition (
            $LauncherReceipt.schema -ceq 'swawkit.entry-launcher/v1' -and
            $LauncherReceipt.entryName -ceq 'proj1' -and
            [uint64]$LauncherReceipt.length -eq [uint64](Get-Item -LiteralPath $EntryPath).Length -and
            $LauncherReceipt.sha256 -ceq $LauncherDigest
        ) `
        -Message 'manager create did not bind the Launcher receipt to proj1 and its exact bytes'
    $ReleaseId = [IO.File]::ReadAllText(
        $CurrentPath,
        [Text.Encoding]::UTF8
    ).Trim()
    Assert-ProjEntryManager `
        -Condition (
            $ReleaseId -ceq [string]$Runtime.ReleaseId -and
            $CreatedDocument.entry.releaseId -ceq $ReleaseId -and
            [IO.Directory]::Exists((Join-Path $RuntimeRoot "releases\$ReleaseId"))
        ) `
        -Message 'manager create did not publish a coherent Runtime Release'

    $Repeated = Invoke-ProjEntryManager `
        -EntryPath $ManagerEntry `
        -Arguments @('.entry/instances/create', 'proj1', '--json')
    Assert-ProjEntryManager `
        -Condition ($Repeated.ExitCode -eq 0) `
        -Message "idempotent manager create failed: $($Repeated.Text)"
    $RepeatedDocument = $Repeated.Text | ConvertFrom-Json
    Assert-ProjEntryManager `
        -Condition (
            $RepeatedDocument.protocol -ceq 'swawkit.entry-instance-mutation/v2' -and
            $RepeatedDocument.operation -ceq 'create' -and
            $RepeatedDocument.changed -eq $false -and
            $RepeatedDocument.entry.status -ceq 'ready' -and
            -not [IO.File]::Exists((Join-Path $DataRoot 'entry.id'))
        ) `
        -Message 'repeated manager create was not idempotent'

    $EntryStatus = Invoke-ProjEntryManager `
        -EntryPath $EntryPath `
        -Arguments @('.entry', '--json')
    Assert-ProjEntryManager `
        -Condition ($EntryStatus.ExitCode -eq 0) `
        -Message "created Entry did not start through Launcher/Core: $($EntryStatus.Text)"
    $EntryStatusDocument = $EntryStatus.Text | ConvertFrom-Json
    Assert-ProjEntryManager `
        -Condition (
            $EntryStatusDocument.protocol -ceq 'swawkit.entry-config-state/v1' -and
            $EntryStatusDocument.status -ceq 'default' -and
            $EntryStatusDocument.config.language -ceq 'zh-CN' -and
            $null -eq $EntryStatusDocument.config.projectRoot
        ) `
        -Message 'created Entry did not expose its valid unbound default config'

    $Denied = Invoke-ProjEntryManager `
        -EntryPath $EntryPath `
        -Arguments @('.entry/instances', '--json')
    Assert-ProjEntryManager `
        -Condition (
            $Denied.ExitCode -ne 0 -and
            $Denied.Text.Contains(
                'Entry lifecycle operations are restricted to the swawkit manager Entry'
            )
        ) `
        -Message 'an ordinary Entry was allowed to invoke a manager-only command'
} finally {
    Remove-ProjCandidateRuntimeFixture -Path $TemporaryRoot
}

Write-Host '[PASS] Proj Entry Manager lifecycle' -ForegroundColor Green
$global:LASTEXITCODE = 0
