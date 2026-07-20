$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$editorLaunchPath = Join-Path $repoRoot "_lib\git_identity_kit\editor-launch.ps1"
. $editorLaunchPath -Tool code

function Assert-EditorTest {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function New-TestEditorWindow {
    param(
        [long]$Hwnd,
        [long]$Marker,
        [int]$Left,
        [int]$Top,
        [int]$Width = 1216,
        [int]$Height = 808
    )

    return [pscustomobject]@{
        Hwnd = $Hwnd
        Marker = $Marker
        Pid = 10
        Started = "1000"
        HasPlacement = $true
        Left = $Left
        Top = $Top
        Width = $Width
        Height = $Height
        HasFrame = $false
        FrameLeft = 0
        FrameTop = 0
        FrameWidth = 0
        FrameHeight = 0
    }
}

function New-TestStorageEntry {
    param(
        [string]$Folder,
        [int]$X,
        [int]$Y,
        [int]$Width = 1200,
        [int]$Height = 800
    )

    return [pscustomobject]@{
        folder = ([Uri]$Folder).AbsoluteUri
        uiState = [pscustomobject]@{ x = $X; y = $Y; width = $Width; height = $Height }
    }
}

function Write-TestEditorStorage {
    param([string]$Path, [object[]]$Entries)

    $storage = [pscustomobject]@{
        windowsState = [pscustomobject]@{
            openedWindows = @($Entries)
            lastActiveWindow = $null
        }
    }
    [IO.File]::WriteAllText($Path, ($storage | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}

$tempRoot = Join-Path $repoRoot "temp_workspace\smoke-editor-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $targetA = Join-Path $tempRoot "account-a\same-repo"
    $targetB = Join-Path $tempRoot "account-b\same-repo"
    New-Item -ItemType Directory -Path $targetA,$targetB -Force | Out-Null
    $targetA = [IO.Path]::GetFullPath($targetA)
    $targetB = [IO.Path]::GetFullPath($targetB)
    $storagePath = Join-Path $tempRoot "storage.json"

    $entryA = New-TestStorageEntry $targetA 100 100
    $entryB = New-TestStorageEntry $targetB 300 200
    Write-TestEditorStorage $storagePath @($entryA, $entryB)
    $windows = @(
        (New-TestEditorWindow 101 501 92 100),
        (New-TestEditorWindow 102 502 292 200)
    )

    $snapshot = Get-EditorStorageSnapshot $storagePath $windows
    Assert-EditorTest ($snapshot.WindowMappings.Count -eq 2) "each live HWND should have one storage mapping"
    $windowA = @($snapshot.WindowMappings | Where-Object { $_.Hwnd -eq 101 })
    $windowB = @($snapshot.WindowMappings | Where-Object { $_.Hwnd -eq 102 })
    Assert-EditorTest ($windowA.Count -eq 1 -and (Test-EditorTextEqual $windowA[0].FolderPath $targetA)) "HWND 101 should map to target A"
    Assert-EditorTest ($windowB.Count -eq 1 -and (Test-EditorTextEqual $windowB[0].FolderPath $targetB)) "HWND 102 should map to target B"

    $records = @(
        [pscustomobject]@{ hwnd = 101; marker = 501; pid = 10; started = "1000"; target = $targetA; identity = "identity-a"; state = "active" },
        [pscustomobject]@{ hwnd = 102; marker = 502; pid = 10; started = "1000"; target = $targetB; identity = "identity-b"; state = "active" }
    )
    Assert-EditorTest (@(Get-LiveEditorRecords $records $windows $snapshot.WindowMappings).Count -eq 2) "matching HWND-folder leases should remain live"

    $entryA.uiState = [pscustomobject]@{ x = 300; y = 200; width = 1200; height = 800 }
    $entryB.uiState = [pscustomobject]@{ x = 100; y = 100; width = 1200; height = 800 }
    Write-TestEditorStorage $storagePath @($entryA, $entryB)
    $swappedSnapshot = Get-EditorStorageSnapshot $storagePath $windows
    $swappedRecords = @(Get-LiveEditorRecords $records $windows $swappedSnapshot.WindowMappings)
    Assert-EditorTest ($swappedRecords.Count -eq 2) "Open Folder should retain ownership through the exact HWND mapping"
    Assert-EditorTest ((@($swappedRecords | Where-Object { $_.hwnd -eq 101 })[0].target) -eq $targetB) "HWND 101 should follow its newly mapped folder"
    Assert-EditorTest ((@($swappedRecords | Where-Object { $_.hwnd -eq 102 })[0].target) -eq $targetA) "HWND 102 should follow its newly mapped folder"

    $frameOnlyWindow = [pscustomobject]@{
        Hwnd = 103; Marker = 503; Pid = 10; Started = "1000"
        HasPlacement = $false; Left = 0; Top = 0; Width = 0; Height = 0
        HasFrame = $true; FrameLeft = 92; FrameTop = 100; FrameWidth = 1216; FrameHeight = 808
    }
    $entryA.uiState = [pscustomobject]@{ x = 100; y = 100; width = 1200; height = 800 }
    Assert-EditorTest ($null -ne (Get-EditorPlacementMatchScore $frameOnlyWindow $entryA)) "frame bounds should work when GetWindowPlacement is unavailable"

    $originalScoreFunction = ${function:Get-EditorPlacementMatchScore}
    try {
        Set-Item Function:Get-EditorPlacementMatchScore {
            param([object]$Window, [object]$Entry)
            $scores = @{
                "w1:e1" = 0; "w1:e2" = 1
                "w2:e1" = 0; "w2:e3" = 10
                "w3:e1" = 10; "w3:e3" = 0
            }
            $key = "$($Window.Id):$($Entry.Id)"
            if ($scores.ContainsKey($key)) { return [long]$scores[$key] }
            return $null
        }

        $graphEntries = @(
            [pscustomobject]@{ Id = "e1" },
            [pscustomobject]@{ Id = "e2" },
            [pscustomobject]@{ Id = "e3" }
        )
        $graphWindows = @(
            [pscustomobject]@{ Id = "w1"; Hwnd = 201 },
            [pscustomobject]@{ Id = "w2"; Hwnd = 202 },
            [pscustomobject]@{ Id = "w3"; Hwnd = 203 }
        )
        $completeMappings = @(Select-LiveEditorWindowMappings $graphEntries $graphWindows)
        Assert-EditorTest ($completeMappings.Count -eq 3) "complete matching should find the assignment that a local greedy choice misses"
        Assert-EditorTest ($completeMappings[0].Entry.Id -eq "e2") "the complete assignment should reserve e1 for the constrained windows"

        Set-Item Function:Get-EditorPlacementMatchScore {
            param([object]$Window, [object]$Entry)
            return [long]0
        }
        $ambiguousMappings = @(Select-LiveEditorWindowMappings $graphEntries[0..1] $graphWindows[0..1])
        Assert-EditorTest ($ambiguousMappings.Count -eq 0) "equally optimal HWND-entry assignments must fail closed"

        Set-Item Function:Get-EditorPlacementMatchScore {
            param([object]$Window, [object]$Entry)
            if ($Window.Id -lt 10 -and $Entry.Id -lt 9) { return [long]0 }
            if ($Window.Id -eq 10) { return [long]0 }
            return $null
        }
        $hallEntries = @(0..10 | ForEach-Object { [pscustomobject]@{ Id = $_ } })
        $hallWindows = @(0..10 | ForEach-Object { [pscustomobject]@{ Id = $_; Hwnd = 400 + $_ } })
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $hallMappings = @(Select-LiveEditorWindowMappings $hallEntries $hallWindows)
        $stopwatch.Stop()
        Assert-EditorTest ($hallMappings.Count -eq 0) "a Hall-conflict graph has no complete mapping"
        Assert-EditorTest ($stopwatch.Elapsed.TotalSeconds -lt 3) "an ambiguous no-match graph should fail closed within the search budget"
    } finally {
        Set-Item Function:Get-EditorPlacementMatchScore $originalScoreFunction
    }

    # Previous target paths are not independent HWND-to-folder evidence. The
    # owned HWND may have used Open Folder from A to B while an external window
    # subsequently opened A. When both windows have indistinguishable bounds,
    # history-based anchoring would silently assign the external A back to the
    # owned HWND. Preserve the lease and fail closed instead.
    $sameBoundsEntryA = New-TestStorageEntry $targetA 100 100
    $sameBoundsEntryB = New-TestStorageEntry $targetB 100 100
    Write-TestEditorStorage $storagePath @($sameBoundsEntryA, $sameBoundsEntryB)
    $sameBoundsWindows = @(
        (New-TestEditorWindow 211 811 92 100),
        (New-TestEditorWindow 212 0 92 100)
    )
    $historicalRecord = [pscustomobject]@{
        hwnd = 211; marker = 811; pid = 10; started = "1000"
        target = $targetA; identity = "identity-a"; state = "active"
    }
    $historicalAnchorRejected = $false
    try {
        $null = Resolve-EditorWindowState $storagePath @($historicalRecord) $sameBoundsWindows $targetB "identity-a" "VS Code" "git1"
    } catch {
        $historicalAnchorRejected = $_.Exception.Message -match "cannot be mapped safely"
    }
    Assert-EditorTest $historicalAnchorRejected "an active lease's previous path must not disambiguate identical windows after Open Folder"
    Assert-EditorTest (Test-EditorTextEqual ([string]$historicalRecord.target) $targetA) "failed ambiguity resolution must not rewrite the active lease target"

    $entryA.uiState = [pscustomobject]@{ x = 100; y = 100; width = 1200; height = 800 }
    $pendingWindow = @(New-TestEditorWindow 301 701 92 100)
    $pendingRecord = [pscustomobject]@{
        hwnd = 301; marker = 701; pid = 10; started = "1000"
        target = $targetA; identity = "identity-a"; state = "pending"
    }
    Write-TestEditorStorage $storagePath @()
    $pendingRejected = $false
    try {
        $null = Resolve-EditorWindowState $storagePath @($pendingRecord) $pendingWindow $targetA "identity-a" "VS Code" "git1"
    } catch {
        $pendingRejected = $_.Exception.Message -match "still confirming ownership"
    }
    Assert-EditorTest $pendingRejected "a bound pending lease should block a rapid second launch while storage lags"
    Assert-EditorTest ($pendingRecord.state -eq "pending") "failed verification must not erase or promote the pending lease"

    $identityChangeRejected = $false
    try {
        $null = Resolve-EditorWindowState $storagePath @($pendingRecord) $pendingWindow $targetA "identity-b" "VS Code" "git1"
    } catch {
        $identityChangeRejected = $_.Exception.Message -match "identity settings changed"
    }
    Assert-EditorTest $identityChangeRejected "a pending window must reject a changed entry identity"

    $otherTarget = Join-Path $tempRoot "stale-window"
    New-Item -ItemType Directory -Path $otherTarget -Force | Out-Null
    $staleEntry = New-TestStorageEntry $otherTarget 100 100
    Write-TestEditorStorage $storagePath @($staleEntry)
    $misleadingSnapshotRejected = $false
    try {
        $null = Resolve-EditorWindowState $storagePath @($pendingRecord) $pendingWindow $targetA "identity-a" "VS Code" "git1"
    } catch {
        $misleadingSnapshotRejected = $_.Exception.Message -match "still confirming ownership"
    }
    Assert-EditorTest $misleadingSnapshotRejected "a successful but stale storage match must not discard a bound pending lease"
    Assert-EditorTest ($pendingRecord.state -eq "pending") "a stale storage match must keep the pending lease"

    Write-TestEditorStorage $storagePath @($entryA)
    $verified = Resolve-EditorWindowState $storagePath @($pendingRecord) $pendingWindow $targetA "identity-a" "VS Code" "git1"
    Assert-EditorTest ($verified.Records.Count -eq 1 -and $verified.Records[0].state -eq "active") "a pending lease should become active only after its own HWND maps to the target"

    $orchestrationRoot = Join-Path $tempRoot "orchestration-entry"
    $orchestrationTarget = Join-Path $tempRoot "orchestration-target"
    New-Item -ItemType Directory -Path $orchestrationRoot,$orchestrationTarget -Force | Out-Null
    $orchestrationTarget = [IO.Path]::GetFullPath($orchestrationTarget)
    $orchestrationEntry = Join-Path $orchestrationRoot "git-test.cmd"
    [IO.File]::WriteAllText($orchestrationEntry, "@echo off`r`n", [Text.UTF8Encoding]::new($false))
    $orchestrationStorage = Join-Path $tempRoot "orchestration-storage.json"
    $orchestrationState = Join-Path $orchestrationRoot "data\swaw-kit-git\git-test.code.json"
    $testMutexName = "Local\swaw-kit-git-editor-smoke-$([guid]::NewGuid().ToString('N'))"
    $oldIdentityEnvironment = @{}
    foreach ($name in @(
        "GIT_ID_ENTRY_FILE", "GIT_ID_ENTRY_COMMAND", "GIT_ID_NAME", "GIT_ID_EMAIL",
        "GIT_ID_ACCESS", "GIT_ID_SIGNING_KEY", "GIT_ID_GPG_FORMAT", "GIT_ID_FINGERPRINT"
    )) {
        $oldIdentityEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    try {
        $env:GIT_ID_ENTRY_FILE = $orchestrationEntry
        $env:GIT_ID_ENTRY_COMMAND = "git-test"
        $env:GIT_ID_NAME = "Editor Test"
        $env:GIT_ID_EMAIL = "editor@example.test"
        $env:GIT_ID_ACCESS = "ssh:ssh -i test-key"
        $env:GIT_ID_SIGNING_KEY = ""
        $env:GIT_ID_GPG_FORMAT = ""

        $fakeWindow = New-TestEditorWindow 901 0 92 100
        $windowSnapshotState = [pscustomobject]@{ Calls = 0 }
        $getWindowsForNewLaunch = {
            param([string]$SelectedTool)
            $windowSnapshotState.Calls++
            if ($windowSnapshotState.Calls -eq 1) { return @() }
            return @($fakeWindow)
        }.GetNewClosure()
        $launches = [Collections.Generic.List[object]]::new()
        $runEditor = {
            param([string]$Command, [string[]]$LaunchArguments)
            [void]$launches.Add([pscustomobject]@{ Command = $Command; Arguments = @($LaunchArguments) })
        }.GetNewClosure()
        $markWindow = {
            param([long]$Handle)
            if ($Handle -ne 901) { throw "unexpected HWND $Handle" }
            return 9901
        }
        $unmarkWindow = { param([long]$Handle) }

        $pendingInformation = @()
        Invoke-IdentityEditorLaunch `
            -EditorTool code `
            -DropCommandArgument `
            -Arguments @(".code", $orchestrationTarget) `
            -EditorCommand "fake-code.exe" `
            -StoragePath $orchestrationStorage `
            -MutexName $testMutexName `
            -GetWindows $getWindowsForNewLaunch `
            -RunEditor $runEditor `
            -MarkWindow $markWindow `
            -UnmarkWindow $unmarkWindow `
            -InformationVariable pendingInformation

        Assert-EditorTest ($launches.Count -eq 1) "the orchestrator should invoke the editor once for a new target"
        Assert-EditorTest ($launches[0].Arguments.Count -eq 2 -and $launches[0].Arguments[0] -eq "--new-window" -and (Test-EditorTextEqual $launches[0].Arguments[1] $orchestrationTarget)) "a new target should use --new-window and its complete path"
        $pendingText = @($pendingInformation | ForEach-Object { $_.MessageData.ToString() }) -join "`n"
        Assert-EditorTest ($pendingText.Contains("[PENDING] Window ownership is recorded") -and $pendingText.Contains("awaits full-path confirmation")) "new-window success should disclose that its ownership is still pending"

        $pendingState = [IO.File]::ReadAllText($orchestrationState, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-EditorTest ($pendingState.version -eq 3 -and @($pendingState.windows).Count -eq 1) "the orchestrator should persist one v3 window lease"
        Assert-EditorTest ($pendingState.windows[0].state -eq "pending" -and $pendingState.windows[0].hwnd -eq 901 -and $pendingState.windows[0].marker -eq 9901) "a new HWND should be persisted as a marked pending lease"

        $fakeWindow.Marker = 9901
        Write-TestEditorStorage $orchestrationStorage @((New-TestStorageEntry $orchestrationTarget 100 100))
        $getWindowsForActivation = { param([string]$SelectedTool) @($fakeWindow) }.GetNewClosure()
        Invoke-IdentityEditorLaunch `
            -EditorTool code `
            -Arguments @($orchestrationTarget) `
            -EditorCommand "fake-code.exe" `
            -StoragePath $orchestrationStorage `
            -MutexName $testMutexName `
            -GetWindows $getWindowsForActivation `
            -RunEditor $runEditor `
            -MarkWindow $markWindow `
            -UnmarkWindow $unmarkWindow

        Assert-EditorTest ($launches.Count -eq 2 -and $launches[1].Arguments.Count -eq 1 -and (Test-EditorTextEqual $launches[1].Arguments[0] $orchestrationTarget)) "a confirmed lease should activate the existing target without --new-window"
        $activeState = [IO.File]::ReadAllText($orchestrationState, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-EditorTest ($activeState.windows[0].state -eq "active") "the main orchestration should promote the exact pending HWND after full-path confirmation"

        $throwingRunEditor = { param([string]$Command, [string[]]$LaunchArguments) throw "injected editor launch failure" }
        $launchFailurePropagated = $false
        $stateBytesBeforeLaunchFailure = [IO.File]::ReadAllBytes($orchestrationState)
        try {
            Invoke-IdentityEditorLaunch `
                -EditorTool code `
                -Arguments @((Join-Path $tempRoot "account-a")) `
                -EditorCommand "fake-code.exe" `
                -StoragePath $orchestrationStorage `
                -MutexName $testMutexName `
                -GetWindows $getWindowsForActivation `
                -RunEditor $throwingRunEditor `
                -MarkWindow $markWindow `
                -UnmarkWindow $unmarkWindow
        } catch {
            $launchFailurePropagated = $_.Exception.Message -match "injected editor launch failure"
        }
        Assert-EditorTest $launchFailurePropagated "the injectable orchestration boundary must propagate editor failures"
        $stateBytesAfterLaunchFailure = [IO.File]::ReadAllBytes($orchestrationState)
        Assert-EditorTest ([Convert]::ToBase64String($stateBytesAfterLaunchFailure) -ceq [Convert]::ToBase64String($stateBytesBeforeLaunchFailure)) "an editor launch failure must leave the state file byte-for-byte unchanged"
        $stateAfterLaunchFailure = [IO.File]::ReadAllText($orchestrationState, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-EditorTest (@($stateAfterLaunchFailure.windows).Count -eq 1 -and $stateAfterLaunchFailure.windows[0].state -eq "active" -and (Test-EditorTextEqual ([string]$stateAfterLaunchFailure.windows[0].target) $orchestrationTarget)) "an editor launch failure must preserve the active lease semantics"

        $markerFailureRoot = Join-Path $tempRoot "marker-failure-entry"
        $markerFailureTarget = Join-Path $tempRoot "marker-failure-target"
        New-Item -ItemType Directory -Path $markerFailureRoot,$markerFailureTarget -Force | Out-Null
        $markerFailureTarget = [IO.Path]::GetFullPath($markerFailureTarget)
        $markerFailureEntry = Join-Path $markerFailureRoot "git-marker-failure.cmd"
        [IO.File]::WriteAllText($markerFailureEntry, "@echo off`r`n", [Text.UTF8Encoding]::new($false))
        $markerFailureStorage = Join-Path $tempRoot "marker-failure-storage.json"
        $markerFailureState = Join-Path $markerFailureRoot "data\swaw-kit-git\git-marker-failure.code.json"
        $markerFailureWindow = New-TestEditorWindow 902 0 192 200
        $markerFailureSnapshots = [pscustomobject]@{ Calls = 0 }
        $getWindowsForMarkerFailure = {
            param([string]$SelectedTool)
            $markerFailureSnapshots.Calls++
            if ($markerFailureSnapshots.Calls -eq 1) { return @() }
            return @($markerFailureWindow)
        }.GetNewClosure()
        $markWindowForFailure = { param([long]$Handle) return 9902 }
        $unmarkedHandles = [Collections.Generic.List[long]]::new()
        $unmarkWindowForFailure = {
            param([long]$Handle)
            [void]$unmarkedHandles.Add($Handle)
        }.GetNewClosure()
        $runEditorForMarkerFailure = { param([string]$Command, [string[]]$LaunchArguments) }
        $originalWriteEditorRecords = ${function:Write-EditorRecords}
        $entryBeforeMarkerFailure = $env:GIT_ID_ENTRY_FILE
        $markerWriteFailurePropagated = $false
        try {
            $env:GIT_ID_ENTRY_FILE = $markerFailureEntry
            Set-Item Function:Write-EditorRecords {
                param([string]$StatePath, [string]$EntryFile, [object[]]$Records)
                throw "injected editor state write failure"
            }
            Invoke-IdentityEditorLaunch `
                -EditorTool code `
                -Arguments @($markerFailureTarget) `
                -EditorCommand "fake-code.exe" `
                -StoragePath $markerFailureStorage `
                -MutexName $testMutexName `
                -GetWindows $getWindowsForMarkerFailure `
                -RunEditor $runEditorForMarkerFailure `
                -MarkWindow $markWindowForFailure `
                -UnmarkWindow $unmarkWindowForFailure
        } catch {
            $markerWriteFailurePropagated = $_.Exception.Message -match "injected editor state write failure"
        } finally {
            Set-Item Function:Write-EditorRecords $originalWriteEditorRecords
            $env:GIT_ID_ENTRY_FILE = $entryBeforeMarkerFailure
        }
        Assert-EditorTest $markerWriteFailurePropagated "a state write failure after marking must propagate"
        Assert-EditorTest ($unmarkedHandles.Count -eq 1 -and $unmarkedHandles[0] -eq 902) "a state write failure after marking must clear the exact HWND marker"
        Assert-EditorTest (-not (Test-Path -LiteralPath $markerFailureState -PathType Leaf)) "a failed pending-lease write must not leave a new state file"
    } finally {
        foreach ($name in $oldIdentityEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $oldIdentityEnvironment[$name])
        }
    }

    $fakeBin = Join-Path $tempRoot "fake-bin"
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeBin "code.cmd"), "@echo off`r`nexit /b 0`r`n", [Text.UTF8Encoding]::new($false))
    $oldPath = $env:PATH
    try {
        $env:PATH = "$fakeBin;$oldPath"
        $engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $wrapperOutput = @(& $engine -NoLogo -NoProfile -ExecutionPolicy Bypass -File $editorLaunchPath -Tool code -RemainingArgs "--unsupported" 2>&1 | ForEach-Object { $_.ToString() })
        $wrapperExitCode = $LASTEXITCODE
    } finally {
        $env:PATH = $oldPath
    }
    Assert-EditorTest ($wrapperExitCode -eq 1) "the production -File wrapper should preserve a main-orchestration failure exit code"
    Assert-EditorTest ((($wrapperOutput | Out-String).Contains("[ERROR] Use"))) "the production wrapper should render the propagated orchestration error"

    Write-Host "editor smoke tests passed"
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
