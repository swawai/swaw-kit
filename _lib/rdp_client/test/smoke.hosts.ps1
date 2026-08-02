[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = New-Object Text.UTF8Encoding($false)

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$TemplateEntry = Join-Path $RepoRoot 'Favorites\template.rdp1.cmd'
$HostsScript = Join-Path $PSScriptRoot '..\hosts.ps1'
$ScratchRoot = Join-Path `
    (Join-Path $RepoRoot 'data\_test') `
    ('rdp-client-hosts-' + [Guid]::NewGuid().ToString('N'))
$Entry = Join-Path $ScratchRoot 'hosts-test.cmd'
$HostsFile = Join-Path $ScratchRoot 'hosts'
$Alias = 'smoke-test-administrator.rdp.home.arpa'
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Invoke-HostsAction {
    param(
        [string]$Action,
        [int]$ExpectedExitCode,
        [AllowEmptyString()][string]$TestAlias = $Alias,
        [switch]$DryRun
    )

    $PreviousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $PowerShellArguments = @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $HostsScript,
            '-EntryFile', $Entry,
            '-Action', $Action,
            '-CommandName', 'hosts-test',
            '-HostsPath', $HostsFile
        )
        if ($TestAlias.Length -gt 0) {
            $PowerShellArguments += @('-HostAlias', $TestAlias)
        }
        if ($DryRun) {
            $PowerShellArguments += '-DryRun'
        }
        $Output = (& PowerShell.exe @PowerShellArguments 2>&1 | Out-String)
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousPreference
    }

    if ($ExitCode -ne $ExpectedExitCode) {
        throw "Unexpected hosts $Action exit code: $ExitCode`n$Output"
    }
    return $Output
}

function Set-HostsText {
    param([AllowEmptyString()][string]$Text)

    [IO.File]::WriteAllText($HostsFile, $Text, $Utf8NoBom)
}

