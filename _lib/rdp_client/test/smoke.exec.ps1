[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = New-Object Text.UTF8Encoding($false)
$Utf8 = New-Object Text.UTF8Encoding($false)

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$RuntimeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ScratchRoot = Join-Path (Join-Path $RepoRoot 'data\rdp-client') (
    '.exec-test-' + [Guid]::NewGuid().ToString('N')
)
$Runtime = Join-Path $ScratchRoot '_lib\rdp_client'
$Entry = Join-Path $ScratchRoot 'account.rdp.cmd'
$SshEntry = Join-Path $ScratchRoot 'peer.ssh.cmd'
$Project = Join-Path $ScratchRoot 'project'
$ArtifactSource = Join-Path $ScratchRoot 'fake-artifacts'
$Capture = Join-Path $ScratchRoot 'request.json'

function Invoke-ExecTestCommand {
    param([string[]]$Arguments, [int]$ExpectedExitCode)

    $OldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Output = (& PowerShell.exe `
            -NoLogo -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $Runtime 'exec.ps1') @Arguments 2>&1 | Out-String)
        $ExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $OldPreference }
    if ($ExitCode -ne $ExpectedExitCode) {
        throw "Unexpected exec exit $ExitCode.`n$Output"
    }
    return $Output
}

try {
    [IO.Directory]::CreateDirectory($Runtime) | Out-Null
    [IO.Directory]::CreateDirectory($Project) | Out-Null
    [IO.Directory]::CreateDirectory($ArtifactSource) | Out-Null
    [IO.File]::WriteAllText($Entry, 'entry')
    [IO.File]::WriteAllText($SshEntry, 'ssh')
    [IO.File]::WriteAllText((Join-Path $Project 'run.ps1'), 'exit 0')
    [IO.File]::WriteAllText((Join-Path $ArtifactSource 'result.txt'), 'artifact')
    foreach ($Name in @(
        'exec.ps1',
        'exec.remote.ps1',
        'exec-task.remote.ps1',
        'helper.ps1',
        'psexec-lib.remote.ps1',
        'project-core.ps1',
        'project-archive.ps1'
    )) {
        [IO.File]::Copy(
            (Join-Path $RuntimeRoot $Name),
            (Join-Path $Runtime $Name)
        )
    }

    $FakeEntry = @'
function Read-RdpClientEntryDocument {
    return [pscustomobject]@{
        Username = 'administrator'
        FullAddress = [pscustomobject]@{ Host = '192.0.2.1' }
    }
}
function Resolve-RdpClientSessionId {
    param([string]$Value)
    return [uint32]$Value
}
'@
    [IO.File]::WriteAllText(
        (Join-Path $Runtime 'entry.ps1'),
        $FakeEntry,
        $Utf8
    )
    $FakePeer = @'
function New-RdpClientTimeoutBudget {
    param([int]$TimeoutSeconds)
    return [pscustomobject]@{
        TimeoutSeconds = $TimeoutSeconds
        Stopwatch = [Diagnostics.Stopwatch]::StartNew()
    }
}
function Get-RdpClientTimeoutBudgetRemainingSeconds {
    param($Budget, [string]$Operation)
    return [Math]::Max(1, $Budget.TimeoutSeconds - [int]$Budget.Stopwatch.Elapsed.TotalSeconds)
}
function Resolve-RdpClientPeerSshEntryPath { return $SshEntryFile }
function Assert-RdpClientPeerSshEntryIsSeparate {}
function Invoke-RdpClientPeerSshCopy {
    param($SshEntryPath, $SourcePath, $RemoteName, $TimeoutBudget)
    if (-not [IO.File]::Exists($SourcePath)) { throw 'Input archive missing.' }
    return [pscustomobject]@{ ExitCode = 0; Output = @() }
}
function Invoke-RdpClientPeerSshPowerShell {
    param($SshEntryPath, $RemoteSource, [int]$TimeoutSeconds)
    if ($RemoteSource.Contains('__RDP_CLIENT_PSEXEC_LIBRARY__') -or
        $RemoteSource.Contains('__RDP_CLIENT_EXEC_PAYLOAD__')) {
        throw 'Execution source markers were not replaced.'
    }
    if ($RemoteSource -notmatch '(?m)^\s*\$PayloadBase64 = ''(?<Payload>[A-Za-z0-9+/=]+)''\s*$') {
        throw 'Execution payload was not found.'
    }
    $Json = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($Matches.Payload)
    )
    [IO.File]::WriteAllText($env:RDP_EXEC_FAKE_CAPTURE, $Json)
    $Request = $Json | ConvertFrom-Json
    $ResultJson = [ordered]@{
        Version = 1
        Success = $true
        ExitCode = 0
        ErrorCode = ''
        Error = ''
        OutputName = [string]$Request.OutputName
        StdOut = "project stdout`n"
        StdErr = ''
    } | ConvertTo-Json -Compress
    $Payload = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($ResultJson)
    )
    return [pscustomobject]@{
        ExitCode = 0
        Output = @('RDP_CLIENT_EXEC_SUPERVISOR_V1:' + $Payload)
    }
}
function Invoke-RdpClientPeerSshDownload {
    param($SshEntryPath, $RemoteName, $DestinationPath, $TimeoutBudget)
    New-RdpClientProjectArchive `
        -ProjectPath $env:RDP_EXEC_FAKE_ARTIFACT_SOURCE `
        -ArchivePath $DestinationPath
    return [pscustomobject]@{ ExitCode = 0; Output = @() }
}
function ConvertTo-RdpClientEncodedCommand { param([string]$Source); return 'unused' }
function Invoke-RdpClientPeerSshEncodedCommand {
    return [pscustomobject]@{ ExitCode = 0; Output = @() }
}
'@
    [IO.File]::WriteAllText(
        (Join-Path $Runtime 'peer-ssh.ps1'),
        $FakePeer,
        $Utf8
    )
    $FakeSession = @'
