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
