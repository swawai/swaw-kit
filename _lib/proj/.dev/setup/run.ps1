$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if (@($args).Count -gt 0) {
    throw '.dev.setup does not accept dynamic arguments.'
}

. (Join-Path $PSScriptRoot '_lib\bootstrap.ps1')

$Context = New-ProjDevContextFromEnvironment
$BunDefinition = Get-ProjDevBunDefinition
$MsvcDefinition = Get-ProjDevMsvcDefinition
$RustDefinition = Get-ProjDevRustDefinition
if ($null -ne $RustDefinition -and $null -eq $MsvcDefinition) {
    throw (
        'Rust V0 with the x86_64-pc-windows-msvc host requires the managed ' +
        'MSVC module.'
    )
}
if ($null -ne $BunDefinition -or
    $null -ne $MsvcDefinition -or
    $null -ne $RustDefinition) {
    Assert-ProjDevWindowsX64 -ToolName 'Managed development tools'
}
$ActiveGenerationId = [string]$env:SWAWKIT_DEV_GENERATION_ID
$ActiveEnvironment = Assert-ProjDevActiveEnvironmentCompatible `
    -Context $Context

# Temporary migration fence: remove each entry when its directory module lands.
$PendingModules = foreach ($Pending in @(
    [pscustomobject]@{ Name = 'uv'; Variable = 'SWAWKIT_PROJ_UV_MODE' },
    [pscustomobject]@{ Name = 'python'; Variable = 'SWAWKIT_PROJ_PYTHON_MODE' },
    [pscustomobject]@{ Name = 'pwsh'; Variable = 'SWAWKIT_PROJ_PWSH_MODE' },
    [pscustomobject]@{ Name = 'go'; Variable = 'SWAWKIT_PROJ_GO_MODE' }
)) {
    $Mode = [string][Environment]::GetEnvironmentVariable(
        [string]$Pending.Variable,
        [EnvironmentVariableTarget]::Process
    )
    if (-not [string]::IsNullOrWhiteSpace($Mode) -and
        $Mode.Trim().ToLowerInvariant() -cne 'disabled') {
        [string]$Pending.Name
    }
}
if (@($PendingModules).Count -gt 0) {
    Write-Warning (
        '.dev.setup does not yet handle these enabled declarations: ' +
        "$([string]::Join(', ', $PendingModules))."
    )
}

$SetupLock = Enter-ProjDevFileLock -Path $Context.SetupLockPath
try {
    $Plan = New-ProjDevEnvironmentPlan -Context $Context
    $BunChanged = $false
    $MsvcChanged = $false
    $RustChanged = $false
    if ($null -ne $BunDefinition) {
        $BunChanged = Install-ProjDevBun `
            -Context $Context `
            -Definition $BunDefinition
        Add-ProjDevBunEnvironment `
            -Context $Context `
            -Definition $BunDefinition `
            -Plan $Plan
    }
    if ($null -ne $MsvcDefinition) {
        $MsvcChanged = Install-ProjDevMsvc `
            -Context $Context `
            -Definition $MsvcDefinition
        Add-ProjDevMsvcEnvironment `
            -Context $Context `
            -Definition $MsvcDefinition `
            -Plan $Plan
    }
    if ($null -ne $RustDefinition) {
        $RustChanged = Install-ProjDevRust `
            -Context $Context `
            -Definition $RustDefinition
        Add-ProjDevRustEnvironment `
            -Context $Context `
            -Definition $RustDefinition `
            -Plan $Plan
    }

    $Scripts = ConvertTo-ProjDevEnvironmentScripts -Plan $Plan
    $EnvironmentChanged = Publish-ProjDevEnvironmentScripts `
        -Context $Context `
        -Scripts $Scripts

    if ($null -ne $BunDefinition -and $BunChanged) {
        Write-Host "[OK] Bun $($BunDefinition.Version) installed and configured." `
            -ForegroundColor Green
    } elseif ($null -ne $BunDefinition) {
        Write-Host "[OK] Bun $($BunDefinition.Version) is ready." `
            -ForegroundColor Green
    }
    if ($null -ne $MsvcDefinition -and $MsvcChanged) {
        Write-Host (
            "[OK] MSVC channel $($MsvcDefinition.Channel) installed and configured."
        ) -ForegroundColor Green
    } elseif ($null -ne $MsvcDefinition) {
        Write-Host (
            "[OK] MSVC channel $($MsvcDefinition.Channel) is ready."
        ) -ForegroundColor Green
    }
    if ($null -ne $RustDefinition -and $RustChanged) {
        Write-Host (
            "[OK] Rust $($RustDefinition.Toolchain) installed and configured."
        ) -ForegroundColor Green
    } elseif ($null -ne $RustDefinition) {
        Write-Host (
            "[OK] Rust $($RustDefinition.Toolchain) is ready."
        ) -ForegroundColor Green
    }
    if ($null -eq $BunDefinition -and
        $null -eq $MsvcDefinition -and
        $null -eq $RustDefinition) {
        Write-Host '[OK] The base development environment is ready.' `
            -ForegroundColor Green
    }
    if ($null -ne $BunDefinition) {
        Write-ProjDevBunTrustWarning `
            -Context $Context `
            -Definition $BunDefinition
    }
    if ($EnvironmentChanged) {
        Write-Host "[ENV] $($Context.EnvCmdPath)" -ForegroundColor DarkGray
        Write-Host "[ENV] $($Context.EnvPs1Path)" -ForegroundColor DarkGray
    }
    if ($ActiveEnvironment -and
        $ActiveGenerationId -cne [string]$Scripts.GenerationId) {
        Write-Warning (
            'The parent shell still has an older environment generation. ' +
            'Start a new project shell to use the published environment.'
        )
    }
} finally {
    $SetupLock.Dispose()
}

$global:LASTEXITCODE = 0
