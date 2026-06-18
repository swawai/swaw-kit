function Test-WslMoveTargetDirectory {
    param([string]$TargetDir)

    if ([string]::IsNullOrWhiteSpace($TargetDir)) {
        Write-Fail ".moveto requires a target directory."
        return $false
    }

    if (Test-Path -LiteralPath $TargetDir -PathType Leaf) {
        Write-Fail ".moveto target is a file: $TargetDir"
        return $false
    }

    if (Test-Path -LiteralPath $TargetDir -PathType Container) {
        $items = @(Get-ChildItem -LiteralPath $TargetDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($items.Count -gt 0) {
            Write-Fail ".moveto target directory must be empty: $TargetDir"
            return $false
        }
    }

    return $true
}

function Set-WslEntryInstallDirLine {
    param(
        [string]$InstallDir,
        [switch]$DryRun
    )

    $entryFile = $script:Config.EntryFile
    if ([string]::IsNullOrWhiteSpace($entryFile) -or -not (Test-Path -LiteralPath $entryFile -PathType Leaf)) {
        Write-Fail "WSL_ENTRY_FILE is not available; cannot update WSL_install_dir."
        return 1
    }

    $lines = [System.IO.File]::ReadAllLines($entryFile)
    $lineIndex = -1
    $prefix = ""
    $suffix = ""
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(?<prefix>\s*set\s+"WSL_install_dir=)(?<value>.*)(?<suffix>"\s*)$') {
            $lineIndex = $i
            $prefix = $Matches["prefix"]
            $suffix = $Matches["suffix"]
            break
        }
    }

    if ($lineIndex -lt 0) {
        Write-Fail "WSL_install_dir line not found in entry file: $entryFile"
        return 1
    }

    if ($DryRun) {
        Write-Host "Would update WSL_install_dir in $entryFile"
        Write-Host "  WSL_install_dir=$InstallDir"
        return 0
    }

    $lines[$lineIndex] = "$prefix$InstallDir$suffix"
    [System.IO.File]::WriteAllLines($entryFile, $lines, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Updated WSL_install_dir in $entryFile"
    return 0
}

function Invoke-WslMoveTo {
    param([string[]]$Rest)

    $dryRun = $false
    $targetItems = New-Object System.Collections.ArrayList
    foreach ($item in @($Rest)) {
        if ($null -eq $item) {
            continue
        }

        if ($item -eq "--dry-run") {
            $dryRun = $true
            continue
        }

        if ($item.StartsWith("-")) {
            Write-Fail "Unknown .moveto option: $item"
            return 1
        }

        [void]$targetItems.Add($item)
    }

    if ($targetItems.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$targetItems[0])) {
        Write-Fail ".moveto requires exactly one target directory."
        return 1
    }

    $targetDir = Resolve-OutputPath ([string]$targetItems[0])
    if (-not (Test-WslMoveTargetDirectory $targetDir)) {
        return 1
    }

    $entryUpdateExit = Set-WslEntryInstallDirLine -InstallDir $targetDir -DryRun:$true
    if ($entryUpdateExit -ne 0) {
        return $entryUpdateExit
    }

    $terminateArgs = @("--terminate", $script:Config.Name)
    $moveArgs = @("--manage", $script:Config.Name, "--move", $targetDir)

    if ($dryRun) {
        Show-NativeCommand "wsl.exe" $terminateArgs
        Show-NativeCommand "wsl.exe" $moveArgs
        return 0
    }

    if ($null -eq (Get-WslDistributionRecord)) {
        Write-Fail "WSL instance is not installed: $($script:Config.Name)"
        return 1
    }

    Ensure-Directory $targetDir
    $terminateExit = Invoke-ControlNativeCommand $terminateArgs
    if ($terminateExit -ne 0) {
        return $terminateExit
    }

    $moveExit = Invoke-ControlNativeCommand $moveArgs
    if ($moveExit -ne 0) {
        return $moveExit
    }

    return (Set-WslEntryInstallDirLine -InstallDir $targetDir)
}
