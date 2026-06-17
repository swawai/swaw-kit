function Open-WslInstallDir {
    param([string[]]$Rest)

    if ($Rest.Count -ne 0) {
        Write-Fail "ctl install dir does not accept extra arguments."
        return 1
    }

    $installDir = Resolve-EntryPath $script:Config.InstallDir
    if ([string]::IsNullOrWhiteSpace($installDir)) {
        Write-Fail "WSL_install_dir is empty."
        return 1
    }

    Ensure-Directory $installDir
    return (Open-WindowsFolder $installDir)
}


function Install-WslResource {
    param([string[]]$Rest)

    $dryRun = $Rest -contains "--dry-run"
    $fallback = $Rest -contains "--fallback"
    if ($fallback -and ($Rest -contains "--refresh")) {
        Write-Fail "ctl install --fallback --refresh has been removed. Cached fallback images are verified by SHA256 and re-downloaded automatically when invalid."
        return 1
    }

    $nativeExtra = New-Object System.Collections.ArrayList
    foreach ($item in @($Rest)) {
        if ($null -eq $item -or $item -in @("--dry-run", "--fallback")) {
            continue
        }

        [void]$nativeExtra.Add($item)
    }

    if ($fallback) {
        return (Install-WslResourceFallback @($nativeExtra) -DryRun:$dryRun)
    }

    $source = Resolve-WslSource $script:Config.Source
    $installDir = Resolve-EntryPath $script:Config.InstallDir

    if ([string]::IsNullOrWhiteSpace($source)) {
        Write-Fail "WSL_source is empty. Set it to a .tar path or an online distro name."
        return 1
    }

    if ([string]::IsNullOrWhiteSpace($installDir)) {
        Write-Fail "WSL_install_dir is empty."
        return 1
    }

    if (Test-ArchiveSource $source) {
        $nativeArgs = @("--import", $script:Config.Name, $installDir, $source)
        if (-not [string]::IsNullOrWhiteSpace($script:Config.Version)) {
            $nativeArgs += @("--version", $script:Config.Version)
        }
        $directoryToEnsure = $installDir
    } else {
        $parentDir = Split-Path -Parent $installDir
        $nativeArgs = @("--install", $source, "--name", $script:Config.Name, "--location", $installDir, "--no-launch")
        if (-not [string]::IsNullOrWhiteSpace($script:Config.Version)) {
            $nativeArgs += @("--version", $script:Config.Version)
        }
        $directoryToEnsure = $parentDir
    }

    $nativeArgs += @($nativeExtra)

    if ($dryRun) {
        Show-NativeCommand "wsl.exe" $nativeArgs
        [void](Ensure-WslConfiguredUser -DryRun -AllowEmpty)
        return 0
    }

    Ensure-Directory $directoryToEnsure
    $exitCode = Invoke-External "wsl.exe" $nativeArgs
    if ($exitCode -ne 0) {
        if (-not (Test-ArchiveSource $source)) {
            Write-Warn "Native wsl --install failed. You can try the explicit fallback path:"
            Write-Warn "  $($script:Config.CommandName) ctl install --fallback"
        }
        return $exitCode
    }

    return (Ensure-WslConfiguredUser -AllowEmpty)
}


function Invoke-InstallControl {
    param([string[]]$Rest)

    if ($Rest.Count -gt 0 -and $Rest[0].ToLowerInvariant() -eq "dir") {
        return (Open-WslInstallDir -Rest (Get-Slice $Rest 1))
    }

    return (Install-WslResource $Rest)
}
