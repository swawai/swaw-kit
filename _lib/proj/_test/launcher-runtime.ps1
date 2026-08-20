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

function Assert-LauncherRuntime {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Launcher runtime assertion failed: $Message"
    }
}

function Invoke-Launcher {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Collections.IDictionary]$EnvironmentVariables = @{}
    )

    $PreviousEnvironment = @{}
    foreach ($Pair in $EnvironmentVariables.GetEnumerator()) {
        $Name = [string]$Pair.Key
        $PreviousEnvironment[$Name] = [Environment]::GetEnvironmentVariable(
            $Name,
            [EnvironmentVariableTarget]::Process
        )
        [Environment]::SetEnvironmentVariable(
            $Name,
            [string]$Pair.Value,
            [EnvironmentVariableTarget]::Process
        )
    }
    $Process = $null
    try {
        $StartInfo = [Diagnostics.ProcessStartInfo]::new()
        $StartInfo.FileName = $Executable
        $StartInfo.Arguments = $Arguments
        $StartInfo.WorkingDirectory = $WorkingDirectory
        $StartInfo.UseShellExecute = $false
        $StartInfo.CreateNoWindow = $true
        $StartInfo.RedirectStandardOutput = $true
        $StartInfo.RedirectStandardError = $true
        $StartInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $StartInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $Process = [Diagnostics.Process]::new()
        $Process.StartInfo = $StartInfo
        if (-not $Process.Start()) {
            throw "Launcher process did not start: $Executable"
        }
        $StandardOutput = $Process.StandardOutput.ReadToEnd()
        $StandardError = $Process.StandardError.ReadToEnd()
        $Process.WaitForExit()
        return [pscustomobject][ordered]@{
            ExitCode = [int]$Process.ExitCode
            StandardOutput = $StandardOutput
            StandardError = $StandardError
        }
    } finally {
        if ($null -ne $Process) {
            $Process.Dispose()
        }
        foreach ($Pair in $PreviousEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable(
                [string]$Pair.Key,
                $Pair.Value,
                [EnvironmentVariableTarget]::Process
            )
        }
    }
}

function Write-HexRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )
    [void][IO.Directory]::CreateDirectory((Split-Path -Path $Path -Parent))
    [IO.File]::WriteAllText(
        $Path,
        ($Value + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function Add-EntryRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$EntryHome,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$EntryId,
        [Parameter(Mandatory = $true)][string]$ReleaseId
    )
    $DataRoot = Join-Path $EntryHome "data\proj.$Name"
    $RuntimeRoot = Join-Path $DataRoot 'runtime'
    $ReleaseRoot = Join-Path $RuntimeRoot "releases\$ReleaseId"
    [void][IO.Directory]::CreateDirectory($ReleaseRoot)
    Write-HexRecord -Path (Join-Path $DataRoot 'entry.id') -Value $EntryId
    Write-HexRecord -Path (Join-Path $RuntimeRoot 'current') -Value $ReleaseId
    [IO.File]::Copy(
        (Join-Path ([Environment]::SystemDirectory) 'cmd.exe'),
        (Join-Path $ReleaseRoot 'swawkit-proj.exe'),
        $false
    )
    return [pscustomobject]@{
        DataRoot = $DataRoot
        RuntimeRoot = $RuntimeRoot
        ReleaseRoot = $ReleaseRoot
    }
}

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
    . (Join-Path $RepoRoot '_lib\proj\_bootstrap\layout.ps1')
    $Layout = Get-ProjBootstrapLayout
    $LauncherPath = $Layout.LauncherCandidatePath
    if (-not [IO.File]::Exists($LauncherPath)) {
        & (Join-Path $RepoRoot '_lib\proj\build.ps1') | Out-Host
    }
}
$LauncherPath = [IO.Path]::GetFullPath($LauncherPath)
if (-not [IO.File]::Exists($LauncherPath)) {
    throw "Launcher candidate does not exist: $LauncherPath"
}

$TemporaryRoot = Join-Path $RepoRoot (
    "data\_test\swawkit-proj-launcher-$([Guid]::NewGuid().ToString('N'))"
)
$EntryHome = Join-Path $TemporaryRoot 'home'
$Invocation = Join-Path $TemporaryRoot 'invocation'
$AlphaId = 'a' * 64
$BetaId = 'b' * 64
$AlphaReleaseId = '1' * 64
$BetaReleaseId = '2' * 64
$Command = '/d /s /c "set SWAWKIT_PROJ_CORE_LAUNCH & echo CORE=%CMDCMDLINE% & exit /b 37"'
$ReparsePaths = [Collections.Generic.List[string]]::new()

