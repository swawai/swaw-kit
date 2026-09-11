$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
$Utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8
[Console]::OutputEncoding = $Utf8
$OutputEncoding = $Utf8
$TaskRoot = ''
$ProjectUploadPath = ''
$Request = $null

function Join-RdpClientProcessArguments {
    param([AllowNull()][object[]]$Arguments = @())

    $Quoted = foreach ($Argument in @($Arguments)) {
        $Value = [string]$Argument
        if ($Value.Length -eq 0) { '""' }
        elseif ($Value -notmatch '[\s"]') { $Value }
        else {
            '"' +
                ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') +
                '"'
        }
    }
    return $Quoted -join ' '
}

__RDP_CLIENT_PSEXEC_LIBRARY__

function Get-RdpClientSshServerAddress {
    $Parts = @([string]$env:SSH_CONNECTION -split '\s+' | Where-Object { $_ })
    if ($Parts.Count -lt 4) {
        throw '[PEER_UNVERIFIED] SSH_CONNECTION is unavailable.'
    }
    $Address = $null
    if (-not [Net.IPAddress]::TryParse($Parts[2], [ref]$Address)) {
        throw '[PEER_UNVERIFIED] SSH_CONNECTION has an invalid peer address.'
    }
    if ($Address.IsIPv4MappedToIPv6) { return $Address.MapToIPv4().ToString() }
    return $Address.ToString()
}

function Assert-RdpClientExecPeer {
    param([Parameter(Mandatory = $true)][object[]]$ExpectedAddresses)

    $Peer = Get-RdpClientSshServerAddress
    if (-not @($ExpectedAddresses | Where-Object {
        [string]::Equals([string]$_, $Peer, [StringComparison]::OrdinalIgnoreCase)
    }).Count) {
        throw "[PEER_UNVERIFIED] SSH peer $Peer does not match the RDP target."
    }
}

function Expand-RdpClientRemoteProjectArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Root = [IO.Path]::GetFullPath($DestinationPath).TrimEnd('\', '/')
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    $Archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($Archive.Entries.Count -gt 1024) {
            throw '[INVALID_PROJECT] Project archive contains too many files.'
        }
        $TotalBytes = [int64]0
        foreach ($Entry in $Archive.Entries) {
            $TotalBytes += [int64]$Entry.Length
            if ($TotalBytes -gt 67108864) {
                throw '[INVALID_PROJECT] Project archive is too large.'
            }
            $Relative = $Entry.FullName.Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($Relative)) { continue }
            $Target = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
            if (-not ($Target + '\').StartsWith(
                $Root + '\',
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw '[INVALID_PROJECT] Project archive contains an unsafe path.'
            }
            if ([string]::IsNullOrEmpty($Entry.Name)) {
                [IO.Directory]::CreateDirectory($Target) | Out-Null
                continue
            }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Target)) |
                Out-Null
            $Input = $Entry.Open()
            try {
                $Output = [IO.File]::Open(
                    $Target,
                    [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::None
                )
                try { $Input.CopyTo($Output) } finally { $Output.Dispose() }
            } finally { $Input.Dispose() }
        }
    } finally { $Archive.Dispose() }
}

function Grant-RdpClientExecDirectoryAccess {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Identity
    )

    $Sid = (New-Object Security.Principal.NTAccount($Identity)).Translate(
        [Security.Principal.SecurityIdentifier]
    )
    $Acl = Get-Acl -LiteralPath $Path
    $Inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $Propagation = [Security.AccessControl.PropagationFlags]::None
    $Acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $Sid,
        [Security.AccessControl.FileSystemRights]::Modify,
        $Inheritance,
        $Propagation,
        [Security.AccessControl.AccessControlType]::Allow
    )))
    Set-Acl -LiteralPath $Path -AclObject $Acl
}

function Wait-RdpClientExecFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][Diagnostics.Stopwatch]$Stopwatch,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds
    )

    while ($Stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ([IO.File]::Exists($Path) -and (Get-Item -LiteralPath $Path).Length -gt 0) {
            return
        }
        Start-Sleep -Milliseconds 100
    }
    throw "[EXEC_TIMEOUT] The session $Kind timed out after $TimeoutSeconds seconds."
}

