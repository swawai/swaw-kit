[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EntryFile,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SshEntryFile,
    [Parameter(Mandatory = $true)][string]$SessionId,
    [Parameter(Mandatory = $true)][string]$Project,
    [AllowNull()][AllowEmptyString()][string]$Timeout = '60s',
    [ValidateRange(0, 128)][int]$ArgumentCount = 0,
    [switch]$Display,
    [string]$CommandName = 'rdp'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'entry.ps1')
. (Join-Path $PSScriptRoot 'peer-ssh.ps1')
. (Join-Path $PSScriptRoot 'session.ps1')
. (Join-Path $PSScriptRoot 'session-connect.ps1')
. (Join-Path $PSScriptRoot 'session-display.ps1')
. (Join-Path $PSScriptRoot 'project-core.ps1')
. (Join-Path $PSScriptRoot 'project-archive.ps1')

function Resolve-RdpClientExecTimeoutSeconds {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    $Text = if ([string]::IsNullOrWhiteSpace($Value)) { '60s' } else { $Value.Trim() }
    if ($Text -notmatch '^(?<Seconds>[0-9]+)(?:s)?$') {
        throw 'Project timeout must use seconds, for example 60s.'
    }
    $Seconds = [int]0
    if (-not [int]::TryParse($Matches.Seconds, [ref]$Seconds) -or
        $Seconds -lt 1 -or $Seconds -gt 1800) {
        throw 'Project timeout must be between 1s and 1800s.'
    }
    return $Seconds
}

function Get-RdpClientExecArguments {
    param([Parameter(Mandatory = $true)][int]$Count)

    $Result = New-Object 'Collections.Generic.List[string]'
    for ($Index = 1; $Index -le $Count; $Index++) {
        $Name = "RDP_EXEC_ARG_$Index"
        $Value = [Environment]::GetEnvironmentVariable($Name, 'Process')
        if ($null -eq $Value) {
            throw "Project argument $Index was not forwarded by client.cmd."
        }
        $Result.Add($Value)
    }
    return $Result.ToArray()
}

function Get-RdpClientExecExpectedPeerAddresses {
    param([Parameter(Mandatory = $true)][string]$EntryPath)

    $Document = Read-RdpClientEntryDocument -Path $EntryPath
    $HostName = [string]$Document.FullAddress.Host
    $Address = $null
    if ([Net.IPAddress]::TryParse($HostName, [ref]$Address)) {
        $Addresses = @($Address)
    } else {
        try { $Addresses = @([Net.Dns]::GetHostAddresses($HostName)) }
        catch { throw "RDP peer name does not resolve: $HostName" }
    }
    if ($Addresses.Count -eq 0) { throw "RDP peer name does not resolve: $HostName" }
    return @($Addresses | ForEach-Object {
        if ($_.IsIPv4MappedToIPv6) { $_.MapToIPv4().ToString() }
        else { $_.ToString() }
    } | Sort-Object -Unique)
}

