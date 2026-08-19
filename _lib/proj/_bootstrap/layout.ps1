Set-StrictMode -Version 2.0

$script:ProjKernelRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Get-ProjBootstrapLayout {
    $KernelRoot = $script:ProjKernelRoot
    $ProjHome = [IO.Path]::GetFullPath((Join-Path $KernelRoot '..\..'))
    $CacheRoot = Join-Path $ProjHome 'data\proj_cache'
    $BootstrapDataRoot = Join-Path $CacheRoot 'bootstrap'
    $LauncherBuildRoot = Join-Path $BootstrapDataRoot 'build\launcher'
    $ModuleProductRoot = Join-Path $KernelRoot 'system\module'
    $ModuleBuildRoot = Join-Path $BootstrapDataRoot 'build\module'
    $DevProductRoot = Join-Path $KernelRoot 'system\dev'
    $DevBuildRoot = Join-Path $BootstrapDataRoot 'build\dev'
    return [pscustomobject][ordered]@{
        ContractPath = Join-Path $KernelRoot 'bootstrap.json'
        BootstrapEntryPath = Join-Path $KernelRoot 'bootstrap.ps1'
        BootstrapSetupPath = Join-Path $KernelRoot '_bootstrap\setup.ps1'
        KernelRoot = $KernelRoot
        ProjHome = $ProjHome
        AppRoot = Join-Path $KernelRoot '_app'
        AppBuildPath = Join-Path $KernelRoot '_app\build.ps1'
        RuntimePublishPath = Join-Path $KernelRoot '_runtime\publish.ps1'
        ModuleManifestPath = Join-Path $ModuleProductRoot 'Cargo.toml'
        ModuleBuildRoot = $ModuleBuildRoot
        ModuleCandidatePath = Join-Path $ModuleBuildRoot (
            'release\swawkit-proj-module.exe'
        )
        DevManifestPath = Join-Path $DevProductRoot 'Cargo.toml'
        DevBuildRoot = $DevBuildRoot
        DevCandidatePath = Join-Path $DevBuildRoot (
            'release\swawkit-proj-dev.exe'
        )
        RuntimeRoot = Join-Path $KernelRoot '_bin'
        RuntimeCurrentPath = Join-Path $KernelRoot '_bin\current'
        LauncherBuildPath = Join-Path $KernelRoot '_launcher\build.ps1'
        LauncherBuildRoot = $LauncherBuildRoot
        LauncherCandidatePath = Join-Path $LauncherBuildRoot (
            'release\template.proj1.exe'
        )
        LauncherTemplatePath = Join-Path $ProjHome (
            'Favorites\template.proj1.exe'
        )
        CacheRoot = $CacheRoot
        BootstrapDataRoot = $BootstrapDataRoot
        ToolchainRoot = Join-Path $BootstrapDataRoot 'toolchains'
        BuildRoot = Join-Path $BootstrapDataRoot 'build\app'
        LockRoot = Join-Path $BootstrapDataRoot '_locks'
        StatePath = Join-Path $BootstrapDataRoot 'state.json'
        EnvironmentPath = Join-Path $BootstrapDataRoot 'environment.json'
        CommandRuntimeRoot = Join-Path $BootstrapDataRoot 'command-runtimes'
    }
}

function Read-ProjBootstrapContract {
    $Layout = Get-ProjBootstrapLayout
    if (-not [IO.File]::Exists($Layout.ContractPath)) {
        throw "The Bootstrap contract is missing: $($Layout.ContractPath)"
    }
    try {
        $Contract = [IO.File]::ReadAllText(
            $Layout.ContractPath,
            [Text.Encoding]::UTF8
        ) | ConvertFrom-Json
    } catch {
        throw "Cannot parse the Bootstrap contract: $($_.Exception.Message)"
    }

    [string[]]$Expected = @(
        'schema',
        'rustToolchain',
        'msvcChannel',
        'commandRuntime'
    )
    [string[]]$Actual = @(
        $Contract.PSObject.Properties | ForEach-Object { [string]$_.Name }
    )
    foreach ($Name in $Expected) {
        if ($Actual -cnotcontains $Name) {
            throw "The Bootstrap contract is missing '$Name'."
        }
    }
    foreach ($Name in $Actual) {
        if ($Expected -cnotcontains $Name) {
            throw "The Bootstrap contract contains unknown field '$Name'."
        }
    }

    $RustToolchain = ([string]$Contract.rustToolchain).Trim().ToLowerInvariant()
    $MsvcChannel = ([string]$Contract.msvcChannel).Trim()
    if ([string]$Contract.schema -cne 'swawkit.proj-bootstrap/v2') {
        throw 'Unsupported Bootstrap contract schema.'
    }
    if ($RustToolchain -cnotmatch '^\d+\.\d+\.\d+$') {
        throw 'Bootstrap rustToolchain must be an exact Rust version.'
    }
    if ($MsvcChannel -cnotmatch '^\d+$') {
        throw 'Bootstrap msvcChannel must be a numeric Visual Studio channel.'
    }
    if ($Contract.commandRuntime -isnot [psobject]) {
        throw 'Bootstrap commandRuntime must be an object.'
    }
    [string[]]$CommandRuntimeExpected = @(
        'bunVersion',
        'bunSha256',
        'pwshVersion',
        'pwshSha256'
    )
    [string[]]$CommandRuntimeActual = @(
        $Contract.commandRuntime.PSObject.Properties |
            ForEach-Object { [string]$_.Name }
    )
    foreach ($Name in $CommandRuntimeExpected) {
        if ($CommandRuntimeActual -cnotcontains $Name) {
            throw "Bootstrap commandRuntime is missing '$Name'."
        }
    }
    foreach ($Name in $CommandRuntimeActual) {
        if ($CommandRuntimeExpected -cnotcontains $Name) {
            throw "Bootstrap commandRuntime contains unknown field '$Name'."
        }
    }
    $BunVersion = ([string]$Contract.commandRuntime.bunVersion).Trim()
    $BunSha256 = ([string]$Contract.commandRuntime.bunSha256).Trim()
    $PwshVersion = ([string]$Contract.commandRuntime.pwshVersion).Trim()
    $PwshSha256 = ([string]$Contract.commandRuntime.pwshSha256).Trim()
    foreach ($Version in @($BunVersion, $PwshVersion)) {
        if ($Version -cnotmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') {
            throw "Bootstrap commandRuntime version is invalid: '$Version'."
        }
    }
    foreach ($Sha256 in @($BunSha256, $PwshSha256)) {
        if ($Sha256 -cnotmatch '^[a-f0-9]{64}$') {
            throw 'Bootstrap commandRuntime SHA-256 is invalid.'
        }
    }
    return [pscustomobject][ordered]@{
        Schema = [string]$Contract.schema
        RustToolchain = $RustToolchain
        MsvcChannel = $MsvcChannel
        BunVersion = $BunVersion
        BunSha256 = $BunSha256
        PwshVersion = $PwshVersion
        PwshSha256 = $PwshSha256
    }
}
