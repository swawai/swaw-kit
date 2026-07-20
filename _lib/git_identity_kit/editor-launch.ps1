[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("code", "cursor")]
    [string]$Tool,

    [switch]$DropFirst,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "editor-window-state.ps1")

function Get-NormalizedDirectory {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "Editor target is not a directory: $Path"
    }

    $fullPath = [IO.Path]::GetFullPath($item.FullName)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if (Test-EditorTextEqual $fullPath $root) {
        throw "A drive root cannot be used as an editor target."
    }
    return $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Get-IdentityFingerprint {
    $entryFile = [IO.Path]::GetFullPath($env:GIT_ID_ENTRY_FILE).ToLowerInvariant()
    $fields = @(
        @("GIT_ID_ENTRY_FILE", $entryFile),
        @("GIT_ID_NAME", [string]$env:GIT_ID_NAME),
        @("GIT_ID_EMAIL", [string]$env:GIT_ID_EMAIL),
        @("GIT_ID_ACCESS", [string]$env:GIT_ID_ACCESS),
        @("GIT_ID_SIGNING_KEY", [string]$env:GIT_ID_SIGNING_KEY),
        @("GIT_ID_GPG_FORMAT", [string]$env:GIT_ID_GPG_FORMAT)
    )

    $payload = "swaw-kit-git.identity.v1`0"
    foreach ($field in $fields) {
        $payload += $field[0] + "=" + $field[1] + "`0"
    }

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($payload)
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Read-EditorRecords {
    param([string]$StatePath, [string]$EntryFile)

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return @()
    }

    try {
        $state = [IO.File]::ReadAllText($StatePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        throw "Editor state is invalid. Delete '$StatePath' and retry. $($_.Exception.Message)"
    }

    [int]$version = 0
    if (-not [int]::TryParse([string]$state.version, [ref]$version) -or $version -ne 3) {
        $displayVersion = if ($null -eq $state.version) { "missing" } else { [string]$state.version }
        throw "Editor state version '$displayVersion' is unsupported. Close identity-owned editor windows, delete '$StatePath', and retry."
    }
    if (-not (Test-EditorTextEqual ([string]$state.entryFile) $EntryFile)) {
        throw "Editor state does not belong to this entry. Delete '$StatePath' and retry."
    }
    return @($state.windows)
}

function Write-EditorRecords {
    param([string]$StatePath, [string]$EntryFile, [object[]]$Records)

    if ($Records.Count -eq 0) {
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
        return
    }

    $directory = Split-Path $StatePath -Parent
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $state = [pscustomobject]@{
        version = 3
        entryFile = $EntryFile
        windows = @($Records)
    }
    $temporaryPath = "$StatePath.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $state | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $StatePath -Force
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-OrphanedEntryStates {
    param([string]$StateDirectory, [string]$EditorTool)

    if (-not (Test-Path -LiteralPath $StateDirectory -PathType Container)) {
        return
    }

    Get-ChildItem -LiteralPath $StateDirectory -Filter "*.$EditorTool.json" -File | ForEach-Object {
        try {
            $candidate = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($candidate.entryFile -and -not (Test-Path -LiteralPath ([string]$candidate.entryFile) -PathType Leaf)) {
                Remove-Item -LiteralPath $_.FullName -Force
            }
        } catch {
            # Malformed state is retained so it cannot silently erase identity evidence.
        }
    }
}

function Invoke-Editor {
    param([string]$EditorCommand, [string[]]$Arguments)

    & $EditorCommand @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Editor command failed with exit code $LASTEXITCODE."
    }
}

function Find-NewEditorWindow {
    param(
        [string]$EditorTool,
        [long[]]$PreviousHandles,
        [scriptblock]$GetWindows = {
            param([string]$SelectedTool)
            Get-EditorWindows $SelectedTool
        }
    )

    [long]$candidateHandle = 0
    $stableSamples = 0
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if ($attempt -gt 0) {
            Start-Sleep -Milliseconds 200
        }

        $windows = @(& $GetWindows $EditorTool)
        $newWindows = @($windows | Where-Object { $PreviousHandles -notcontains $_.Hwnd })
        if ($newWindows.Count -gt 1) {
            throw "Multiple editor windows appeared during launch; ownership cannot be determined."
        }
        if ($newWindows.Count -ne 1) {
            $candidateHandle = 0
            $stableSamples = 0
            continue
        }

        # Do not claim the first transient HWND immediately: another editor
        # launch may still be appearing in the same sampling window.
        $handle = [long]$newWindows[0].Hwnd
        if ($handle -eq $candidateHandle) {
            $stableSamples += 1
        } else {
            $candidateHandle = $handle
            $stableSamples = 1
        }
        if ($stableSamples -ge 4) {
            return $newWindows[0]
        }
    }

    return $null
}