function Get-RdpClientExecFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.File]::Exists($Path)) { throw "Required file was not found: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Remove-RdpClientExecRemoteTransfersBestEffort {
    param(
        [AllowNull()][AllowEmptyString()][string]$SshEntryPath,
        [AllowNull()][object[]]$RemoteNames = @()
    )

    $Names = @($RemoteNames | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    } | ForEach-Object { [string]$_ })
    if ([string]::IsNullOrWhiteSpace($SshEntryPath) -or $Names.Count -eq 0) {
        return
    }
    foreach ($Name in $Names) {
        if ($Name -notmatch '^\.swaw-kit-rdp-exec-(?:input|output)-[a-f0-9]{32}\.zip$') {
            return
        }
    }
    try {
        $Payload = [Convert]::ToBase64String(
            (New-Object Text.UTF8Encoding($false)).GetBytes(
                (ConvertTo-Json -InputObject $Names -Compress)
            )
        )
        $Source = (
            '$u=New-Object Text.UTF8Encoding($false);' +
            '$j=$u.GetString([Convert]::FromBase64String(''' + $Payload + '''));' +
            '$d=$j|ConvertFrom-Json;' +
            '$p=@();' +
            'foreach($n in $d){' +
            'if([string]$n -notmatch ''^\.swaw-kit-rdp-exec-(?:input|output)-[a-f0-9]{32}\.zip$'')' +
            '{throw ''Invalid transfer cleanup name.''};' +
            '$p+=Join-Path $env:USERPROFILE ([string]$n)};' +
            'for($a=0;$a-lt 5;$a++){' +
            '$r=@($p|Where-Object{Test-Path -LiteralPath $_});' +
            'if($r.Count-eq 0){break};' +
            'foreach($x in $r){try{Remove-Item -LiteralPath $x -Force -ErrorAction Stop}catch{}};' +
            'if($a-lt 4){Start-Sleep -Milliseconds 250}};' +
            '$r=@($p|Where-Object{Test-Path -LiteralPath $_});' +
            'if($r.Count-ne 0){throw ''Remote transfer cleanup left files behind.''}'
        )
        $Cleanup = Invoke-RdpClientPeerSshEncodedCommand `
            -SshEntryPath $SshEntryPath `
            -EncodedCommand (ConvertTo-RdpClientEncodedCommand -Source $Source) `
            -TimeoutSeconds 10
        if ($Cleanup.ExitCode -ne 0) {
            throw (
                "Remote cleanup exited with $($Cleanup.ExitCode). " +
                ($Cleanup.Output -join ' ')
            )
        }
    } catch {
        [Console]::Error.WriteLine(
            "[WARN] Could not remove peer transfers: $($_.Exception.Message)"
        )
    }
}

$Lease = $null
$LocalInputArchive = ''
$LocalOutputArchive = ''
$RemoteInputName = ''
$RemoteOutputName = ''
$ResolvedSshEntry = ''
try {
    $Utf8 = New-Object Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $Utf8
    $OutputEncoding = $Utf8
    $TimeoutSeconds = Resolve-RdpClientExecTimeoutSeconds -Value $Timeout
    $TimeoutBudget = New-RdpClientTimeoutBudget -TimeoutSeconds $TimeoutSeconds
    $ResolvedSessionId = Resolve-RdpClientSessionId -Value $SessionId
    if ($null -eq $ResolvedSessionId -or $ResolvedSessionId -le 0 -or
        [uint64]$ResolvedSessionId -gt [int]::MaxValue) {
        throw 'A positive project session ID supported by PsExec is required.'
    }
    $ResolvedEntry = [IO.Path]::GetFullPath($EntryFile)
    $ResolvedProject = Resolve-RdpClientProject `
        -EntryFile $ResolvedEntry `
        -Value $Project `
        -RequireExisting
    $Arguments = @(Get-RdpClientExecArguments -Count $ArgumentCount)
    $ArgumentCharacters = [int64]0
    foreach ($Argument in $Arguments) {
        $ArgumentCharacters += $Argument.Length
        if ($Argument.Length -gt 8192 -or $ArgumentCharacters -gt 32768) {
            throw 'Project arguments exceed the 32,768-character safety limit.'
        }
    }
    $Document = Read-RdpClientEntryDocument -Path $ResolvedEntry
    $ResolvedSshEntry = Resolve-RdpClientPeerSshEntryPath -Value $SshEntryFile
    Assert-RdpClientPeerSshEntryIsSeparate `
        -SshEntryPath $ResolvedSshEntry `
        -RdpEntryPath $ResolvedEntry

    $InitialState = Get-RdpClientPeerSessionState `
        -SshEntryPath $ResolvedSshEntry `
        -TimeoutSeconds (Get-RdpClientTimeoutBudgetRemainingSeconds `
            -Budget $TimeoutBudget `
            -Operation 'Project command')
    $SelectedSession = Resolve-RdpClientSessionSelection `
        -State $InitialState `
        -EntryUserName $Document.Username `
        -SessionId $ResolvedSessionId
    $DisplaySource = 'existing'
    if (-not (Test-RdpClientSessionDisplayReady -Session $SelectedSession)) {
        $LockedProperty = $SelectedSession.PSObject.Properties['Locked']
        if ([string]::Equals(
            [string]$SelectedSession.State,
            'Active',
            [StringComparison]::OrdinalIgnoreCase
        ) -and $null -ne $LockedProperty -and
            $null -ne $LockedProperty.Value -and [bool]$LockedProperty.Value) {
            throw (
                "DESKTOP_NOT_INTERACTIVE: Session $ResolvedSessionId is active but " +
                'locked. Project execution does not unlock an existing session.'
            )
        }
        if (-not $Display) {
            throw (
                "DISPLAY_NOT_READY: Session $ResolvedSessionId is " +
                "$($SelectedSession.State) or locked. Run `"$CommandName " +
                ".$ResolvedSessionId exec $Project --display`"."
            )
        }
        $Lease = Open-RdpClientSessionDisplayLease `
            -SshEntryPath $ResolvedSshEntry `
            -EntryFile $ResolvedEntry `
            -EntryUserName $Document.Username `
            -CommandName $CommandName `
            -BeforeState $InitialState `
            -SessionId $ResolvedSessionId `
            -TimeoutBudget $TimeoutBudget
        $SelectedSession = $Lease.Session
        $DisplaySource = 'temporary-rdp'
    }

    $UserName = Get-RdpClientSessionDisplayUserName -Session $SelectedSession
    $ExpectedIdentity = if ([string]::IsNullOrWhiteSpace(
        [string]$SelectedSession.DomainName
    )) { [string]$SelectedSession.UserName } else {
        [string]$SelectedSession.DomainName + '\' + [string]$SelectedSession.UserName
    }
    Write-Host "[RDP] Project:   $($ResolvedProject.Path)"
    Write-Host (
        '[RDP] Session:   {0} ({1}; {2}; {3})' -f `
            $SelectedSession.Id,
            $UserName,
            $SelectedSession.State,
            $SelectedSession.Terminal
    )
    Write-Host "[RDP] Display:   $DisplaySource"

    $TransferId = [Guid]::NewGuid().ToString('N')
    $EntryData = Get-RdpClientEntryDataDirectory -EntryFile $ResolvedEntry
    $TransferDirectory = Join-Path $EntryData 'temp'
    [IO.Directory]::CreateDirectory($TransferDirectory) | Out-Null
    $RemoteInputName = ".swaw-kit-rdp-exec-input-$TransferId.zip"
    $RemoteOutputName = ".swaw-kit-rdp-exec-output-$TransferId.zip"
    $LocalInputArchive = Join-Path $TransferDirectory $RemoteInputName
    $LocalOutputArchive = Join-Path $TransferDirectory $RemoteOutputName
    New-RdpClientProjectArchive `
        -ProjectPath $ResolvedProject.Path `
        -ArchivePath $LocalInputArchive
    $Copy = Invoke-RdpClientPeerSshCopy `
        -SshEntryPath $ResolvedSshEntry `
        -SourcePath $LocalInputArchive `
        -RemoteName $RemoteInputName `
        -TimeoutBudget $TimeoutBudget
    if ($Copy.ExitCode -ne 0) {
        throw ('Project upload failed. ' + ($Copy.Output -join ' '))
    }

    $WorkerPath = Join-Path $PSScriptRoot 'exec-task.remote.ps1'
    $HelperPath = Join-Path $PSScriptRoot 'helper.ps1'
    $RemoteScriptPath = Join-Path $PSScriptRoot 'exec.remote.ps1'
    $LibraryPath = Join-Path $PSScriptRoot 'psexec-lib.remote.ps1'
    foreach ($Path in @($WorkerPath, $HelperPath, $RemoteScriptPath, $LibraryPath)) {
        if (-not [IO.File]::Exists($Path)) { throw "Required execution file was not found: $Path" }
    }
    $RemainingSeconds = Get-RdpClientTimeoutBudgetRemainingSeconds `
        -Budget $TimeoutBudget `
        -Operation 'Project command'
    if ($RemainingSeconds -le 5) {
        throw 'Project command has insufficient time remaining for supervised cleanup.'
    }
    $Request = [ordered]@{
        SessionId        = [int]$ResolvedSessionId
        ExpectedIdentity = $ExpectedIdentity
        TimeoutSeconds   = $RemainingSeconds - 5
        Arguments        = $Arguments
        ExpectedAddresses = @(Get-RdpClientExecExpectedPeerAddresses `
            -EntryPath $ResolvedEntry)
        ProjectUploadName = $RemoteInputName
        OutputName        = $RemoteOutputName
        HelperSha256      = Get-RdpClientExecFileSha256 -Path $HelperPath
        WorkerSha256      = Get-RdpClientExecFileSha256 -Path $WorkerPath
        WorkerBase64      = [Convert]::ToBase64String([IO.File]::ReadAllBytes($WorkerPath))
    }
    $PayloadBase64 = [Convert]::ToBase64String($Utf8.GetBytes(
        (ConvertTo-Json -InputObject $Request -Compress -Depth 5)
    ))
    $RemoteSource = [IO.File]::ReadAllText($RemoteScriptPath, [Text.Encoding]::UTF8)
    $LibraryMarker = '__RDP_CLIENT_PSEXEC_LIBRARY__'
    $PayloadMarker = '__RDP_CLIENT_EXEC_PAYLOAD__'
    if ([regex]::Matches($RemoteSource, [regex]::Escape($LibraryMarker)).Count -ne 1 -or
        [regex]::Matches($RemoteSource, [regex]::Escape($PayloadMarker)).Count -ne 1) {
        throw 'RDP project supervisor has invalid source markers.'
    }
    $RemoteSource = $RemoteSource.Replace(
        $LibraryMarker,
        [IO.File]::ReadAllText($LibraryPath, [Text.Encoding]::UTF8)
    ).Replace($PayloadMarker, $PayloadBase64)
    $Invocation = Invoke-RdpClientPeerSshPowerShell `
        -SshEntryPath $ResolvedSshEntry `
        -RemoteSource $RemoteSource `
        -TimeoutSeconds (Get-RdpClientTimeoutBudgetRemainingSeconds `
            -Budget $TimeoutBudget `
            -Operation 'Project command')

    $Pattern = '^RDP_CLIENT_EXEC_SUPERVISOR_V1:(?<Payload>[A-Za-z0-9+/=]+)$'
    $Markers = @($Invocation.Output | Where-Object { $_ -match $Pattern })
    if ($Markers.Count -ne 1 -or $Markers[0] -notmatch $Pattern) {
        throw (
            'The peer did not return exactly one project result. ' +
            "exit=$($Invocation.ExitCode) " + ($Invocation.Output -join ' ')
        )
    }
    $Result = $Utf8.GetString(
        [Convert]::FromBase64String($Matches.Payload)
    ) | ConvertFrom-Json
    if ($null -eq $Result -or $Result -is [Array] -or
        [int]$Result.Version -ne 1) {
        throw 'The peer returned an unsupported project result.'
    }
    if (-not [string]::IsNullOrEmpty([string]$Result.StdOut)) {
        [Console]::Out.Write([string]$Result.StdOut)
        if (-not ([string]$Result.StdOut).EndsWith("`n")) { Write-Output '' }
    }
    if (-not [string]::IsNullOrEmpty([string]$Result.StdErr)) {
        [Console]::Error.Write([string]$Result.StdErr)
        if (-not ([string]$Result.StdErr).EndsWith("`n")) {
            [Console]::Error.WriteLine()
        }
    }

    $RunDirectory = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$Result.OutputName)) {
        if ([string]$Result.OutputName -ne $RemoteOutputName) {
            throw 'The peer returned an unexpected output archive name.'
        }
        $Download = Invoke-RdpClientPeerSshDownload `
            -SshEntryPath $ResolvedSshEntry `
            -RemoteName $RemoteOutputName `
            -DestinationPath $LocalOutputArchive `
            -TimeoutBudget $TimeoutBudget
        if ($Download.ExitCode -ne 0) {
            throw ('Project output download failed. ' + ($Download.Output -join ' '))
        }
        $RunDirectory = New-RdpClientRunDirectory `
            -EntryFile $ResolvedEntry `
            -ProjectName $ResolvedProject.Name
        Expand-RdpClientArtifactArchive `
            -ArchivePath $LocalOutputArchive `
            -DestinationPath $RunDirectory
        Write-Host "[RDP] Artifacts: $RunDirectory"
    }
    if (-not [bool]$Result.Success) {
        throw "$($Result.ErrorCode): $($Result.Error)"
    }
    if ($Invocation.ExitCode -ne 0) {
        throw "Project succeeded but the SSH supervisor exited with $($Invocation.ExitCode)."
    }
    Write-Host '[RDP] Project completed.'
    exit 0
} catch {
    [Console]::Error.WriteLine("[ERROR] $($_.Exception.Message)")
    [Console]::Error.WriteLine(
        "[ERROR] Run `"$CommandName .project --help`" for project usage."
    )
    exit 1
} finally {
    if (-not [string]::IsNullOrWhiteSpace($ResolvedSshEntry)) {
        Remove-RdpClientExecRemoteTransfersBestEffort `
            -SshEntryPath $ResolvedSshEntry `
            -RemoteNames @($RemoteInputName, $RemoteOutputName)
    }
    foreach ($Path in @($LocalInputArchive, $LocalOutputArchive)) {
        if (-not [string]::IsNullOrWhiteSpace($Path) -and [IO.File]::Exists($Path)) {
            try { [IO.File]::Delete($Path) } catch { }
        }
    }
    Close-RdpClientSessionDisplayLease -Lease $Lease
}
