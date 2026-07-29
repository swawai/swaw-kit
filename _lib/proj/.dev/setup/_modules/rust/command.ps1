Set-StrictMode -Version 2.0

function Invoke-ProjDevRustCommand {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('cargo.exe', 'rustc.exe')]
        [string]$ExecutableName,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments
    )

    if ($Arguments.Count -gt 0 -and
        [string]$Arguments[0] -cmatch '^\+') {
        throw (
            'Swaw Kit owns the Rust toolchain selection; +toolchain ' +
            'overrides are not allowed. Change SWAWKIT_PROJ_RUST_TOOLCHAIN ' +
            "and run 'swawkit .dev.setup'."
        )
    }
    $Context = New-ProjDevContextFromEnvironment
    $Definition = Get-ProjDevRustDefinition
    if ($null -eq $Definition) {
        throw (
            'Rust is disabled for this project. Set SWAWKIT_PROJ_RUST_MODE=' +
            "rustup and run '$($Context.EntryCommand) .dev.setup'."
        )
    }
    $MsvcDefinition = Get-ProjDevMsvcDefinition
    if ($null -eq $MsvcDefinition) {
        throw (
            'Rust V0 requires the managed MSVC environment. Set ' +
            'SWAWKIT_PROJ_MSVC_MODE=managed and run ' +
            "'$($Context.EntryCommand) .dev.setup'."
        )
    }
    Assert-ProjDevWindowsX64 -ToolName 'Rust'
    $AlreadyActive = Assert-ProjDevActiveEnvironmentCompatible `
        -Context $Context
    Assert-ProjDevMsvcReady `
        -Context $Context `
        -Definition $MsvcDefinition
    Assert-ProjDevRustReady `
        -Context $Context `
        -Definition $Definition
    Import-ProjDevGeneratedEnvironment `
        -Context $Context `
        -AlreadyActive $AlreadyActive | Out-Null
    Assert-ProjDevMsvcEnvironmentCurrent `
        -Context $Context `
        -Definition $MsvcDefinition
    Assert-ProjDevRustEnvironmentCurrent `
        -Context $Context `
        -Definition $Definition

    $InstallRoot = Get-ProjDevRustInstallRoot `
        -Context $Context `
        -Definition $Definition
    $Executable = Resolve-ProjDevChildPath `
        -Root $InstallRoot `
        -RelativePath (
            "rustup\toolchains\$($Definition.ToolchainName)\" +
            "bin\$ExecutableName"
        ) `
        -Description 'Rust command executable'
    return Invoke-ProjConsoleProcess `
        -Executable $Executable `
        -Arguments $Arguments `
        -WorkingDirectory $Context.InvocationDirectory
}