function Get-RdpClientPeerSessionState { return [pscustomobject]@{ Sessions = @() } }
function Resolve-RdpClientSessionSelection {
    return [pscustomobject]@{
        Id = 2
        UserName = 'administrator'
        DomainName = 'TEST'
        State = 'Active'
        Locked = $false
        Terminal = 'rdp'
    }
}
function Get-RdpClientSessionDisplayUserName { return 'TEST\administrator' }
'@
    [IO.File]::WriteAllText(
        (Join-Path $Runtime 'session.ps1'),
        $FakeSession,
        $Utf8
    )
    [IO.File]::WriteAllText(
        (Join-Path $Runtime 'session-connect.ps1'),
        'Set-StrictMode -Version 2.0',
        $Utf8
    )
    $FakeDisplay = @'
function Test-RdpClientSessionDisplayReady { return $true }
function Open-RdpClientSessionDisplayLease { throw 'Display lease should not open.' }
function Close-RdpClientSessionDisplayLease {}
'@
    [IO.File]::WriteAllText(
        (Join-Path $Runtime 'session-display.ps1'),
        $FakeDisplay,
        $Utf8
    )

    $env:RDP_EXEC_FAKE_CAPTURE = $Capture
    $env:RDP_EXEC_FAKE_ARTIFACT_SOURCE = $ArtifactSource
    $env:RDP_EXEC_ARG_1 = '--size'
    $env:RDP_EXEC_ARG_2 = '800 x 600'
    $Output = Invoke-ExecTestCommand `
        -Arguments @(
            '-EntryFile', $Entry,
            '-SshEntryFile', $SshEntry,
            '-SessionId', '2',
            '-Project', $Project,
            '-Timeout', '60s',
            '-ArgumentCount', '2',
            '-CommandName', 'rdp-test'
        ) `
        -ExpectedExitCode 0
    $CapturedRequest = [IO.File]::ReadAllText($Capture) | ConvertFrom-Json
    if (@($CapturedRequest.Arguments).Count -ne 2 -or
        [string]$CapturedRequest.Arguments[0] -ne '--size' -or
        [string]$CapturedRequest.Arguments[1] -ne '800 x 600' -or
        [string]$CapturedRequest.ExpectedIdentity -ne 'TEST\administrator') {
        throw 'The exec supervisor request lost identity or script arguments.'
    }
    if (-not $Output.Contains('project stdout') -or
        -not $Output.Contains('[RDP] Artifacts:') -or
        -not $Output.Contains('[RDP] Project completed.')) {
        throw "The exec result was not presented correctly.`n$Output"
    }
    $ArtifactLine = @($Output -split '\r?\n' | Where-Object {
        $_ -like '[[]RDP[]] Artifacts:*'
    })[0]
    $ArtifactPath = $ArtifactLine.Substring($ArtifactLine.IndexOf(':') + 1).Trim()
    if ([IO.File]::ReadAllText((Join-Path $ArtifactPath 'result.txt')) -ne 'artifact') {
        throw 'The downloaded project artifact was not extracted.'
    }

    $WorkerRoot = Join-Path $ScratchRoot 'worker'
    $WorkerInput = Join-Path $WorkerRoot 'input'
    $WorkerOutput = Join-Path $WorkerRoot 'output'
    $WorkerLogs = Join-Path $WorkerRoot 'logs'
    [IO.Directory]::CreateDirectory($WorkerInput) | Out-Null
    [IO.Directory]::CreateDirectory($WorkerOutput) | Out-Null
    [IO.Directory]::CreateDirectory($WorkerLogs) | Out-Null
    $WorkerRun = @'