try {
    [void][IO.Directory]::CreateDirectory($EntryHome)
    [void][IO.Directory]::CreateDirectory($Invocation)
    $Alpha = Add-EntryRuntime `
        -EntryHome $EntryHome `
        -Name 'alpha' `
        -EntryId $AlphaId `
        -ReleaseId $AlphaReleaseId
    $Beta = Add-EntryRuntime `
        -EntryHome $EntryHome `
        -Name 'beta' `
        -EntryId $BetaId `
        -ReleaseId $BetaReleaseId
    $AlphaEntry = Join-Path $EntryHome 'alpha.exe'
    $BetaEntry = Join-Path $EntryHome 'beta.exe'
    [IO.File]::Copy($LauncherPath, $AlphaEntry, $false)
    [IO.File]::Copy($LauncherPath, $BetaEntry, $false)

    $AlphaRun = Invoke-Launcher `
        -Executable $AlphaEntry `
        -Arguments $Command `
        -WorkingDirectory $Invocation
    $BetaRun = Invoke-Launcher `
        -Executable $BetaEntry `
        -Arguments $Command `
        -WorkingDirectory $Invocation
    Assert-LauncherRuntime `
        -Condition (
            $AlphaRun.ExitCode -eq 37 -and
            $AlphaRun.StandardOutput.Contains(
                "SWAWKIT_PROJ_CORE_LAUNCH_PROTOCOL=4"
            ) -and
            $AlphaRun.StandardOutput.Contains(
                "SWAWKIT_PROJ_CORE_LAUNCH_ENTRY_ID=$AlphaId"
            ) -and
            $AlphaRun.StandardOutput.Contains(
                "SWAWKIT_PROJ_CORE_LAUNCH_ENTRY_FILE=$AlphaEntry"
            ) -and
            -not $AlphaRun.StandardOutput.Contains('ENTRY_FILE=\\?\') -and
            $AlphaRun.StandardOutput.Contains($AlphaReleaseId) -and
            -not $AlphaRun.StandardOutput.Contains($BetaReleaseId)
        ) `
        -Message "alpha did not use only its own selector: $($AlphaRun.StandardOutput)"
    Assert-LauncherRuntime `
        -Condition (
            $BetaRun.ExitCode -eq 37 -and
            $BetaRun.StandardOutput.Contains(
                "SWAWKIT_PROJ_CORE_LAUNCH_ENTRY_ID=$BetaId"
            ) -and
            $BetaRun.StandardOutput.Contains($BetaReleaseId) -and
            -not $BetaRun.StandardOutput.Contains($AlphaReleaseId)
        ) `
        -Message "beta did not use only its own selector: $($BetaRun.StandardOutput)"

    $WorkerRun = Invoke-Launcher `
        -Executable $AlphaEntry `
        -Arguments $Command `
        -WorkingDirectory $Invocation `
        -EnvironmentVariables @{
            SWAWKIT_PROJ_CORE_LAUNCH_WORKER_PROTOCOL = '2'
        }
    Assert-LauncherRuntime `
        -Condition (
            $WorkerRun.ExitCode -eq 37 -and
            $WorkerRun.StandardOutput.Contains(
                'SWAWKIT_PROJ_CORE_LAUNCH_MODE=worker'
            ) -and
            -not $WorkerRun.StandardOutput.Contains(
                'SWAWKIT_PROJ_CORE_LAUNCH_WORKER_PROTOCOL='
            )
        ) `
        -Message 'Launcher did not consume the worker transition declaration'

    $InvalidWorkerRun = Invoke-Launcher `
        -Executable $AlphaEntry `
        -Arguments $Command `
        -WorkingDirectory $Invocation `
        -EnvironmentVariables @{
            SWAWKIT_PROJ_CORE_LAUNCH_WORKER_PROTOCOL = 'invalid'
        }
    Assert-LauncherRuntime `
        -Condition (
            $InvalidWorkerRun.ExitCode -eq 1 -and
            $InvalidWorkerRun.StandardError.Contains(
                'Web worker launch declaration'
            )
        ) `
        -Message 'Launcher accepted an invalid worker transition declaration'

    $BootstrapMarker = Join-Path $EntryHome 'bootstrap-ran.txt'
    $BootstrapPath = Join-Path $EntryHome '_lib\proj\bootstrap.ps1'
    [void][IO.Directory]::CreateDirectory((Split-Path $BootstrapPath -Parent))
    [IO.File]::WriteAllText(
        $BootstrapPath,
        "[IO.File]::WriteAllText('$($BootstrapMarker.Replace("'", "''"))', 'ran')`n",
        [Text.UTF8Encoding]::new($false)
    )
    $MissingEntry = Join-Path $EntryHome 'missing.exe'
    [IO.File]::Copy($LauncherPath, $MissingEntry, $false)
    $LegacyRelease = '9' * 64
    $LegacyCore = Join-Path $EntryHome (
        "_lib\proj\_bin\releases\$LegacyRelease\swawkit-proj.exe"
    )
    [void][IO.Directory]::CreateDirectory((Split-Path $LegacyCore -Parent))
    [IO.File]::Copy(
        (Join-Path ([Environment]::SystemDirectory) 'cmd.exe'),
        $LegacyCore,
        $false
    )
    Write-HexRecord `
        -Path (Join-Path $EntryHome '_lib\proj\_bin\current') `
        -Value $LegacyRelease
    $MissingRun = Invoke-Launcher `
        -Executable $MissingEntry `
        -Arguments $Command `
        -WorkingDirectory $Invocation
    Assert-LauncherRuntime `
        -Condition (
            $MissingRun.ExitCode -eq 1 -and
            $MissingRun.StandardError.Contains('Entry Runtime is missing or invalid') -and
            -not [IO.File]::Exists($BootstrapMarker)
        ) `
        -Message 'ordinary Entry used Bootstrap or the legacy shared selector'

    $ManagerHome = Join-Path $TemporaryRoot 'manager-home'
    $ManagerEntry = Join-Path $ManagerHome 'SwAwKiT.exe'
    $ManagerBootstrap = Join-Path $ManagerHome '_lib\proj\bootstrap.ps1'
    $ManagerMarker = Join-Path $ManagerHome 'bootstrap-ran.txt'
    $ManagerEntryId = 'c' * 64
    [void][IO.Directory]::CreateDirectory((Split-Path $ManagerBootstrap -Parent))
    [IO.File]::Copy($LauncherPath, $ManagerEntry, $false)
    $ManagerFixture = @"
`$ErrorActionPreference = 'Stop'
`$ManagerRoot = [IO.Path]::GetFullPath((Join-Path `$PSScriptRoot '..\..'))
`$DataRoot = Join-Path `$ManagerRoot 'data\proj.swawkit'
`$RuntimeRoot = Join-Path `$DataRoot 'runtime'
`$ReleaseId = '3' * 64
`$ReleaseRoot = Join-Path `$RuntimeRoot "releases\`$ReleaseId"
[void][IO.Directory]::CreateDirectory(`$ReleaseRoot)
[IO.File]::WriteAllText((Join-Path `$DataRoot 'entry.id'), ('$ManagerEntryId' + [char]10), [Text.UTF8Encoding]::new(`$false))
[IO.File]::WriteAllText((Join-Path `$RuntimeRoot 'current'), (`$ReleaseId + [char]10), [Text.UTF8Encoding]::new(`$false))
[IO.File]::Copy((Join-Path ([Environment]::SystemDirectory) 'cmd.exe'), (Join-Path `$ReleaseRoot 'swawkit-proj.exe'), `$false)
[IO.File]::WriteAllText('$($ManagerMarker.Replace("'", "''"))', 'ran')
"@
    [IO.File]::WriteAllText(
        $ManagerBootstrap,
        $ManagerFixture,
        [Text.UTF8Encoding]::new($false)
    )
    $ManagerRun = Invoke-Launcher `
        -Executable $ManagerEntry `
        -Arguments $Command `
        -WorkingDirectory $Invocation
    Assert-LauncherRuntime `
        -Condition (
            $ManagerRun.ExitCode -eq 37 -and
            [IO.File]::Exists($ManagerMarker) -and
            $ManagerRun.StandardOutput.Contains(
                "SWAWKIT_PROJ_CORE_LAUNCH_ENTRY_ID=$ManagerEntryId"
            )
        ) `
        -Message "manager cold Bootstrap failed: $($ManagerRun.StandardError)"

    $MalformedHome = Join-Path $TemporaryRoot 'malformed-home'
    $MalformedEntry = Join-Path $MalformedHome 'swawkit.exe'
    [void][IO.Directory]::CreateDirectory($MalformedHome)
    [IO.File]::Copy($LauncherPath, $MalformedEntry, $false)
    $Malformed = Add-EntryRuntime `
        -EntryHome $MalformedHome `
        -Name 'swawkit' `
        -EntryId ('d' * 64) `
        -ReleaseId ('4' * 64)
    [IO.File]::WriteAllText(
        (Join-Path $Malformed.DataRoot 'entry.id'),
        (('D' * 64) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    $MalformedRun = Invoke-Launcher `
        -Executable $MalformedEntry `
        -Arguments $Command `
        -WorkingDirectory $Invocation
    Assert-LauncherRuntime `
        -Condition (
            $MalformedRun.ExitCode -eq 1 -and
            $MalformedRun.StandardError.Contains('identity is malformed or unsafe')
        ) `
        -Message 'Launcher accepted a malformed entry.id'

    $ReparseName = 'reparse'
    $ReparseEntry = Join-Path $EntryHome "$ReparseName.exe"
    $ReparseDataRoot = Join-Path $EntryHome "data\proj.$ReparseName"
    $ExternalFixture = Add-EntryRuntime `
        -EntryHome $TemporaryRoot `
        -Name 'external-data-root' `
        -EntryId ('e' * 64) `
        -ReleaseId ('5' * 64)
    $ExternalDataRoot = $ExternalFixture.DataRoot
    [IO.File]::Copy($LauncherPath, $ReparseEntry, $false)
    [void][IO.Directory]::CreateDirectory((Split-Path $ReparseDataRoot -Parent))
    [void](New-Item -ItemType Junction -Path $ReparseDataRoot -Target $ExternalDataRoot)
    $ReparsePaths.Add($ReparseDataRoot)
    $ReparseRun = Invoke-Launcher `
        -Executable $ReparseEntry `
        -Arguments $Command `
        -WorkingDirectory $Invocation
    Assert-LauncherRuntime `
        -Condition (
            $ReparseRun.ExitCode -eq 1 -and
            $ReparseRun.StandardError.Contains('identity is malformed or unsafe')
        ) `
        -Message 'Launcher followed a reparse-point DataRoot'

    $AncestorHome = Join-Path $TemporaryRoot 'ancestor-home'
    $AncestorEntry = Join-Path $AncestorHome 'ancestor.exe'
    $AncestorData = Join-Path $AncestorHome 'data'
    $AncestorExternalHome = Join-Path $TemporaryRoot 'ancestor-external'
    $AncestorFixture = Add-EntryRuntime `
        -EntryHome $AncestorExternalHome `
        -Name 'ancestor' `
        -EntryId ('f' * 64) `
        -ReleaseId ('6' * 64)
    [void][IO.Directory]::CreateDirectory($AncestorHome)
    [IO.File]::Copy($LauncherPath, $AncestorEntry, $false)
    [void](New-Item `
        -ItemType Junction `
        -Path $AncestorData `
        -Target (Split-Path -Path $AncestorFixture.DataRoot -Parent))
    $ReparsePaths.Add($AncestorData)
    $AncestorRun = Invoke-Launcher `
        -Executable $AncestorEntry `
        -Arguments $Command `
        -WorkingDirectory $Invocation
    Assert-LauncherRuntime `
        -Condition (
            $AncestorRun.ExitCode -eq 1 -and
            $AncestorRun.StandardError.Contains('identity is malformed or unsafe')
        ) `
        -Message 'Launcher followed a reparse-point data ancestor'

    $NestedRun = Invoke-Launcher `
        -Executable $AlphaEntry `
        -Arguments $Command `
        -WorkingDirectory $Invocation `
        -EnvironmentVariables @{ SWAWKIT_PROJ_CORE_COMMAND_PROTOCOL = '1' }
    Assert-LauncherRuntime `
        -Condition (
            $NestedRun.ExitCode -eq 1 -and
            $NestedRun.StandardError.Contains('inside another Entry command')
        ) `
        -Message 'Launcher accepted nested Entry startup'
} finally {
    foreach ($ReparsePath in $ReparsePaths) {
        if ([IO.Directory]::Exists($ReparsePath) -and
            ([IO.File]::GetAttributes($ReparsePath) -band
                [IO.FileAttributes]::ReparsePoint)) {
            [IO.Directory]::Delete($ReparsePath)
        }
    }
    if ([IO.Directory]::Exists($TemporaryRoot) -and
        $TemporaryRoot.StartsWith(
            (Join-Path $RepoRoot 'data\_test') + '\',
            [StringComparison]::OrdinalIgnoreCase
        )) {
        [IO.Directory]::Delete($TemporaryRoot, $true)
    }
}

Write-Host '[PASS] Proj native Launcher runtime' -ForegroundColor Green
$global:LASTEXITCODE = 0
