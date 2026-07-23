[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("code", "cursor")]
    [string]$Tool,

    [string]$ForbiddenEnvironmentVariable = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "windows.ps1")
. (Join-Path $PSScriptRoot "launch.ps1")

function Assert-EditorBootstrapEnvironmentVariableAbsent {
    param([string]$VariableName)

    if ([string]::IsNullOrWhiteSpace($VariableName)) {
        return
    }
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($VariableName))) {
        throw "Close all editor windows, then launch from a normal shell or File Explorer; this shell already carries scoped environment variable '$VariableName'."
    }
}

function Invoke-EditorBootstrap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("code", "cursor")]
        [string]$EditorTool,

        [string]$EditorCommand = "",

        [string]$ForbiddenEnvironmentVariable = "",

        [scriptblock]$GetWindows = {
            param([string]$SelectedTool)
            Get-EditorKitWindows $SelectedTool
        },

        [scriptblock]$RunEditor = {
            param([string]$Command, [string[]]$Arguments)
            & $Command @Arguments
            if ($LASTEXITCODE -ne 0) {
                throw "Editor command failed with exit code $LASTEXITCODE."
            }
        },

        [scriptblock]$AssertCommandSupported = {
            param([string]$SelectedTool, [string]$Command)
            Assert-EditorKitCommandSupported -Tool $SelectedTool -EditorCommand $Command
        },

        [scriptblock]$AssertEnvironment = {
            param([string]$VariableName)
            Assert-EditorBootstrapEnvironmentVariableAbsent $VariableName
        }
    )

    if ([string]::IsNullOrWhiteSpace($EditorCommand)) {
        $editor = Get-Command $EditorTool -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $EditorCommand = $editor.Source
    }
    & $AssertCommandSupported $EditorTool $EditorCommand

    $previousWindows = @(& $GetWindows $EditorTool)
    if ($previousWindows.Count -gt 0) {
        return "existing"
    }

    & $AssertEnvironment $ForbiddenEnvironmentVariable
    $launchArguments = @(Get-EditorKitNewWindowArguments -Tool $EditorTool)
    & $RunEditor $EditorCommand $launchArguments
    $newWindow = Wait-EditorNewWindow `
        -EditorTool $EditorTool `
        -PreviousHandles @() `
        -GetWindows $GetWindows
    if (-not $newWindow) {
        throw "The editor bootstrap window did not become ready in time."
    }

    return "created"
}

if ($MyInvocation.InvocationName -ne ".") {
    try {
        $result = Invoke-EditorBootstrap `
            -EditorTool $Tool `
            -ForbiddenEnvironmentVariable $ForbiddenEnvironmentVariable
        if ($result -eq "created") {
            exit 10
        }
        exit 0
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)"
        exit 1
    }
}