try {
    [IO.Directory]::CreateDirectory($ScratchRoot) | Out-Null
    [IO.File]::Copy($TemplateEntry, $Entry)
    $EntryText = [IO.File]::ReadAllText($Entry, [Text.Encoding]::UTF8)
    $EntryText = [regex]::Replace(
        $EntryText,
        '(?m)^full address:s:.*\r?$',
        'full address:s:192.168.1.115:3389'
    )
    $EntryText = [regex]::Replace(
        $EntryText,
        '(?m)^username:s:.*\r?$',
        'username:s:administrator'
    )
    [IO.File]::WriteAllText($Entry, $EntryText, $Utf8NoBom)

    $Original = [string]::Join("`r`n", [string[]]@(
        '# original hosts content',
        "127.0.0.1`tlocalhost",
        "10.0.0.8`tother.example`t# user-owned",
        ''
    ))
    Set-HostsText $Original

    $Missing = Invoke-HostsAction -Action status -ExpectedExitCode 0
    if (-not $Missing.Contains('State:        Missing')) {
        throw "Fresh hosts state should be Missing.`n$Missing"
    }

    $Installed = Invoke-HostsAction -Action install -ExpectedExitCode 0
    if (-not $Installed.Contains('[RDP] Installed hosts mapping:')) {
        throw "Install did not report its mutation.`n$Installed"
    }
    $ManagedMarker = "# swaw-kit:rdp-client entry=`"$Entry`""
    $ManagedLine = "192.168.1.115`t$Alias`t$ManagedMarker"
    $InstalledText = [IO.File]::ReadAllText($HostsFile, [Text.Encoding]::UTF8)
    foreach ($Expected in @('# original hosts content', 'other.example', $ManagedLine)) {
        if (-not $InstalledText.Contains($Expected)) {
            throw "Install did not preserve or add '$Expected'.`n$InstalledText"
        }
    }
    if ($InstalledText.Contains('# swaw-kit:rdp-client alias=')) {
        throw "Generated ownership markers should not repeat the mapped alias.`n$InstalledText"
    }
    $InstalledBytes = [IO.File]::ReadAllBytes($HostsFile)
    if ($InstalledBytes.Length -ge 3 -and
        $InstalledBytes[0] -eq 0xEF -and
        $InstalledBytes[1] -eq 0xBB -and
        $InstalledBytes[2] -eq 0xBF) {
        throw 'Hosts install should preserve UTF-8 without a BOM.'
    }
    if ([regex]::Matches($InstalledText, '(?<!\r)\n').Count -ne 0) {
        throw 'Hosts install should preserve CRLF newlines.'
    }

    $BeforeIdempotent = [Convert]::ToBase64String($InstalledBytes)
    $AlreadyReady = Invoke-HostsAction -Action install -ExpectedExitCode 0
    if (-not $AlreadyReady.Contains('already ready')) {
        throw "A repeated install should be idempotent.`n$AlreadyReady"
    }
    $AfterIdempotent = [Convert]::ToBase64String(
        [IO.File]::ReadAllBytes($HostsFile)
    )
    if ($BeforeIdempotent -ne $AfterIdempotent) {
        throw 'An idempotent install rewrote the hosts file.'
    }

    $Ready = Invoke-HostsAction -Action status -ExpectedExitCode 0
    if (-not $Ready.Contains('State:        Ready') -or
        -not $Ready.Contains('Orphaned:     0') -or
        -not $Ready.Contains("Entry file:   $Entry")) {
        throw "Managed hosts state should be Ready.`n$Ready"
    }

    $OrphanAlias = 'orphaned.rdp.home.arpa'
    $MissingEntry = Join-Path $ScratchRoot 'missing entry.cmd'
    $OrphanLine = "192.168.1.116`t$OrphanAlias`t# swaw-kit:rdp-client entry=`"$MissingEntry`""
    Set-HostsText ($InstalledText.TrimEnd("`r", "`n") + "`r`n$OrphanLine`r`n")
    $OrphanStatus = Invoke-HostsAction -Action status -ExpectedExitCode 0
    if (-not $OrphanStatus.Contains('Orphaned:     1')) {
        throw "Status should report an entry whose command file is absent.`n$OrphanStatus"
    }
    $BeforeDryRun = [Convert]::ToBase64String([IO.File]::ReadAllBytes($HostsFile))
    $DryRun = Invoke-HostsAction `
        -Action cleanup `
        -ExpectedExitCode 0 `
        -TestAlias '' `
        -DryRun
    if (-not $DryRun.Contains("$OrphanAlias <- $MissingEntry") -or
        -not $DryRun.Contains('Dry run: no hosts entries were changed')) {
        throw "Cleanup dry-run should list the orphan and remain non-mutating.`n$DryRun"
    }
    $AfterDryRun = [Convert]::ToBase64String([IO.File]::ReadAllBytes($HostsFile))
    if ($BeforeDryRun -ne $AfterDryRun) {
        throw 'Cleanup dry-run modified the hosts file.'
    }
    $Cleanup = Invoke-HostsAction `
        -Action cleanup `
        -ExpectedExitCode 0 `
        -TestAlias ''
    if (-not $Cleanup.Contains('Removed 1 orphaned managed hosts mapping')) {
        throw "Cleanup did not report the orphan removal.`n$Cleanup"
    }
    $CleanedText = [IO.File]::ReadAllText($HostsFile, [Text.Encoding]::UTF8)
    if ($CleanedText.Contains($OrphanLine) -or
        -not $CleanedText.Contains($ManagedLine)) {
        throw "Cleanup should remove only missing-entry markers.`n$CleanedText"
    }
    $InstalledText = $CleanedText

    $DriftedText = $InstalledText.Replace(
        "192.168.1.115`t$Alias",
        "192.168.1.99`t$Alias"
    )
    Set-HostsText $DriftedText
    Invoke-HostsAction -Action install -ExpectedExitCode 0 | Out-Null
    $RepairedText = [IO.File]::ReadAllText($HostsFile, [Text.Encoding]::UTF8)
    if (-not $RepairedText.Contains($ManagedLine) -or
        $RepairedText.Contains("192.168.1.99`t$Alias`t# swaw-kit")) {
        throw "Install did not repair its drifted managed line.`n$RepairedText"
    }

    $ConflictText = $RepairedText.TrimEnd("`r", "`n") +
        "`r`n192.168.1.99`t$Alias`t# user conflict`r`n"
    Set-HostsText $ConflictText
    $BeforeConflict = [Convert]::ToBase64String([IO.File]::ReadAllBytes($HostsFile))
    $Conflict = Invoke-HostsAction -Action install -ExpectedExitCode 1
    if (-not $Conflict.Contains('conflicting hosts entries')) {
        throw "A foreign conflicting mapping should fail closed.`n$Conflict"
    }
    $AfterConflict = [Convert]::ToBase64String([IO.File]::ReadAllBytes($HostsFile))
    if ($BeforeConflict -ne $AfterConflict) {
        throw 'A failed conflict check modified the hosts file.'
    }

    Invoke-HostsAction -Action remove -ExpectedExitCode 0 | Out-Null
    $RemovedText = [IO.File]::ReadAllText($HostsFile, [Text.Encoding]::UTF8)
    if ($RemovedText.Contains('swaw-kit:rdp-client') -or
        -not $RemovedText.Contains('# user conflict')) {
        throw "Remove should delete only owned lines.`n$RemovedText"
    }

    Set-HostsText "192.168.1.115`t$Alias`t# user-owned`r`n"
    $ExternalBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($HostsFile))
    $External = Invoke-HostsAction -Action install -ExpectedExitCode 0
    if (-not $External.Contains('equivalent unowned hosts mapping')) {
        throw "Equivalent external mappings should not be adopted.`n$External"
    }
    $ExternalAfter = [Convert]::ToBase64String([IO.File]::ReadAllBytes($HostsFile))
    if ($ExternalBefore -ne $ExternalAfter) {
        throw 'An equivalent external mapping was unexpectedly modified.'
    }

    [IO.File]::Delete($HostsFile)
    Invoke-HostsAction -Action install -ExpectedExitCode 0 | Out-Null
    if (-not [IO.File]::Exists($HostsFile)) {
        throw 'Install should create a missing hosts file.'
    }

    $HostnameEntry = $EntryText.Replace(
        'full address:s:192.168.1.115:3389',
        'full address:s:server.example:3389'
    )
    [IO.File]::WriteAllText($Entry, $HostnameEntry, $Utf8NoBom)
    Set-HostsText ''
    $Unsupported = Invoke-HostsAction -Action install -ExpectedExitCode 1
    if (-not $Unsupported.Contains('source full address must use an IP address')) {
        throw "A DNS source should be rejected for hosts installation.`n$Unsupported"
    }

    $Disabled = Invoke-HostsAction `
        -Action status `
        -ExpectedExitCode 0 `
        -TestAlias ''
    if (-not $Disabled.Contains('Disabled')) {
        throw "An empty alias should report Disabled.`n$Disabled"
    }

    Write-Host 'rdp client hosts tests: PASS' -ForegroundColor Green
} finally {
    foreach ($Path in @($HostsFile, $Entry)) {
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Delete($Path)
        }
    }
    if ([IO.Directory]::Exists($ScratchRoot)) {
        [IO.Directory]::Delete($ScratchRoot, $false)
    }
}
