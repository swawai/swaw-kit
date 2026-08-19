[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
    [string]$RequestBase64,

    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
    [string]$ResultPath,

    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()]
    [string]$ProcessIdentityPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
$Utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8
[Console]::OutputEncoding = $Utf8
$OutputEncoding = $Utf8

function Join-RdpClientExecArguments {
    param([AllowNull()][object[]]$Arguments = @())

    $Quoted = foreach ($Argument in @($Arguments)) {
        $Value = [string]$Argument
        if ($Value.Length -eq 0) {
            '""'
        } elseif ($Value -notmatch '[\s"]') {
            $Value
        } else {
            '"' +
                ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') +
                '"'
        }
    }
    return $Quoted -join ' '
}

function Write-RdpClientExecResult {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Result)

    $Json = ConvertTo-Json -InputObject $Result -Compress -Depth 4
    $Payload = [Convert]::ToBase64String($Utf8.GetBytes($Json))
    $Bytes = $Utf8.GetBytes('RDP_CLIENT_EXEC_RESULT_V1:' + $Payload)
    $Stream = [IO.File]::Open(
        [IO.Path]::GetFullPath($ResultPath),
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try { $Stream.Write($Bytes, 0, $Bytes.Length) } finally { $Stream.Dispose() }
}

$Child = $null
try {
    $CurrentProcess = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $IdentityJson = ConvertTo-Json -InputObject ([ordered]@{
            Version           = 1
            ProcessId         = [int]$CurrentProcess.Id
            StartTimeUtcTicks = [int64]$CurrentProcess.StartTime.ToUniversalTime().Ticks
        }) -Compress
    } finally { $CurrentProcess.Dispose() }
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($ProcessIdentityPath),
        $IdentityJson,
        $Utf8
    )

    $RequestJson = $Utf8.GetString([Convert]::FromBase64String($RequestBase64))
    $Request = $RequestJson | ConvertFrom-Json
    if ($null -eq $Request -or $Request -is [Array]) {
        throw '[INVALID_REQUEST] The execution request is invalid.'
    }
    $ExpectedSessionId = [int]0
    if (-not [int]::TryParse(
        [string]$Request.SessionId,
        [ref]$ExpectedSessionId
    ) -or $ExpectedSessionId -le 0) {
        throw '[INVALID_REQUEST] The expected session ID is invalid.'
    }
    $CurrentProcess = [Diagnostics.Process]::GetCurrentProcess()
    try { $ActualSessionId = $CurrentProcess.SessionId } finally {
        $CurrentProcess.Dispose()
    }
    if ($ActualSessionId -ne $ExpectedSessionId) {
        throw (
            '[SESSION_CHANGED] The project started in session ' +
            "$ActualSessionId, not expected session $ExpectedSessionId."
        )
    }
    $ExpectedIdentity = [string]$Request.ExpectedIdentity
    $ActualIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ([string]::IsNullOrWhiteSpace($ExpectedIdentity) -or
        -not [string]::Equals(
            $ActualIdentity,
            $ExpectedIdentity,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw (
            '[SESSION_CHANGED] The project ran as the wrong user. ' +
            "Expected $ExpectedIdentity; found $ActualIdentity."
        )
    }

    $WorkDirectory = [IO.Path]::GetFullPath([string]$Request.WorkDirectory)
    $LogDirectory = [IO.Path]::GetFullPath([string]$Request.LogDirectory)
    $InputDirectory = [IO.Path]::GetFullPath([string]$Request.InputDirectory)
    $OutputDirectory = [IO.Path]::GetFullPath([string]$Request.OutputDirectory)
    $RunPath = Join-Path $InputDirectory 'run.ps1'
    if (-not [IO.File]::Exists($RunPath)) {
        throw '[INVALID_PROJECT] The transferred project has no run.ps1.'
    }
    if (-not [IO.Directory]::Exists($OutputDirectory)) {
        throw '[INVALID_REQUEST] The execution output directory is unavailable.'
    }

    $ChildArguments = Join-RdpClientExecArguments (@(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $RunPath
    ) + @($Request.Arguments | ForEach-Object { [string]$_ }))
    $env:RDP_EXEC_OUTPUT_DIR = $OutputDirectory
    $env:RDP_EXEC_SESSION_ID = [string]$ExpectedSessionId
    $env:RDP_EXEC_WORK_DIR = $WorkDirectory
    $StdOutPath = Join-Path $LogDirectory 'stdout.log'
    $StdErrPath = Join-Path $LogDirectory 'stderr.log'
    $Child = Start-Process `
        -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList $ChildArguments `
        -WorkingDirectory $InputDirectory `
        -NoNewWindow `
        -RedirectStandardOutput $StdOutPath `
        -RedirectStandardError $StdErrPath `
        -PassThru
    $Child.WaitForExit()
    $ExitCode = [int]$Child.ExitCode
    Write-RdpClientExecResult -Result ([ordered]@{
        Version   = 1
        Success   = $ExitCode -eq 0
        ExitCode  = $ExitCode
        SessionId = $ActualSessionId
        Identity  = $ActualIdentity
        ErrorCode = $(if ($ExitCode -eq 0) { '' } else { 'PROJECT_FAILED' })
        Error     = $(if ($ExitCode -eq 0) { '' } else { "run.ps1 exited with $ExitCode." })
    })
    exit $(if ($ExitCode -eq 0) { 0 } else { 1 })
} catch {
    $Failure = $_.Exception
    while ($null -ne $Failure.InnerException) { $Failure = $Failure.InnerException }
    $Message = [string]$Failure.Message
    $Code = 'EXEC_TASK_FAILED'
    if ($Message -match '^\[(?<Code>[A-Z0-9_]+)\]\s*(?<Detail>.*)$') {
        $Code = $Matches.Code
        $Message = $Matches.Detail
    }
    try {
        Write-RdpClientExecResult -Result ([ordered]@{
            Version   = 1
            Success   = $false
            ExitCode  = 1
            ErrorCode = $Code
            Error     = $Message
        })
    } catch { }
    exit 1
} finally {
    if ($null -ne $Child) {
        if (-not $Child.HasExited) { try { $Child.Kill() } catch { } }
        $Child.Dispose()
    }
}