param([string]$Value)
[IO.File]::WriteAllText(
    (Join-Path $env:RDP_EXEC_OUTPUT_DIR 'worker-result.txt'),
    "$Value|$env:RDP_EXEC_SESSION_ID|$env:RDP_EXEC_WORK_DIR"
)
Write-Output "worker stdout: $Value"
'@
    [IO.File]::WriteAllText((Join-Path $WorkerInput 'run.ps1'), $WorkerRun, $Utf8)
    $Current = [Diagnostics.Process]::GetCurrentProcess()
    try { $CurrentSessionId = $Current.SessionId } finally { $Current.Dispose() }
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $WorkerRequestJson = [ordered]@{
        SessionId = $CurrentSessionId
        ExpectedIdentity = $Identity
        WorkDirectory = $WorkerRoot
        LogDirectory = $WorkerLogs
        InputDirectory = $WorkerInput
        OutputDirectory = $WorkerOutput
        Arguments = @('value with spaces')
    } | ConvertTo-Json -Compress -Depth 4
    $WorkerResultPath = Join-Path $WorkerRoot 'result.txt'
    $WorkerIdentityPath = Join-Path $WorkerRoot 'identity.json'
    $WorkerProcessOutput = (& PowerShell.exe `
        -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $RuntimeRoot 'exec-task.remote.ps1') `
        -RequestBase64 ([Convert]::ToBase64String($Utf8.GetBytes($WorkerRequestJson))) `
        -ResultPath $WorkerResultPath `
        -ProcessIdentityPath $WorkerIdentityPath 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "The target-user exec worker failed.`n$WorkerProcessOutput"
    }
    $WorkerArtifact = [IO.File]::ReadAllText(
        (Join-Path $WorkerOutput 'worker-result.txt')
    )
    if (-not $WorkerArtifact.StartsWith("value with spaces|$CurrentSessionId|")) {
        throw 'The target-user worker lost its argument or execution environment.'
    }
    if (-not [IO.File]::ReadAllText((Join-Path $WorkerLogs 'stdout.log')).Contains(
        'worker stdout: value with spaces'
    )) {
        throw 'The target-user worker did not capture stdout.'
    }

    $RemoteSource = [IO.File]::ReadAllText(
        (Join-Path $RuntimeRoot 'exec.remote.ps1'),
        [Text.Encoding]::UTF8
    )
    foreach ($Required in @(
        "Join-Path `$env:ProgramData 'swaw-kit\rdp-client\temp\exec'",
        'Grant-RdpClientExecDirectoryAccess',
        "'-File', `$HelperPath",
        'taskkill.exe /PID $ProcessId /T /F',
        'New-RdpClientExecOutputArchive',
        'RDP_CLIENT_EXEC_SUPERVISOR_V1:'
    )) {
        if (-not $RemoteSource.Contains($Required)) {
            throw "The remote exec supervisor is missing '$Required'."
        }
    }

    Write-Host 'rdp client exec tests: PASS' -ForegroundColor Green
} finally {
    foreach ($Name in @(
        'RDP_EXEC_FAKE_CAPTURE',
        'RDP_EXEC_FAKE_ARTIFACT_SOURCE',
        'RDP_EXEC_ARG_1',
        'RDP_EXEC_ARG_2'
    )) { Remove-Item "Env:$Name" -ErrorAction SilentlyContinue }
    if ([IO.Directory]::Exists($ScratchRoot)) {
        [IO.Directory]::Delete($ScratchRoot, $true)
    }
}
