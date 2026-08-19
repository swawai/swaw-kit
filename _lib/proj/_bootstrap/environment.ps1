Set-StrictMode -Version 2.0

$script:ProjBootstrapEnvironmentSchema = `
    'swawkit.proj-bootstrap-environment/v1'

function New-ProjBootstrapToolArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedName,
        [Parameter(Mandatory = $true)][string]$ToolchainRoot
    )

    $Path = Assert-ProjDevPathInsideDataRoot `
        -Path $Path `
        -DataRoot $ToolchainRoot `
        -Activity "publishing Bootstrap $ExpectedName"
    if ([IO.Path]::GetFileName($Path) -cne $ExpectedName) {
        throw "The Bootstrap tool has an unexpected name: $Path"
    }
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not [IO.File]::Exists($Path) -or
        $Item.Length -le 0 -or
        $Item.Length -gt 512MB -or
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The Bootstrap tool is not a bounded regular file: $Path"
    }
    return [ordered]@{
        path = $Path
        length = [long]$Item.Length
        sha256 = Get-ProjDevFileSha256 -Path $Path
    }
}

function Publish-ProjBootstrapEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Contract,
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$Scripts,
        [Parameter(Mandatory = $true)][string]$CargoPath,
        [Parameter(Mandatory = $true)][string]$CompilerPath,
        [Parameter(Mandatory = $true)][string]$LinkerPath
    )

    $Layout = Get-ProjBootstrapLayout
    $Variables = [ordered]@{}
    foreach ($Name in $Plan.Variables.Keys) {
        $Variables[[string]$Name] = $Plan.Variables[$Name]
    }
    $RustcPath = [string]$Variables['RUSTC']
    if ([string]::IsNullOrWhiteSpace($RustcPath)) {
        throw 'The Bootstrap environment did not publish RUSTC.'
    }
    $ContractRevision = 'sha256-' + (
        Get-ProjDevFileSha256 -Path $Layout.ContractPath
    )
    $Document = [ordered]@{
        schema = $script:ProjBootstrapEnvironmentSchema
        contract = [ordered]@{
            schema = [string]$Contract.Schema
            rustToolchain = [string]$Contract.RustToolchain
            msvcChannel = [string]$Contract.MsvcChannel
        }
        contractRevision = $ContractRevision
        environmentRevision = [string]$Scripts.Revision
        variables = $Variables
        pathPrefixes = [string[]]$Plan.PathPrefixes.ToArray()
        tools = [ordered]@{
            cargo = New-ProjBootstrapToolArtifact `
                -Path $CargoPath `
                -ExpectedName 'cargo.exe' `
                -ToolchainRoot $Layout.ToolchainRoot
            rustc = New-ProjBootstrapToolArtifact `
                -Path $RustcPath `
                -ExpectedName 'rustc.exe' `
                -ToolchainRoot $Layout.ToolchainRoot
            compiler = New-ProjBootstrapToolArtifact `
                -Path $CompilerPath `
                -ExpectedName 'cl.exe' `
                -ToolchainRoot $Layout.ToolchainRoot
            linker = New-ProjBootstrapToolArtifact `
                -Path $LinkerPath `
                -ExpectedName 'link.exe' `
                -ToolchainRoot $Layout.ToolchainRoot
        }
    }
    Write-ProjDevTextAtomic `
        -Path $Layout.EnvironmentPath `
        -Content (ConvertTo-ProjDevJsonText -Value $Document) `
        -ControlledRoot $Context.DataRoot
}
