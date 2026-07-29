Set-StrictMode -Version 2.0

function Add-ProjDevMsvcEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][object]$Plan
    )

    $InstallRoot = Get-ProjDevMsvcInstallRoot `
        -Context $Context `
        -Definition $Definition
    $Metadata = Get-ProjDevMsvcValidMetadata `
        -Context $Context `
        -Definition $Definition
    if ($null -eq $Metadata) {
        throw 'Cannot generate an environment from an invalid MSVC installation.'
    }
    $ToolVersion = [string]$Metadata.toolVersion
    $SdkVersion = [string]$Metadata.sdkVersion
    $VcRoot = Join-Path $InstallRoot 'VC'
    $ToolRoot = Join-Path $VcRoot "Tools\MSVC\$ToolVersion"
    $SdkRoot = Join-Path $InstallRoot 'Windows Kits\10'
    $ToolBin = Join-Path $ToolRoot 'bin\Hostx64\x64'
    $SdkBin = Join-Path $SdkRoot "bin\$SdkVersion\x64"

    $Variables = [ordered]@{
        SWAWKIT_DEV_MSVC_MODE = [string]$Definition.Mode
        SWAWKIT_DEV_MSVC_CHANNEL = [string]$Definition.Channel
        SWAWKIT_DEV_MSVC_TOOL_VERSION = $ToolVersion
        SWAWKIT_DEV_MSVC_SDK_VERSION = $SdkVersion
        SWAWKIT_DEV_MSVC_HOME = $InstallRoot
        SWAWKIT_DEV_MSVC_SIGNATURE = Get-ProjDevSha256Text -Value (
            [string]::Join("`n", [string[]]@(
                (Get-ProjDevMsvcDefinitionSignature -Definition $Definition),
                [string]$Metadata.manifestSha256,
                $ToolVersion,
                $SdkVersion
            ))
        )
        VSCMD_ARG_HOST_ARCH = 'x64'
        VSCMD_ARG_TGT_ARCH = 'x64'
        VCToolsVersion = $ToolVersion
        WindowsSDKVersion = "$SdkVersion\"
        VCToolsInstallDir = "$ToolRoot\"
        VCINSTALLDIR = "$VcRoot\"
        WindowsSdkDir = "$SdkRoot\"
        WindowsSdkBinPath = "$SdkRoot\bin\"
        WindowsSdkVerBinPath = "$SdkBin\"
        UniversalCRTSdkDir = "$SdkRoot\"
        UCRTVersion = $SdkVersion
        INCLUDE = [string]::Join(';', [string[]]@(
            (Join-Path $ToolRoot 'include')
            (Join-Path $SdkRoot "Include\$SdkVersion\ucrt")
            (Join-Path $SdkRoot "Include\$SdkVersion\shared")
            (Join-Path $SdkRoot "Include\$SdkVersion\um")
            (Join-Path $SdkRoot "Include\$SdkVersion\winrt")
            (Join-Path $SdkRoot "Include\$SdkVersion\cppwinrt")
        ))
        LIB = [string]::Join(';', [string[]]@(
            (Join-Path $ToolRoot 'lib\x64')
            (Join-Path $SdkRoot "Lib\$SdkVersion\ucrt\x64")
            (Join-Path $SdkRoot "Lib\$SdkVersion\um\x64")
        ))
    }
    foreach ($Name in $Variables.Keys) {
        Set-ProjDevEnvironmentVariable `
            -Plan $Plan `
            -Name ([string]$Name) `
            -Value ([string]$Variables[$Name])
    }
    foreach ($Path in @(
        $ToolBin,
        $SdkBin,
        (Join-Path $SdkBin 'ucrt')
    )) {
        Add-ProjDevEnvironmentPath -Plan $Plan -Path $Path
    }
}
