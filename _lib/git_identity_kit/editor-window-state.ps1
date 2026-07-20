. (Join-Path $PSScriptRoot "editor-windows.ps1")

function Test-EditorTextEqual {
    param([string]$Left, [string]$Right)
    return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
}

function Get-EditorStoragePath {
    param([string]$Tool)

    $applicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    if (-not $applicationData) {
        throw "Windows application data directory could not be resolved."
    }

    $productDirectory = if ($Tool -eq "code") { "Code" } elseif ($Tool -eq "cursor") { "Cursor" } else { throw "Unsupported editor tool: $Tool" }
    return Join-Path $applicationData "$productDirectory\User\globalStorage\storage.json"
}

function ConvertFrom-EditorFileUri {
    param([string]$Value)

    if (-not $Value) {
        return $null
    }

    $uri = [Uri]$Value
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne "file") {
        return $null
    }

    $path = [Uri]::UnescapeDataString($uri.AbsolutePath).Replace("/", "\")
    if ($uri.Host -and -not (Test-EditorTextEqual $uri.Host "localhost")) {
        $path = "\\$($uri.Host)\" + $path.TrimStart("\")
    } elseif ($path -match '^\\[A-Za-z]:') {
        $path = $path.Substring(1)
    }

    $fullPath = [IO.Path]::GetFullPath($path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if (Test-EditorTextEqual $fullPath $root) {
        return $fullPath
    }
    return $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Read-EditorStorageJson {
    param([string]$StoragePath)

    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            return [IO.File]::ReadAllText($StoragePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        } catch {
            if ($attempt -eq 2) {
                throw "Editor window storage could not be read: $StoragePath. $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds 40
        }
    }
}

function Get-EditorStorageEntries {
    param(
        [string]$StoragePath,
        [int]$LiveWindowCount
    )

    if ($LiveWindowCount -eq 0) {
        return @()
    }
    if (-not (Test-Path -LiteralPath $StoragePath -PathType Leaf)) {
        throw "Editor is running, but its window storage is missing: $StoragePath"
    }

    $storage = Read-EditorStorageJson $StoragePath
    if (-not $storage.windowsState) {
        throw "Editor window storage has an unsupported format: $StoragePath"
    }

    $openedEntries = @($storage.windowsState.openedWindows)
    if ($LiveWindowCount -eq 1 -and $openedEntries.Count -eq 0) {
        if ($storage.windowsState.lastActiveWindow) {
            return @($storage.windowsState.lastActiveWindow)
        }
        return @()
    }
    return @($openedEntries)
}

function Get-EditorBoundsMatchScore {
    param(
        [int]$Left,
        [int]$Top,
        [int]$Width,
        [int]$Height,
        [int]$EntryX,
        [int]$EntryY,
        [int]$EntryWidth,
        [int]$EntryHeight
    )

    if ($Width -le 0 -or $Height -le 0) {
        return $null
    }

    $centerXDifference = [Math]::Abs((2 * $Left + $Width) - (2 * $EntryX + $EntryWidth))
    $centerYDifference = [Math]::Abs((2 * $Top + $Height) - (2 * $EntryY + $EntryHeight))
    $widthDifference = [Math]::Abs($Width - $EntryWidth)
    $heightDifference = [Math]::Abs($Height - $EntryHeight)
    if ($centerXDifference -gt 64 -or $centerYDifference -gt 64 -or
        $widthDifference -gt 64 -or $heightDifference -gt 64) {
        return $null
    }

    return $centerXDifference + $centerYDifference + $widthDifference + $heightDifference
}

function Get-EditorPlacementMatchScore {
    param(
        [object]$Window,
        [object]$Entry
    )

    if ((-not $Window.HasPlacement -and -not $Window.HasFrame) -or -not $Entry.uiState) {
        return $null
    }

    [int]$entryX = 0
    [int]$entryY = 0
    [int]$entryWidth = 0
    [int]$entryHeight = 0
    if (-not [int]::TryParse([string]$Entry.uiState.x, [ref]$entryX) -or
        -not [int]::TryParse([string]$Entry.uiState.y, [ref]$entryY) -or
        -not [int]::TryParse([string]$Entry.uiState.width, [ref]$entryWidth) -or
        -not [int]::TryParse([string]$Entry.uiState.height, [ref]$entryHeight) -or
        $entryWidth -le 0 -or $entryHeight -le 0) {
        return $null
    }

    # Normal/minimized windows are represented by the current frame. Maximized
    # windows keep their previous restore bounds in GetWindowPlacement, so both
    # rectangles are candidates. VS Code omits the Windows resize border; their
    # centers still align and their dimensions differ by only a few pixels.
    $scores = @()
    if ($Window.HasPlacement) {
        $score = Get-EditorBoundsMatchScore $Window.Left $Window.Top $Window.Width $Window.Height $entryX $entryY $entryWidth $entryHeight
        if ($null -ne $score) {
            $scores += $score
        }
    }
    if ($Window.HasFrame) {
        $score = Get-EditorBoundsMatchScore $Window.FrameLeft $Window.FrameTop $Window.FrameWidth $Window.FrameHeight $entryX $entryY $entryWidth $entryHeight
        if ($null -ne $score) {
            $scores += $score
        }
    }
    if ($scores.Count -eq 0) {
        return $null
    }
    return ($scores | Measure-Object -Minimum).Minimum
}

function Select-LiveEditorWindowMappings {
    param(
        [object[]]$Entries,
        [object[]]$LiveWindows
    )

    if ($Entries.Count -lt $LiveWindows.Count) {
        return @()
    }

    $windowChoices = @()
    for ($windowIndex = 0; $windowIndex -lt $LiveWindows.Count; $windowIndex++) {
        $candidates = @()
        for ($entryIndex = 0; $entryIndex -lt $Entries.Count; $entryIndex++) {
            $score = Get-EditorPlacementMatchScore $LiveWindows[$windowIndex] $Entries[$entryIndex]
            if ($null -ne $score) {
                $candidates += [pscustomobject]@{
                    EntryIndex = $entryIndex
                    Entry = $Entries[$entryIndex]
                    Score = [long]$score
                }
            }
        }
        if ($candidates.Count -eq 0) {
            return @()
        }
        $windowChoices += [pscustomobject]@{
            WindowIndex = $windowIndex
            Candidates = @($candidates | Sort-Object Score, EntryIndex)
        }
    }

    # A local greedy choice can consume the only entry available to a later
    # window. Search complete assignments instead, minimize their total score,
    # and accept the result only when that optimum is unique.
    $orderedChoices = @($windowChoices | Sort-Object { $_.Candidates.Count }, WindowIndex)
    $usedEntries = [Collections.Generic.HashSet[int]]::new()
    $workingAssignment = New-Object object[] $LiveWindows.Count
    $bestAssignment = [Collections.Generic.List[object]]::new()
    $bestScore = [long[]]@([long]::MaxValue)
    $bestCount = [int[]]@(0)
    $searchNodes = [int[]]@(0)
    $searchAborted = [bool[]]@($false)
    $maxSearchNodes = 25000
    $search = $null
    $search = {
        param([int]$Depth, [long]$Score)

        $searchNodes[0] += 1
        if ($searchNodes[0] -gt $maxSearchNodes) {
            $searchAborted[0] = $true
            return
        }

        $lowerBound = $Score
        for ($remainingIndex = $Depth; $remainingIndex -lt $orderedChoices.Count; $remainingIndex++) {
            $minimum = [long]::MaxValue
            foreach ($candidate in $orderedChoices[$remainingIndex].Candidates) {
                if (-not $usedEntries.Contains([int]$candidate.EntryIndex) -and $candidate.Score -lt $minimum) {
                    $minimum = [long]$candidate.Score
                }
            }
            if ($minimum -eq [long]::MaxValue) {
                return
            }
            $lowerBound += $minimum
        }
        if ($lowerBound -gt $bestScore[0] -or ($lowerBound -eq $bestScore[0] -and $bestCount[0] -ge 2)) {
            return
        }

        if ($Depth -eq $orderedChoices.Count) {
            if ($Score -lt $bestScore[0]) {
                $bestScore[0] = $Score
                $bestCount[0] = 1
                $bestAssignment.Clear()
                foreach ($candidate in $workingAssignment) {
                    $bestAssignment.Add($candidate)
                }
            } elseif ($Score -eq $bestScore[0]) {
                $bestCount[0] = [Math]::Min(2, $bestCount[0] + 1)
            }
            return
        }

        $choice = $orderedChoices[$Depth]
        foreach ($candidate in $choice.Candidates) {
            if ($searchAborted[0]) {
                return
            }
            $entryIndex = [int]$candidate.EntryIndex
            if (-not $usedEntries.Add($entryIndex)) {
                continue
            }
            $workingAssignment[[int]$choice.WindowIndex] = $candidate
            & $search ($Depth + 1) ($Score + [long]$candidate.Score)
            $workingAssignment[[int]$choice.WindowIndex] = $null
            [void]$usedEntries.Remove($entryIndex)
        }
    }
    & $search 0 0

    if ($searchAborted[0] -or $bestCount[0] -ne 1 -or $bestAssignment.Count -ne $LiveWindows.Count) {
        return @()
    }

    $mappings = @()
    for ($windowIndex = 0; $windowIndex -lt $LiveWindows.Count; $windowIndex++) {
        $candidate = $bestAssignment[$windowIndex]
        $folderPath = $null
        if ($candidate.Entry.folder) {
            try {
                $folderPath = ConvertFrom-EditorFileUri ([string]$candidate.Entry.folder)
            } catch {
                throw "Editor window storage contains an invalid folder URI: $($candidate.Entry.folder)"
            }
        }
        $mappings += [pscustomobject]@{
            Hwnd = [long]$LiveWindows[$windowIndex].Hwnd
            FolderPath = $folderPath
            Entry = $candidate.Entry
        }
    }
    return @($mappings)
}

function Get-EditorStorageSnapshot {
    param(
        [string]$StoragePath,
        [object[]]$LiveWindows
    )

    if ($LiveWindows.Count -eq 0) {
        return [pscustomobject]@{ WindowMappings = @(); FolderPaths = @(); EntryCount = 0 }
    }
    $entries = @(Get-EditorStorageEntries $StoragePath $LiveWindows.Count)

    $windowMappings = @(Select-LiveEditorWindowMappings $entries $LiveWindows)
    if ($windowMappings.Count -ne $LiveWindows.Count) {
        throw "Editor windows cannot be mapped safely to their stored folders.`n        Storage may still be updating, or multiple windows may have indistinguishable bounds. Retry shortly; if this persists, move or restore one editor window."
    }
    $folders = @($windowMappings | ForEach-Object { $_.FolderPath } | Where-Object { $_ })

    return [pscustomobject]@{
        WindowMappings = @($windowMappings)
        FolderPaths = @($folders)
        EntryCount = $windowMappings.Count
    }
}

function Get-WindowBoundEditorRecords {
    param(
        [object[]]$Records,
        [object[]]$LiveWindows
    )

    $boundRecords = @()
    foreach ($record in $Records) {
        if (-not $record -or -not $record.target -or -not $record.identity -or -not $record.started -or -not $record.marker) {
            continue
        }

        [long]$handle = 0
        [long]$marker = 0
        [int]$processId = 0
        if (-not [long]::TryParse([string]$record.hwnd, [ref]$handle) -or
            -not [long]::TryParse([string]$record.marker, [ref]$marker) -or
            -not [int]::TryParse([string]$record.pid, [ref]$processId)) {
            continue
        }

        $window = $LiveWindows | Where-Object {
            $_.Hwnd -eq $handle -and $_.Marker -eq $marker -and $_.Pid -eq $processId -and $_.Started -eq [string]$record.started
        } | Select-Object -First 1
        if ($window) {
            $boundRecords += $record
        }
    }

    return @($boundRecords)
}

function Get-LiveEditorRecords {
    param(
        [object[]]$Records,
        [object[]]$LiveWindows,
        [object[]]$WindowMappings
    )

    $liveRecords = @()
    foreach ($record in @(Get-WindowBoundEditorRecords $Records $LiveWindows)) {
        [long]$handle = 0
        if (-not [long]::TryParse([string]$record.hwnd, [ref]$handle)) {
            continue
        }

        $matches = @($WindowMappings | Where-Object { $_.Hwnd -eq $handle })
        if ($matches.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$matches[0].FolderPath)) {
            continue
        }

        $mappedTarget = [string]$matches[0].FolderPath
        if ($record.state -eq "pending") {
            if (-not (Test-EditorTextEqual $mappedTarget ([string]$record.target))) {
                continue
            }
        } else {
            # Open Folder keeps the editor process environment. Follow the
            # exact HWND mapping so an owned window remains owned, while a
            # different entry can never claim it through a global path match.
            $record.target = $mappedTarget
        }

        $liveRecords += $record
    }

    return @($liveRecords)
}

function Resolve-EditorWindowState {
    param(
        [string]$StoragePath,
        [object[]]$Records,
        [object[]]$LiveWindows,
        [string]$Target,
        [string]$Identity,
        [string]$DisplayName,
        [string]$EntryCommand
    )

    $boundRecords = @(Get-WindowBoundEditorRecords $Records $LiveWindows)
    $pendingRecords = @($boundRecords | Where-Object { $_.state -eq "pending" })
    try {
        $snapshot = Get-EditorStorageSnapshot $StoragePath $LiveWindows
    } catch {
        if ($pendingRecords.Count -eq 0) {
            throw
        }

        $pendingTargetRecords = @($pendingRecords | Where-Object { Test-EditorTextEqual ([string]$_.target) $Target })
        if ($pendingTargetRecords.Count -eq 1 -and
            -not (Test-EditorTextEqual ([string]$pendingTargetRecords[0].identity) $Identity)) {
            throw "Close and reopen the $DisplayName window.`n        $EntryCommand identity settings changed while '$(Split-Path $Target -Leaf)' was opening."
        }
        throw "Retry after a few seconds.`n        $DisplayName is still confirming ownership of a newly opened window."
    }

    $verifiedPendingRecords = @(Get-LiveEditorRecords $pendingRecords $LiveWindows $snapshot.WindowMappings)
    if ($verifiedPendingRecords.Count -ne $pendingRecords.Count) {
        $pendingTargetRecords = @($pendingRecords | Where-Object { Test-EditorTextEqual ([string]$_.target) $Target })
        if ($pendingTargetRecords.Count -eq 1 -and
            -not (Test-EditorTextEqual ([string]$pendingTargetRecords[0].identity) $Identity)) {
            throw "Close and reopen the $DisplayName window.`n        $EntryCommand identity settings changed while '$(Split-Path $Target -Leaf)' was opening."
        }
        throw "Retry after a few seconds.`n        $DisplayName is still confirming ownership of a newly opened window."
    }

    $liveRecords = @(Get-LiveEditorRecords $Records $LiveWindows $snapshot.WindowMappings)
    foreach ($record in $liveRecords) {
        if ($record.state -eq "pending") {
            $record.state = "active"
        }
    }

    return [pscustomobject]@{
        Records = @($liveRecords)
        Snapshot = $snapshot
    }
}