function Invoke-IdentityEditorLaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("code", "cursor")]
        [string]$EditorTool,

        [switch]$DropCommandArgument,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EditorCommand,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$StoragePath,

        [string]$MutexName = "",

        [scriptblock]$GetWindows = {
            param([string]$SelectedTool)
            Get-EditorWindows $SelectedTool
        },

        [scriptblock]$RunEditor = {
            param([string]$Command, [string[]]$LaunchArguments)
            Invoke-Editor $Command $LaunchArguments
        },

        [scriptblock]$MarkWindow = {
            param([long]$Handle)
            Set-EditorWindowMarker $Handle
        },

        [scriptblock]$UnmarkWindow = {
            param([long]$Handle)
            Clear-EditorWindowMarker $Handle
        }
    )

    if ($DropCommandArgument -and $Arguments.Count -gt 0) {
        $Arguments = @($Arguments | Select-Object -Skip 1)
    }
    if ($Arguments.Count -gt 1 -or ($Arguments.Count -eq 1 -and $Arguments[0].StartsWith("-"))) {
        throw "Use '$($env:GIT_ID_ENTRY_COMMAND) .$EditorTool [directory]'. Editor options are not supported."
    }

    $targetArgument = if ($Arguments.Count -eq 1) { $Arguments[0] } else { "." }
    $target = Get-NormalizedDirectory $targetArgument
    $entryFile = [IO.Path]::GetFullPath($env:GIT_ID_ENTRY_FILE)
    $identity = Get-IdentityFingerprint
    $env:GIT_ID_FINGERPRINT = $identity

    $entryRoot = Split-Path $entryFile -Parent
    $entryName = [IO.Path]::GetFileNameWithoutExtension($entryFile)
    $stateDirectory = Join-Path $entryRoot "data\swaw-kit-git"
    $statePath = Join-Path $stateDirectory "$entryName.$EditorTool.json"
    $displayName = if ($EditorTool -eq "code") { "VS Code" } else { "Cursor" }

    if ([string]::IsNullOrWhiteSpace($MutexName)) {
        $MutexName = "Local\swaw-kit-git-editor-$EditorTool"
    }
    $mutex = [Threading.Mutex]::new($false, $MutexName)
    $hasMutex = $false
    try {
        try {
            $hasMutex = $mutex.WaitOne([TimeSpan]::FromSeconds(60))
        } catch [Threading.AbandonedMutexException] {
            $hasMutex = $true
        }
        if (-not $hasMutex) {
            throw "Timed out waiting for another $displayName identity launch to finish."
        }

        Remove-OrphanedEntryStates $stateDirectory $EditorTool
        $windows = @(& $GetWindows $EditorTool)
        $records = @(Read-EditorRecords $statePath $entryFile)
        $verifiedState = Resolve-EditorWindowState $storagePath $records $windows $target $identity $displayName $env:GIT_ID_ENTRY_COMMAND
        $records = @($verifiedState.Records)
        $snapshot = $verifiedState.Snapshot

        $targetCount = @($snapshot.FolderPaths | Where-Object { Test-EditorTextEqual $_ $target }).Count
        if ($targetCount -gt 1) {
            throw "$displayName has the same folder open in multiple windows. No window was activated."
        }

        $targetRecords = @($records | Where-Object { Test-EditorTextEqual ([string]$_.target) $target })
        if ($targetCount -eq 1) {
            if ($targetRecords.Count -ne 1) {
                throw "Close the existing $displayName window first.`n        $displayName already has '$(Split-Path $target -Leaf)' open, but $($env:GIT_ID_ENTRY_COMMAND) did not open it."
            }
            if (-not (Test-EditorTextEqual ([string]$targetRecords[0].identity) $identity)) {
                throw "Close and reopen the $displayName window.`n        $($env:GIT_ID_ENTRY_COMMAND) identity settings changed after '$(Split-Path $target -Leaf)' was opened."
            }

            Write-EditorRecords $statePath $entryFile $records
            $launchArguments = @($target)
            & $RunEditor $EditorCommand $launchArguments
            return
        }

        $records = @($records | Where-Object { -not (Test-EditorTextEqual ([string]$_.target) $target) })
        $previousHandles = @($windows | ForEach-Object { [long]$_.Hwnd })
        $launchArguments = @("--new-window", $target)
        & $RunEditor $EditorCommand $launchArguments
        $newWindow = Find-NewEditorWindow $EditorTool $previousHandles $GetWindows
        if (-not $newWindow) {
            throw "Close the newly opened $displayName window and retry.`n        $($env:GIT_ID_ENTRY_COMMAND) could not verify ownership of '$(Split-Path $target -Leaf)'."
        }

        $marker = & $MarkWindow ([long]$newWindow.Hwnd)
        try {
            $records += [pscustomobject]@{
                hwnd = [long]$newWindow.Hwnd
                marker = $marker
                pid = [int]$newWindow.Pid
                started = [string]$newWindow.Started
                target = $target
                identity = $identity
                state = "pending"
            }
            Write-EditorRecords $statePath $entryFile $records
        } catch {
            & $UnmarkWindow ([long]$newWindow.Hwnd)
            throw
        }
        Write-Host "[OK] $displayName opened a new window for '$target'."
        Write-Host "[PENDING] Window ownership is recorded and awaits full-path confirmation on the next .$EditorTool invocation."
        return
    } finally {
        if ($hasMutex) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    try {
        $editor = Get-Command $Tool -CommandType Application -ErrorAction Stop | Select-Object -First 1
        Invoke-IdentityEditorLaunch `
            -EditorTool $Tool `
            -DropCommandArgument:$DropFirst `
            -Arguments @($RemainingArgs) `
            -EditorCommand $editor.Source `
            -StoragePath (Get-EditorStoragePath $Tool)
        exit 0
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)"
        exit 1
    }
}