function Stop-RdpClientExecProcessTree {
    param([Parameter(Mandatory = $true)][string]$IdentityPath)

    if (-not [IO.File]::Exists($IdentityPath)) { return }
    $Process = $null
    try {
        $Identity = [IO.File]::ReadAllText($IdentityPath) | ConvertFrom-Json
        $ProcessId = [int]$Identity.ProcessId
        $Ticks = [int64]$Identity.StartTimeUtcTicks
        if ([int]$Identity.Version -ne 1 -or $ProcessId -le 0 -or $Ticks -le 0) {
            return
        }
        try { $Process = [Diagnostics.Process]::GetProcessById($ProcessId) }
        catch [ArgumentException] { return }
        if ($Process.StartTime.ToUniversalTime().Ticks -ne $Ticks) { return }
        & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
    } catch { } finally {
        if ($null -ne $Process) { $Process.Dispose() }
    }
}

function New-RdpClientExecOutputArchive {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if ([IO.File]::Exists($ArchivePath)) { [IO.File]::Delete($ArchivePath) }
    $ResolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    $RootItem = Get-Item -LiteralPath $ResolvedOutputDirectory -Force
    if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw '[INVALID_OUTPUT] Project output root cannot be a reparse point.'
    }
    $Files = New-Object 'Collections.Generic.List[IO.FileInfo]'
    $Pending = New-Object 'Collections.Generic.Stack[string]'
    $Pending.Push($ResolvedOutputDirectory)
    $Total = [int64]0
    while ($Pending.Count -gt 0) {
        $Directory = $Pending.Pop()
        foreach ($Item in @(Get-ChildItem -LiteralPath $Directory -Force)) {
            if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw '[INVALID_OUTPUT] Project output cannot contain reparse points.'
            }
            if ($Item -is [IO.DirectoryInfo]) {
                $Pending.Push($Item.FullName)
            } elseif ($Item -is [IO.FileInfo]) {
                $Files.Add($Item)
                if ($Files.Count -gt 4096) {
                    throw '[OUTPUT_TOO_LARGE] Project output contains more than 4096 files.'
                }
                $Total += [int64]$Item.Length
                if ($Total -gt 1073741824) {
                    throw '[OUTPUT_TOO_LARGE] Project output exceeds 1 GiB.'
                }
            } else {
                throw '[INVALID_OUTPUT] Project output contains an unsupported filesystem object.'
            }
        }
    }
    $Stream = [IO.File]::Open(
        $ArchivePath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    try {
        $Archive = New-Object IO.Compression.ZipArchive(
            $Stream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            $Root = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
            foreach ($File in $Files.ToArray()) {
                $Relative = $File.FullName.Substring($Root.Length).
                    TrimStart('\', '/').Replace('\', '/')
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $Archive,
                    $File.FullName,
                    $Relative,
                    [IO.Compression.CompressionLevel]::Optimal
                ) | Out-Null
            }
        } finally { $Archive.Dispose() }
    } finally { $Stream.Dispose() }
}

function Read-RdpClientExecLog {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.File]::Exists($Path)) { return '' }
    $Reader = New-Object IO.StreamReader($Path, $Utf8, $true)
    try {
        $Buffer = New-Object char[] 65537
        $Read = $Reader.ReadBlock($Buffer, 0, $Buffer.Length)
        $Text = New-Object string($Buffer, 0, [Math]::Min($Read, 65536))
        if ($Read -gt 65536 -or -not $Reader.EndOfStream) {
            return $Text + "`n[RDP] Log truncated."
        }
        return $Text
    } finally { $Reader.Dispose() }
}

function Write-RdpClientExecMarker {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Result)

    $Json = ConvertTo-Json -InputObject $Result -Compress -Depth 5
    $Payload = [Convert]::ToBase64String($Utf8.GetBytes($Json))
    Write-Output ('RDP_CLIENT_EXEC_SUPERVISOR_V1:' + $Payload)
}

