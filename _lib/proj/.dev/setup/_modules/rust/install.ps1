Set-StrictMode -Version 2.0

function Invoke-ProjDevRustupInstaller {
    param(
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $Info = [Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $InstallerPath
    $Info.Arguments = ConvertTo-ProjDevRustWindowsArguments -Arguments @(
        '-y'
        '--default-host'
        [string]$Definition.Host
        '--no-modify-path'
        '--profile'
        [string]$Definition.Profile
        '--default-toolchain'
        [string]$Definition.Toolchain
    )
    $Info.WorkingDirectory = $InstallRoot
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $false
    Set-ProjDevRustProcessEnvironment `
        -Info $Info `
        -InstallRoot $InstallRoot
    $Info.EnvironmentVariables['RUSTUP_INIT_SKIP_PATH_CHECK'] = 'yes'
    $Process = [Diagnostics.Process]::Start($Info)
    if ($null -eq $Process) {
        throw 'Failed to start rustup-init.exe.'
    }
    try {
        if (-not $Process.WaitForExit(1800000)) {
            try { $Process.Kill() } catch {}
            try { [void]$Process.WaitForExit(5000) } catch {}
            throw 'rustup-init timed out after 30 minutes.'
        }
        if ($Process.ExitCode -ne 0) {
            throw "rustup-init exited with code $($Process.ExitCode)."
        }
    } finally {
        $Process.Dispose()
    }
}

function Install-ProjDevRust {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    Assert-ProjDevWindowsX64 -ToolName 'Rust'
    $Target = Get-ProjDevRustInstallRoot `
        -Context $Context `
        -Definition $Definition
    $ValidateInstalled = {
        param($ValidationContext, $ValidationDefinition, $InstallRoot)

        return Test-ProjDevRustInstalled `
            -Context $ValidationContext `
            -Definition $ValidationDefinition `
            -InstallRoot $InstallRoot
    }
    $Recovery = Repair-ProjDevInstallState `
        -Context $Context `
        -Definition $Definition `
        -TargetPath $Target `
        -ValidateCandidate $ValidateInstalled
    if ($Recovery.Ready) {
        return $false
    }
    $Installer = Get-ProjDevVerifiedRustupInstaller `
        -Context $Context `
        -Definition $Definition
    $Parent = Split-Path -Path $Target -Parent
    [void][IO.Directory]::CreateDirectory($Parent)
    $StagedRoot = New-ProjDevInstallWorkPath `
        -TargetPath $Target `
        -Kind 'partial'
    [void][IO.Directory]::CreateDirectory($StagedRoot)
    [void][IO.Directory]::CreateDirectory((Join-Path $StagedRoot 'cargo'))
    [void][IO.Directory]::CreateDirectory((Join-Path $StagedRoot 'rustup'))
    try {
        Write-Host (
            "[STEP] Installing Rust $($Definition.Toolchain) " +
            "($($Definition.Profile))..."
        ) -ForegroundColor Cyan
        Invoke-ProjDevRustupInstaller `
            -Definition $Definition `
            -InstallerPath ([string]$Installer.Path) `
            -InstallRoot $StagedRoot
        $Probe = Get-ProjDevRustProbe `
            -Definition $Definition `
            -InstallRoot $StagedRoot
        Write-ProjDevRustMetadata `
            -Definition $Definition `
            -Probe $Probe `
            -InstallRoot $StagedRoot `
            -RustupInitSha256 ([string]$Installer.Sha256)
        if (-not (Test-ProjDevRustInstalled `
            -Context $Context `
            -Definition $Definition `
            -InstallRoot $StagedRoot)) {
            throw 'Staged Rust installation failed validation.'
        }
        Publish-ProjDevInstallDirectory `
            -Context $Context `
            -Definition $Definition `
            -StagedPath $StagedRoot `
            -TargetPath $Target `
            -ValidatePublished $ValidateInstalled
        return $true
    } finally {
        Remove-ProjDevInstallResidues `
            -Context $Context `
            -Paths @($StagedRoot) `
            -Activity 'cleaning Rust installation work data'
    }
}
