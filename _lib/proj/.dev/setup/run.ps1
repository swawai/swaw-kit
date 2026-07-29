$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if (@($args).Count -gt 0) {
    throw '.dev.setup does not accept dynamic arguments.'
}

. (Join-Path $PSScriptRoot '_lib\bootstrap.ps1')

$Context = New-ProjDevContextFromEnvironment
$BunDefinition = Get-ProjDevBunDefinition
if ($null -ne $BunDefinition) {
    Assert-ProjDevWindowsX64 -ToolName 'Bun'
}
$ActiveGenerationId = [string]$env:SWAWKIT_DEV_GENERATION_ID
$ActiveEnvironment = Assert-ProjDevActiveEnvironmentCompatible `
    -Context $Context

# Temporary migration fence: remove each entry when its directory module lands.
$PendingModules = foreach ($Pending in @(
    [pscustomobject]@{ Name = 'uv'; Variable = 'SWAWKIT_PROJ_UV_MODE' },
    [pscustomobject]@{ Name = 'python'; Variable = 'SWAWKIT_PROJ_PYTHON_MODE' },
    [pscustomobject]@{ Name = 'rust'; Variable = 'SWAWKIT_PROJ_RUST_MODE' },
    [pscustomobject]@{ Name = 'msvc'; Variable = 'SWAWKIT_PROJ_MSVC_MODE' },
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
        '.dev.setup currently configures Bun only; enabled declarations ' +
        "not handled in this slice: $([string]::Join(', ', $PendingModules))."
    )
}

$SetupLock = Enter-ProjDevFileLock -Path $Context.SetupLockPath
try {
    $Plan = New-ProjDevEnvironmentPlan -Context $Context
    $BunChanged = $false
    if ($null -ne $BunDefinition) {
        $BunChanged = Install-ProjDevBun `
            -Context $Context `
            -Definition $BunDefinition
        Add-ProjDevBunEnvironment `
            -Context $Context `
            -Definition $BunDefinition `
            -Plan $Plan
    }

    $Scripts = ConvertTo-ProjDevEnvironmentScripts -Plan $Plan
    $EnvironmentChanged = Publish-ProjDevEnvironmentScripts `
        -Context $Context `
        -Scripts $Scripts

    if ($null -eq $BunDefinition) {
        Write-Host '[OK] Bun is disabled; the base development environment is ready.' `
            -ForegroundColor Green
    } elseif ($BunChanged) {
        Write-Host "[OK] Bun $($BunDefinition.Version) installed and configured." `
            -ForegroundColor Green
    } else {
        Write-Host "[OK] Bun $($BunDefinition.Version) is ready." `
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