$Result = [ordered]@{
    Version    = 1
    Success    = $false
    ExitCode   = 1
    ErrorCode  = 'EXEC_FAILED'
    Error      = ''
    OutputName = ''
    StdOut     = ''
    StdErr     = ''
}
$WorkerFinished = $false
$Stopwatch = [Diagnostics.Stopwatch]::StartNew()
try {
    $PayloadBase64 = '__RDP_CLIENT_EXEC_PAYLOAD__'
    $RequestJson = $Utf8.GetString([Convert]::FromBase64String($PayloadBase64))
    $Request = $RequestJson | ConvertFrom-Json
    Assert-RdpClientExecPeer -ExpectedAddresses @($Request.ExpectedAddresses)

    $SessionId = [int]$Request.SessionId
    $TimeoutSeconds = [int]$Request.TimeoutSeconds
    if ($SessionId -le 0 -or $TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 1800) {
        throw '[INVALID_REQUEST] Session ID or timeout is invalid.'
    }
    $ProjectUploadName = [string]$Request.ProjectUploadName
    $OutputName = [string]$Request.OutputName
    if ($ProjectUploadName -notmatch '^\.swaw-kit-rdp-exec-input-[a-f0-9]{32}\.zip$' -or
        $OutputName -notmatch '^\.swaw-kit-rdp-exec-output-[a-f0-9]{32}\.zip$') {
        throw '[INVALID_REQUEST] Transfer filenames are invalid.'
    }
    $ProjectUploadPath = Join-Path $HOME $ProjectUploadName
    $OutputArchivePath = Join-Path $HOME $OutputName
    if (-not [IO.File]::Exists($ProjectUploadPath)) {
        throw '[INVALID_PROJECT] Uploaded project archive was not found.'
    }

    $LocalAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    $ManagedDirectory = Join-Path $LocalAppData 'swaw-kit\rdp-client'
    $PsExecPath = Join-Path $ManagedDirectory 'psexec.exe'
    $HelperPath = Join-Path $ManagedDirectory 'helper.ps1'
    if (-not [IO.File]::Exists($PsExecPath) -or
        -not (Get-RdpClientPsExecSignature -Path $PsExecPath).IsTrusted) {
        throw '[PSEXEC_NOT_READY] Managed PsExec is absent or untrusted. Run .peer psexec add.'
    }
    $ExpectedHelperHash = [string]$Request.HelperSha256
    $HelperState = Get-RdpClientManagedScriptState `
        -Path $HelperPath `
        -ExpectedHash $ExpectedHelperHash
    if (-not $HelperState.Ready) {
        throw '[PSEXEC_NOT_READY] Managed session helper is absent or outdated. Run .peer psexec add.'
    }

    $TemporaryRoot = Join-Path $env:ProgramData 'swaw-kit\rdp-client\temp\exec'
    [IO.Directory]::CreateDirectory($TemporaryRoot) | Out-Null
    $TaskRoot = Join-Path $TemporaryRoot ([Guid]::NewGuid().ToString('N'))
    $InputDirectory = Join-Path $TaskRoot 'input'
    $OutputDirectory = Join-Path $TaskRoot 'output'
    $WorkDirectory = Join-Path $TaskRoot 'work'
    $ControlDirectory = Join-Path $TaskRoot 'control'
    [IO.Directory]::CreateDirectory($TaskRoot) | Out-Null
    Grant-RdpClientExecDirectoryAccess `
        -Path $TaskRoot `
        -Identity ([string]$Request.ExpectedIdentity)
    [IO.Directory]::CreateDirectory($InputDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($WorkDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($ControlDirectory) | Out-Null
    Expand-RdpClientRemoteProjectArchive `
        -ArchivePath $ProjectUploadPath `
        -DestinationPath $InputDirectory
    if (-not [IO.File]::Exists((Join-Path $InputDirectory 'run.ps1'))) {
        throw '[INVALID_PROJECT] Project archive has no root run.ps1.'
    }

    $WorkerPath = Join-Path $ControlDirectory 'exec-task.ps1'
    $WorkerBytes = [Convert]::FromBase64String([string]$Request.WorkerBase64)
    [IO.File]::WriteAllBytes($WorkerPath, $WorkerBytes)
    $WorkerHash = (Get-FileHash -LiteralPath $WorkerPath -Algorithm SHA256).Hash
    if ($WorkerHash -ne [string]$Request.WorkerSha256) {
        throw '[INVALID_REQUEST] Execution worker failed SHA-256 verification.'
    }
    $IdentityPath = Join-Path $ControlDirectory 'worker-identity.json'
    $ResultPath = Join-Path $ControlDirectory 'worker-result.txt'
    $WorkerRequest = [ordered]@{
        SessionId       = $SessionId
        ExpectedIdentity = [string]$Request.ExpectedIdentity
        WorkDirectory   = $WorkDirectory
        LogDirectory    = $ControlDirectory
        InputDirectory  = $InputDirectory
        OutputDirectory = $OutputDirectory
        Arguments       = @($Request.Arguments | ForEach-Object { [string]$_ })
    } | ConvertTo-Json -Compress -Depth 4
    $WorkerRequestBase64 = [Convert]::ToBase64String($Utf8.GetBytes($WorkerRequest))
    $LaunchRequest = [ordered]@{
        Arguments = @(
            (Join-Path $PSHOME 'powershell.exe'),
            '-NoLogo', '-NoProfile', '-NonInteractive',
            '-ExecutionPolicy', 'Bypass',
            '-File', $WorkerPath,
            '-RequestBase64', $WorkerRequestBase64,
            '-ResultPath', $ResultPath,
            '-ProcessIdentityPath', $IdentityPath
        )
    } | ConvertTo-Json -Compress -Depth 4
    $LaunchBase64 = [Convert]::ToBase64String($Utf8.GetBytes($LaunchRequest))

    $Remaining = [int][Math]::Ceiling(
        $TimeoutSeconds - $Stopwatch.Elapsed.TotalSeconds
    )
    if ($Remaining -le 0) { throw '[EXEC_TIMEOUT] Project timed out before launch.' }
    $LauncherExitCode = Invoke-RdpClientUncapturedProcess `
        -FilePath $PsExecPath `
        -TimeoutSeconds ([Math]::Min(30, $Remaining)) `
        -Arguments @(
            '-accepteula', '-nobanner', '-s',
            'powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive',
            '-ExecutionPolicy', 'Bypass', '-File', $HelperPath,
            '-SessionId', [string]$SessionId,
            '-PayloadBase64', $LaunchBase64
        )
    if ($LauncherExitCode -ne 0) {
        throw "[EXEC_LAUNCH_FAILED] Session launcher exited with $LauncherExitCode."
    }
    Wait-RdpClientExecFile `
        -Path $IdentityPath `
        -Kind 'project launcher' `
        -Stopwatch $Stopwatch `
        -TimeoutSeconds ([Math]::Min($TimeoutSeconds, 10))
    Wait-RdpClientExecFile `
        -Path $ResultPath `
        -Kind 'project' `
        -Stopwatch $Stopwatch `
        -TimeoutSeconds $TimeoutSeconds
    $WorkerFinished = $true

    $Marker = [IO.File]::ReadAllText($ResultPath, $Utf8).Trim()
    if ($Marker -notmatch '^RDP_CLIENT_EXEC_RESULT_V1:(?<Payload>[A-Za-z0-9+/=]+)$') {
        throw '[EXEC_RESULT_INVALID] Project worker returned an invalid result.'
    }
    $WorkerResult = $Utf8.GetString(
        [Convert]::FromBase64String($Matches.Payload)
    ) | ConvertFrom-Json
    $Result.Success = [bool]$WorkerResult.Success
    $Result.ExitCode = [int]$WorkerResult.ExitCode
    $Result.ErrorCode = [string]$WorkerResult.ErrorCode
    $Result.Error = [string]$WorkerResult.Error
} catch {
    $Failure = $_.Exception
    while ($null -ne $Failure.InnerException) { $Failure = $Failure.InnerException }
    $Message = [string]$Failure.Message
    if ($Message -match '^\[(?<Code>[A-Z0-9_]+)\]\s*(?<Detail>.*)$') {
        $Result.ErrorCode = $Matches.Code
        $Result.Error = $Matches.Detail
    } else { $Result.Error = $Message }
} finally {
    $Stopwatch.Stop()
    if (-not $WorkerFinished -and -not [string]::IsNullOrWhiteSpace($TaskRoot)) {
        Stop-RdpClientExecProcessTree `
            -IdentityPath (Join-Path $TaskRoot 'control\worker-identity.json')
    }
    if (-not [string]::IsNullOrWhiteSpace($TaskRoot)) {
        $Result.StdOut = Read-RdpClientExecLog `
            -Path (Join-Path $TaskRoot 'control\stdout.log')
        $Result.StdErr = Read-RdpClientExecLog `
            -Path (Join-Path $TaskRoot 'control\stderr.log')
        try {
            $OutputDirectory = Join-Path $TaskRoot 'output'
            if ([IO.Directory]::Exists($OutputDirectory) -and
                $null -ne $Request -and
                -not [string]::IsNullOrWhiteSpace([string]$Request.OutputName)) {
                $ArchivePath = Join-Path $HOME ([string]$Request.OutputName)
                New-RdpClientExecOutputArchive `
                    -OutputDirectory $OutputDirectory `
                    -ArchivePath $ArchivePath
                $Result.OutputName = [string]$Request.OutputName
            }
        } catch {
            if ($Result.Success) {
                $Result.Success = $false
                $Result.ExitCode = 1
                $Result.ErrorCode = 'OUTPUT_COLLECTION_FAILED'
                $Result.Error = $_.Exception.Message
            } else {
                $Result.Error += " Output collection also failed: $($_.Exception.Message)"
            }
        }
        try { [IO.Directory]::Delete($TaskRoot, $true) } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($ProjectUploadPath) -and
        [IO.File]::Exists($ProjectUploadPath)) {
        try { [IO.File]::Delete($ProjectUploadPath) } catch { }
    }
}
Write-RdpClientExecMarker -Result $Result
exit $(if ($Result.Success) { 0 } else { 1 })
