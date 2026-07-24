[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("code", "cursor")]
    [string]$Tool,

    [switch]$ReuseBootstrapWindow
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\editor_kit\launch.ps1")

function Get-RemoteKitEditorLaunchArguments {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("code", "cursor")]
        [string]$Editor,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EditorTarget,

        [string]$EditorRemoteAuthority = "",

        [switch]$ReuseWindow
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    if ($Editor -eq "cursor") {
        $arguments.Add("--classic")
    }
    if ($ReuseWindow) {
        $arguments.Add("--reuse-window")
    }
    if (-not [string]::IsNullOrWhiteSpace($EditorRemoteAuthority)) {
        $arguments.Add("--remote=$EditorRemoteAuthority")
    }
    $arguments.Add($EditorTarget)
    return @($arguments)
}

if ($MyInvocation.InvocationName -ne ".") {
    try {
        $target = [Environment]::GetEnvironmentVariable("WIN_RUN_REMOTE_EDITOR_TARGET")
        $remoteAuthority = [Environment]::GetEnvironmentVariable("WIN_RUN_REMOTE_EDITOR_AUTHORITY")
        [Environment]::SetEnvironmentVariable("WIN_RUN_REMOTE_EDITOR_TARGET", $null, "Process")
        [Environment]::SetEnvironmentVariable("WIN_RUN_REMOTE_EDITOR_AUTHORITY", $null, "Process")
        if ([string]::IsNullOrWhiteSpace($target)) {
            throw "Remote editor target was not provided by the Remote Kit."
        }

        $editorCommand = Get-Command `
            -Name $Tool `
            -CommandType Application `
            -ErrorAction Stop |
            Select-Object -First 1
        Assert-EditorKitCommandSupported `
            -Tool $Tool `
            -EditorCommand ([string]$editorCommand.Source)
        $arguments = Get-RemoteKitEditorLaunchArguments `
            -Editor $Tool `
            -EditorTarget $target `
            -EditorRemoteAuthority $remoteAuthority `
            -ReuseWindow:$ReuseBootstrapWindow
        & ([string]$editorCommand.Source) @arguments
        exit $LASTEXITCODE
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)"
        exit 1
    }
}
