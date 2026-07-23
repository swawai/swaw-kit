function Assert-EditorKitCommandSupported {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("code", "cursor")]
        [string]$Tool,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EditorCommand,

        [scriptblock]$ReadHelp = {
            param([string]$Command)

            $output = @(& $Command --help 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "Editor capability check failed with exit code $LASTEXITCODE."
            }
            return @($output | ForEach-Object { $_.ToString() })
        }
    )

    if ($Tool -ne "cursor") {
        return
    }

    $helpText = @(& $ReadHelp $EditorCommand) -join [Environment]::NewLine
    if ($helpText -notmatch "(?m)^\s*--classic(?:\s|$)") {
        throw "Cursor classic IDE launch is unsupported by '$EditorCommand'. Install Cursor 3 or newer; this command requires the '--classic' CLI option."
    }
}

function Get-EditorKitNewWindowArguments {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("code", "cursor")]
        [string]$Tool,

        [string]$Target = ""
    )

    $arguments = [Collections.Generic.List[string]]::new()
    if ($Tool -eq "cursor") {
        $arguments.Add("--classic")
    }
    $arguments.Add("--new-window")
    if (-not [string]::IsNullOrWhiteSpace($Target)) {
        $arguments.Add($Target)
    }
    return @($arguments)
}

function Get-EditorKitReuseWindowArguments {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("code", "cursor")]
        [string]$Tool,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Target
    )

    if ($Tool -eq "cursor") {
        return @("--classic", "--reuse-window", $Target)
    }
    return @("--reuse-window", $Target)
}

function Get-EditorKitOpenTargetArguments {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("code", "cursor")]
        [string]$Tool,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Target
    )

    if ($Tool -eq "cursor") {
        return @("--classic", $Target)
    }
    return @($Target)
}

function Wait-EditorNewWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EditorTool,

        [long[]]$PreviousHandles = @(),

        [Parameter(Mandatory = $true)]
        [scriptblock]$GetWindows,

        [int]$MaximumAttempts = 50,

        [int]$PollMilliseconds = 200,

        [int]$StableSamplesRequired = 4
    )

    [long]$candidateHandle = 0
    $stableSamples = 0
    for ($attempt = 0; $attempt -lt $MaximumAttempts; $attempt++) {
        if ($attempt -gt 0) {
            Start-Sleep -Milliseconds $PollMilliseconds
        }

        $windows = @(& $GetWindows $EditorTool)
        $newWindows = @($windows | Where-Object { $PreviousHandles -notcontains $_.Hwnd })
        if ($newWindows.Count -gt 1) {
            throw "Multiple editor windows appeared during launch; ownership cannot be determined."
        }
        if ($newWindows.Count -ne 1) {
            $candidateHandle = 0
            $stableSamples = 0
            continue
        }

        # Do not claim the first transient HWND immediately: another editor
        # launch may still be appearing in the same sampling window.
        $handle = [long]$newWindows[0].Hwnd
        if ($handle -eq $candidateHandle) {
            $stableSamples += 1
        } else {
            $candidateHandle = $handle
            $stableSamples = 1
        }
        if ($stableSamples -ge $StableSamplesRequired) {
            return $newWindows[0]
        }
    }

    return $null
}
