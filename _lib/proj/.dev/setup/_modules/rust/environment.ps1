Set-StrictMode -Version 2.0

function Get-ProjDevRustRuntimeSignature {
    param(
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][object]$Metadata
    )

    return Get-ProjDevSha256Text -Value ([string]::Join("`n", [string[]]@(
        (Get-ProjDevRustDefinitionSignature -Definition $Definition)
        [string]$Metadata.rustupInitSha256
        [string]$Metadata.rustupVersion
        [string]$Metadata.rustcVersion
        [string]$Metadata.rustcCommit
        [string]$Metadata.cargoVersion
    )))
}

function Add-ProjDevRustEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][object]$Plan
    )

    $InstallRoot = Get-ProjDevRustInstallRoot `
        -Context $Context `
        -Definition $Definition
    $Metadata = Get-ProjDevRustValidMetadata `
        -Context $Context `
        -Definition $Definition
    if ($null -eq $Metadata) {
        throw 'Cannot generate an environment from an invalid Rust installation.'
    }
    $CargoHome = Join-Path $InstallRoot 'cargo'
    $RustupHome = Join-Path $InstallRoot 'rustup'
    $Variables = [ordered]@{
        SWAWKIT_DEV_RUST_MODE = [string]$Definition.Mode
        SWAWKIT_DEV_RUST_TOOLCHAIN = [string]$Definition.Toolchain
        SWAWKIT_DEV_RUST_TOOLCHAIN_NAME = [string]$Definition.ToolchainName
        SWAWKIT_DEV_RUST_PROFILE = [string]$Definition.Profile
        SWAWKIT_DEV_RUST_HOST = [string]$Definition.Host
        SWAWKIT_DEV_RUST_RUSTC_VERSION = [string]$Metadata.rustcVersion
        SWAWKIT_DEV_RUST_CARGO_VERSION = [string]$Metadata.cargoVersion
        SWAWKIT_DEV_RUST_HOME = $InstallRoot
        SWAWKIT_DEV_RUST_SIGNATURE = Get-ProjDevRustRuntimeSignature `
            -Definition $Definition `
            -Metadata $Metadata
        RUSTUP_HOME = $RustupHome
        CARGO_HOME = $CargoHome
    }
    foreach ($Name in Get-ProjDevRustAmbientOverrideNames) {
        $Variables[$Name] = $null
    }
    foreach ($Name in $Variables.Keys) {
        Set-ProjDevEnvironmentVariable `
            -Plan $Plan `
            -Name ([string]$Name) `
            -Value $Variables[$Name]
    }
    Add-ProjDevEnvironmentPath `
        -Plan $Plan `
        -Path (Join-Path $CargoHome 'bin')
}

function Assert-ProjDevRustEnvironmentCurrent {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    $InstallRoot = Get-ProjDevRustInstallRoot `
        -Context $Context `
        -Definition $Definition
    $Metadata = Get-ProjDevRustValidMetadata `
        -Context $Context `
        -Definition $Definition
    if ($null -eq $Metadata) {
        throw 'The generated Rust environment has no valid installation.'
    }
    $ExpectedCargoHome = Join-Path $InstallRoot 'cargo'
    $ExpectedRustupHome = Join-Path $InstallRoot 'rustup'
    $ExpectedSignature = Get-ProjDevRustRuntimeSignature `
        -Definition $Definition `
        -Metadata $Metadata
    $ValuesMatch =
        [string]$env:SWAWKIT_DEV_RUST_MODE -ceq
            [string]$Definition.Mode -and
        [string]$env:SWAWKIT_DEV_RUST_TOOLCHAIN -ceq
            [string]$Definition.Toolchain -and
        [string]$env:SWAWKIT_DEV_RUST_TOOLCHAIN_NAME -ceq
            [string]$Definition.ToolchainName -and
        [string]$env:SWAWKIT_DEV_RUST_PROFILE -ceq
            [string]$Definition.Profile -and
        [string]$env:SWAWKIT_DEV_RUST_HOST -ceq
            [string]$Definition.Host -and
        [string]$env:SWAWKIT_DEV_RUST_SIGNATURE -ceq $ExpectedSignature
    if (-not $ValuesMatch) {
        throw (
            'The generated Rust environment does not match the project ' +
            "declaration. Run '$($Context.EntryCommand) .dev.setup'."
        )
    }
    foreach ($Name in Get-ProjDevRustAmbientOverrideNames) {
        $Value = [Environment]::GetEnvironmentVariable($Name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            throw "The generated Rust environment retained ambient $Name."
        }
    }
    foreach ($Pair in @(
        [pscustomobject]@{
            Actual = [string]$env:CARGO_HOME
            Expected = $ExpectedCargoHome
        }
        [pscustomobject]@{
            Actual = [string]$env:RUSTUP_HOME
            Expected = $ExpectedRustupHome
        }
    )) {
        if ([string]::IsNullOrWhiteSpace($Pair.Actual) -or
            -not (Get-ProjDevCanonicalPath -Path $Pair.Actual).Equals(
                (Get-ProjDevCanonicalPath -Path $Pair.Expected),
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'The generated Rust home directories are stale.'
        }
    }
    $CargoCommand = Get-Command cargo.exe `
        -CommandType Application `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $ExpectedCargo = Join-Path $ExpectedCargoHome 'bin\cargo.exe'
    if ($null -eq $CargoCommand -or
        -not (Get-ProjDevCanonicalPath -Path $CargoCommand.Source).Equals(
            (Get-ProjDevCanonicalPath -Path $ExpectedCargo),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw (
            'The managed Cargo proxy is not active. Exit this shell and ' +
            'start a new project shell.'
        )
    }
}

function Assert-ProjDevRustReady {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition
    )

    if ($null -eq (Get-ProjDevRustValidMetadata `
        -Context $Context `
        -Definition $Definition)) {
        throw (
            'The managed Rust installation is missing or inconsistent. Run ' +
            "'$($Context.EntryCommand) .dev.setup'."
        )
    }
}
